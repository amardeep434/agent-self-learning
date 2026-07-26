#!/usr/bin/env python3
"""telemetry.py -- per-request telemetry extracted from the HARNESS-NATIVE
session stores, for the Coach rules that need more than role/content/
timestamp.

WHY THIS EXISTS
---------------
`scripts/coach-rules-eval.py` used to skip 34 of the 45 vendored Coach rules
with the reason "not captured", pointing at
`schema/session-search-schema.sql`, which stores only per-message `role`,
`content` and `timestamp`. That reasoning was correct about *this project's
own index* and wrong about the world: both harnesses already write far
richer per-request telemetry of their own, and this project already reads
one of those stores for an unrelated purpose (`scripts/lib/transcript.py`
reads Copilot's `events.jsonl` and Claude Code's `projects/*.jsonl` to build
the reviewer's conversation digest). The fields were never "not captured" --
they were captured by the harness and never plumbed.

Verified directly against the real stores on a development machine
(2026-07-26), not inferred from documentation:

  Copilot CLI, `~/.copilot/session-state/<id>/events.jsonl`
    session.start           context{cwd,gitRoot,branch,headCommit}, copilotVersion
    session.model_change    newModel, previousModel, reasoningEffort, contextTier
    user.message            content, source, delivery, attachments
    assistant.turn_start    turnId, model, interactionId
    assistant.message       turnId, model, outputTokens, toolRequests, content
    assistant.turn_end      turnId, model
    tool.execution_start    turnId, toolName, mcpServerName, mcpToolName, arguments
    tool.execution_complete turnId, success, error, toolTelemetry
    permission.requested    permissionRequest{kind,commands,possiblePaths,...}
    permission.completed    result{kind}   ("approved" | "approved-for-location"
                                            | "denied-interactively-by-user"
                                            | "denied-no-approval-rule-...")
    skill.invoked           name, path, source, pluginName, trigger
    subagent.started        agentName, agentDisplayName, model
    subagent.completed      agentName, model, totalToolCalls, totalTokens, durationMs
    abort                   reason ("user_initiated")
    session.shutdown        tokenDetails{input,output,cache_read,cache_write},
                            codeChanges{linesAdded,linesRemoved,filesModified[]},
                            totalPremiumRequests, totalApiDurationMs

  Copilot CLI, `~/.copilot/session-store.db`
    assistant_usage_events  session_id, turn_index, model, input_tokens,
                            output_tokens, cache_read_tokens,
                            cache_write_tokens, reasoning_tokens, duration_ms,
                            time_to_first_token_ms, initiator, reasoning_effort,
                            finish_reason  (2302 rows in the corpus checked)
    session_files           file_path, tool_name ('create'/'edit'), turn_index
    sessions                cwd, repository, branch, summary

  Claude Code, `~/.claude/projects/<slug>/<sessionId>.jsonl`
    assistant  message.model, message.usage{input_tokens, output_tokens,
               cache_read_input_tokens, cache_creation_input_tokens},
               message.content[] blocks (text/thinking/tool_use), requestId
    user       message.content (str or blocks incl. tool_result),
               interruptedMessageId, promptSource, permissionMode

TWO GRANULARITIES, DELIBERATELY KEPT APART
------------------------------------------
Upstream's `requests` scope is per *user request* for some rules (how many
tools did this request use? was it cancelled? how long did it take?) and per
*model API call* for others (prompt/cache tokens, reasoning effort). One
user request is many API calls in an agentic harness -- 2302 usage rows
across 133 turns in the corpus checked. Flattening them into one list would
silently inflate every count that is really per-request and deflate every
rate that is really per-API-call, so this module returns two lists and each
adapter picks the one its rule actually means:

  build_turn_requests()  -- one record per user request (turn)
  build_api_calls()      -- one record per model API call

FIELD PRESENCE IS EXPLICIT, AND `None` MEANS "NOT AVAILABLE HERE"
-----------------------------------------------------------------
Records from different harnesses can fill different fields: Copilot's DB has
`reasoning_effort`, Claude's transcripts have no equivalent; Claude's
transcripts carry `interruptedMessageId`, Copilot signals cancellation with
an `abort` event. A missing field is `None`, never 0/""/[] -- because the
standing rule on this branch is that a rule which "evaluates" against a
structurally-empty input is WORSE than a loud skip: it converts a visible
gap into an invisible clean bill of health. `requests_with()` below is the
only supported way to select records for a rule, and it returns only records
where every named field is actually present. An adapter whose selection
comes back empty must raise so its rule skips loudly.

Read-only, stdlib-only, 3.9-compatible. SQLite is opened through an
immutable file: URI so a live harness holding the database open is never
blocked, locked, or written to.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Reuse the ONE resolver for Copilot's state root rather than re-deriving
# ~/.copilot here -- duplicated path logic is this project's most repeated
# defect class, and transcript.py already owns that resolution (including
# the COPILOT_HOME/HOME override handling and the no-$HOME error).
from transcript import resolve_copilot_state_root  # noqa: E402

# A hard bound on how much history any single evaluation reads. The corpus
# on the development machine had two 22MB events.jsonl files; reading every
# session on every hook-adjacent invocation is not acceptable, and Coach
# rules are all about recent habits anyway. Newest-first by mtime.
MAX_SESSIONS = 40
MAX_EVENT_BYTES = 64 * 1024 * 1024


def _iter_jsonl(path: Path):
    """Yield parsed JSON objects from a JSONL file, skipping unparseable
    lines. Never raises for a malformed or truncated file -- a half-written
    last line is normal for a session that is still open."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    yield obj
    except OSError:
        return


