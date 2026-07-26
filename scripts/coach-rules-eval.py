#!/usr/bin/env python3
"""coach-rules-eval.py — evaluate vendored AI Engineering Coach anti-pattern
rules ADAPTED to this project's own session index.

IMPORTANT — these are ADAPTATIONS, not the upstream rules re-implemented:
Upstream (microsoft/AI-Engineering-Coach) rules with `scan: requests` are
written against VS Code Copilot Chat's own per-turn telemetry object
(modelId, toolsUsed[], referencedFiles[], editedFiles[], aiCode.loc,
isCanceled, agentMode/agentName, reasoningEffort, promptTokens/
completionTokens/cacheReadTokens, totalElapsed, toolConfirmations[],
customInstructions, skillsUsed[], slashCommand, workspaceName).

TWO DATA SOURCES, AND A CORRECTION OF RECORD (2026-07-26)
---------------------------------------------------------
This module long said that "none of that exists in this project's data".
That was true of this project's OWN index -- schema/session-search-schema.sql
stores, per message, only `role`, `content` (flattened text; tool calls
survive as an unattributed "[tool: Name]" marker with no args/paths) and
`timestamp`, plus session-level `project_path`/`message_count` -- and it was
WRONG as a statement about what is available. Both harnesses write rich
per-request telemetry of their own, and this project already reads those
same stores to build the reviewer's conversation digest
(scripts/lib/transcript.py). Fields recorded here as "not captured" for
months were captured by the harness all along and simply never plumbed.

So there are now two sources:

  1. The project's own index (SL_SEARCH_DB) -- role/content/timestamp.
     Feeds the generic engine, REQUEST_ADAPTERS, and the two bespoke
     session adapters.
  2. scripts/lib/telemetry.py -- Copilot CLI's
     session-state/<id>/events.jsonl and session-store.db, and Claude
     Code's projects/<slug>/<id>.jsonl, normalised into per-turn and
     per-API-call records. Feeds TELEMETRY_ADAPTERS. See that module's
     docstring for the field-by-field evidence, which was gathered by
     reading the real stores, not from documentation.

A rule whose input selection comes back empty raises, so it SKIPS loudly
rather than reporting a clean bill of health from no data.

Where a rule's *predicate* can be evaluated faithfully against an
equivalent field we genuinely store, this module does so and calls the
result "requests" scope narrowed to "per-user-message text/timestamp from
the `messages` table" — never "the upstream rule". Every such substitution
is a documented, lossy adaptation (see ADAPTATION NOTES below). Where a
rule needs a field we do not capture, it is skipped with a message naming
the specific missing field(s) — never silently coerced to a "supported but
always empty" no-op signal.

ADAPTATION NOTES (each is lossy; documented per project instruction):
  - tunnel-vision: upstream groups by `workspaceName`; we group by this
    project's `project_path` column instead (the closest equivalent we
    store — one Claude Code/Copilot CLI project == one workspace).
  - mcp-tool-bloat: upstream counts distinct tools from structured
    `toolsUsed[]` per request; we regex-count distinct "[tool: X]" markers
    embedded in stored message text across a session. This loses tool
    call arguments and file paths, and only sees tools whose invocation
    survived index-session.py's message flattening.
  - repeated-prompts: upstream's `duplicateGroups(...)` is a near-duplicate
    (fuzzy) grouping algorithm with no available specification; we
    implement EXACT-duplicate grouping (case-insensitive, whitespace-
    normalized) on stored `content`, which is narrower than "near-duplicate".
  - late-night-coding / weekend-overwork: hour-of-day / day-of-week are
    computed in UTC from the stored timestamp (parsed via
    scripts/lib/isotime.py, the project's single source of truth for
    ISO-8601 parsing) — not the user's local timezone, which we do not
    capture.
  - caps-lock / frustration-signals: `capsLetterRatio`/`capsWordRatio`/
    `matchesAny` are this evaluator's own reconstruction of underspecified
    upstream helper functions (no implementation is vendored or available
    upstream). Validated against the `# Tests` fixtures embedded in
    lazy-prompting.md and frustration-signals.md themselves.

Supported `detect` DSL, scan: sessions (generic engine):
    match: requestCount <op> thresholds.<key>
    aggregate: count | ratio
    check: one or more `<count|ratio> <op> (thresholds.<key>|<literal>)`
           clauses joined by " AND "
`requestCount` maps to the sessions.message_count column.

Plus per-rule-id adapters (see REQUEST_ADAPTERS/TELEMETRY_ADAPTERS/
eval_tunnel_vision/eval_mcp_tool_bloat below) for rules whose detect block
does not fit the generic engine but whose predicate is evaluable against
data we have. Every other rule is skipped with a specific reason (see
UNSUPPORTED_REASONS).

That `detect` grammar above is a deliberately narrow SUBSET of upstream's.
Upstream ships a real expression language -- lexer, parser and interpreter
under src/core/dsl/ (~4,300 lines) with function calls, pipes and format
filters. This module hand-parses two regex-shaped clause forms and hardcodes
everything else per rule id. That is a scoping decision, not an
implementation of the dialect: any rule whose detect block changes shape is
refused by its adapter's `_pin()` check rather than silently misread.
"""

from __future__ import annotations

import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from isotime import parse_iso  # noqa: E402  (single source of truth, see module docstring)
import telemetry  # noqa: E402  (harness-native per-request telemetry; see TELEMETRY_ADAPTERS)

