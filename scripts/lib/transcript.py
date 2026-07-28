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
`user.message` / `assistant.message` was a plain string in 2,729 of 2,729
such events across the 94 local sessions that have an `events.jsonl`, with
no other type observed at all). Before this module,
`copilot-session-review.sh` never read stdin at all, so the reviewer it
spawns had zero information about what
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
    human-typed text, e.g. `"continue"`) OR a list of content blocks; for
    `type: "assistant"` it is a list of blocks. Re-measured over the whole
    local corpus (702 files, 58,124 user/assistant lines): content was
    `str` 4,839 times and `list` 53,285 times -- 58,124/58,124 one of the
    two -- and every one of the 53,305 list elements was a dict.
    Observed block `type`s, with counts: `tool_use` 16,778,
    `tool_result` 16,764, `thinking` 10,152, `text` 9,583, `fallback` 26,
    `image` 2. The earlier version of this paragraph named only
    text/tool_result/thinking/tool_use and called that "the observed
    block set"; `fallback` and `image` disprove it, so the block-type set
    is explicitly NOT treated as closed -- see UNKNOWN_SHAPE_THRESHOLD for
    what IS treated as closed and why the distinction matters.
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

Empty sessions (fix-empty-session)
----------------------------------
Roughly half of all Copilot CLI sessions never take a turn -- `copilot`
starts, the user quits or the process is spawned non-interactively, and
`sessionEnd` still fires. Those sessions have no transcript because there
was no conversation, not because anything broke. Reporting them in
persist-failures.log (the ONLY channel that can surface a silently-failed
detached review) taught the user to ignore that channel and flipped
`doctor.sh` to UNHEALTHY on a healthy store. See the OUTCOME_* constants and
copilot_session_conversed() for the three-way classification and the
discriminator's supporting measurements.
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
from typing import NamedTuple

MAX_DIGEST_CHARS = 20_000

# --- Outcome classification (fix-empty-session) --------------------------
#
# Reporting "this session had no conversation" as a PERSISTENCE FAILURE was
# the original bug wearing the opposite costume. persist-failures.log is the
# only channel that can surface a silently-failed detached review; filling it
# with benign no-op sessions (roughly half of all Copilot sessions on the
# machine this was found on: 95 of 179 session-state dirs never recorded a
# turn) trains the user to ignore the one signal that must never be ignored,
# and flips doctor to UNHEALTHY on a healthy store.
#
# So a transcript lookup now has three outcomes, not two:
#
#   OUTCOME_OK              a digest was produced.
#   OUTCOME_FAILURE         the session DID converse but its transcript could
#                           not be found, read, or parsed. Loud: this is what
#                           persist-failures.log exists for and must not
#                           regress.
#   OUTCOME_NO_CONVERSATION the session never conversed, so there is provably
#                           nothing to review. Benign: recorded in persist.log
#                           as a skipped outcome, never in persist-failures.log.
#
# Discriminator (Copilot), and why this one -- see copilot_session_conversed().
OUTCOME_OK = "ok"
OUTCOME_FAILURE = "failure"
OUTCOME_NO_CONVERSATION = "no-conversation"

# main()'s exit code for OUTCOME_NO_CONVERSATION, so the calling hook script
# can skip spawning a paid reviewer for a session with nothing in it. 0 still
# means "handled" for both OK and FAILURE, preserving the existing contract
# that a transcript problem never fails the hook.
EXIT_NO_CONVERSATION = 20

