#!/usr/bin/env python3
"""
scan-threats.py
Security scanner for memory and skill writes.

Scans content for prompt injection, credential leaks, data exfiltration
URLs, and encoded payloads before they are persisted to memory or skill
stores. Prevents malicious content from persisting across sessions.

Usage:
    python3 scan-threats.py [--scope strict|relaxed] <file>
    echo "content" | python3 scan-threats.py [--scope strict|relaxed] -

Exit codes:
    0 - Clean (no threats found)
    1 - Threats found (content should be blocked)
    2 - Usage error

Adapted from NousResearch Hermes Agent threat_patterns.py (21 patterns).
"""

import json
import re
import sys
from typing import TextIO

# ---------------------------------------------------------------------------
# Threat pattern definitions (21 patterns, 5 categories)
# ---------------------------------------------------------------------------

THREAT_PATTERNS: dict[str, list[str]] = {
    "api_keys_and_tokens": [
        # Generic API key / secret key assignments
        r"(?i)(api[_-]?key|apikey)\s*[:=]\s*['\"]?[a-zA-Z0-9_\-]{20,}",
        r"(?i)(secret[_-]?key|secretkey)\s*[:=]\s*['\"]?[a-zA-Z0-9_\-]{20,}",
        r"(?i)bearer\s+[a-zA-Z0-9_\-\.]{20,}",
        # Anthropic / OpenAI keys
        r"sk-ant-[a-zA-Z0-9_\-]{20,}",
        r"sk-[a-zA-Z0-9]{20,}",
        # GitHub tokens
        r"gh[ps]_[a-zA-Z0-9]{36,}",
        r"github_pat_[a-zA-Z0-9_]{22,}",
        # AWS credentials
        r"AKIA[A-Z0-9]{16}",
        r"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*['\"]?[a-zA-Z0-9/+]{40}",
        # Generic password patterns
        r"(?i)(password|passwd|pwd)\s*[:=]\s*['\"][^\s'\"]{8,}['\"]",
    ],

    "jwt_tokens": [
        r"eyJ[a-zA-Z0-9_\-]{10,}\.eyJ[a-zA-Z0-9_\-]{10,}\.[a-zA-Z0-9_\-]{10,}",
    ],

    "private_keys_and_connection_strings": [
        r"-----BEGIN\s+(RSA|EC|DSA|OPENSSH)\s+PRIVATE\s+KEY-----",
        r"(?i)(postgres|mysql|mongodb|redis)://[^\s]{10,}",
    ],

    "prompt_injection": [
        r"(?i)ignore\s+(all\s+)?previous\s+instructions",
        r"(?i)you\s+are\s+now\s+(?:a|an|in)\s+(?:different|new|unrestricted)",
        r"(?i)system\s*:\s*you\s+are",
        r"(?i)disregard\s+(?:all\s+)?(?:prior|previous|above)",
    ],

    "data_exfiltration": [
        r"(?i)(?:curl|wget|fetch)\s+https?://[^\s]+\?.*(?:key|token|secret|password)",
        r"(?i)(?:send|post|upload)\s+(?:to|this)\s+(?:my|the)\s+(?:server|endpoint|webhook)",
    ],

    "shell_injection_in_content": [
        r"(?i)\$\(.*(?:curl|wget|nc|bash|sh|python).*\)",
        r"(?i)`.*(?:curl|wget|nc|bash|sh|python).*`",
    ],

    "encoded_payloads": [
        r"\beval\s*\(",
        r"\bexec\s*\(",
        r"base64\s+(?:decode|--decode|-d)",
        r"\batob\s*\(",
        r"String\.fromCharCode",
        r"\\x[0-9a-fA-F]{2}(\\x[0-9a-fA-F]{2}){3,}",
    ],
}

# In "relaxed" scope, skip these categories (for contexts where inline
# shell examples are expected, like skill scripts/).
RELAXED_SKIP = {"encoded_payloads", "shell_injection_in_content"}


def scan_for_threats(
    content: str,
    scope: str = "strict",
) -> list[dict]:
    """Scan content for threat patterns.

    Args:
        content: The text to scan.
        scope: "strict" (all patterns) or "relaxed" (skip shell/encoded).

    Returns:
        List of finding dicts with keys: category, pattern_preview,
        match_preview, position.
    """
    findings: list[dict] = []

    for category, patterns in THREAT_PATTERNS.items():
        if scope == "relaxed" and category in RELAXED_SKIP:
            continue

        for pattern in patterns:
            try:
                for match in re.finditer(pattern, content):
                    # Truncate match text for safety -- never echo full
                    # credentials even in scan output
                    match_text = match.group()
                    if len(match_text) > 20:
                        match_text = match_text[:20] + "..."
                    findings.append({
                        "category": category,
                        "pattern_preview": (
                            pattern[:40] + "..."
                            if len(pattern) > 40
                            else pattern
                        ),
                        "match_preview": match_text,
                        "position": match.start(),
                    })
            except re.error:
                # Skip malformed patterns silently
                continue

    return findings


def scan_file(source: TextIO, scope: str = "strict") -> list[dict]:
    """Read all content from a file-like object and scan it."""
    content = source.read()
    return scan_for_threats(content, scope=scope)


def main() -> int:
    """CLI entry point."""
    scope = "strict"
    file_path = None

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--scope" and i + 1 < len(args):
            scope = args[i + 1]
            if scope not in ("strict", "relaxed"):
                print(
                    f"Error: scope must be 'strict' or 'relaxed', got '{scope}'",
                    file=sys.stderr,
                )
                return 2
            i += 2
        elif args[i] in ("--help", "-h"):
            print(__doc__.strip())
            return 0
        else:
            file_path = args[i]
            i += 1

    # Read from file or stdin
    if file_path is None or file_path == "-":
        findings = scan_file(sys.stdin, scope=scope)
    else:
        try:
            with open(file_path, "r") as f:
                findings = scan_file(f, scope=scope)
        except FileNotFoundError:
            print(f"Error: file not found: {file_path}", file=sys.stderr)
            return 2
        except PermissionError:
            print(f"Error: permission denied: {file_path}", file=sys.stderr)
            return 2

    if not findings:
        return 0

    # Output findings as JSON lines
    for finding in findings:
        print(json.dumps(finding))

    print(
        f"\n[THREAT SCAN] {len(findings)} threat(s) detected. "
        f"Content should be BLOCKED.",
        file=sys.stderr,
    )

    return 1


if __name__ == "__main__":
    sys.exit(main())
