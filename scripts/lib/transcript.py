#!/usr/bin/env python3
"""Extract a bounded, redacted conversation digest from a Copilot CLI or
Claude Code session -- both harnesses share this module (P0b: the Claude
Code path had the identical "reviewer sees no transcript" defect as
Copilot's, fixed in P0; see the harness-specific sections below and each
build_*_session_digest()'s docstring for what is shared vs. harness-specific
and why).

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

Claude Code path (P0b)
-----------------------
`session-review.sh`'s Stop hook payload carries `transcript_path`
(scripts/lib/hook-input.sh already parsed this field; nothing previously
read it) pointing at Claude Code's OWN transcript file,
`~/.claude/projects/<project-slug>/<sessionId>.jsonl` -- a COMPLETELY
different schema from Copilot's `events.jsonl`, verified directly against
real transcripts on this machine (multiple real sessions under
`~/.claude/projects/`, cross-checked against `scripts/index-session.py`'s
independent parser, which already consumes this exact file format for the
unrelated purpose of full-text search indexing):

  - One JSON object per line. Relevant top-level keys: `type` (`"user"`,
    `"assistant"`, plus non-conversation types this module ignores --
    `"system"`, `"attachment"`, `"queue-operation"`, `"mode"`,
    `"permission-mode"`, `"agent-setting"`, `"ai-title"`,
    `"file-history-snapshot"`, `"file-history-delta"`, `"last-prompt"`,
    `"bridge-session"`, `"pr-link"`), `message` (a dict with `role` and
    `content`), `isSidechain` (bool), `isMeta` (bool, observed on
    harness-injected synthetic turns like "Continue from where you left
    off." -- not something the human typed).
  - `message.content` for `type: "user"` is EITHER a plain string (real
    human-typed text, e.g. `"continue"`) OR a list of content blocks --
    observed block `type`s: `"text"` (real text) and `"tool_result"` (a
    tool's output being fed back to the model, not something a human
    wrote). For `type: "assistant"` it is ALWAYS a list of blocks --
    observed: `"thinking"` (internal reasoning, never shown to the human),
    `"text"` (the actual reply), and `"tool_use"` (a tool invocation, not
    prose). Confirmed empirically across the corpus on this machine
    (1,029 user/assistant lines sampled): user content was `str` or
    `list`, assistant content was always `list`, never `str`.
  - `isSidechain: true` lines are subagent-internal turns (none were
    observed on this machine, but the field exists in the schema
    `index-session.py` already handles) and `isMeta: true` lines are
    harness-injected, not user-authored -- both are excluded from the
    digest so it stays actual conversation, not machinery. Only `"text"`
    blocks (and plain-string user content) are extracted; `"thinking"`,
    `"tool_use"`, and `"tool_result"` blocks are skipped for the same
    reason Copilot's extractor only reads `user.message`/`assistant.message`
    and ignores `hook.*`/`tool.*`/`session.*` events -- this is a
    conversation digest, not a full event trace.

What is shared vs. Claude-specific, and why: `build_digest()` (oldest-first
truncation to MAX_DIGEST_CHARS) and `redact_secrets()` operate on a plain
`list[tuple[str, str]]` of `(role, content)` pairs -- there is nothing
Copilot-specific about either function, so both harnesses call the SAME
implementation rather than keeping two truncation policies or two redaction
tables that could independently drift (this project's CLAUDE.md already logs
four instances of exactly that drift: two ISO parsers, skill-layout literals
in four files, two opposite corrupt-`.usage.json` policies, one correctly-
shared helper that proves sharing works). Only the RESOLUTION layer differs
by construction, because the two harnesses hand this module fundamentally
different inputs on fundamentally different schedules: Copilot gives a
`sessionId` that must be resolved to a file via `~/.copilot/session-state/`
(`find_events_file`/`resolve_copilot_state_root`), while Claude Code hands
the file path directly (`transcript_path` from the hook payload) with no
resolution step of its own -- and the two on-disk event schemas
(`events.jsonl`'s flat `{type, data, id, parentId, timestamp}` vs. Claude's
tree-shaped `{type, message, isSidechain, isMeta, parentUuid, uuid}`) have
nothing in common syntactically, so `summarize_events` (Copilot) and
`summarize_claude_events` (Claude) are necessarily separate functions. That
split -- one resolution+parsing function per harness, one shared
build_digest/redact_secrets pair -- is deliberate: sharing the parts that
have no reason to differ, keeping separate the parts that structurally
cannot be unified without discarding one harness's real schema.
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


def build_copilot_session_digest(
    session_id: str,
    env: "dict[str, str] | None" = None,
    max_chars: int = MAX_DIGEST_CHARS,
) -> "tuple[str, str]":
    """Resolve + extract + redact in one call, for a Copilot CLI sessionId.

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