# --- Schema-drift detection (C6) -----------------------------------------
#
# Both on-disk formats this module parses are third-party, undocumented and
# unversioned. TOTAL breakage is already loud: zero extracted messages =>
# OUTCOME_FAILURE => persist-failures.log => doctor.sh UNHEALTHY. PARTIAL
# drift was not. Reproduced: a session where only `assistant.message`'s
# `data.content` moves from a plain string to `[{"type": "text", ...}]`
# loses EVERY assistant turn (5 of 5) and halves the digest (238 -> 93
# bytes), while the exit code (0), persist.log and persist-failures.log are
# byte-for-byte identical to a healthy run. The review still fires, still
# costs a paid model call, and now reviews half a conversation -- a quieter
# version of the same "exits 0 while doing nothing" defect this module was
# written to fix.
#
# What is NOT used: a floor on messages-per-event. Measured across the 94
# local Copilot sessions with an events.jsonl, the messages/events ratio is
# min 0.0159, median 0.0571, max 0.1667, and no session has zero messages.
# The drift above only moves a session from ~0.057 to ~0.028 -- comfortably
# inside the healthy range, so any threshold that catches it also fires on
# real sessions. A ratio detector is unshippable here.
#
# What IS used: a count of values whose SHAPE is one the schema has never
# produced, with a threshold of one. That is justified only because the
# shapes are perfectly stable in the corpora (see the module docstring):
# Copilot `data["content"]` was `str` in 2,729/2,729 conversation events;
# Claude `message["content"]` was `str` or `list` in 58,124/58,124
# user/assistant lines, with all 53,305 list elements dicts. One occurrence
# of anything else is therefore not noise, it is the format having changed.
#
# Deliberately NOT flagged: an unrecognised block `type` inside a Claude
# content list. The local corpus already contains two (`fallback` x26,
# `image` x2) that are legitimate and carry no prose, so that check has a
# demonstrated false-positive rate; the block-type set is open, the
# container shapes are closed.
UNKNOWN_SHAPE_THRESHOLD = 1

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


class EventSummary(NamedTuple):
    """(messages, total, unknown_shapes) from one transcript file.

    `unknown_shapes` maps a JSON path (e.g. `data.content`) to how many
    values at that path had a shape the schema has never produced. Empty on
    every healthy session -- see UNKNOWN_SHAPE_THRESHOLD.
    """

    messages: "list[tuple[str, str]]"
    total: int
    unknown_shapes: "dict[str, int]"


def describe_drift(unknown_shapes: "dict[str, int]", kept_messages: int) -> str:
    """Render an unknown-shape tally as one loud, self-contained line.

    Names the count, the path, and how many messages still came through --
    the last of those is what tells a reader whether they are looking at a
    total failure or the silent partial one, which is the whole point.
    Returns "" when nothing drifted, so callers can test it as a boolean.
    """
    if not unknown_shapes:
        return ""
    where = ", ".join(
        f"{count} at `{path}`" for path, count in sorted(unknown_shapes.items())
    )
    total = sum(unknown_shapes.values())
    return (
        f"SCHEMA DRIFT -- {total} value(s) of an unrecognised shape ({where}); "
        f"only {kept_messages} message(s) extracted. The session transcript "
        f"format has changed; the digest just produced is INCOMPLETE."
    )


def _drift_line(unknown_shapes: "dict[str, int]", kept_messages: int) -> str:
    """describe_drift(), gated on UNKNOWN_SHAPE_THRESHOLD. Counts VALUES, not
    distinct paths: one drifted value at one path must already trip it.
    """
    if sum(unknown_shapes.values()) < UNKNOWN_SHAPE_THRESHOLD:
        return ""
    return describe_drift(unknown_shapes, kept_messages)


class TranscriptResult(NamedTuple):
    """(digest, reason, outcome, drift) -- see the OUTCOME_* constants.

    Kept a NamedTuple rather than a bare tuple so `result.outcome` reads at
    call sites while `digest, reason, outcome, drift = ...` still works.

    `drift` is describe_drift()'s line, or "" when the transcript parsed
    with no surprises. It is deliberately independent of `outcome`: drift
    does NOT downgrade a usable digest to a failure (breaking a session over
    it would be worse than the drift), it only demands to be seen.
    """

    digest: str
    reason: str
    outcome: str
    drift: str = ""


# Files Copilot CLI creates inside a session-state dir only once a turn
# actually begins. Both are per-session and local to that dir.
_CONVERSATION_MARKERS = ("events.jsonl", "session.db")