def _newest(paths, limit):
    """Newest-mtime-first, capped. Mirrors lib/list-transcripts.py's
    rationale: one getmtime() syscall per file, no `find`/`stat`/`sort`
    pipeline whose flags and text output differ between GNU and BSD
    userlands."""
    scored = []
    for p in paths:
        try:
            scored.append((os.path.getmtime(p), p))
        except OSError:
            continue
    scored.sort(key=lambda pair: pair[0], reverse=True)
    return [p for _mtime, p in scored[:limit]]


# ---------------------------------------------------------------------------
# Copilot CLI: events.jsonl -> turn-level requests
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Custom-instruction file size.
#
# Upstream computes this FOR CLI SESSIONS -- resolveCustomInstructionsBytes(
# entryPath, isCLI) branches on isCLI to read <session dir>/workspace.yaml
# and stat <folder>/.github/copilot-instructions.md [upstream
# src/core/parser-vscode.ts:106-133], and parseCLIEventsFile takes
# customInstructionsBytes as its fourth parameter [parser-vscode-cli.ts:398].
# The claim that upstream reads this "from the VS Code workspace, not from
# any CLI session log" was false, and it kept three rules skipped.
#
# ADAPTATION, Claude Code half: Claude Code has no
# .github/copilot-instructions.md. Its equivalent per-project instruction
# file is <cwd>/CLAUDE.md, which is what is stat'ed for that harness. This is
# an adaptation of upstream's semantics, not upstream's literal field: the
# QUESTION ("how many bytes of always-on instructions does this workspace
# push into every request?") is preserved exactly; the FILENAME is not, and
# cannot be, because the harnesses read different files.
#
# A missing file is 0 bytes, matching detectCustomInstructionsBytes; an
# unreadable folder is None, meaning "not determined", which keeps the
# session out of the denominator rather than scoring it as instruction-free.
# ---------------------------------------------------------------------------

COPILOT_INSTRUCTIONS_RELPATH = (".github", "copilot-instructions.md")
CLAUDE_INSTRUCTIONS_RELPATH = ("CLAUDE.md",)

_INSTRUCTION_BYTES_CACHE = {}


def _instruction_bytes(folder, relparts):
    """Size of a workspace's instruction file: 0 if absent, None if the
    workspace folder itself is unknown."""
    if not folder:
        return None
    key = (folder, relparts)
    if key in _INSTRUCTION_BYTES_CACHE:
        return _INSTRUCTION_BYTES_CACHE[key]
    try:
        size = Path(folder).joinpath(*relparts).stat().st_size
    except OSError:
        size = 0
    _INSTRUCTION_BYTES_CACHE[key] = size
    return size


_WORKSPACE_CWD_RE = re.compile(r"^cwd:\s*(.+)$", re.M)


def _copilot_workspace_folder(session_dir):
    """`cwd:` out of a session's workspace.yaml.

    Transcribes parseCLIWorkspaceFolderPath [upstream
    src/core/parser-vscode-files.ts:580-592] including its absolute-path
    guard, which is what stops a relative or templated value being joined
    onto the process's own working directory. No YAML parser: upstream reads
    the one key with a regex and so does this, which keeps the dependency
    surface at zero and matches upstream byte for byte on the same file.
    """
    try:
        raw = (Path(session_dir) / "workspace.yaml").read_text(
            encoding="utf-8", errors="replace")
    except OSError:
        return None
    match = _WORKSPACE_CWD_RE.search(raw)
    if not match:
        return None
    cwd = match.group(1).strip()
    if not (cwd.startswith("/") or re.match(r"^[A-Za-z]:", cwd)):
        return None
    return cwd.rstrip("/") or None


def _copilot_event_files(env=None, limit=MAX_SESSIONS):
    try:
        root = resolve_copilot_state_root(env)
    except (RuntimeError, OSError):
        return []
    # resolve_copilot_state_root() returns the CONFIG root (~/.copilot);
    # per-session event logs live one level down, under session-state/<id>/.
    root = root / "session-state"
    if not root.is_dir():
        return []
    candidates = []
    try:
        for child in root.iterdir():
            events = child / "events.jsonl"
            try:
                if events.is_file() and events.stat().st_size <= MAX_EVENT_BYTES:
                    candidates.append(events)
            except OSError:
                continue
    except OSError:
        return []
    return _newest(candidates, limit)