OPS = {
    ">=": lambda a, b: a >= b,
    "<=": lambda a, b: a <= b,
    "==": lambda a, b: a == b,
    ">": lambda a, b: a > b,
    "<": lambda a, b: a < b,
}

MATCH_RE = re.compile(
    r"^requestCount\s*(>=|<=|==|>|<)\s*(thresholds\.[A-Za-z_][A-Za-z0-9_]*|[0-9]+(?:\.[0-9]+)?)$"
)

CHECK_CLAUSE_RE = re.compile(
    r"^(count|ratio)\s*(>=|<=|==|>|<)\s*(thresholds\.[A-Za-z_][A-Za-z0-9_]*|[0-9.]+)$"
)

# Rule ids evaluated by a bespoke adapter rather than the generic
# requestCount engine.
BESPOKE_SESSION_IDS = {"tunnel-vision", "mcp-tool-bloat"}

# ---------------------------------------------------------------------------
# Rules this evaluator does NOT evaluate, each with the SPECIFIC reason.
#
# REWRITTEN 2026-07-26 against upstream's own source, not against a guess.
# The previous version of this table said "not captured" for most entries,
# meaning "not in schema/session-search-schema.sql". That conflated one
# project's index with what is obtainable, and it was wrong for a majority
# of the entries. Ground truth, read from microsoft/AI-Engineering-Coach at
# HEAD 766d0f2 (2026-07-24), which is also the commit the rules are now
# vendored at. The six commits between the previously vendored 9b4deb1 and
# 766d0f2 are all Dependabot bumps: nothing under src/core/rules, src/core/dsl
# or any parser changed, and a live re-run of scripts/sync-coach-rules.sh
# produced byte-identical rule files. (An earlier comment claimed 9b4deb1 was
# unreachable upstream; it is a direct ancestor of HEAD -- compare reports
# status "ahead", behind_by 0.):
#
#   * Upstream is not a VS Code-internals consumer. Its README is "any
#     harness, one dashboard", and src/core/parser-harnesses.ts registers
#     parsers for Claude Code, Codex CLI and OpenCode alongside VS Code;
#     src/core/parser-vscode-cli.ts parses Copilot CLI's OWN
#     session-state/<id>/events.jsonl -- the same file scripts/lib/
#     telemetry.py now reads. src/core/types/session-types.ts even documents
#     the CLI origins field by field ("Copilot CLI: session.start.data.
#     reasoningEffort and session.model_change.data.reasoningEffort").
#     So the telemetry was never unobtainable; it was unplumbed.
#
#   * Upstream itself marks exactly ELEVEN rules `requiresIdeContext: true`
#     and DROPS them when analysing a non-IDE harness
#     (src/core/detector-registry.ts getActiveDetectors(); the flag is set
#     in analyzer-patterns.ts as `harness && !startsWith('Local Agent') &&
#     !== 'Xcode'`). Those eleven are marked IDE-ONLY below. For a CLI
#     harness they are a CORRECT permanent skip, not a coverage gap --
#     upstream would skip them too. They are reachable only through Route B
#     (`SL_COACH_EXPORT_ENABLED`, the Coach extension's own export), and
#     then only for sessions the user actually ran in VS Code Copilot Chat.
#
#   * The remaining entries are genuinely reachable from data already on
#     disk, and are skipped here for a stated cost/fidelity reason, not
#     because the data is missing. Each names what would have to be built.
# ---------------------------------------------------------------------------
UNSUPPORTED_REASONS = {
    # -- IDE-ONLY (upstream `requiresIdeContext: true`; skipped for CLI
    #    harnesses by upstream too). Route B reaches these; Route A cannot,
    #    and should not pretend to.
    "agent-mode-for-asks": "IDE-ONLY (upstream requiresIdeContext): keys off "
        "VS Code's ask/agent mode toggle. Neither CLI has that toggle -- "
        "upstream's own CLI parser hardcodes agentMode='agent' "
        "(parser-vscode-cli.ts, parser-claude.ts), so the rule's ask-mode "
        "branch could never fire here. Reachable via Route B only",
    "agentic-no-tools": "IDE-ONLY (upstream requiresIdeContext): same "
        "agentMode dependency as agent-mode-for-asks. toolsUsed IS now "
        "captured (see telemetry.py), but the mode half of the predicate is "
        "constant for a CLI harness. Reachable via Route B only",
    "auto-approve-terminal": "IDE-ONLY (upstream requiresIdeContext), and "
        "independently unmeasurable here: upstream's CLI and Claude parsers "
        "populate toolConfirmations for NO harness but VS Code "
        "(parser-vscode-request.ts is the only parser that sets it). Copilot "
        "CLI does emit permission.requested/completed, but an AUTO-approved "
        "call emits no permission event at all -- measured across 242 real "
        "confirmations, every approval took human-scale time (min 0.638s) "
        "and only non-interactive DENIALS were instantaneous (median "
        "0.004s). An auto-approve RATE computed from this stream would have "
        "a permanently zero numerator: a rule that evaluates and can never "
        "fire, which is worse than this skip. Reachable via Route B only",
    "instruction-bloat": "IDE-ONLY (upstream requiresIdeContext): needs "
        "customInstructions byte size, which upstream reads from the VS Code "
        "workspace, not from any CLI session log. Reachable via Route B only",
    "no-custom-instructions": "IDE-ONLY (upstream requiresIdeContext): same "
        "customInstructions dependency. Reachable via Route B only",
    "no-devcontainer": "IDE-ONLY (upstream requiresIdeContext): needs a "
        "vscode-vs-terminal request classification, a distinction that does "
        "not exist inside a single CLI harness. Reachable via Route B only",
    "no-file-context": "IDE-ONLY (upstream requiresIdeContext): the rule is "
        "about attaching file context in the chat UI. referencedFiles/"
        "editedFiles ARE now captured for both CLIs (telemetry.py), but a "
        "CLI agent reads files by calling a tool, so the absence the rule "
        "looks for cannot occur and it would never fire. Reachable via "
        "Route B only",
    "no-plan-mode": "IDE-ONLY (upstream requiresIdeContext): needs VS Code's "
        "plan mode / slash command surface. Reachable via Route B only",
    "no-skills": "IDE-ONLY (upstream requiresIdeContext). skillsUsed IS now "
        "captured (Copilot's `skill` tool + skill.invoked; Claude's Skill "
        "tool), but the rule fires on the ABSENCE of skill usage across an "
        "IDE session population, which a CLI-only corpus cannot represent. "
        "Reachable via Route B only",
    "no-slash-commands": "IDE-ONLY (upstream requiresIdeContext): needs a "
        "parsed slashCommand, which upstream extracts only in the VS Code "
        "request parser. Confirmed absent from the CLI corpus: 0 of 136 "
        "real Copilot user.message events began with a slash. Reachable via "
        "Route B only",
    "yolo-mode": "IDE-ONLY (upstream requiresIdeContext), and independently "
        "unmeasurable here for the same reason as auto-approve-terminal -- "
        "see that entry for the measured evidence. Reachable via Route B only",

    # -- REACHABLE from data already on disk, not implemented here. Each of
    #    these is a cost/fidelity decision with a named missing piece, NOT a
    #    missing-data claim.
    "broken-flow-state": "reachable but not implemented: needs "
        "flowScoreStats, a per-day session-fragmentation score. Upstream "
        "implements it in src/core/analyzer-flow.ts; the vendored rule file "
        "does not carry the algorithm, so evaluating it here means porting "
        "that analyzer rather than adapting a predicate",
    "copy-paste-blindness": "reachable but not implemented: needs aiCode.loc "
        "per request. Upstream derives it by pulling generated code out of "
        "tool arguments (file_text/new_str/content) and counting lines "
        "(parser-vscode-cli.ts). telemetry.py captures the tool calls and "
        "paths but not the code bodies -- doing so would put whole file "
        "contents in memory for every indexed session",
    "low-markdown-ratio": "reachable but not implemented: same aiCode.loc "
        "dependency as copy-paste-blindness, plus per-language attribution",
    "speed-accept": "reachable but not implemented: same aiCode.loc "
        "dependency, plus inter-request acceptance timing",
    "vibe-coding": "reachable but not implemented: same aiCode.loc dependency",
    "no-spec-driven-development": "reachable but not implemented: needs "
        "first(requests).referencedFiles (now captured) AND .agentMode "
        "(constant 'agent' for both CLIs). Two of the rule's three OR "
        "branches would be dead, changing what the signal means",
    "no-spec-structure": "reachable but would never fire: the predicate is "
        "someWhere(requests, agentMode, agent), and agentMode is hardcoded "
        "'agent' for every CLI request by upstream's own parsers -- so the "
        "condition is universally true and the rule is a constant. Skipped "
        "deliberately rather than emitted as a permanent signal",
    "session-drift": "reachable but not implemented: needs "
        "workTypeCount(requests). Upstream ships a work-type classifier; the "
        "vendored rule does not carry its taxonomy, so implementing it here "
        "would mean inventing a different one and calling it the same rule",
    "context-engineering-gaps": "reachable but not implemented: needs "
        "agentName, skillsUsed, toolsUsed (mcp_ prefix) and referencedFiles "
        "-- all now captured -- PLUS customInstructions, which is not "
        "available outside the IDE. Blocked on that one field",
    "no-language-exploration": "reachable but not implemented: needs a "
        "per-request programming-language attribution, which upstream "
        "derives from aiCode blocks -- same dependency as vibe-coding",
    "auto-avoidance": "reachable but not implemented: modelId is now "
        "captured, but the predicate also needs modelTier(models.topModel) "
        "and a countWhere(...) regex over model ids -- the same maintained "
        "premium-tier table premium-waste needs",
    "premium-waste": "reachable but not implemented: needs modelTier(modelId) "
        "AND aiCode.length. modelId is now captured; the tier mapping is a "
        "maintained upstream table of which model ids bill as premium, and "
        "hardcoding a snapshot of it here would silently rot as models ship",
    "premium-for-lookup-questions": "reachable but not implemented: same "
        "modelTier(modelId) dependency as premium-waste",
    "verbose-prompt-no-compression": "reachable but not implemented: needs "
        "hasSkillByPattern(skillsUsed) -- skillsUsed is now captured, but "
        "the rule's pattern set is not carried in the vendored rule file",
    "profanity": "no patterns: the wordlist is supplied by the rule and the "
        "vendored file carries none; upstream keeps it in src/core/"
        "profanity.ts. Evaluating it would mean inventing a moderation "
        "wordlist -- a product judgment out of scope for this evaluator",
}