def copilot_session_conversed(state_dir: Path) -> bool:
    """True when Copilot recorded a conversation store for this session.

    Discriminator: the presence, in the session's OWN state dir, of either
    `events.jsonl` (the transcript) or `session.db` (Copilot's per-session
    conversation database). Copilot creates the state dir, `checkpoints/`,
    `files/`, `research/` and `workspace.yaml` at session START; it creates
    `events.jsonl` and `session.db` only when a turn actually happens.

    Measured against the full 179-dir corpus on the machine where the defect
    was found:

      - 95 dirs had NEITHER marker; 84 had BOTH. The two markers co-occurred
        perfectly -- there was no dir with one and not the other.
      - All 84 marker-bearing dirs yielded >=1 user/assistant message through
        summarize_events(); zero of them would be misclassified as empty.

    Rejected alternatives, each with the measurement that rejected it:

      - `turns` / membership in the SHARED ~/.copilot/session-store.db. This
        was the reporter's leading hypothesis and it is WRONG in exactly the
        dangerous direction: 82 of the 95 no-conversation sessions DO appear
        in the `sessions` table (so membership is not a signal at all), and
        14 of the 84 sessions that really did converse have `turns == 0` or
        no `turns` rows -- they would have been silently classified as empty,
        restoring the original bug. It is also the expensive option: opening
        a shared, concurrently-written SQLite DB on every session end.
      - `workspace.yaml` size / its `name:` key. 18 of the 84 conversed
        sessions have no `name:` key, so this too would misclassify real
        sessions as empty. Size tracks `name:`, so it fails identically.
      - `checkpoints/index.md`: byte-identical (172 bytes) in both
        populations. No signal.

    Cost: two `stat()` calls in the session's own directory, no shared state,
    no lock, no DB handle -- which matters because this runs inside a hook
    with a <100ms budget.

    Biased safe: a session is treated as "conversed" if EITHER marker exists,
    so `session.db` present with `events.jsonl` missing -- a genuinely lost
    transcript -- stays a loud failure.
    """
    return any((state_dir / marker).is_file() for marker in _CONVERSATION_MARKERS)


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


def summarize_events(events_path: Path) -> EventSummary:
    """Return EventSummary(messages, total parseable events, unknown shapes).

    Only `user.message` / `assistant.message` events with a non-empty string
    `data.content` become messages -- every other event type (hook.*,
    session.*, tool.*, subagent.*, skill.invoked, ...) is telemetry, not
    conversation, and is skipped. `total` counts every line that parsed as
    JSON regardless of type, so a caller can distinguish "file was empty or
    entirely unparseable" from "file had events, just none worth reviewing".

    A conversation event whose `data.content` is present but NOT a string is
    counted as drift. An ABSENT `data.content`, and the empty string, are
    not: 1,265 of the 2,729 local conversation events carry `""`, which is
    ordinary (an assistant turn that only called tools says nothing), and
    treating it as drift would fire on roughly half of all real sessions.
    """
    messages: "list[tuple[str, str]]" = []
    total = 0
    unknown: "dict[str, int]" = {}
    for event in _iter_events(events_path):
        total += 1
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        data = event.get("data")
        if event_type not in ("user.message", "assistant.message") or not isinstance(data, dict):
            continue
        content = data.get("content")
        if content is not None and not isinstance(content, str):
            unknown["data.content"] = unknown.get("data.content", 0) + 1
            continue
        if isinstance(content, str) and content:
            role = "User" if event_type == "user.message" else "Assistant"
            messages.append((role, content))
    return EventSummary(messages, total, unknown)


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
) -> TranscriptResult:
    """Resolve + extract + redact in one call, for a Copilot CLI sessionId.

    Returns TranscriptResult(digest, reason, outcome, drift). `digest` is
    non-empty only for OUTCOME_OK; otherwise `reason` explains why, and
    `outcome` tells the caller WHICH log it belongs in. `drift` is set
    independently of all three when the on-disk shapes stopped matching what
    the corpus has ever produced -- see UNKNOWN_SHAPE_THRESHOLD:

      - OUTCOME_NO_CONVERSATION -- the session-state dir exists but the
        session never started a turn (see copilot_session_conversed for the
        discriminator and the corpus it was measured against). Benign; it
        must NOT reach persist-failures.log.
      - OUTCOME_FAILURE -- everything else: no sessionId, no state dir at
        all (a state dir is created at session start, so its absence means
        a wrong state root or an externally deleted session, both worth
        shouting about), a conversed session whose events.jsonl is missing,
        and an events.jsonl that is empty or yields no messages.

    Never raises for expected degraded conditions (missing session id,
    missing directory, missing/empty/garbled file); it does not catch
    RuntimeError from resolve_copilot_state_root (no $HOME and no override)
    or OSError from a permissions problem, since those are environment
    misconfigurations the caller should see, not silently swallow.
    """
    if not session_id:
        return TranscriptResult(
            "", "unavailable (no sessionId in sessionEnd payload)", OUTCOME_FAILURE
        )

    state_dir = session_state_dir(session_id, env)
    events_path = find_events_file(session_id, env)
    if events_path is None:
        if not state_dir.is_dir():
            return TranscriptResult(
                "", f"unavailable (no session-state dir at {state_dir})", OUTCOME_FAILURE
            )
        if not copilot_session_conversed(state_dir):
            return TranscriptResult(
                "",
                "not applicable -- session ended without a turn "
                f"(no events.jsonl and no session.db under {state_dir})",
                OUTCOME_NO_CONVERSATION,
            )
        return TranscriptResult(
            "", f"unavailable (events.jsonl not found under {state_dir})", OUTCOME_FAILURE
        )

    messages, total, unknown = summarize_events(events_path)
    drift = _drift_line(unknown, len(messages))
    if not messages:
        if total == 0:
            return TranscriptResult(
                "", f"empty (0 parseable events in {events_path})", OUTCOME_FAILURE, drift
            )
        return TranscriptResult(
            "",
            f"has no user/assistant messages ({total} other event(s) in {events_path})",
            OUTCOME_FAILURE,
            drift,
        )

    digest = build_digest(messages, max_chars=max_chars)
    return TranscriptResult(redact_secrets(digest), "", OUTCOME_OK, drift)


