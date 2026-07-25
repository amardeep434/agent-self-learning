#!/usr/bin/env python3
"""coach-rules-eval.py — evaluate vendored AI Engineering Coach anti-pattern
rules ADAPTED to this project's own session index.

IMPORTANT — these are ADAPTATIONS, not the upstream rules re-implemented:
Upstream (microsoft/AI-Engineering-Coach) rules with `scan: requests` are
written against VS Code Copilot Chat's own per-turn telemetry object
(modelId, toolsUsed[], referencedFiles[], editedFiles[], aiCode.loc,
isCanceled, agentMode/agentName, reasoningEffort, promptTokens/
completionTokens/cacheReadTokens, totalElapsed, toolConfirmations[],
customInstructions, skillsUsed[], slashCommand, workspaceName). None of
that exists in this project's data for either Claude Code or Copilot CLI:
schema/session-search-schema.sql only stores, per message, `role`,
`content` (flattened text; tool calls survive only as an unattributed
"[tool: Name]" marker with no args/paths) and `timestamp`, plus session-
level `project_path`/`message_count`. There is no richer per-request
telemetry indexer for either harness.

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

Plus per-rule-id adapters (see REQUEST_ADAPTERS/eval_tunnel_vision/
eval_mcp_tool_bloat below) for rules whose detect block does not fit the
generic engine but whose predicate is evaluable against data we store.
Every other rule is skipped with a field-specific reason (see
UNSUPPORTED_REASONS).
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

# Field-specific reasons for every rule this evaluator does NOT evaluate.
# Named per project instruction: "unsupported" alone is not an acceptable
# skip reason -- state exactly what data would be needed.
UNSUPPORTED_REASONS = {
    # scan: sessions
    "broken-flow-state": "needs flowScoreStats (per-day session-fragmentation "
        "scoring across request timestamps) -- that algorithm is not specified "
        "anywhere in the vendored rule or an available upstream source; "
        "reconstructing it would be guessing, not adapting",
    "copy-paste-blindness": "needs aiCode.loc and per-request messageText/"
        "editedFiles at turn granularity within a session -- not captured; "
        "only session-level message_count is stored",
    "instruction-bloat": "needs customInstructions size per session -- "
        "Claude Code/Copilot CLI custom-instructions content is not captured",
    "low-markdown-ratio": "needs aiCode diff LOC (markdown vs code) per "
        "session -- code-change size is not captured",
    "no-devcontainer": "needs vscode-vs-terminal request classification "
        "(terminalReqs/vscodeReqs) -- a VS Code-specific concept not "
        "applicable to, or captured by, Claude Code/Copilot CLI",
    "no-spec-driven-development": "needs first(requests).referencedFiles and "
        ".agentMode -- not captured; evaluating on messageText alone would "
        "silently drop 2 of the rule's OR-branches and change its meaning",
    "no-spec-structure": "needs someWhere(requests, agentMode, agent) -- "
        "agentMode is not captured / not applicable to these harnesses",
    "session-drift": "needs workTypeCount(requests), a per-request work-type "
        "classifier with no taxonomy specified anywhere available -- would "
        "require inventing a classification scheme",
    "speed-accept": "needs aiCode.loc and inter-request acceptance timing -- "
        "code-diff size is not captured",
    "vibe-coding": "needs aiCode.loc per session -- code-change size is not "
        "captured",
    # scan: requests
    "agentic-no-tools": "needs agentMode/agentName and toolsUsed per request "
        "-- Claude Code/Copilot CLI have no ask/agent mode toggle, and tool "
        "use is only visible as an unattributed session-wide marker, not "
        "per request",
    "agent-mode-for-asks": "needs agentMode, toolsUsed, aiCode, "
        "referencedFiles, editedFiles per request -- none captured",
    "auto-approve-terminal": "needs toolConfirmations[] (auto-approve events) "
        "per request -- not captured",
    "auto-avoidance": "needs modelId per request -- not captured",
    "cache-hit-starvation": "needs promptTokens/cacheReadTokens per request "
        "-- token usage is not captured",
    "context-engineering-gaps": "needs agentName, skillsUsed, toolsUsed "
        "(mcp_ prefix), referencedFiles, customInstructions per request -- "
        "none captured",
    "excessive-file-context": "needs referencedFiles per request -- not "
        "captured",
    "high-cancellation": "needs isCanceled per request -- not captured",
    "model-overreliance": "needs modelId per request -- not captured",
    "no-custom-instructions": "needs customInstructions per request -- not "
        "captured",
    "no-file-context": "needs referencedFiles/editedFiles per request -- not "
        "captured",
    "no-language-exploration": "needs a per-request programming-language "
        "field -- not captured",
    "no-plan-mode": "needs agentMode/slashCommand per request -- not "
        "captured",
    "no-skills": "needs skillsUsed per request -- only a generic "
        "'[tool: Skill]' marker is stored per session, not which skill or "
        "which request invoked it",
    "no-slash-commands": "needs a parsed slashCommand per request -- not "
        "captured",
    "premium-for-lookup-questions": "needs modelId (for modelTier) per "
        "request -- not captured",
    "premium-waste": "needs modelId per request -- not captured",
    "profanity": "no patterns: wordlist is provided by the rule; evaluating "
        "it would require inventing a moderation wordlist -- a product/"
        "judgment call out of scope for this evaluator",
    "reasoning-effort-overuse": "needs reasoningEffort per request -- not "
        "captured",
    "runaway-agent-loops": "needs toolsUsed per request plus agentMode/"
        "agentName -- tool use is only visible at session granularity, not "
        "per request",
    "slow-responses": "needs totalElapsed (response latency) per request -- "
        "not captured",
    "verbose-output": "needs completionTokens per request -- token usage is "
        "not captured",
    "verbose-prompt-no-compression": "needs skillsUsed (hasSkillByPattern) "
        "per request -- only an unattributed session-wide tool marker is "
        "stored",
    "yolo-mode": "needs toolConfirmations[] per request -- not captured",
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
SUPPORTED_COUNT = len(REQUEST_ADAPTERS) + len(BESPOKE_SESSION_IDS) + 1  # +1 = mega-sessions/abandon-sessions handled by the generic engine below, counted explicitly in main()


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
            if rule_id in REQUEST_ADAPTERS:
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