# Which tool names carry a file path, and under which argument key. Taken
# from upstream microsoft/AI-Engineering-Coach's OWN parsers rather than
# guessed, so `referencedFiles`/`editedFiles` here mean what the rules that
# consume them mean:
#   src/core/parser-vscode-cli.ts  FILE_REF_TOOLS / FILE_EDIT_TOOLS / META_TOOLS
#   src/core/parser-claude.ts      CLAUDE_READ_FILE_TOOLS / CLAUDE_READ_PATH_TOOLS
#                                  / CLAUDE_WRITE_TOOLS
# (upstream HEAD 766d0f2, 2026-07-24. Correction of record: an earlier
# comment here said the previously vendored commit 9b4deb1 was "no longer
# reachable in the public history". That was false -- the compare API reports
# 9b4deb1...766d0f2 as status "ahead", behind_by 0, i.e. a direct ancestor.
# The rules are now vendored at 766d0f2 and are byte-identical to 9b4deb1's.)
COPILOT_FILE_REF_TOOLS = {"view", "grep", "glob", "rg", "show_file"}
COPILOT_FILE_EDIT_TOOLS = {"edit", "create"}
COPILOT_META_TOOLS = {"report_intent"}

# ---------------------------------------------------------------------------
# aiCode: AI-authored code blocks per request.
#
# WHAT UPSTREAM ACTUALLY COUNTS -- read from source, not inferred. A previous
# note in this repo said upstream "reconstructs generated code from tool
# arguments"; that is half of it, and the half it omits changes the answer.
#
# src/core/parser-shared.ts:
#     export const CODE_BLOCK_RE = /```(\w+)?\n([\s\S]*?)```/g;
#     const MAX_CODE_SCAN_CHARS = 128_000;
#     aiCode: extractCodeBlocks(textForCodeScan(rawResp))
#     ... loc = code.trim() ? code.trim().split('\n').length : 0
#
# So `aiCode` is *markdown fenced code blocks found in the assistant's
# response text*, and `loc` is the newline count of the trimmed fence body.
# Both harness parsers then FEED tool-written code into that same response
# text as a synthesised fence, tagged with the file extension:
#
#   parser-vscode-cli.ts  (FILE_EDIT_TOOLS = edit, create)
#       code = args.file_text ?? args.content ?? args.new_str
#              ?? args.newString ?? args.code
#       turn.responseChunks.push(`\`\`\`${ext}\n${code}\n\`\`\``)
#   parser-claude.ts      (CLAUDE_WRITE_TOOLS = Write, Edit, MultiEditTool)
#       code = input.content ?? input.new_str
#       assistantTexts.push(`\`\`\`${ext}\n${code}\n\`\`\``)
#
# Consequences worth stating because they decide what the rules mean:
#   * ADDED LINES ONLY. `new_str`/`file_text`/`content` is the new content.
#     `old_str` is never read, so nothing is netted off and deletions are
#     invisible. "AI LoC" means "lines the AI produced", not "diff size".
#   * A fence in ordinary prose counts exactly as much as a written file.
#   * Language is the fence info string (the file EXTENSION for synthesised
#     fences), lowercased and mapped through LANG_ALIASES.
#
# MEASURED ON THIS MACHINE before any of it was implemented, over the six
# largest real sessions per harness: Copilot 29,819 LoC (py 19,000 / md 6,540
# / html 3,434 ...), Claude 11,391 LoC (md 6,803 / kt 2,637 / py 1,033 ...).
# `edit` appears 379 times with `new_str`, `create` 91 times with `file_text`.
# The input is real and large, not a theoretical field.
#
# STREAMING, NOT ACCUMULATING. Upstream joins every chunk into one
# responseText and regexes the join. This module scans each chunk as it comes
# off the event stream and keeps only (language, loc) pairs, so a session's
# file bodies are never all resident at once -- one 22 MB events.jsonl here
# would otherwise be largely held in memory. The one behavioural difference
# is stated rather than hidden: a fence OPENED in one chunk and CLOSED in a
# later one is found by upstream and not by us. Harness events carry complete
# messages and complete tool arguments, so a fence spanning two chunks is not
# a shape either harness emits; if that ever changes, this under-counts
# rather than over-counts, which is the safe direction for rules that fire on
# "too much AI code".
CODE_BLOCK_RE = re.compile(r"```(\w+)?\n([\s\S]*?)```")

# src/core/parser-shared.ts LANG_ALIASES, verbatim. Without it `py` and
# `python`, or `md` and `markdown`, are different languages -- which would
# split low-markdown-ratio's numerator and corrupt no-language-exploration's
# distinct-language count. Real data on this machine contains both spellings.
LANG_ALIASES = {
    "sh": "bash", "shell": "bash", "zsh": "bash",
    "ts": "typescript", "tsx": "typescript",
    "js": "javascript", "jsx": "javascript",
    "py": "python", "python3": "python",
    "cs": "csharp", "c#": "csharp",
    "yml": "yaml", "md": "markdown",
    "tf": "terraform", "rs": "rust", "rb": "ruby",
    "jsonc": "json", "jsonl": "json",
    "txt": "text", "plaintext": "text", "env": "dotenv",
}

MAX_CODE_SCAN_CHARS = 128000