def _claude_block_text(content, unknown: "dict[str, int] | None" = None) -> str:
    """Extract only 'text' block content (or a plain string) from a Claude
    Code message's `content` field. Skips 'thinking', 'tool_use', and
    'tool_result' blocks entirely -- see this module's docstring for why.

    When `unknown` is supplied, records shape drift into it: a `content`
    that is neither `str` nor `list`, and any list element that is not a
    dict. A block whose `type` is merely unfamiliar is NOT recorded --
    `fallback` and `image` already occur legitimately in the local corpus.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                if unknown is not None:
                    key = "message.content[]"
                    unknown[key] = unknown.get(key, 0) + 1
                continue
            if block.get("type") == "text":
                text = block.get("text")
                if isinstance(text, str) and text:
                    parts.append(text)
        return "\n".join(parts)
    if content is not None and unknown is not None:
        unknown["message.content"] = unknown.get("message.content", 0) + 1
    return ""


def summarize_claude_events(transcript_path: Path) -> EventSummary:
    """Return EventSummary(messages, total parseable events, unknown shapes)
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
    unknown: "dict[str, int]" = {}
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
        text = _claude_block_text(message.get("content"), unknown)
        if text:
            messages.append(("User" if role == "user" else "Assistant", text))
    return EventSummary(messages, total, unknown)


def build_claude_session_digest(
    transcript_path: str,
    max_chars: int = MAX_DIGEST_CHARS,
) -> TranscriptResult:
    """Resolve + extract + redact in one call, for a Claude Code
    transcript_path (from the Stop hook payload's `transcript_path` field --
    see scripts/lib/hook-input.sh). Unlike the Copilot path, there is no
    separate resolution step: Claude Code hands the file path directly, so
    this only needs to validate it exists and is readable before parsing.

    Same TranscriptResult contract as build_copilot_session_digest --
    including `drift`, which is set on unrecognised container shapes without
    downgrading the outcome -- but this path NEVER returns
    OUTCOME_NO_CONVERSATION, deliberately.

    Copilot's `sessionEnd` fires for every session including ones that never
    took a turn -- that is what created the false-failure flood. Claude
    Code's `Stop` hook fires when the assistant finishes responding, so a
    conversation exists by construction, and there is no "session dir
    created but never used" state to detect: the hook hands over a path to
    a file the harness has already written. Checked against the whole
    transcript corpus on the machine where the Copilot defect was found --
    369 of 369 real session transcripts under ~/.claude/projects/ yielded at
    least one user/assistant message. (The 355 `agent-*.jsonl` files that
    yield none are subagent sidechains, which are never passed to Stop, and
    the 17 remaining zero-message files are `journal.jsonl`, not transcripts
    at all.) A missing or unparseable transcript here therefore still means
    something is genuinely wrong, and stays loud. Adding an "empty" class
    here on symmetry alone would be inventing a benign explanation for a
    condition that has never been benign.

    Does not catch OSError from a permissions problem; that is an
    environment misconfiguration the caller should see, not silently
    swallow.
    """
    if not transcript_path:
        return TranscriptResult(
            "", "unavailable (no transcript_path in Stop hook payload)", OUTCOME_FAILURE
        )

    path = Path(transcript_path)
    if not path.is_file():
        return TranscriptResult(
            "", f"unavailable (transcript file not found: {path})", OUTCOME_FAILURE
        )

    messages, total, unknown = summarize_claude_events(path)
    drift = _drift_line(unknown, len(messages))
    if not messages:
        if total == 0:
            return TranscriptResult(
                "", f"empty (0 parseable events in {path})", OUTCOME_FAILURE, drift
            )
        return TranscriptResult(
            "",
            f"has no user/assistant text content ({total} other event(s) in {path})",
            OUTCOME_FAILURE,
            drift,
        )

    digest = build_digest(messages, max_chars=max_chars)
    return TranscriptResult(redact_secrets(digest), "", OUTCOME_OK, drift)


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