def parse_rule(path):
    """Parse frontmatter (flat keys + one-level `thresholds:`/`patterns:`
    maps), the `# How to Improve` section, and the ```detect block."""
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None

    meta = {}
    thresholds = {}
    patterns = {}
    section = None  # None | "thresholds" | "patterns"
    end_idx = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end_idx = i
            break
        if line.startswith("thresholds:"):
            section = "thresholds"
            continue
        if line.startswith("patterns:"):
            section = "patterns"
            continue
        if section and re.match(r"^\s+[A-Za-z_]", line):
            key, _, val = line.strip().partition(":")
            key = key.strip()
            val = val.strip()
            if section == "thresholds":
                try:
                    thresholds[key] = float(val) if "." in val else int(val)
                except ValueError:
                    thresholds[key] = val
            else:
                try:
                    patterns[key] = json.loads(val)
                except (json.JSONDecodeError, ValueError):
                    pass  # malformed pattern list -> key stays absent -> skip
            continue
        section = None
        key, sep, val = line.partition(":")
        if sep:
            meta[key.strip()] = val.strip()
    if end_idx is None:
        return None

    body = "\n".join(lines[end_idx + 1:])

    improve = ""
    m = re.search(r"^# How to Improve\s*\n(.*?)(?=^# |\Z)", body, re.M | re.S)
    if m:
        improve = " ".join(m.group(1).split())

    detect = {}
    m = re.search(r"```detect\s*\n(.*?)```", body, re.S)
    if m:
        for dline in m.group(1).splitlines():
            key, sep, val = dline.partition(":")
            if sep:
                detect[key.strip()] = val.strip()

    return {
        "id": meta.get("id", path.stem),
        "severity": meta.get("severity", "unknown"),
        "thresholds": thresholds,
        "patterns": patterns,
        "suggestion": improve,
        "detect": detect,
    }