# Argument keys each harness's edit/create tools carry the NEW content under,
# in upstream's own precedence order.
COPILOT_CODE_ARG_KEYS = ("file_text", "content", "new_str", "newString", "code")
CLAUDE_CODE_ARG_KEYS = ("content", "new_str")

CLAUDE_WRITE_TOOLS = {"Write", "Edit", "MultiEditTool"}
CLAUDE_READ_FILE_TOOLS = {"Read", "View"}
CLAUDE_READ_PATH_TOOLS = {"Glob", "LS", "Find"}


def extract_code_blocks(text):
    """Fenced code blocks in `text` as [{"language":..., "loc":...}, ...].

    Mirrors upstream's extractCodeBlocks exactly, including the empty-body
    case (loc 0, block still emitted -- it counts toward `aiCode.length`,
    which analyzer-patterns tests for, even though it adds no lines).
    """
    blocks = []
    for match in CODE_BLOCK_RE.finditer(text):
        lang = (match.group(1) or "unknown").lower().strip()
        lang = LANG_ALIASES.get(lang, lang)
        body = match.group(2).strip()
        blocks.append({"language": lang, "loc": len(body.split("\n")) if body else 0})
    return blocks


def _code_fence(path, code):
    """The synthesised fence both upstream parsers push for a write tool.

    `path` decides the language, exactly as upstream does it: the substring
    after the last dot, or "unknown" when there is none. Returns None when
    either half is missing, because upstream only pushes when BOTH are
    present -- a write tool call with no path contributes nothing.
    """
    if not isinstance(path, str) or not path or not isinstance(code, str) or not code:
        return None
    ext = path.split(".")[-1] if "." in path else "unknown"
    return "```{}\n{}\n```".format(ext, code)


class _CodeScan:
    """Per-request streaming scanner for aiCode blocks.

    Holds only the running (language, loc) list and a character budget --
    never the accumulated text. `feed()` is called once per assistant message
    and once per write-tool call, in event order.

    The budget reproduces upstream's MAX_CODE_SCAN_CHARS truncation, which is
    not cosmetic: without it a single enormous generated file would dominate
    every LoC-based rule, and the fixture-vs-production answers would diverge
    from upstream's for the same input.
    """

    __slots__ = ("blocks", "_remaining")

    def __init__(self):
        self.blocks = []
        self._remaining = MAX_CODE_SCAN_CHARS

    def feed(self, chunk, separator_len=0):
        if not chunk or self._remaining <= 0:
            return
        self._remaining -= separator_len
        if self._remaining <= 0:
            return
        if len(chunk) > self._remaining:
            chunk = chunk[:self._remaining]
        self._remaining -= len(chunk)
        self.blocks.extend(extract_code_blocks(chunk))


def _first_str(mapping, keys):
    """First key in `keys` whose value is a non-empty string. Upstream's
    ?? chain, which is precedence-ordered -- not "any key that happens to
    be there"."""
    if not isinstance(mapping, dict):
        return None
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _arg(mapping, key):
    if isinstance(mapping, dict):
        value = mapping.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _tool_label(data):
    """Upstream's toolsUsed entries are prefixed `mcp_` for MCP tools (the
    mcp-tool-bloat and context-engineering-gaps rules both key off that
    prefix). Copilot records the MCP server and tool separately, so rebuild
    the upstream-shaped label rather than dropping the distinction."""
    server = data.get("mcpServerName")
    mcp_tool = data.get("mcpToolName")
    if server and mcp_tool:
        return "mcp_{}_{}".format(server, mcp_tool)
    name = data.get("toolName")
    return name if isinstance(name, str) and name else None