def _log_drift(log_file: "str | None", component: str, drift: str) -> None:
    """Append a schema-drift line to persist-failures.log.

    Same file, same leading-ISO-timestamp shape as _log_failure, because
    doctor.sh section 5 parses the first field of the last line as a
    timestamp and flips STATUS on ANY non-empty content -- which is exactly
    the outcome wanted here. It is deliberately NOT routed through
    _log_failure: the session did not fail, and the line must not read as
    though it did.
    """
    if not log_file:
        return
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"{ts} {component}: {drift}\n")
    except OSError:
        pass


def _log_notice(notice_file: "str | None", component: str, reason: str) -> None:
    """Record a benign, non-failure outcome in persist.log.

    Written in persist-proposal.py's own persist.log line shape -- a JSON
    object with `written`/`skipped`/`bytes` -- so the file stays one
    homogeneous, machine-readable stream of per-session outcomes rather than
    two interleaved formats. `skipped: ["no-conversation"]` is deliberately
    distinct from persist-proposal.py's `["no-proposal"]`; doctor.sh counts
    consecutive `no-proposal` results as evidence of broken extraction, and
    a benign empty session must neither be counted as one nor be allowed to
    break the streak (see doctor.sh section 5b).

    This is what keeps "the hook never ran" distinguishable from "the hook
    ran and found nothing": the first leaves no line at all.
    """
    if not notice_file:
        return
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    record = {
        "written": [],
        "skipped": ["no-conversation"],
        "bytes": 0,
        "component": component,
        "reason": reason,
        "timestamp": ts,
    }
    try:
        with open(notice_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
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
    parser.add_argument(
        "--notice-log",
        default=None,
        help=(
            "append a benign skipped-outcome line here (normally persist.log) "
            "when the session ended without ever taking a turn; exits "
            f"{EXIT_NO_CONVERSATION} so the caller can skip the review entirely"
        ),
    )
    args = parser.parse_args(argv)

    component = "session-review" if args.harness == "claude" else "copilot-session-review"

    try:
        if args.harness == "claude":
            result = build_claude_session_digest(args.identifier, max_chars=args.max_chars)
        else:
            env = dict(os.environ)
            if args.home:
                env["SL_COPILOT_HOME"] = args.home
            result = build_copilot_session_digest(
                args.identifier, env=env, max_chars=args.max_chars
            )
    except (RuntimeError, OSError) as exc:
        _log_failure(args.log_file, component, f"unavailable ({exc})")
        return 0

    # Drift is reported FIRST and independently of the outcome, so it is
    # recorded even when the same run also has something else to say. It
    # never changes the exit code and never suppresses the digest: a changed
    # transcript format must be seen, but must not break the session.
    if result.drift:
        _log_drift(args.log_file, component, result.drift)

    if result.outcome == OUTCOME_NO_CONVERSATION:
        _log_notice(args.notice_log, component, result.reason)
        return EXIT_NO_CONVERSATION

    if result.outcome == OUTCOME_FAILURE:
        _log_failure(args.log_file, component, result.reason)
        return 0

    sys.stdout.write(result.digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