def load_sessions(db_path):
    """Return list of {session_id, project_path, message_count} or None if
    the db is missing/unreadable. Tolerates a `sessions` table that lacks
    `project_path` (older/minimal schemas) by defaulting it to ""; only the
    tunnel-vision adapter needs project_path, and it degrades to a single
    group in that case rather than failing every rule."""
    if not Path(db_path).is_file():
        return None
    conn = sqlite3.connect(str(db_path))
    try:
        try:
            rows = conn.execute(
                "SELECT session_id, project_path, message_count FROM sessions"
            ).fetchall()
        except sqlite3.OperationalError:
            rows = [
                (r[0], "", r[1]) for r in
                conn.execute("SELECT session_id, message_count FROM sessions").fetchall()
            ]
    except sqlite3.Error:
        return None
    finally:
        conn.close()
    return [
        {"session_id": r[0], "project_path": r[1] or "", "message_count": r[2] or 0}
        for r in rows
    ]


def load_user_messages(db_path):
    """Return list of {session_id, content, timestamp} for role='user' rows,
    or [] if unavailable."""
    if not Path(db_path).is_file():
        return []
    conn = sqlite3.connect(str(db_path))
    try:
        rows = conn.execute(
            "SELECT session_id, content, timestamp FROM messages WHERE role = 'user'"
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        conn.close()
    return [{"session_id": r[0], "content": r[1] or "", "timestamp": r[2]} for r in rows]


def load_tool_markers_by_session(db_path):
    """Return {session_id: set(tool_name, ...)} parsed from the "[tool: X]"
    markers index-session.py embeds in stored message content. ADAPTATION:
    loses tool-call arguments and file paths -- see module docstring."""
    if not Path(db_path).is_file():
        return {}
    conn = sqlite3.connect(str(db_path))
    try:
        rows = conn.execute("SELECT session_id, content FROM messages").fetchall()
    except sqlite3.Error:
        return {}
    finally:
        conn.close()
    result = defaultdict(set)
    marker_re = re.compile(r"\[tool: ([^\]]+)\]")
    for session_id, content in rows:
        for name in marker_re.findall(content or ""):
            result[session_id].add(name)
    return result


# --------------------------------------------------------------------------
# Generic engine: scan: sessions, match: requestCount <op> thresholds.key
# --------------------------------------------------------------------------

def _resolve_check_operand(token, thresholds, values):
    if token in values:
        return values[token]
    if token.startswith("thresholds."):
        key = token[len("thresholds."):]
        return thresholds.get(key)
    try:
        return float(token) if "." in token else int(token)
    except ValueError:
        raise ValueError("cannot resolve check operand {!r}".format(token))


def eval_check(check_str, thresholds, values):
    """Evaluate a check string of one or more `<lhs> <op> <rhs>` clauses
    joined by literal " AND ". Raises ValueError for anything else."""
    clauses = check_str.split(" AND ")
    for clause in clauses:
        clause = clause.strip()
        m = CHECK_CLAUSE_RE.match(clause)
        if not m:
            raise ValueError("unsupported check clause: {}".format(clause))
        lhs, op, rhs = m.groups()
        lhs_val = _resolve_check_operand(lhs, thresholds, values)
        rhs_val = _resolve_check_operand(rhs, thresholds, values)
        if lhs_val is None or rhs_val is None:
            raise ValueError("undefined operand in check clause: {}".format(clause))
        if not OPS[op](lhs_val, rhs_val):
            return False
    return True


def eval_generic_session_rule(rule, sessions):
    """requestCount-only scan:sessions rules (mega-sessions, abandon-sessions)."""
    d = rule["detect"]
    if d.get("scan") != "sessions":
        raise ValueError("unsupported scan: {}".format(d.get("scan")))
    if d.get("aggregate") not in ("count", "ratio"):
        raise ValueError("unsupported aggregate: {}".format(d.get("aggregate")))
    m = MATCH_RE.match(d.get("match", ""))
    if not m:
        raise ValueError("match not in the generic requestCount form: {}".format(d.get("match")))
    op, rhs = m.group(1), m.group(2)
    if rhs.startswith("thresholds."):
        key = rhs[len("thresholds."):]
        if key not in rule["thresholds"]:
            raise ValueError("threshold {} not defined".format(key))
        threshold = rule["thresholds"][key]
        if not isinstance(threshold, (int, float)):
            raise ValueError("threshold {} is not numeric".format(key))
    else:
        threshold = float(rhs) if "." in rhs else int(rhs)

    total = len(sessions)
    matched = sum(1 for s in sessions if OPS[op](s["message_count"], threshold))
    ratio = (matched / total) if total else 0.0
    values = {"count": matched, "ratio": ratio}

    check = d.get("check", "")
    if not check:
        raise ValueError("no check clause")
    if not eval_check(check, rule["thresholds"], values):
        return None
    return matched


# --------------------------------------------------------------------------
# Bespoke adapters
# --------------------------------------------------------------------------

def eval_tunnel_vision(rule, sessions):
    """ADAPTATION: workspaceName -> project_path (see module docstring)."""
    d = rule["detect"]
    expected_check = ("top.share > thresholds.maxTopRate AND top.sum >= "
                       "thresholds.minReqs AND top.count >= thresholds.minWorkspaces")
    if d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("maxTopRate", "minReqs", "minWorkspaces"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    by_project = defaultdict(int)
    for s in sessions:
        by_project[s["project_path"]] += s["message_count"]
    if not by_project:
        return None
    total = sum(by_project.values())
    top_key, top_sum = max(by_project.items(), key=lambda kv: kv[1])
    share = (top_sum / total) if total else 0.0
    workspace_count = len(by_project)

    if not (share > t["maxTopRate"] and top_sum >= t["minReqs"]
            and workspace_count >= t["minWorkspaces"]):
        return None
    return top_sum


def eval_mcp_tool_bloat(rule, tool_markers_by_session):
    """ADAPTATION: toolsUsed[] per request -> "[tool: X]" text markers
    accumulated per session (see module docstring: loses args/paths)."""
    d = rule["detect"]
    expected_match = 'flatUnique(reqs, "toolsUsed") > thresholds.maxToolsPerSession'
    expected_check = "count >= thresholds.minSessions"
    if d.get("match", "").strip() != expected_match or d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("maxToolsPerSession", "minSessions"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    bloated = sum(
        1 for tools in tool_markers_by_session.values()
        if len(tools) > t["maxToolsPerSession"]
    )
    if bloated < t["minSessions"]:
        return None
    return bloated


_WORD_RE = re.compile(r"[A-Za-z']+")


def caps_letter_ratio(text):
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 0.0
    upper = sum(1 for c in letters if c.isupper())
    return upper / len(letters)


def caps_word_ratio(text, min_word_len):
    words = [w for w in _WORD_RE.findall(text) if len(w) >= min_word_len]
    if not words:
        return 0.0
    upper = sum(1 for w in words if w.isupper())
    return upper / len(words)


def eval_caps_lock(rule, user_messages):
    d = rule["detect"]
    expected_match = ("messageLength >= thresholds.minLength AND "
                       "capsLetterRatio(messageText) >= thresholds.capsRate")
    expected_check = "count >= thresholds.minReqs"
    if d.get("match", "").strip() != expected_match or d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("minLength", "capsRate", "minReqs"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    matched = sum(
        1 for m in user_messages
        if len(m["content"]) >= t["minLength"]
        and caps_letter_ratio(m["content"]) >= t["capsRate"]
    )
    if matched < t["minReqs"]:
        return None
    return matched


def eval_late_night_coding(rule, user_messages):
    d = rule["detect"]
    expected_match = ("timestamp > 0 AND hour(timestamp) >= 0 AND "
                       "hour(timestamp) < thresholds.lateNightHour")
    expected_check = "count > thresholds.minSample"
    if d.get("match", "").strip() != expected_match or d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("lateNightHour", "minSample"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    matched = 0
    for m in user_messages:
        epoch = parse_iso(m["timestamp"])
        if epoch is None:
            continue
        hour = datetime.fromtimestamp(epoch, tz=timezone.utc).hour  # UTC, see docstring
        if 0 <= hour < t["lateNightHour"]:
            matched += 1
    if matched <= t["minSample"]:
        return None
    return matched


def eval_lazy_prompting(rule, user_messages):
    d = rule["detect"]
    expected_match = "messageLength < thresholds.minChars AND messageLength > 0"
    expected_check = "ratio > thresholds.maxRatio AND count > thresholds.minSample"
    if d.get("match", "").strip() != expected_match or d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("minChars", "maxRatio", "minSample"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    total = len(user_messages)
    matched = sum(
        1 for m in user_messages
        if 0 < len(m["content"]) < t["minChars"]
    )
    ratio = (matched / total) if total else 0.0
    if not (ratio > t["maxRatio"] and matched > t["minSample"]):
        return None
    return matched


_LOW_CONSTRAINT_RE = re.compile(
    r"(?i)\b(do not|don't|must not|never|without|avoid|only|strictly|"
    r"limit to|at most|at least|no more than|require|restrict|exclude|"
    r"ensure|must|shall|should not)\b"
)


def eval_low_constraint_usage(rule, user_messages):
    d = rule["detect"]
    expected_check = ("substantialTotal >= thresholds.minReqs AND count / "
                       "substantialTotal > (1 - thresholds.constraintRate)")
    if d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("minReqs", "minMessageLength", "constraintRate"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    substantial = [m for m in user_messages if len(m["content"]) >= t["minMessageLength"]]
    substantial_total = len(substantial)
    unconstrained = sum(1 for m in substantial if not _LOW_CONSTRAINT_RE.search(m["content"]))
    if substantial_total == 0:
        return None
    if not (substantial_total >= t["minReqs"]
            and unconstrained / substantial_total > (1 - t["constraintRate"])):
        return None
    return unconstrained


def eval_weekend_overwork(rule, user_messages):
    d = rule["detect"]
    expected_match = "timestamp > 0 AND (dayOfWeek(timestamp) == 0 OR dayOfWeek(timestamp) == 6)"
    expected_check = "ratio > thresholds.maxWeekendRate AND count > thresholds.minWeekendReqs"
    if d.get("match", "").strip() != expected_match or d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("maxWeekendRate", "minWeekendReqs"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))

    total = 0
    matched = 0
    for m in user_messages:
        epoch = parse_iso(m["timestamp"])
        if epoch is None:
            continue
        total += 1
        dow = (datetime.fromtimestamp(epoch, tz=timezone.utc).weekday() + 1) % 7  # Sun=0..Sat=6
        if dow in (0, 6):
            matched += 1
    ratio = (matched / total) if total else 0.0
    if not (ratio > t["maxWeekendRate"] and matched > t["minWeekendReqs"]):
        return None
    return matched


def eval_repeated_prompts(rule, user_messages):
    """ADAPTATION: exact-duplicate grouping, not upstream's unspecified
    near-duplicate algorithm (see module docstring)."""
    d = rule["detect"]
    expected_check = "dupes.totalDupes >= thresholds.minDuplicates"
    if d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    if "minDuplicates" not in t:
        raise ValueError("threshold minDuplicates not defined")

    normalized = [
        " ".join(m["content"].strip().lower().split())
        for m in user_messages if m["content"].strip()
    ]
    counts = Counter(normalized)
    total_dupes = sum(c for c in counts.values() if c >= t["minDuplicates"])
    if total_dupes < t["minDuplicates"]:
        return None
    return total_dupes


def eval_frustration_signals(rule, user_messages):
    d = rule["detect"]
    expected_match = ('messageLength >= 10 AND (matchesAny(messageText, '
                       'patterns.frustration) OR capsWordRatio(messageText, '
                       'thresholds.minWords) >= thresholds.capsRate)')
    expected_check = "count >= thresholds.minReqs"
    if d.get("match", "").strip() != expected_match or d.get("check", "").strip() != expected_check:
        raise ValueError("detect block changed since this adapter was written")
    t = rule["thresholds"]
    for key in ("capsRate", "minWords", "minReqs"):
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))
    frustration_patterns = rule["patterns"].get("frustration")
    if not frustration_patterns:
        raise ValueError("patterns.frustration not defined")
    compiled = [re.compile(p) for p in frustration_patterns]

    matched = 0
    for m in user_messages:
        text = m["content"]
        if len(text) < 10:
            continue
        if any(p.search(text) for p in compiled) or caps_word_ratio(text, t["minWords"]) >= t["capsRate"]:
            matched += 1
    if matched < t["minReqs"]:
        return None
    return matched


# --------------------------------------------------------------------------
# Telemetry-backed adapters (scripts/lib/telemetry.py)
#
# These rules were skipped as "not captured" until 2026-07-26. That was
# correct about this project's OWN session index (role/content/timestamp
# only) and wrong about the world: both harnesses write per-request
# telemetry of their own, and this project already reads those same stores
# for the reviewer's conversation digest. See telemetry.py's module
# docstring for the field-by-field evidence, gathered by reading the real
# stores rather than by consulting documentation.
#
# Two rules that LOOK reachable from the same data are still skipped, on
# evidence rather than assumption -- see UNSUPPORTED_REASONS for yolo-mode
# and auto-approve-terminal. Confirmations are captured; auto-approvals are
# not, because an auto-approved call emits no permission event at all. A
# rate over the surviving records would have a permanently zero numerator.
# --------------------------------------------------------------------------

def _require_records(records, rule_id, what):
    """Turn an empty telemetry selection into a loud skip.

    Never returns an empty list to an adapter. A rule scored against zero
    records reports "no problem found" in exactly the situation where the
    honest answer is "no data" -- the failure mode this branch has ruled
    worse than skipping.
    """
    if not records:
        raise ValueError(
            "harness telemetry has no usable {} records -- neither Copilot "
            "CLI's session-state/*/events.jsonl + session-store.db nor "
            "Claude Code's projects/*.jsonl yielded any (harness not "
            "installed, or no sessions yet)".format(what)
        )
    return records


def _pin(rule, match=None, check=None):
    d = rule["detect"]
    if match is not None and d.get("match", "").strip() != match:
        raise ValueError("detect block changed since this adapter was written")
    if check is not None and d.get("check", "").strip() != check:
        raise ValueError("detect block changed since this adapter was written")
    return d


def _thresholds(rule, *keys):
    t = rule["thresholds"]
    for key in keys:
        if key not in t:
            raise ValueError("threshold {} not defined".format(key))
    return t


def eval_model_overreliance(rule, tel):
    _pin(rule, check="models.topShare > thresholds.maxTopModelRate AND "
                     "models.modelCount < thresholds.minModels AND "
                     "models.total > thresholds.minSample")
    t = _thresholds(rule, "maxTopModelRate", "minModels", "minSample")
    calls = _require_records(
        telemetry.requests_with(tel.api_calls, "modelId"), rule["id"], "modelId")
    counts = Counter(c["modelId"] for c in calls)
    total = len(calls)
    top_count = counts.most_common(1)[0][1]
    share = top_count / total
    if not (share > t["maxTopModelRate"] and len(counts) < t["minModels"]
            and total > t["minSample"]):
        return None
    return top_count


def eval_reasoning_effort_overuse(rule, tel):
    _pin(rule, check="stats.totalKnown > thresholds.minSample AND "
                     "stats.ratio > thresholds.maxRatio")
    t = _thresholds(rule, "minSample", "maxRatio")
    # "totalKnown" is upstream's own word for it: records where the field is
    # ABSENT are excluded from the denominator, not counted as low effort.
    calls = _require_records(
        telemetry.requests_with(tel.api_calls, "reasoningEffort"),
        rule["id"], "reasoningEffort")
    premium = sum(1 for c in calls if c["reasoningEffort"] in ("high", "max"))
    ratio = premium / len(calls)
    if not (len(calls) > t["minSample"] and ratio > t["maxRatio"]):
        return None
    return premium


def eval_cache_hit_starvation(rule, tel):
    _pin(rule, match="promptTokens > thresholds.minPromptTokens",
               check="count > thresholds.minSample AND "
                     "cacheRate < thresholds.minCacheRate")
    t = _thresholds(rule, "minPromptTokens", "minSample", "minCacheRate")
    calls = _require_records(
        telemetry.requests_with(tel.api_calls, "promptTokens", "cacheReadTokens"),
        rule["id"], "promptTokens/cacheReadTokens")
    matched = [c for c in calls if c["promptTokens"] > t["minPromptTokens"]]
    if not matched:
        return None
    total_prompt = sum(c["promptTokens"] for c in matched)
    total_cache = sum(c["cacheReadTokens"] for c in matched)
    cache_rate = (total_cache / total_prompt) if total_prompt else 0.0
    if not (len(matched) > t["minSample"] and cache_rate < t["minCacheRate"]):
        return None
    return len(matched)


def eval_slow_responses(rule, tel):
    _pin(rule, match="totalElapsed > thresholds.slowMs AND totalElapsed > 0",
               check="count > thresholds.minCount")
    t = _thresholds(rule, "slowMs", "minCount")
    # Turn granularity, not API-call granularity: upstream's totalElapsed is
    # how long the USER waited for a request, which in an agentic harness
    # spans many API calls.
    turns = _require_records(
        telemetry.requests_with(tel.turns, "totalElapsed"), rule["id"], "totalElapsed")
    matched = sum(1 for r in turns if r["totalElapsed"] > t["slowMs"])
    if not matched > t["minCount"]:
        return None
    return matched


def eval_verbose_output(rule, tel):
    _pin(rule, match="completionTokens > thresholds.minCompletionTokens AND "
                     "messageLength > 0 AND messageLength < "
                     "thresholds.maxMessageLength",
               check="ratio > thresholds.maxRatio AND count > thresholds.minSample")
    t = _thresholds(rule, "minCompletionTokens", "maxMessageLength",
                    "minSample", "maxRatio")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "completionTokens", "messageLength"),
        rule["id"], "completionTokens/messageLength")
    matched = sum(1 for r in turns
                  if r["completionTokens"] > t["minCompletionTokens"]
                  and 0 < r["messageLength"] < t["maxMessageLength"])
    ratio = matched / len(turns)
    if not (ratio > t["maxRatio"] and matched > t["minSample"]):
        return None
    return matched


def eval_high_cancellation(rule, tel):
    _pin(rule, match="isCanceled == true", check="ratio > thresholds.maxCancelRate")
    t = _thresholds(rule, "maxCancelRate")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "isCanceled"), rule["id"], "isCanceled")
    matched = sum(1 for r in turns if r["isCanceled"])
    ratio = matched / len(turns)
    if not ratio > t["maxCancelRate"]:
        return None
    return matched