def _copilot_turns(events_path: Path):
    """Group one session's events into per-turn request records.

    Turns are keyed by the `turnId` that Copilot stamps on turn_start,
    assistant.message, turn_end and tool.execution_start. A user.message
    with no turnId of its own is attributed to the NEXT turn that starts --
    which is what "the prompt that caused this request" means, and is how
    the message text reaches rules like verbose-output.
    """
    session_id = events_path.parent.name
    # workspace.yaml is a SECOND, independent statement of the same folder
    # session.start's context carries. Upstream treats it as the CLI
    # workspace identity (parseCLIWorkspaceFolderPath), and it is present
    # even for a session whose log was truncated before session.start --
    # which is why it is also the fallback for workspaceName below.
    workspace_folder = _copilot_workspace_folder(events_path.parent)
    instruction_bytes = _instruction_bytes(
        workspace_folder, COPILOT_INSTRUCTIONS_RELPATH)
    turns = {}
    order = []
    scans = {}
    workspace = None
    pending_user = None
    # permission.requested carries no turnId, only a requestId that
    # permission.completed echoes; attribute each completed confirmation to
    # whichever turn was open when its request was raised.
    pending_perm = {}
    current = None

    def _turn(turn_id):
        if turn_id not in turns:
            turns[turn_id] = {
                "source": "copilot",
                "session_id": session_id,
                "turn_id": turn_id,
                "timestamp": None,
                "modelId": None,
                "messageText": None,
                "messageLength": None,
                "completionTokens": 0,
                "totalElapsed": None,
                "isCanceled": False,
                "toolsUsed": [],
                "referencedFiles": [],
                "editedFiles": [],
                "toolConfirmations": [],
                "skillsUsed": [],
                "agentName": None,
                "_start_ts": None,
                "_end_ts": None,
            }
            order.append(turn_id)
            scans[turn_id] = _CodeScan()
        return turns[turn_id]

    for event in _iter_jsonl(events_path):
        etype = event.get("type")
        data = event.get("data")
        if not isinstance(data, dict):
            data = {}
        ts = event.get("timestamp")

        if etype == "session.start":
            # Upstream buckets low-markdown-ratio by workspace. Copilot puts
            # the repo root in session.start.data.context; gitRoot is
            # preferred over cwd so a session started in a subdirectory lands
            # in the same bucket as one started at the top.
            context = data.get("context")
            if isinstance(context, dict):
                root = context.get("gitRoot") or context.get("cwd")
                if isinstance(root, str) and root:
                    workspace = root
            continue

        if etype == "user.message":
            content = data.get("content")
            pending_user = content if isinstance(content, str) else None
            continue

        if etype == "assistant.turn_start":
            turn_id = data.get("turnId")
            if not turn_id:
                continue
            rec = _turn(turn_id)
            current = rec
            rec["_start_ts"] = ts
            rec["timestamp"] = ts
            if data.get("model"):
                rec["modelId"] = data["model"]
            if pending_user is not None:
                rec["messageText"] = pending_user
                rec["messageLength"] = len(pending_user)
                pending_user = None
            continue

        if etype == "assistant.turn_end":
            turn_id = data.get("turnId")
            if not turn_id:
                continue
            rec = _turn(turn_id)
            rec["_end_ts"] = ts
            continue

        if etype == "assistant.message":
            turn_id = data.get("turnId")
            if not turn_id:
                continue
            rec = _turn(turn_id)
            if data.get("model"):
                rec["modelId"] = data["model"]
            out = data.get("outputTokens")
            if isinstance(out, int):
                rec["completionTokens"] += out
            content = data.get("content")
            if isinstance(content, str):
                # separator_len 2: upstream joins responseChunks with '\n\n',
                # and those separator characters count against the same
                # MAX_CODE_SCAN_CHARS budget there.
                scans[turn_id].feed(content, separator_len=2)
            continue

        if etype == "tool.execution_start":
            turn_id = data.get("turnId")
            if not turn_id:
                continue
            rec = _turn(turn_id)
            label = _tool_label(data)
            name = data.get("toolName")
            if label and name not in COPILOT_META_TOOLS:
                rec["toolsUsed"].append(label)
            path = _arg(data.get("arguments"), "path")
            if path and name in COPILOT_FILE_EDIT_TOOLS:
                rec["editedFiles"].append(path)
                fence = _code_fence(
                    path, _first_str(data.get("arguments"), COPILOT_CODE_ARG_KEYS))
                if fence:
                    scans[turn_id].feed(fence, separator_len=2)
            elif path and name in COPILOT_FILE_REF_TOOLS:
                rec["referencedFiles"].append(path)
            # Copilot's own `skill` tool is how upstream detects skill use;
            # the separate skill.invoked event is handled below and both are
            # deduplicated at finalisation.
            skill = _arg(data.get("arguments"), "skill")
            if skill and name == "skill":
                rec["skillsUsed"].append(skill)
            continue

        if etype == "permission.requested":
            request_id = data.get("requestId")
            req = data.get("permissionRequest")
            kind = req.get("kind") if isinstance(req, dict) else None
            if request_id:
                pending_perm[request_id] = (current, kind)
            continue

        if etype == "permission.completed":
            request_id = data.get("requestId")
            rec, kind = pending_perm.pop(request_id, (current, None))
            result = data.get("result")
            result_kind = result.get("kind") if isinstance(result, dict) else None
            if rec is not None and result_kind:
                # autoApproveScope: upstream counts a confirmation as
                # auto-approved when the scope is 'session' or 'always'
                # [upstream src/core/dsl/interpreter.ts:658-678,815-834].
                # Copilot CLI's analogue of 'always' is
                # `approved-for-location`: an approval PERSISTED into
                # ~/.copilot/permissions-config.json's location-keyed
                # tool_approvals list, as against a one-shot `approved`.
                #
                # This field previously did not exist, on the recorded
                # ground that "an auto-approve RATE computed from this
                # stream would have a permanently zero numerator". That was
                # false. Re-measured over all 62 local sessions:
                # permission.completed result.kind is approved 165,
                # denied-no-approval-rule 150, denied-interactively 9,
                # approved-for-location 7. The numerator is 7. The old
                # comment rejected approved-for-location because it took
                # human-scale time (3.1s minimum) -- but upstream applies NO
                # latency test, and in VS Code clicking "Always allow" also
                # takes human-scale time. The latency argument rejected the
                # exact field it was looking for.
                #
                # WHAT DIFFERS FROM UPSTREAM, and it is a real gap: Copilot
                # CLI has no session-scoped approval, so only 'always' is
                # ever produced here; upstream's 'session' arm is dead for
                # this harness. And a tool that runs under a STANDING
                # allow-rule emits no permission event at all, so it is
                # absent from both numerator and denominator -- upstream has
                # the same blind spot for the same reason, since it only
                # sees the confirmations the harness reports.
                #
                # NOT IMPLEMENTED, deliberately: the tempting alternative is
                # to define auto-approval by subtraction, tool executions
                # minus permission events [measured: 1046 bash executions
                # against 219 shell permission requests, ratio ~0.96, fires
                # loudly]. That is rejected under upstream's rule id because
                # Copilot CLI ships an unpublished built-in allow-list of
                # safe read-only commands, so "no permission event"
                # conflates "the user auto-approved this" with "Copilot
                # never asks about ls". It is a good local signal under a
                # local name; it is not upstream's yolo-mode.
                #
                # isTerminal: upstream's flag for a shell confirmation
                # [upstream src/core/dsl/interpreter.ts:826]; Copilot CLI's
                # permissionRequest.kind == "shell" is the same thing.
                rec["toolConfirmations"].append({
                    "kind": kind or "unknown",
                    "result": result_kind,
                    "autoApproveScope": (
                        "always" if result_kind == "approved-for-location"
                        else None),
                    "isTerminal": kind == "shell",
                })
            continue

        if etype == "skill.invoked":
            name = data.get("name")
            if current is not None and isinstance(name, str) and name:
                current["skillsUsed"].append(name)
            continue

        if etype == "subagent.started":
            name = data.get("agentName")
            if current is not None and isinstance(name, str) and name:
                current["agentName"] = name
            continue

        if etype == "abort":
            if current is not None:
                current["isCanceled"] = True
            continue

    out = []
    for turn_id in order:
        rec = turns[turn_id]
        start, end = rec.pop("_start_ts"), rec.pop("_end_ts")
        rec["totalElapsed"] = _elapsed_ms(start, end)
        # Upstream de-duplicates both file lists; excessive-file-context
        # counts DISTINCT files, so leaving repeats in would inflate every
        # request that read the same file twice.
        rec["referencedFiles"] = _unique(rec["referencedFiles"])
        rec["editedFiles"] = _unique(rec["editedFiles"])
        rec["skillsUsed"] = _unique(rec["skillsUsed"])
        rec["aiCode"] = scans[turn_id].blocks
        rec["workspaceName"] = workspace or workspace_folder
        rec["customInstructionsBytes"] = instruction_bytes
        if not rec["toolsUsed"] and not rec["modelId"]:
            # A turn that produced neither a model attribution nor a tool
            # call is a fragment (truncated tail of an open session), not a
            # request; including it would dilute every ratio.
            continue
        out.append(rec)
    return out