def _claude_block_text(content) -> str:
    """Extract only 'text' block content (or a plain string) from a Claude
    Code message's `content` field. Skips 'thinking', 'tool_use', and
    'tool_result' blocks entirely -- see this module's docstring for why.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text")
                if isinstance(text, str) and text:
                    parts.append(text)
        return "\n".join(parts)
    return ""


def summarize_claude_events(transcript_path: Path) -> "tuple[list[tuple[str, str]], int]":
    """Return (ordered (role, content) messages, total parseable events seen)
    from a Claude Code session JSONL file.

    Only `type: "user"` / `type: "assistant"` lines with `message.role`
    matching become candidates; `isSidechain: true` (subagent-internal) and
    `isMeta: true` (harness-injected, not user-authored) lines are excluded.
    `total` counts every line that parsed as JSON regardless of type, same
    contract as summarize_events (Copilot), so callers can distinguish "file
    was empty/unparseable" from "file had events, just none worth reviewing".
    """
    messages: "list[tuple[str, str]]" = []
    total = 0
    for event in _iter_events(transcript_path):
        total += 1
        if not isinstance(event, dict):
            continue
        if event.get("isSidechain") or event.get("isMeta"):
            continue
        event_type = event.get("type")
        if event_type not in ("user", "assistant"):
            continue
        message = event.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if role not in ("user", "assistant"):
            continue
        text = _claude_block_text(message.get("content"))
        if text:
            messages.append(("User" if role == "user" else "Assistant", text))
    return messages, total


def build_claude_session_digest(
    transcript_path: str,
    max_chars: int = MAX_DIGEST_CHARS,
) -> "tuple[str, str]":
    """Resolve + extract + redact in one call, for a Claude Code
    transcript_path (from the Stop hook payload's `transcript_path` field --
    see scripts/lib/hook-input.sh). Unlike the Copilot path, there is no
    separate resolution step: Claude Code hands the file path directly, so
    this only needs to validate it exists and is readable before parsing.

    Same (digest, failure_reason) contract as build_copilot_session_digest.
    Does not catch OSError from a permissions problem; that is an
    environment misconfiguration the caller should see, not silently
    swallow.
    """
    if not transcript_path:
        return "", "unavailable (no transcript_path in Stop hook payload)"

    path = Path(transcript_path)
    if not path.is_file():
        return "", f"unavailable (transcript file not found: {path})"

    messages, total = summarize_claude_events(path)
    if not messages:
        if total == 0:
            return "", f"empty (0 parseable events in {path})"
        return "", f"has no user/assistant text content ({total} other event(s) in {path})"

    digest = build_digest(messages, max_chars=max_chars)
    return redact_secrets(digest), ""


def _log_failure(log_file: "str | None", component: str, reason: str) -> None:
    if not log_file:
        return
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"{ts} {component}: transcript {reason}\n")
    except OSError:
        # persist-failures.log itself being unwritable is a separate,
        # already-fatal problem for the whole pipeline; nothing useful to
        # do here besides not crashing the transcript step over it.
        pass


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(
        description="Print a bounded, redacted transcript digest for a Copilot CLI or Claude Code session."
    )
    parser.add_argument(
        "identifier",
        nargs="?",
        default="",
        help="Copilot: sessionId. Claude: transcript_path (from the Stop hook payload).",
    )
    parser.add_argument(
        "--harness",
        choices=("copilot", "claude"),
        default="copilot",
        help="which harness's schema to parse (default: copilot, for backward compatibility)",
    )
    parser.add_argument("--home", default=None, help="override for SL_COPILOT_HOME (Copilot only, testing)")
    parser.add_argument("--max-chars", type=int, default=MAX_DIGEST_CHARS)
    parser.add_argument(
        "--log-file",
        default=None,
        help="append a visible failure line here when the transcript is unavailable/empty",
    )
    args = parser.parse_args(argv)

    component = "session-review" if args.harness == "claude" else "copilot-session-review"

    try:
        if args.harness == "claude":
            digest, failure_reason = build_claude_session_digest(
                args.identifier, max_chars=args.max_chars
            )
        else:
            env = dict(os.environ)
            if args.home:
                env["SL_COPILOT_HOME"] = args.home
            digest, failure_reason = build_copilot_session_digest(
                args.identifier, env=env, max_chars=args.max_chars
            )
    except (RuntimeError, OSError) as exc:
        _log_failure(args.log_file, component, f"unavailable ({exc})")
        return 0

    if failure_reason:
        _log_failure(args.log_file, component, failure_reason)
        return 0

    sys.stdout.write(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
