#!/usr/bin/env python3
"""Extract a bounded, redacted conversation digest from a Copilot CLI session.

Copilot CLI's `sessionEnd` hook passes a JSON payload on stdin shaped like:

    {"sessionId": "...", "timestamp": 1784982920820, "cwd": "...", "reason": "complete"}

No transcript content and no argv arguments are provided -- the hook only
learns the session's id. The full conversation lives separately, in
`~/.copilot/session-state/<sessionId>/events.jsonl` (one JSON object per
line, keys `data`, `id`, `parentId`, `timestamp`, `type`; verified against
the real event schema written by Copilot CLI 1.0.75, both interactively and
in this project's own probe sessions -- `event["data"]["content"]` for
`user.message` / `assistant.message` was always a plain string across the
corpus checked). Before this module, `copilot-session-review.sh` never read
stdin at all, so the reviewer it spawns had zero information about what
happened in the session it was asked to review -- a paid model call that,
by construction, could never learn anything (this project's ninth instance
of "a component that exits 0 while doing nothing").

This module is the single place that resolves a Copilot session id to its
transcript file, extracts the user/assistant turns, bounds their size, and
redacts credential-shaped substrings, so a caller (the hook script) never
has to re-derive any of that.

Size cap
--------
MAX_DIGEST_CHARS defaults to 20,000 characters (~5,000 tokens at a ~4
chars/token rule of thumb). This review already costs one paid model call
per qualifying session end (see copilot-session-review.sh); the digest is
one section of that prompt alongside MEMORY.md/USER.md/skill-directory
scanning instructions and Coach signals, so it is sized to stay a minority
of the total prompt rather than dominate it. Truncation drops the OLDEST
messages first (see build_digest) -- the most recent exchanges are the ones
most likely to contain corrections and decisions worth persisting, and the
oldest ones have already had their chance to be reviewed in a prior cycle.

Redaction
---------
redact_secrets() reuses scan-threats.py's own THREAT_PATTERNS table (the
credential-shaped categories only) rather than keeping a second copy of
those regexes -- this project's CLAUDE.md flags duplicated logic as its
single most recurring defect class. A raw transcript can contain anything
the user typed or pasted, including secrets, and this digest is about to be
embedded in a prompt sent to a model; the prompt's own rules already say
"Never save secrets, tokens, API keys, passwords, or personal data," which
applies just as much to what gets *sent* as to what gets *written*. The
behavioral categories (prompt_injection, data_exfiltration,
shell_injection_in_content, encoded_payloads) are deliberately NOT redacted:
the transcript section is already framed as untrusted data, not
instructions (see copilot-session-review.sh), and silently stripping an
attempted injection would just hide the fact that one was attempted.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

MAX_DIGEST_CHARS = 20_000

_SECRET_CATEGORIES = (
    "api_keys_and_tokens",
    "jwt_tokens",
    "private_keys_and_connection_strings",
)

_scan_threats_module = None


def _scan_threats():
    """Lazily load scan-threats.py (sibling of this file's parent dir).

    Its filename has a hyphen, so it cannot be `import`ed by name; this is
    the same technique persist-proposal.py's neighbors use for lib/ modules,
    extended to reach one directory up.
    """
    global _scan_threats_module
    if _scan_threats_module is None:
        path = Path(__file__).resolve().parent.parent / "scan-threats.py"
        spec = importlib.util.spec_from_file_location("sl_scan_threats", path)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load scan-threats.py from {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _scan_threats_module = module
    return _scan_threats_module


def redact_secrets(text: str) -> str:
    """Replace credential-shaped substrings with a `[REDACTED:<category>]` marker."""
    if not text:
        return text
    module = _scan_threats()
    redacted = text
    for category in _SECRET_CATEGORIES:
        for pattern in module.THREAT_PATTERNS.get(category, []):
            try:
                redacted = re.sub(pattern, f"[REDACTED:{category}]", redacted)
            except re.error:
                continue
    return redacted


def resolve_copilot_state_root(env: "dict[str, str] | None" = None) -> Path:
    """Resolve the Copilot CLI config/state root (normally ~/.copilot).

    Copilot CLI does not document (per `copilot --help`) any environment
    variable or config setting for relocating this directory -- only
    COPILOT_ALLOW_ALL is documented, and it is unrelated. SL_COPILOT_HOME is
    this project's OWN override, for tests and debugging only; it is not a
    Copilot-native variable and must never be presented as one.
    """
    env = os.environ if env is None else env
    override = env.get("SL_COPILOT_HOME")
    if override:
        return Path(override)
    home = env.get("HOME")
    if not home:
        raise RuntimeError(
            "cannot resolve Copilot state root: $HOME is unset and "
            "SL_COPILOT_HOME is not set"
        )
    return Path(home) / ".copilot"


def session_state_dir(session_id: str, env: "dict[str, str] | None" = None) -> Path:
    return resolve_copilot_state_root(env) / "session-state" / session_id


def find_events_file(session_id: str, env: "dict[str, str] | None" = None) -> "Path | None":
    if not session_id:
        return None
    candidate = session_state_dir(session_id, env) / "events.jsonl"
    return candidate if candidate.is_file() else None


def _iter_events(events_path: Path):
    with open(events_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def summarize_events(events_path: Path) -> "tuple[list[tuple[str, str]], int]":
    """Return (ordered (role, content) messages, total parseable events seen).

    Only `user.message` / `assistant.message` events with a non-empty string
    `data.content` become messages -- every other event type (hook.*,
    session.*, tool.*, subagent.*, skill.invoked, ...) is telemetry, not
    conversation, and is skipped. `total` counts every line that parsed as
    JSON regardless of type, so a caller can distinguish "file was empty or
    entirely unparseable" from "file had events, just none worth reviewing".
    """
    messages: "list[tuple[str, str]]" = []
    total = 0
    for event in _iter_events(events_path):
        total += 1
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        data = event.get("data")
        if event_type not in ("user.message", "assistant.message") or not isinstance(data, dict):
            continue
        content = data.get("content")
        if isinstance(content, str) and content:
            role = "User" if event_type == "user.message" else "Assistant"
            messages.append((role, content))
    return messages, total


def build_digest(messages: "list[tuple[str, str]]", max_chars: int = MAX_DIGEST_CHARS) -> str:
    """Render messages oldest-to-newest as "Role: content" blocks, keeping the
    most recent ones and truncating the OLDEST first once max_chars is
    exceeded. A single message larger than max_chars is hard-truncated from
    its start (keeping its tail, the same "keep the most recent" bias) so
    one oversized turn never produces an empty digest.
    """
    if not messages:
        return ""

    lines = [f"{role}: {content}" for role, content in messages]
    kept: "list[str]" = []
    total = 0
    for line in reversed(lines):
        cost = len(line) + 2  # + the blank-line separator joined below
        if kept and total + cost > max_chars:
            break
        kept.append(line)
        total += cost
    kept.reverse()

    dropped = len(lines) - len(kept)
    digest = "\n\n".join(kept)
    if len(digest) > max_chars:
        digest = digest[-max_chars:]
    if dropped:
        digest = f"[... {dropped} earlier message(s) truncated ...]\n\n{digest}"
    return digest


def build_session_digest(
    session_id: str,
    env: "dict[str, str] | None" = None,
    max_chars: int = MAX_DIGEST_CHARS,
) -> "tuple[str, str]":
    """Resolve + extract + redact in one call.

    Returns (digest, failure_reason). Exactly one is non-empty: digest is
    "" whenever the transcript could not be found, read, or parsed into any
    messages -- failure_reason then explains why, for the caller to log
    visibly. Never raises for expected degraded conditions (missing
    session id, missing directory, missing/empty/garbled file); it does not
    catch RuntimeError from resolve_copilot_state_root (no $HOME and no
    override) or OSError from a permissions problem, since those are
    environment misconfigurations the caller should see, not silently
    swallow.
    """
    if not session_id:
        return "", "unavailable (no sessionId in sessionEnd payload)"

    events_path = find_events_file(session_id, env)
    if events_path is None:
        state_dir = session_state_dir(session_id, env)
        return "", f"unavailable (events.jsonl not found under {state_dir})"

    messages, total = summarize_events(events_path)
    if not messages:
        if total == 0:
            return "", f"empty (0 parseable events in {events_path})"
        return "", f"has no user/assistant messages ({total} other event(s) in {events_path})"

    digest = build_digest(messages, max_chars=max_chars)
    return redact_secrets(digest), ""


def _log_failure(log_file: "str | None", reason: str) -> None:
    if not log_file:
        return
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"{ts} copilot-session-review: transcript {reason}\n")
    except OSError:
        # persist-failures.log itself being unwritable is a separate,
        # already-fatal problem for the whole pipeline; nothing useful to
        # do here besides not crashing the transcript step over it.
        pass


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(
        description="Print a bounded, redacted transcript digest for a Copilot CLI session."
    )
    parser.add_argument("session_id", nargs="?", default="")
    parser.add_argument("--home", default=None, help="override for SL_COPILOT_HOME (testing)")
    parser.add_argument("--max-chars", type=int, default=MAX_DIGEST_CHARS)
    parser.add_argument(
        "--log-file",
        default=None,
        help="append a visible failure line here when the transcript is unavailable/empty",
    )
    args = parser.parse_args(argv)

    env = dict(os.environ)
    if args.home:
        env["SL_COPILOT_HOME"] = args.home

    try:
        digest, failure_reason = build_session_digest(
            args.session_id, env=env, max_chars=args.max_chars
        )
    except RuntimeError as exc:
        _log_failure(args.log_file, f"unavailable ({exc})")
        return 0

    if failure_reason:
        _log_failure(args.log_file, failure_reason)
        return 0

    sys.stdout.write(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