def _unique(seq):
    """Order-preserving de-duplication (dict.fromkeys, not set) so example
    strings a rule emits stay in the order the files were touched."""
    return list(dict.fromkeys(seq))


def _elapsed_ms(start, end):
    """Milliseconds between two ISO-8601 event timestamps, or None.

    Returns None -- never 0 -- when either endpoint is missing or
    unparseable, so that `requests_with("totalElapsed")` excludes the record
    instead of scoring it as an instantaneous response.
    """
    if not isinstance(start, str) or not isinstance(end, str):
        return None
    try:
        from datetime import datetime
        fmt = lambda s: datetime.strptime(  # noqa: E731
            s.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z"
        )
        delta = fmt(end) - fmt(start)
    except (ValueError, TypeError):
        return None
    ms = int(delta.total_seconds() * 1000)
    return ms if ms >= 0 else None


# ---------------------------------------------------------------------------
# Copilot CLI: session-store.db -> API-call-level records
# ---------------------------------------------------------------------------

def _copilot_store_db(env=None):
    try:
        root = resolve_copilot_state_root(env)
    except (RuntimeError, OSError):
        return None
    db = root / "session-store.db"
    return db if db.is_file() else None


def _copilot_api_calls(env=None, limit_rows=20000):
    db = _copilot_store_db(env)
    if db is None:
        return []
    # Immutable URI: never takes a lock, never creates a -wal/-shm, and is
    # safe against a Copilot process holding the same file open. The cost is
    # that rows still only in the WAL are invisible -- acceptable for
    # habit-scale statistics and strictly better than risking the user's
    # live database.
    uri = "file:{}?immutable=1".format(db.as_posix().replace("?", "%3f").replace("#", "%23"))
    try:
        conn = sqlite3.connect(uri, uri=True)
    except sqlite3.Error:
        return []
    try:
        rows = conn.execute(
            "SELECT session_id, model, input_tokens, output_tokens, "
            "cache_read_tokens, duration_ms, reasoning_effort, initiator, "
            "finish_reason, created_at FROM assistant_usage_events "
            "ORDER BY id DESC LIMIT ?",
            (limit_rows,),
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        conn.close()

    out = []
    for (session_id, model, inp, outp, cache_read, duration,
         effort, initiator, finish, created) in rows:
        out.append({
            "source": "copilot",
            "session_id": session_id,
            "timestamp": created,
            "modelId": model or None,
            "promptTokens": inp if isinstance(inp, int) else None,
            "completionTokens": outp if isinstance(outp, int) else None,
            # 0 is a genuine, meaningful value here (a cold prompt with no
            # cache hit is exactly what cache-hit-starvation looks for), so
            # only a NULL column becomes None.
            "cacheReadTokens": cache_read if isinstance(cache_read, int) else None,
            "totalElapsed": duration if isinstance(duration, int) else None,
            "reasoningEffort": effort or None,
            "initiator": initiator or None,
            "finishReason": finish or None,
        })
    return out


# ---------------------------------------------------------------------------
# Claude Code: projects/<slug>/<sessionId>.jsonl
# ---------------------------------------------------------------------------

def _claude_projects_root(env=None):
    environ = os.environ if env is None else env
    home = environ.get("CLAUDE_CONFIG_DIR")
    if home:
        return Path(home) / "projects"
    user_home = environ.get("HOME") or environ.get("USERPROFILE")
    if not user_home:
        return None
    return Path(user_home) / ".claude" / "projects"


def _claude_transcripts(env=None, limit=MAX_SESSIONS):
    root = _claude_projects_root(env)
    if root is None or not root.is_dir():
        return []
    candidates = []
    for dirpath, _dirs, names in os.walk(str(root)):
        for name in names:
            if name.endswith(".jsonl"):
                p = Path(dirpath) / name
                try:
                    if p.stat().st_size <= MAX_EVENT_BYTES:
                        candidates.append(p)
                except OSError:
                    continue
    return _newest(candidates, limit)


def _claude_user_text(message):
    """Text of a Claude `type: user` line, or None when the line is a
    tool_result carrier rather than something a human typed. Distinguishing
    them matters: attributing a tool_result to a new request would multiply
    the request count by the number of tool calls."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                return None
        parts = [b.get("text", "") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        joined = "\n".join(p for p in parts if p)
        return joined or None
    return None


def _claude_records(path: Path):
    """Return (turn_requests, api_calls) for one Claude Code transcript.

    API calls are deduped by `requestId`: Claude Code writes one JSONL line
    per content BLOCK of a single API response (thinking, text, tool_use are
    separate lines) and repeats the identical `message.usage` object on each
    one. Summing usage per line would triple-count tokens on a typical
    tool-using response -- verified on a real transcript where three
    consecutive lines carried the same requestId and the same
    input_tokens/output_tokens.
    """
    session_id = path.stem
    turns = []
    api_calls = []
    seen_requests = set()
    current = None
    scans = {}
    workspace = None

    for event in _iter_jsonl(path):
        etype = event.get("type")
        if event.get("isSidechain"):
            continue
        # Every Claude Code line carries the session's working directory;
        # upstream buckets low-markdown-ratio by workspace, and this is the
        # only workspace identity the transcript offers.
        if workspace is None:
            cwd = event.get("cwd")
            if isinstance(cwd, str) and cwd:
                workspace = cwd

        message = event.get("message")
        if not isinstance(message, dict):
            continue

        if etype == "user":
            if event.get("interruptedMessageId") and current is not None:
                current["isCanceled"] = True
            if event.get("isMeta"):
                continue
            text = _claude_user_text(message)
            if text is None:
                continue
            current = {
                "source": "claude",
                "session_id": session_id,
                "turn_id": event.get("uuid"),
                "timestamp": event.get("timestamp"),
                "modelId": None,
                "messageText": text,
                "messageLength": len(text),
                "completionTokens": 0,
                "totalElapsed": None,
                "isCanceled": False,
                "toolsUsed": [],
                "referencedFiles": [],
                "editedFiles": [],
                "toolConfirmations": [],
                "skillsUsed": [],
                "agentName": None,
            }
            turns.append(current)
            scans[id(current)] = _CodeScan()
            continue

        if etype != "assistant":
            continue

        request_id = event.get("requestId")
        usage = message.get("usage")
        model = message.get("model")
        if request_id and request_id not in seen_requests and isinstance(usage, dict):
            seen_requests.add(request_id)
            cache_read = usage.get("cache_read_input_tokens")
            api_calls.append({
                "source": "claude",
                "session_id": session_id,
                "timestamp": event.get("timestamp"),
                "modelId": model or None,
                "promptTokens": usage.get("input_tokens")
                    if isinstance(usage.get("input_tokens"), int) else None,
                "completionTokens": usage.get("output_tokens")
                    if isinstance(usage.get("output_tokens"), int) else None,
                "cacheReadTokens": cache_read if isinstance(cache_read, int) else None,
                # Claude Code's transcript records no per-response wall
                # clock and no reasoning-effort setting. None, not 0/"".
                "totalElapsed": None,
                "reasoningEffort": None,
                "initiator": None,
                "finishReason": message.get("stop_reason") or None,
            })
            if current is not None and isinstance(usage.get("output_tokens"), int):
                current["completionTokens"] += usage["output_tokens"]

        if current is not None:
            if model:
                current["modelId"] = model
            scan = scans.get(id(current))
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        # Upstream pushes assistant text blocks into
                        # assistantTexts, joined with '\n' -- so prose fences
                        # count exactly like written files.
                        text = block.get("text")
                        if isinstance(text, str) and scan is not None:
                            scan.feed(text, separator_len=1)
                        continue
                    if block.get("type") != "tool_use":
                        continue
                    name = block.get("name")
                    if not isinstance(name, str) or not name:
                        continue
                    current["toolsUsed"].append(name)
                    args = block.get("input")
                    if name == "Skill":
                        skill = _arg(args, "skill")
                        # Upstream drops the ai_toolkit pseudo-skill; match
                        # that so skill counts mean the same thing here.
                        if skill and "ai_toolkit" not in skill:
                            current["skillsUsed"].append(skill)
                    elif name in CLAUDE_WRITE_TOOLS:
                        path = _arg(args, "file_path")
                        if path:
                            current["editedFiles"].append(path)
                        fence = _code_fence(path, _first_str(args, CLAUDE_CODE_ARG_KEYS))
                        if fence and scan is not None:
                            scan.feed(fence, separator_len=1)
                    elif name in CLAUDE_READ_FILE_TOOLS:
                        path = _arg(args, "file_path")
                        if path:
                            current["referencedFiles"].append(path)
                    elif name in CLAUDE_READ_PATH_TOOLS:
                        path = _arg(args, "path")
                        if path:
                            current["referencedFiles"].append(path)
                    elif name in ("Agent", "Task"):
                        sub = _arg(args, "subagent_type")
                        if sub:
                            current["agentName"] = sub

    for rec in turns:
        rec["referencedFiles"] = _unique(rec["referencedFiles"])
        rec["editedFiles"] = _unique(rec["editedFiles"])
        rec["skillsUsed"] = _unique(rec["skillsUsed"])
        rec["aiCode"] = scans[id(rec)].blocks
        rec["workspaceName"] = workspace
        rec["customInstructionsBytes"] = _instruction_bytes(
            workspace, CLAUDE_INSTRUCTIONS_RELPATH)
    return turns, api_calls


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def build_turn_requests(env=None, limit=MAX_SESSIONS):
    """One record per user request, across every harness whose store is
    present. Empty list when neither harness has readable state -- callers
    MUST treat that as "skip this rule loudly", never as "no problems
    found"."""
    records = []
    for events in _copilot_event_files(env, limit):
        records.extend(_copilot_turns(events))
    for transcript_path in _claude_transcripts(env, limit):
        turns, _api = _claude_records(transcript_path)
        records.extend(turns)
    return records


def build_sessions(records):
    """Group turn records into upstream's session shape.

    Four of the aiCode rules are `scan: sessions`, and upstream's helpers
    (computeSpeedAcceptPairs, computeMdRatio) walk `session.requests` in
    order. Grouping here rather than in each adapter keeps "what is a
    session" in one place.

    Keyed by (source, session_id) so a Copilot and a Claude session that
    happen to share an id are never merged. Request order is preserved --
    speed-accept's adjacent-pair gap is meaningless otherwise.
    """
    sessions = {}
    order = []
    for rec in records:
        key = (rec.get("source"), rec.get("session_id"))
        if key not in sessions:
            sessions[key] = {
                "source": rec.get("source"),
                "sessionId": rec.get("session_id"),
                # Upstream falls back workspaceName -> workspaceId ->
                # 'unknown'; here the session id is the only other identity,
                # and lumping every unknown-workspace session into one
                # bucket would make low-markdown-ratio answer about a
                # workspace that does not exist.
                "workspaceName": rec.get("workspaceName") or rec.get("session_id"),
                "requests": [],
            }
            order.append(key)
        sessions[key]["requests"].append(rec)
    out = []
    for key in order:
        session = sessions[key]
        session["requestCount"] = len(session["requests"])
        out.append(session)
    return out


def ai_loc(record):
    """Sum of `aiCode[].loc` for one request -- upstream's
    flatSumField(requests, "aiCode", "loc") for a single element."""
    return sum(block.get("loc") or 0 for block in (record.get("aiCode") or []))


def session_ai_loc(session):
    return sum(ai_loc(rec) for rec in session["requests"])


def build_api_calls(env=None, limit=MAX_SESSIONS):
    """One record per model API call, across every harness present."""
    records = list(_copilot_api_calls(env))
    for transcript_path in _claude_transcripts(env, limit):
        _turns, api = _claude_records(transcript_path)
        records.extend(api)
    return records


def requests_with(records, *fields):
    """Records where EVERY named field is present (not None).

    The only supported way for a rule adapter to select its input. A field
    that is None means the harness that produced this record does not
    provide it; scoring such a record as 0/""/[] is what turns a real
    coverage gap into a silent all-clear, which this branch treats as worse
    than skipping.
    """
    out = []
    for rec in records:
        if all(rec.get(f) is not None for f in fields):
            out.append(rec)
    return out


def _main(argv):
    """`python3 telemetry.py [turns|calls]` -- prints a JSON array. Exists so
    the extraction can be inspected against a real store without going
    through the rules evaluator."""
    what = argv[1] if len(argv) > 1 else "turns"
    data = build_turn_requests() if what == "turns" else build_api_calls()
    json.dump(data, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