def eval_runaway_agent_loops(rule, tel):
    _pin(rule, match="toolsUsed.length >= thresholds.minToolsPerReq AND "
                     "(agentMode == \"agent\" OR agentName != \"\")",
               check="count >= thresholds.minReqs")
    t = _thresholds(rule, "minToolsPerReq", "minReqs")
    # ADAPTATION: the `agentMode == "agent"` branch is dropped -- neither
    # harness has an ask/agent mode toggle, so there is nothing to map it
    # to. The surviving `agentName != ""` branch is genuinely populated
    # (Copilot subagent.started.agentName; Claude Agent/Task tool inputs),
    # which is why this is an adaptation and not a silent no-op.
    turns = _require_records(
        telemetry.requests_with(tel.turns, "toolsUsed", "agentName"),
        rule["id"], "toolsUsed/agentName")
    matched = sum(1 for r in turns if len(r["toolsUsed"]) >= t["minToolsPerReq"])
    if not matched >= t["minReqs"]:
        return None
    return matched


def eval_excessive_file_context(rule, tel):
    _pin(rule, match="length(referencedFiles) >= thresholds.minFiles",
               check="stats.outlierCount >= thresholds.minOutliers AND "
                     "stats.ratio >= thresholds.maxRatio")
    t = _thresholds(rule, "minFiles", "minOutliers", "maxRatio")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "referencedFiles"),
        rule["id"], "referencedFiles")
    outliers = sum(1 for r in turns if len(r["referencedFiles"]) >= t["minFiles"])
    ratio = outliers / len(turns)
    if not (outliers >= t["minOutliers"] and ratio >= t["maxRatio"]):
        return None
    return outliers


TELEMETRY_ADAPTERS = {
    "excessive-file-context": eval_excessive_file_context,
    "model-overreliance": eval_model_overreliance,
    "reasoning-effort-overuse": eval_reasoning_effort_overuse,
    "cache-hit-starvation": eval_cache_hit_starvation,
    "slow-responses": eval_slow_responses,
    "verbose-output": eval_verbose_output,
    "high-cancellation": eval_high_cancellation,
    "runaway-agent-loops": eval_runaway_agent_loops,
}


class TelemetrySource:
    """Lazily-built, evaluated-once holder for the two telemetry streams.

    Built at most once per process and only if some rule actually asks for
    it: extraction walks up to MAX_SESSIONS harness session logs, which is
    real I/O that the eleven pre-existing rules have no use for.
    """

    def __init__(self, env=None):
        self._env = env
        self._turns = None
        self._api_calls = None

    @property
    def turns(self):
        if self._turns is None:
            self._turns = telemetry.build_turn_requests(self._env)
        return self._turns

    @property
    def api_calls(self):
        if self._api_calls is None:
            self._api_calls = telemetry.build_api_calls(self._env)
        return self._api_calls


REQUEST_ADAPTERS = {
    "caps-lock": eval_caps_lock,
    "late-night-coding": eval_late_night_coding,
    "lazy-prompting": eval_lazy_prompting,
    "low-constraint-usage": eval_low_constraint_usage,
    "weekend-overwork": eval_weekend_overwork,
    "repeated-prompts": eval_repeated_prompts,
    "frustration-signals": eval_frustration_signals,
}

# Total rule ids this evaluator can produce a signal for (used only for the
# coverage line printed to stderr).
SUPPORTED_COUNT = (len(REQUEST_ADAPTERS) + len(TELEMETRY_ADAPTERS)
                   + len(BESPOKE_SESSION_IDS) + 1)  # +1 = mega-sessions/abandon-sessions handled by the generic engine below, counted explicitly in main()


def main():
    if len(sys.argv) != 3:
        print("Usage: coach-rules-eval.py <rules_dir> <db_path>", file=sys.stderr)
        return 1

    rules_dir, db_path = Path(sys.argv[1]), sys.argv[2]
    sessions = load_sessions(db_path)
    if sessions is None:
        print("[]")
        return 0
    user_messages = load_user_messages(db_path)
    tool_markers_by_session = None  # lazily computed only if a rule needs it
    telemetry_source = None  # ditto -- harness telemetry is real I/O

    signals = []
    evaluated = 0
    skipped = 0
    for rule_file in sorted(rules_dir.glob("*.md")):
        if rule_file.name == "UPSTREAM.md":
            continue
        rule = parse_rule(rule_file)
        if rule is None:
            print("coach-rules-eval: skipping {} (no frontmatter)".format(rule_file.name),
                  file=sys.stderr)
            skipped += 1
            continue

        rule_id = rule["id"]
        reason = UNSUPPORTED_REASONS.get(rule_id)
        if reason is not None:
            print("coach-rules-eval: skipping {} (adapted evaluator {})".format(rule_id, reason),
                  file=sys.stderr)
            skipped += 1
            continue

        try:
            if rule_id in TELEMETRY_ADAPTERS:
                if telemetry_source is None:
                    telemetry_source = TelemetrySource()
                count = TELEMETRY_ADAPTERS[rule_id](rule, telemetry_source)
            elif rule_id in REQUEST_ADAPTERS:
                count = REQUEST_ADAPTERS[rule_id](rule, user_messages)
            elif rule_id == "tunnel-vision":
                count = eval_tunnel_vision(rule, sessions)
            elif rule_id == "mcp-tool-bloat":
                if tool_markers_by_session is None:
                    tool_markers_by_session = load_tool_markers_by_session(db_path)
                count = eval_mcp_tool_bloat(rule, tool_markers_by_session)
            else:
                count = eval_generic_session_rule(rule, sessions)
        except ValueError as exc:
            print("coach-rules-eval: skipping {} ({})".format(rule_id, exc),
                  file=sys.stderr)
            skipped += 1
            continue

        evaluated += 1
        if count is not None and count > 0:
            signals.append({
                "id": rule_id,
                "severity": rule["severity"],
                "suggestion": rule["suggestion"],
                "count": count,
                "source": "rules",
            })

    print(
        "coach-rules-eval: {} of 45 vendored rules evaluated (adapted to this "
        "project's own data, not upstream-equivalent), {} skipped -- see "
        "stderr above for each skip's specific missing-data reason".format(
            evaluated, skipped
        ),
        file=sys.stderr,
    )
    print(json.dumps(signals, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
