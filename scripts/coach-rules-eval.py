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
import coachtables  # noqa: E402  (vendored MODEL_TIERS / WORK_TYPE_PATTERNS)
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
# REWRITTEN 2026-07-26 (second time), after an adversarial re-analysis
# (.superpowers/sdd/2026-07-25-harness-neutral-persistence/
# skip-reanalysis-audit.md) found that TWELVE of the twenty-one entries then
# in this table asserted something about upstream's source, or about the data
# on this machine, that is FALSE -- and that every one of the twelve pointed
# away from doing work. A skip reason is user-visible output. A reason that
# misstates WHY is the same class of defect as a rule that silently never
# fires, and it is the mechanism by which the wrongness survives review.
#
# Standing rules for this table:
#
#   1. Every reason must be checkable and must say HOW: either
#      "[upstream <file>:<line>]" against microsoft/AI-Engineering-Coach at
#      the commit vendor/coach-rules/UPSTREAM.md records, or "[measured ...]"
#      naming a count actually run over the local harness stores. No reason
#      may rest on an unverified belief about upstream's code.
#
#   2. `requiresIdeContext: true` is NOT evidence of unreachability and must
#      never again be cited as if it were. Upstream computes
#        skipIdeDetectors = !!(f?.harness && !f.harness.startsWith('Local Agent')
#                              && f.harness !== 'Xcode')
#      [upstream src/core/analyzer-patterns.ts:262] -- i.e. only when a
#      HARNESS FILTER is applied in the dashboard. In upstream's default
#      unfiltered view all 45 detectors run over a corpus that includes CLI
#      sessions (src/core/parser-vscode-cli.ts parses Copilot CLI's own
#      session-state/<id>/events.jsonl -- byte-for-byte the file
#      scripts/lib/telemetry.py reads). The flag is a presentation decision
#      about attributing a finding in a mixed-harness dashboard, not a claim
#      that the input is absent.
#
#   3. "A conjunct is constant here, so the rule is a constant" is a logic
#      error and is banned as a reason. A universally-true clause inside a
#      conjunction is a NO-OP; the discriminating work is done by the other
#      clauses. Three rules were skipped on that reasoning.
#
#   4. "We would have to invent the table" is only admissible after checking
#      whether upstream has one. MODEL_TIERS [upstream
#      src/core/dsl/interpreter.ts:267-284] and WORK_TYPE_PATTERNS
#      [:303-313] are plain literals in MIT-licensed source, vendorable by
#      the same mechanism as the rules themselves.
#
# The standing principle is unchanged and is NOT weakened: a rule that
# evaluates but can never fire, because its input is structurally always
# empty, is worse than a loud skip. What the re-analysis established is that
# the principle had been invoked for inputs that were UNPLUMBED rather than
# structurally empty. Where a rule evaluates, tests/test-coach-rules-eval.py
# carries a fire/no-fire pair for it built from real-shaped harness events.
# ---------------------------------------------------------------------------
UNSUPPORTED_REASONS = {
    # -- GENUINELY UNREACHABLE (1)
    "no-devcontainer": "genuinely unreachable, and the only entry in this "
        "table for which that is true. NOT because of requiresIdeContext: "
        "because upstream's own computeDevcontainerStats opens with "
        "sessions.filter(s => VSCODE_HARNESSES.has(asStr(s.harness))), "
        "VSCODE_HARNESSES = {'VS Code','VS Code Insiders','Local Agent',"
        "'Local Agent (Insiders)'} [upstream src/core/dsl/interpreter.ts:"
        "579-583]. For a CLI harness the scored population is empty INSIDE "
        "UPSTREAM'S OWN FUNCTION, by a hardcoded harness gate, before any "
        "field of ours is consulted. It additionally needs "
        "session.hasDevcontainer and toolConfirmations[].isTerminal, which "
        "no CLI emits",

    # -- REACHABLE, NOT YET BUILT. Each names the work, not a missing input.
    "broken-flow-state": "reachable; deferred, cost stated. Needs "
        "flowScoreStats: a four-component weighted per-session score "
        "(rapid-followup rate 40%, median-latency band 30%, duration band "
        "15%, request density 15%) with hardcoded breakpoints, bucketed per "
        "day into a lowScoreRate [upstream src/core/analyzer-flow.ts:41 "
        "computeSessionFlowScore; ~100 of that file's 275 lines]. Every "
        "INPUT is already captured (request timestamps, session duration, "
        "request counts) -- this is a ~150-line analyzer port with its own "
        "test surface, not a data gap",

    "no-file-context": "reachable; deliberately not shipped under THIS rule "
        "id. Upstream's referencedFiles here means context the HUMAN "
        "attached to the prompt, and Copilot CLI records exactly that as "
        "user.message.data.attachments [measured over 62 local Copilot "
        "sessions: 5 of 156 user.message events carry attachments, so the "
        "rule would fire]. But telemetry.py populates referencedFiles from "
        "TOOL ARGUMENTS, mirroring upstream's own CLI parser, and four "
        "shipped adapters depend on that definition. Answering under "
        "upstream's rule id with a different input is exactly the drift "
        "_pin() exists to prevent. This wants a locally-named signal with "
        "its own suggestion text, not a redefinition of a vendored rule",


















}


def _join_continuations(text):
    """Physical lines folded on a trailing backslash into logical lines.

    `a AND \\\n  b` becomes `a AND b`. Continuation whitespace is collapsed
    to one space so a pin does not depend on how upstream indents.
    """
    out = []
    pending = None
    for line in text.splitlines():
        stripped = line.rstrip()
        piece = stripped[:-1].rstrip() if stripped.endswith("\\") else stripped
        if pending is None:
            pending = piece
        else:
            pending = pending + " " + piece.strip()
        if not stripped.endswith("\\"):
            out.append(pending)
            pending = None
    if pending is not None:
        out.append(pending)
    return out


# ---------------------------------------------------------------------------
# Remediation text that names a UI neither CLI has.
#
# A rule's "How to Improve" section is what gets written into the user's
# memory file, so a suggestion naming a nonexistent command or mode is not a
# cosmetic problem -- it is wrong advice, persisted. Two vendored rules have
# this problem, and it is the ONLY honest objection to evaluating them (the
# reasons previously recorded were about data, and were false).
#
# Skipping the rules would discard a real finding to avoid a text problem.
# Emitting upstream's text would persist bad advice. So the finding ships and
# the text is replaced, with the substitution declared here rather than
# buried in an adapter. The rule id and the count remain upstream's.
# ---------------------------------------------------------------------------
SUGGESTION_OVERRIDES = {
    # Kept under coach-signals.py's 240-character sanitize cap ON PURPOSE.
    # Inspecting the persisted coach-signals.json showed the first version of
    # these was cut mid-word at 240, losing the half that says what to do
    # instead -- so the marker survived but the replacement advice did not,
    # which is the only thing that made substituting the text honest. Two
    # of upstream's own suggestions are still truncated by the same cap;
    # that is upstream's text being shortened, not ours being falsified.
    # scripts/lib/coachtables.py has no equivalent constraint; this one is
    # load-bearing, and OVERRIDE_MAX_CHARS below is asserted by a test.
    "no-slash-commands":
        "ADAPTED FOR CLI: upstream names /fix, /explain, /tests, /doc - none "
        "exist in either CLI. Define project-level commands for the tasks "
        "you repeat (Claude Code: .claude/commands/). The count includes "
        "built-in UI commands such as /model.",
    "agent-mode-for-asks":
        "ADAPTED FOR CLI: upstream says switch to Ask/Chat mode, which "
        "neither CLI has. These were short questions that spent a full "
        "agentic turn and produced no tool call, no code and no file access; "
        "ask them somewhere cheaper.",
}

# coach-signals.py sanitizes every suggestion to this many characters before
# it can reach a reviewer prompt or the memory file. An override longer than
# this is silently cut mid-sentence, so the length is a contract, not a
# style preference.
OVERRIDE_MAX_CHARS = 240



# ---------------------------------------------------------------------------
# Absence-based findings, and the window they were measured over.
#
# telemetry.MAX_SESSIONS caps how many session logs are parsed. For a RATE
# that cap is sound -- a rate over the newest N sessions is an estimate of a
# rate, and estimating is what it is for. For an ABSENCE it is not: "no
# ExitPlanMode in the newest 40 sessions" and "this user never uses plan
# mode" are different claims, and only the second is worth telling someone.
# Emitting the first while wording it as the second is the same vacuity
# shape this evaluator's skip table exists to remove -- a global assertion
# resting on data that cannot support it.
#
# So every rule whose check is driven by a "this never happened" boolean
# carries a scope note into the emitted signal. The note travels in its OWN
# field rather than appended to `suggestion`, because coach-signals.py
# sanitizes each suggestion to 240 characters and a note on the end of a long
# suggestion would be silently cut -- which is exactly how the first version
# of SUGGESTION_OVERRIDES lost half its text.
#
# Rate-driven rules (no-slash-commands, no-custom-instructions,
# no-spec-structure, ...) are deliberately NOT listed: they assert a rate
# over a sample, which the sample supports.
# ---------------------------------------------------------------------------

SAMPLE_SCOPE_NOTE = (
    "SCOPE: this is an absence, measured over the {sessions} session log(s) "
    "read (newest {cap} per harness), not over full history."
)

CORPUS_SCOPE_NOTE = (
    "SCOPE: this absence was checked across every session log on disk, not "
    "only the parsed sample."
)

ABSENCE_SCOPED_RULES = {
    "no-skills": SAMPLE_SCOPE_NOTE,
    "auto-avoidance": SAMPLE_SCOPE_NOTE,
    "context-engineering-gaps": SAMPLE_SCOPE_NOTE,
}


def _scope_note(rule_id, telemetry_source):
    """The scope note for a signal, or "" when the rule is not absence-based."""
    if telemetry_source is None:
        return ""
    recorded = telemetry_source.recorded_scope(rule_id)
    if recorded:
        return recorded
    template = ABSENCE_SCOPED_RULES.get(rule_id)
    if template is None:
        return ""
    return template.format(sessions=telemetry_source.session_count,
                           cap=telemetry.MAX_SESSIONS)


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
        # Upstream continues a long clause with a trailing backslash (seven
        # of the 45 rules do it). Splitting on raw lines would hand _pin()
        # only the FIRST physical line of such a clause, so an upstream edit
        # to any continuation line would slip past the drift guard
        # unnoticed. Join them first, collapsing the fold to a single space
        # so the pinned string is stable against indentation churn.
        for dline in _join_continuations(m.group(1)):
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
# The two permission rules (yolo-mode, auto-approve-terminal) were also
# skipped here, on the claim that "an auto-approved call emits no permission
# event at all" and so "a rate over the surviving records would have a
# permanently zero numerator". That was a measurement, and it was wrong:
# Copilot CLI's `approved-for-location` is a PERSISTED approval, upstream's
# exact analogue of autoApproveScope 'always', and there are 7 of them in
# the local corpus. Both rules now evaluate. See the permission.completed
# handler in scripts/lib/telemetry.py for what differs from upstream.
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


def _as_datetime(value):
    """A record `timestamp` (ISO-8601 string, both harnesses) as an aware
    UTC datetime, or None. Goes through the shared isotime parser rather
    than a second hand-rolled one -- duplicated timestamp parsing is a
    documented defect class in this repo."""
    epoch = parse_iso(value) if isinstance(value, str) else None
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


def _epoch_ms(value):
    """Milliseconds since the epoch, matching upstream's numeric timestamps.
    None when unparsable -- never 0, which would make every gap look huge."""
    epoch = parse_iso(value) if isinstance(value, str) else None
    return None if epoch is None else epoch * 1000


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


# ---------------------------------------------------------------------------
# The aiCode.loc cluster.
#
# `aiCode` is now extracted by lib/telemetry.py (see its aiCode section for
# what upstream actually counts and the evidence it was measured against).
# These five rules were previously listed as "reachable but not implemented"
# with the cost "holding whole file bodies in memory". That cost was real for
# upstream's join-then-scan approach and is avoided here by scanning each
# chunk as it streams off the event log; the rules themselves needed no new
# data source beyond that.
#
# Each helper below reimplements one upstream DSL builtin from
# src/core/dsl/interpreter.ts. They are transcriptions, not reinterpretations
# -- the function name and the behaviour it copies are named at each one so a
# future reader can diff them against upstream directly.
# ---------------------------------------------------------------------------

# computeLangExploration's IGNORE set, verbatim: markup and data formats are
# not "languages you explored".
LANG_EXPLORATION_IGNORE = {
    "text", "plaintext", "unknown", "json", "yaml", "toml", "xml", "csv",
    "ini", "env", "markdown", "md",
}

# The "was the first prompt spec-shaped?" branch, shared verbatim by
# vibe-coding and no-spec-structure -- both rules carry the SAME five OR
# branches in their own detect blocks, and both are pinned on the full
# folded text below, so a drift in either upstream file is caught.
SPEC_SHAPED_PATTERNS = (
    re.compile(r"^[-*]\s", re.M),
    re.compile(r"^\d+[.)]\s", re.M),
    re.compile(r"^#+\s", re.M),
    re.compile(r"(?i)\b(requirements?|spec|acceptance criteria|user stories?|"
               r"given|when|then|should|must)\b"),
)

# Upstream's lineCount() is a plain newline count, so a one-line prompt is 1.
SPEC_SHAPED_MIN_LINES = 4


def _line_count(text):
    """Transcribes lineCount (dsl/interpreter.ts): text.split('\n').length."""
    return len(text.split("\n"))


def _is_spec_shaped(text):
    """The fifth OR branch -- lineCount >= 4 -- was MISSING from
    eval_vibe_coding until 2026-07-26, which made that rule over-fire: a
    session whose opening prompt was a four-line paragraph with no bullets,
    heading or requirement keyword counted as "unstructured" when upstream
    would have excluded it. Found by transcribing the branch list for
    no-spec-structure and diffing it against the code already here."""
    if any(pattern.search(text) for pattern in SPEC_SHAPED_PATTERNS):
        return True
    return _line_count(text) >= SPEC_SHAPED_MIN_LINES

COPY_PASTE_REFINEMENT_RE = re.compile(
    r"(?i)\b(change|fix|modify|update|refactor|wrong|instead|actually|revert|"
    r"redo|try again)\b")


def _sessions_with_aicode(tel, rule_id):
    """Sessions whose requests actually carry an `aiCode` list.

    A session list built from records with no aiCode key would evaluate every
    LoC threshold against 0 and report a clean bill of health -- the exact
    always-false-rule this branch forbids. Raising here makes the rule skip
    loudly instead.
    """
    turns = _require_records(
        telemetry.requests_with(tel.turns, "aiCode"), rule_id, "aiCode")
    return telemetry.build_sessions(turns)


def eval_vibe_coding(rule, tel):
    _pin(rule, check="count >= thresholds.minSessions")
    t = _thresholds(rule, "minAiLoc", "maxUserPrompts", "minSessions")
    sessions = _sessions_with_aicode(tel, rule["id"])
    matched = 0
    for session in sessions:
        if telemetry.session_ai_loc(session) < t["minAiLoc"]:
            continue
        if session["requestCount"] > t["maxUserPrompts"]:
            continue
        first = session["requests"][0].get("messageText") or ""
        if _is_spec_shaped(first):
            continue
        matched += 1
    if not matched >= t["minSessions"]:
        return None
    return matched


def eval_copy_paste_blindness(rule, tel):
    _pin(rule, check="count >= thresholds.minSessions")
    t = _thresholds(rule, "minAiLoc", "minSessions")
    sessions = _sessions_with_aicode(tel, rule["id"])
    matched = 0
    for session in sessions:
        if session["requestCount"] < 2:
            continue
        if telemetry.session_ai_loc(session) < t["minAiLoc"]:
            continue
        # slice(requests, 1): everything AFTER the first request. A session
        # is only "no follow-up refinement" if none of the later prompts asks
        # for a change AND none of them edited a file.
        rest = session["requests"][1:]
        refined = any(
            COPY_PASTE_REFINEMENT_RE.search(r.get("messageText") or "") for r in rest)
        edited = any(len(r.get("editedFiles") or []) > 0 for r in rest)
        if refined or edited:
            continue
        matched += 1
    if not matched >= t["minSessions"]:
        return None
    return matched


def eval_speed_accept(rule, tel):
    """Transcribes computeSpeedAcceptPairs (dsl/interpreter.ts:374)."""
    _pin(rule, match="requestCount >= 2", check="pairs.count >= thresholds.minOccurrences")
    t = _thresholds(rule, "minAiLoc", "maxGapMs", "minOccurrences")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "aiCode", "timestamp", "totalElapsed"),
        rule["id"], "aiCode/timestamp/totalElapsed")
    count = 0
    for session in telemetry.build_sessions(turns):
        requests = session["requests"]
        if len(requests) < 2:
            continue
        for prev, nxt in zip(requests, requests[1:]):
            if telemetry.ai_loc(prev) < t["minAiLoc"]:
                continue
            prev_start = _epoch_ms(prev.get("timestamp"))
            next_start = _epoch_ms(nxt.get("timestamp"))
            if prev_start is None or next_start is None:
                continue
            prev_end = prev_start + (prev.get("totalElapsed") or 0)
            gap = next_start - prev_end
            # Upstream requires gap >= 0: a negative gap means overlapping or
            # out-of-order timestamps, which is bad data, not a fast human.
            if 0 <= gap <= t["maxGapMs"]:
                count += 1
    if not count >= t["minOccurrences"]:
        return None
    return count


def eval_low_markdown_ratio(rule, tel):
    """Transcribes computeMdRatio (dsl/interpreter.ts:518).

    NOTE the threshold asymmetry, which is upstream's and is preserved
    deliberately: `isLow` hardcodes `ratio < 0.05` rather than reading
    thresholds.markdownRatio, even though that threshold exists and holds the
    same 0.05. Reading the threshold instead would silently change behaviour
    the day upstream retunes one and not the other.
    """
    _pin(rule, match="true", check="md.lowCount >= thresholds.minWorkspaces")
    t = _thresholds(rule, "minTotalLoc", "minWorkspaces")
    sessions = _sessions_with_aicode(tel, rule["id"])
    per_workspace = {}
    for session in sessions:
        stats = per_workspace.setdefault(session["workspaceName"], {"md": 0, "code": 0})
        for record in session["requests"]:
            for block in record.get("aiCode") or []:
                loc = block.get("loc") or 0
                if (block.get("language") or "") in ("markdown", "md"):
                    stats["md"] += loc
                else:
                    stats["code"] += loc
    low = 0
    for stats in per_workspace.values():
        total = stats["md"] + stats["code"]
        if total <= 0:
            continue
        if total >= t["minTotalLoc"] and (stats["md"] / total) < 0.05:
            low += 1
    if not low >= t["minWorkspaces"]:
        return None
    return low


def eval_no_language_exploration(rule, tel):
    """Transcribes computeLangExploration (dsl/interpreter.ts:476).

    ADAPTATION, stated because it changes the numerator: upstream unions
    `aiCode` and `userCode` languages per week. This project has no
    `userCode` -- neither harness's log distinguishes a fenced block the USER
    pasted from the surrounding prompt text in a way upstream's own CLI
    parser uses either (parser-vscode-cli.ts never sets userCode). So this
    counts aiCode languages only, which can only make "no new language" MORE
    likely to fire. Reported here rather than buried.

    Upstream's week key is reproduced verbatim, bug and all:
        `${y}-W${ceil((dayOfMonth + firstWeekdayOfMonth) / 7)}`
    That is a week-of-MONTH number (1-6) concatenated with the year, so weeks
    from different months collide. Reimplementing it "correctly" as an ISO
    week would make this project's answer differ from upstream's for the same
    input, which is worse than reproducing a quirk we can name.
    """
    _pin(rule, match="timestamp > 0",
         check="lang.recentNew == 0 AND lang.totalWeeks >= thresholds.minWeeks")
    t = _thresholds(rule, "minWeeks")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "aiCode", "timestamp"),
        rule["id"], "aiCode/timestamp")
    week_langs = {}
    for record in turns:
        moment = _as_datetime(record.get("timestamp"))
        if moment is None:
            continue
        first_weekday = (datetime(moment.year, moment.month, 1).weekday() + 1) % 7
        week_index = -(-(moment.day + first_weekday) // 7)  # ceil division
        key = "{}-W{:02d}".format(moment.year, week_index)
        bucket = week_langs.setdefault(key, set())
        for block in record.get("aiCode") or []:
            lang = (block.get("language") or "").lower()
            if lang and lang not in LANG_EXPLORATION_IGNORE:
                bucket.add(lang)
    weeks = sorted(week_langs)
    if not weeks:
        return None
    seen = set()
    last_new = 0
    for index, week in enumerate(weeks):
        new_here = week_langs[week] - seen
        if new_here:
            seen |= new_here
            last_new = index
    weeks_since_new = len(weeks) - 1 - last_new
    recent_new = 1 if weeks_since_new == 0 else 0
    if not (recent_new == 0 and len(weeks) >= t["minWeeks"]):
        return None
    return weeks_since_new


# ---------------------------------------------------------------------------
# Rules restored on 2026-07-26 after the skip re-analysis. Each of these was
# previously skipped on a reason the audit falsified; none of them needed a
# new data source. Where the CLI mapping differs from upstream's field it is
# marked ADAPTATION and the difference is spelled out -- silently answering a
# vendored rule id with a different input is exactly the drift _pin() exists
# to prevent.
#
# The specific error that produced three of these skips: "a conjunct that is
# universally true here makes the rule a constant". It does not. A
# universally-true clause inside a conjunction is a NO-OP; the discriminating
# work is done by the other clauses. The reduction is stated at each site.
# ---------------------------------------------------------------------------

def eval_no_skills(rule, tel):
    """No adaptation at all: skillsUsed is captured natively for both
    harnesses (Copilot's `skill` tool and skill.invoked events; Claude
    Code's Skill tool). The previous skip reason asserted that "the rule
    fires on the ABSENCE of skill usage across an IDE session population,
    which a CLI-only corpus cannot represent" -- a restatement of upstream's
    requiresIdeContext flag, not a reason. Nothing about "did you ever use a
    skill" is IDE-shaped."""
    _pin(rule, match="skillsUsed.length == 0",
               check="count == total AND total > thresholds.minReqs")
    t = _thresholds(rule, "minReqs")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "skillsUsed"), rule["id"], "skillsUsed")
    matched = sum(1 for r in turns if len(r["skillsUsed"]) == 0)
    if not (matched == len(turns) and len(turns) > t["minReqs"]):
        return None
    return matched


def eval_agentic_no_tools(rule, tel):
    """ADAPTATION: `agentMode == "agent"` is universally true for a CLI
    harness, so the disjunction (agentMode == "agent" OR agentName != "")
    is a tautology and the predicate reduces to `toolsUsed.length == 0`.

    What differs from upstream: on a mixed corpus upstream would count only
    the subset of no-tool turns that were agentic. Here every turn is
    agentic -- Copilot CLI and Claude Code have no ask mode -- so the count
    is over ALL no-tool turns. That is broader than upstream's number and
    correct for this data, not a silent no-op: the second conjunct does all
    the discriminating and is fully captured.
    """
    _pin(rule, match='(agentMode == "agent" OR agentName != "") AND '
                     "toolsUsed.length == 0",
               check="count > thresholds.minSample")
    t = _thresholds(rule, "minSample")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "toolsUsed"), rule["id"], "toolsUsed")
    matched = sum(1 for r in turns if len(r["toolsUsed"]) == 0)
    if not matched > t["minSample"]:
        return None
    return matched


# verbose-prompt-no-compression's filler alternation, transcribed from its
# own detect block. Upstream requires it to match TWICE in the same message
# (the pattern is the alternation, `.*`, then the alternation again), so a
# single "please" does not make a prompt fluffy.
VERBOSE_FILLER_RE = re.compile(
    r"(?i)\b(please|kindly|thanks|thank you|basically|essentially|definitely|"
    r"absolutely|simply|very|quite|somewhat|certainly|actually|literally)\b")

# hasSkillByPattern(allReqs, "(?i)cavecrew|caveman|compress"), also a literal
# in the detect block.
COMPRESSION_SKILL_RE = re.compile(r"(?i)cavecrew|caveman|compress")


def eval_verbose_prompt_no_compression(rule, tel):
    """The previous skip reason -- "the rule's pattern set is not carried in
    the vendored rule file" -- was false. Both regexes are literals inside
    the detect block; there is no `patterns:` frontmatter because none is
    needed. messageLength, messageText and skillsUsed are all captured.

    hasSkillByPattern is a CORPUS-WIDE predicate (upstream passes `allReqs`,
    not the matched subset): if the user has a compression skill anywhere in
    the corpus, the rule is off entirely. Transcribed from
    dsl/interpreter.ts:1635.
    """
    _pin(rule, check="ratio > thresholds.maxRatio AND count > thresholds.minSample")
    t = _thresholds(rule, "minMessageLength", "minSample", "maxRatio")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "messageText", "messageLength", "skillsUsed"),
        rule["id"], "messageText/messageLength/skillsUsed")
    for record in turns:
        if any(COMPRESSION_SKILL_RE.search(s) for s in record["skillsUsed"]):
            return None
    matched = 0
    for record in turns:
        if record["messageLength"] < t["minMessageLength"]:
            continue
        if len(VERBOSE_FILLER_RE.findall(record["messageText"])) < 2:
            continue
        matched += 1
    ratio = matched / len(turns)
    if not (ratio > t["maxRatio"] and matched > t["minSample"]):
        return None
    return matched


def eval_no_spec_structure(rule, tel):
    """ADAPTATION: `someWhere(requests, "agentMode", "agent")` is
    universally true for a CLI harness, so it is dropped as a no-op. The
    previous skip reason concluded from that same observation that "the rule
    is a constant", which is a logic error -- the clause sits inside a
    conjunction with a requestCount floor and five regex tests on the
    session's FIRST user message, all of which are live and captured.

    What differs from upstream: `agentSessionTotal` is
    countWhere(all, "requestCount", ">=", 3) in upstream's own detect block,
    i.e. it does NOT filter on agent mode either -- so on this data the
    denominator is identical to upstream's and only the numerator widens, by
    exactly the sessions upstream would also have counted.
    """
    _pin(rule,
         match='requestCount >= 3 AND someWhere(requests, "agentMode", "agent") '
               'AND NOT ( matches(first(requests).messageText, "(?m)^[-*]\\\\s") OR '
               'matches(first(requests).messageText, "(?m)^\\\\d+[.)]\\\\s") OR '
               'matches(first(requests).messageText, "(?m)^#+\\\\s") OR '
               'matches(first(requests).messageText, "(?i)\\\\b(requirements?|spec|'
               'acceptance criteria|user stories?|given|when|then|should|must)'
               '\\\\b") OR lineCount(first(requests).messageText) >= 4)',
         check="agentSessionTotal >= thresholds.minAgentSessions AND "
               "count / agentSessionTotal > (1 - thresholds.structuredRate)")
    t = _thresholds(rule, "minAgentSessions", "structuredRate")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "messageText"), rule["id"], "messageText")
    sessions = telemetry.build_sessions(turns)
    eligible = [s for s in sessions if s["requestCount"] >= 3]
    if not eligible:
        return None
    matched = 0
    for session in eligible:
        first = session["requests"][0].get("messageText") or ""
        if _is_spec_shaped(first):
            continue
        matched += 1
    if not (len(eligible) >= t["minAgentSessions"]
            and matched / len(eligible) > (1 - t["structuredRate"])):
        return None
    return matched


# ---------------------------------------------------------------------------
# The MODEL_TIERS / WORK_TYPE_PATTERNS cluster.
#
# All four were skipped on "upstream maintains a table; a snapshot would
# silently rot". Both tables are plain literals in MIT-licensed upstream
# source and are now vendored and pinned exactly as the rules are -- see
# scripts/lib/coachtables.py for the argument and the mechanism. The tables
# are loaded LAZILY, once, so a rule that does not need them is unaffected
# by a pin mismatch and the four that do skip loudly with the pin message.
# ---------------------------------------------------------------------------

_TABLE_CACHE = {}


def _model_tiers():
    if "tiers" not in _TABLE_CACHE:
        _TABLE_CACHE["tiers"] = coachtables.model_tiers()
    return _TABLE_CACHE["tiers"]


def _work_type_patterns():
    if "worktypes" not in _TABLE_CACHE:
        _TABLE_CACHE["worktypes"] = coachtables.work_type_patterns()
    return _TABLE_CACHE["worktypes"]


def eval_premium_waste(rule, tel):
    """modelTier(modelId) >= 1 AND a short prompt that produced no code.

    No adaptation: every input is upstream's own field, read from the same
    events upstream's CLI parser reads.
    """
    _pin(rule, match="modelTier(modelId) >= 1 AND messageLength < "
                     "thresholds.maxMessageLength AND messageLength > 0 AND "
                     "aiCode.length == 0",
               check="count > thresholds.minSample")
    t = _thresholds(rule, "minSample", "maxMessageLength")
    tiers = _model_tiers()
    turns = _require_records(
        telemetry.requests_with(tel.turns, "modelId", "messageLength", "aiCode"),
        rule["id"], "modelId/messageLength/aiCode")
    matched = 0
    for record in turns:
        if coachtables.model_tier(record["modelId"], tiers) < 1:
            continue
        if not 0 < record["messageLength"] < t["maxMessageLength"]:
            continue
        # `aiCode.length` is the number of fenced blocks, not their LoC --
        # resolveField returns Array.length for a `.length` suffix.
        if len(record["aiCode"]) != 0:
            continue
        matched += 1
    if not matched > t["minSample"]:
        return None
    return matched


# premium-for-lookup-questions' question-opener regex, a literal in its own
# detect block (there is no patterns: frontmatter for it).
LOOKUP_QUESTION_RE = re.compile(
    r"(?i)^\s*(what(?:'s| is| are)|where(?:'s| is| are)|how do (?:i|you)|"
    r"explain|why (?:does|is|are)|when (?:should|do)|which|tell me about|"
    r"define)\b")


def eval_premium_for_lookup_questions(rule, tel):
    """A premium model asked a bare lookup question: no code, no tools."""
    _pin(rule, check="ratio > thresholds.maxRatio AND count > thresholds.minSample")
    t = _thresholds(rule, "minSample", "maxRatio", "maxMessageLength")
    tiers = _model_tiers()
    turns = _require_records(
        telemetry.requests_with(tel.turns, "modelId", "messageText",
                                "messageLength", "aiCode", "toolsUsed"),
        rule["id"], "modelId/messageText/messageLength/aiCode/toolsUsed")
    matched = 0
    for record in turns:
        if coachtables.model_tier(record["modelId"], tiers) < 1:
            continue
        if not 0 < record["messageLength"] < t["maxMessageLength"]:
            continue
        if len(record["aiCode"]) != 0 or len(record["toolsUsed"]) != 0:
            continue
        if not LOOKUP_QUESTION_RE.search(record["messageText"]):
            continue
        matched += 1
    ratio = matched / len(turns)
    if not (ratio > t["maxRatio"] and matched > t["minSample"]):
        return None
    return matched


AUTO_MODEL_RE = re.compile(r"(?i)auto")


def eval_auto_avoidance(rule, tel):
    """One premium model dominates and the `auto` router was never used."""
    _pin(rule, match='modelId != ""',
               check="models.topShare > thresholds.minTopShare AND "
                     "modelTier(models.topModel) >= 1 AND hasAutoUsage == 0 "
                     "AND models.total > thresholds.minSample")
    t = _thresholds(rule, "minTopShare", "minSample")
    tiers = _model_tiers()
    turns = _require_records(
        telemetry.requests_with(tel.turns, "modelId"), rule["id"], "modelId")
    matched = [r for r in turns if r["modelId"] != ""]
    if not matched:
        return None
    # computeModelStats normalises the id before counting [upstream
    # src/core/dsl/interpreter.ts:859-876]; hasAutoUsage does NOT -- it
    # regexes the raw field. Keeping that difference matters: a normalised
    # id has already lost nothing here, but conflating the two would be a
    # silent reinterpretation of two different upstream call sites.
    counts = Counter(coachtables.normalize_model_id(r["modelId"]) for r in matched)
    top_model, top_count = counts.most_common(1)[0]
    top_share = top_count / len(matched)
    has_auto = sum(1 for r in matched if AUTO_MODEL_RE.search(r["modelId"]))
    if not (top_share > t["minTopShare"]
            and coachtables.model_tier(top_model, tiers) >= 1
            and has_auto == 0
            and len(matched) > t["minSample"]):
        return None
    return top_count


def eval_session_drift(rule, tel):
    """Sessions that touched four or more distinct kinds of work."""
    _pin(rule, match="requestCount >= thresholds.minReqsPerSession AND "
                     "workTypeCount(requests) >= thresholds.maxWorkTypes",
               check="count > thresholds.minSessions")
    t = _thresholds(rule, "maxWorkTypes", "minReqsPerSession", "minSessions")
    patterns = _work_type_patterns()
    turns = _require_records(
        telemetry.requests_with(tel.turns, "messageText"), rule["id"], "messageText")
    matched = 0
    for session in telemetry.build_sessions(turns):
        if session["requestCount"] < t["minReqsPerSession"]:
            continue
        # workTypeCount prefers an explicit `workType` field and falls back
        # to classifying messageText [upstream src/core/dsl/
        # interpreter.ts:1401-1410]. Neither harness records workType, so
        # the fallback is always taken -- which is upstream's behaviour for
        # CLI data too, not an adaptation.
        kinds = {
            coachtables.classify_work_text(r.get("messageText") or "", patterns)
            for r in session["requests"]
        }
        if len(kinds) >= t["maxWorkTypes"]:
            matched += 1
    if not matched > t["minSessions"]:
        return None
    return matched


# ---------------------------------------------------------------------------
# The instruction-file cluster.
#
# All three were skipped on the claim that upstream reads custom-instruction
# size "from the VS Code workspace, not from any CLI session log". False:
# resolveCustomInstructionsBytes branches on an `isCLI` parameter to read the
# CLI session's own workspace.yaml [upstream src/core/parser-vscode.ts:118].
# scripts/lib/telemetry.py now does the same, and states the Claude-side
# adaptation (CLAUDE.md in place of .github/copilot-instructions.md) at the
# point where it is made.
# ---------------------------------------------------------------------------

def _instruction_records(tel, rule_id):
    """Turns whose workspace instruction size could be DETERMINED.

    None means "workspace folder unknown", not "no instructions". Scoring
    those as 0 bytes would report a clean bill of health from absent data,
    so they are excluded and an empty selection skips the rule loudly.
    """
    return _require_records(
        telemetry.requests_with(tel.turns, "customInstructionsBytes",
                                "workspaceName"),
        rule_id, "customInstructionsBytes/workspaceName")


def eval_instruction_bloat(rule, tel):
    """Transcribes computeInstructionBloatStats [upstream
    src/core/dsl/interpreter.ts:717-746].

    Note the field is named bloatedSessions but is counted PER WORKSPACE --
    upstream folds sessions onto workspaceName and keeps the maximum size
    seen. Counting per session instead would multiply one bloated
    instruction file by however many sessions happened to touch it.
    """
    _pin(rule, match="true", check="stats.bloatedSessions >= thresholds.minBloated")
    t = _thresholds(rule, "maxBytes", "minBloated")
    turns = _instruction_records(tel, rule["id"])
    per_workspace = {}
    for record in turns:
        name = record["workspaceName"]
        size = record["customInstructionsBytes"]
        if name not in per_workspace or size > per_workspace[name]:
            per_workspace[name] = size
    bloated = sum(1 for size in per_workspace.values() if size > t["maxBytes"])
    if not bloated >= t["minBloated"]:
        return None
    return bloated


def eval_no_custom_instructions(rule, tel):
    """ADAPTATION, and the most dangerous rule in this file to get wrong.

    Upstream's input is a PER-REQUEST customInstructions[] array, populated
    only by extractCustomInstructions(req.contentReferences) [upstream
    src/core/parser-vscode-request.ts:387] -- the VS Code request parser.
    No CLI parser sets it, upstream's included. Evaluating the rule with
    that field simply absent would give usageRate == 0 < 0.05 for every
    corpus on earth: a rule that ALWAYS fires, which is the same failure
    class as one that never fires and worse in practice, because it looks
    like a finding.

    So the input is redefined for CLI harnesses: a request counts as
    carrying custom instructions when its workspace has a non-empty
    instruction file, since that file is prepended to every request in the
    workspace. What differs from upstream: upstream can distinguish two
    requests in the SAME workspace, one of which attached an instruction
    reference and one of which did not. This cannot -- the value is constant
    within a workspace. The rule therefore answers "what fraction of your
    requests ran in a workspace with no instruction file", which varies
    across a real corpus and is the question the remediation text addresses.
    """
    _pin(rule, match="customInstructions.length == 0",
               check="usageRate < thresholds.minRate AND total > thresholds.minReqs")
    t = _thresholds(rule, "minRate", "minReqs")
    turns = _instruction_records(tel, rule["id"])
    without = sum(1 for r in turns if r["customInstructionsBytes"] <= 0)
    total = len(turns)
    usage_rate = (total - without) / total
    if not (usage_rate < t["minRate"] and total > t["minReqs"]):
        return None
    return without


def eval_context_engineering_gaps(rule, tel):
    """Five independent gap booleans; the rule reports how many are open.

    The previous skip called this "blocked on customInstructions". It was
    not blocked -- four of the five gaps read fields telemetry.py already
    produced, and `severity` keys on gapCount >= 4, so a missing fifth gap
    would have moved a severity boundary rather than the rule's ability to
    answer. The fifth is now available anyway.

    ADAPTATION, hasSubAgents: the vendored detect block's third conjunct is
    someWhere(allReqs, "agentMode", "agent"), universally true for a CLI, so
    it is a no-op and dropped. Note also that upstream's DSL block and its
    TypeScript computeContextGaps [upstream src/core/dsl/interpreter.ts:612]
    disagree with each other -- the block ANDs three independent someWhere()
    calls, the function requires all three conditions on the SAME request.
    The vendored block is what this project pins, so the block is what is
    followed here.
    """
    _pin(rule, match="true",
               check="gapCount > 0 AND reqCount >= thresholds.minReqs")
    t = _thresholds(rule, "minReqs", "fileRefMinRate", "instructionMinRate")
    # agentName is deliberately NOT in the requires list: it is None on
    # every turn that ran no subagent, and "this corpus used no subagents"
    # is precisely gap 1 -- the finding, not missing data. Upstream reads it
    # through asStr(), which maps absent to "". The other four fields are
    # always populated when the harness produced the turn at all, so an
    # empty selection there really does mean "no data".
    turns = _require_records(
        telemetry.requests_with(tel.turns, "skillsUsed", "toolsUsed",
                                "referencedFiles", "customInstructionsBytes"),
        rule["id"],
        "skillsUsed/toolsUsed/referencedFiles/customInstructionsBytes")
    total = len(turns)
    has_subagents = any(
        (r.get("agentName") or "") not in ("", "copilot") for r in turns)
    has_skills = any(len(r["skillsUsed"]) > 0 for r in turns)
    has_mcp = any(t_name.startswith("mcp_")
                  for r in turns for t_name in r["toolsUsed"])
    file_ref_rate = sum(1 for r in turns if len(r["referencedFiles"]) > 0) / total
    instr_rate = sum(1 for r in turns if r["customInstructionsBytes"] > 0) / total
    gap_count = sum((
        not has_subagents,
        not has_skills,
        not has_mcp,
        file_ref_rate < t["fileRefMinRate"],
        instr_rate < t["instructionMinRate"],
    ))
    if not (gap_count > 0 and total >= t["minReqs"]):
        return None
    return gap_count


def _profanity_digests():
    if "profanity" not in _TABLE_CACHE:
        _TABLE_CACHE["profanity"] = coachtables.profanity_hashes()
    return _TABLE_CACHE["profanity"]


def eval_profanity(rule, tel):
    """Hostile language in a prompt, using upstream's own dictionary.

    Not an adaptation: upstream's containsProfanity() is leo-profanity's
    check() over a code-stripped message, and both halves are transcribed in
    scripts/lib/coachtables.py. The only difference from upstream is that
    the dictionary is stored as SHA-256 hashes rather than plaintext -- which
    is behaviour-preserving, because check() is exact whole-word set
    membership after lowercasing and replacing '.' and ',' with spaces -- and
    which keeps this repository free of the slurs, the property Microsoft
    wanted when they pushed the list into an external package.

    `messageLength > 0` is an EQUIVALENT MUTANT: contains_profanity("") is
    False, so the guard cannot change any answer. It is kept because it is
    upstream's own first conjunct and this adapter is pinned on that exact
    predicate text.
    """
    _pin(rule, match="messageLength > 0 AND hasProfanity(messageText)",
               check="count >= thresholds.minReqs")
    t = _thresholds(rule, "minReqs")
    digests = _profanity_digests()
    turns = _require_records(
        telemetry.requests_with(tel.turns, "messageText", "messageLength"),
        rule["id"], "messageText/messageLength")
    matched = sum(1 for r in turns
                  if r["messageLength"] > 0
                  and coachtables.contains_profanity(r["messageText"], digests))
    if not matched >= t["minReqs"]:
        return None
    return matched


# ---------------------------------------------------------------------------
# The permission-confirmation pair.
#
# Both were skipped on "an auto-approve RATE computed from this stream would
# have a permanently zero numerator: a rule that evaluates and can never
# fire". That measurement was wrong -- the numerator is 7 corpus-wide, see
# scripts/lib/telemetry.py's permission.completed handler for the counts and
# for what differs from upstream. Under the faithful mapping these evaluate
# and stay silent on this corpus, which is the same status as
# model-overreliance and cache-hit-starvation, both of which this project
# already ships.
#
# COPILOT-ONLY, and this is a genuine coverage gap rather than a mapping
# choice: Claude Code's transcripts record no per-tool-call confirmation
# event of any kind, so there is nothing to correlate against. The rules
# score whatever confirmations the Copilot half of the corpus produced.
# ---------------------------------------------------------------------------

def _requests_with_confirmations(tel, rule_id):
    turns = _require_records(
        telemetry.requests_with(tel.turns, "toolConfirmations"),
        rule_id, "toolConfirmations")
    matched = [r for r in turns if len(r["toolConfirmations"]) > 0]
    if not matched:
        # No confirmation anywhere is NOT "nothing was auto-approved". It is
        # a corpus with no permission stream -- Claude-only, or a Copilot
        # corpus that never prompted. Scoring it would be a clean bill of
        # health derived from absent data.
        raise ValueError(
            "no request in the harness corpus carries a tool confirmation "
            "(Claude Code records none at all; a Copilot corpus that never "
            "prompted records none either), so there is no permission "
            "stream to compute an auto-approval rate over")
    return matched


def _is_auto_approved(confirmation):
    """Upstream's test, verbatim: scope 'session' or 'always'
    [upstream src/core/dsl/interpreter.ts:672]."""
    return confirmation.get("autoApproveScope") in ("session", "always")


def eval_yolo_mode(rule, tel):
    """Transcribes computeYoloStats [upstream src/core/dsl/interpreter.ts:658].

    Note the denominator is CONFIRMATIONS, not requests -- one request can
    carry several -- while auto-approve-terminal's is requests. Getting
    those the wrong way round would make both rules answer the same
    question under two names.
    """
    _pin(rule, match="toolConfirmations.length > 0",
               check="yolo.ratio > thresholds.autoApproveRate AND "
                     "yolo.totalConfirmations >= thresholds.minConfirmations")
    t = _thresholds(rule, "autoApproveRate", "minConfirmations")
    matched = _requests_with_confirmations(tel, rule["id"])
    confirmations = [c for r in matched for c in r["toolConfirmations"]]
    auto_approved = sum(1 for c in confirmations if _is_auto_approved(c))
    ratio = auto_approved / len(confirmations)
    if not (ratio > t["autoApproveRate"]
            and len(confirmations) >= t["minConfirmations"]):
        return None
    return auto_approved


def eval_auto_approve_terminal(rule, tel):
    """Transcribes computeAutoApproveStats [upstream
    src/core/dsl/interpreter.ts:815]. Counted PER REQUEST: a request
    contributes at most one to each total, however many confirmations it
    carried."""
    _pin(rule, match="toolConfirmations.length > 0",
               check="stats.terminalAutoApproved > thresholds.minTerminalAutoApprove "
                     "AND stats.autoApprovedTotal > thresholds.minAutoApprove")
    t = _thresholds(rule, "minAutoApprove", "minTerminalAutoApprove")
    matched = _requests_with_confirmations(tel, rule["id"])
    auto_total = 0
    terminal_auto = 0
    for record in matched:
        has_auto = False
        has_terminal_auto = False
        for confirmation in record["toolConfirmations"]:
            if not _is_auto_approved(confirmation):
                continue
            has_auto = True
            if confirmation.get("isTerminal"):
                has_terminal_auto = True
        auto_total += 1 if has_auto else 0
        terminal_auto += 1 if has_terminal_auto else 0
    if not (terminal_auto > t["minTerminalAutoApprove"]
            and auto_total > t["minAutoApprove"]):
        return None
    return terminal_auto


# ---------------------------------------------------------------------------
# The slash-command / plan-mode cluster.
#
# scripts/lib/telemetry.py now extracts slashCommand for both harnesses and
# records Claude Code's ExitPlanMode tool use, which is the plan-mode marker
# (NOT permissionMode -- see that module for the measurement that rules it
# out). Two of these four also carry a remediation problem, handled by
# SUGGESTION_OVERRIDES below rather than by skipping the rule.
# ---------------------------------------------------------------------------

def _used_plan_mode(record):
    """ADAPTATION. Upstream's hasPlanning tests slashCommand == "plan" or
    agentMode containing "plan" [upstream src/core/dsl/interpreter.ts:1772].
    Neither CLI sets agentMode, but Claude Code emits ExitPlanMode when it
    LEAVES plan mode, which is a positive record that plan mode was used.
    Copilot CLI has no plan mode at all, so for that harness this is always
    False -- a real per-harness gap, not a mapping choice.
    """
    if record.get("slashCommand") == "plan":
        return True
    return telemetry.CLAUDE_PLAN_MODE_TOOL in (record.get("toolsUsed") or [])


def eval_no_slash_commands(rule, tel):
    """Did any request use a slash command at all?

    The old skip measured Copilot only (0 of 136 user.message events began
    with a slash -- correct, and it reproduces) and never looked at Claude
    Code, where a slash command is a <command-name> block inside the user
    message.

    DISCLOSED CAVEAT: every slash command in the local Claude corpus is a
    built-in UI command (/model, /compact), not a task command, so this
    fires for essentially any CLI user. That is a fidelity note about what
    the count means, not a reason the rule cannot be evaluated -- and
    upstream's own remediation text is replaced, see SUGGESTION_OVERRIDES.
    """
    _pin(rule, match='slashCommand == ""',
               check="usageRate < thresholds.minRate AND total > thresholds.minReqs")
    t = _thresholds(rule, "minRate", "minReqs")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "slashCommand"), rule["id"], "slashCommand")
    without = sum(1 for r in turns if r["slashCommand"] == "")
    total = len(turns)
    usage_rate = (total - without) / total
    if not (usage_rate < t["minRate"] and total > t["minReqs"]):
        return None
    return without


def eval_no_plan_mode(rule, tel):
    """ADAPTATION: the `agentMode == "agent"` half of the match clause is
    universally true for a CLI, so the predicate reduces to all requests and
    agentRatio is 1.0 -- which clears the agentRate floor rather than
    bypassing it, because in a CLI every request genuinely is agentic.

    The discriminating clause is planUsage, and it is live: see
    _used_plan_mode. Note the vendored detect block's planUsage line is
    CORRUPTED upstream -- it reads
      someWhere(all, "agentMode", "matches", "(?i)plan"slashCommand", "plan")
    with an unbalanced quote. The intent is unambiguous from the surrounding
    clauses and from hasPlanning, and _pin() holds this adapter to that
    exact text, so if upstream fixes the typo the adapter stops rather than
    silently answering the old shape.
    """
    _pin(rule, match='agentMode == "agent" OR agentName != ""',
               check="planUsage == 0 AND total >= thresholds.minReqs AND "
                     "agentRatio >= thresholds.agentRate")
    t = _thresholds(rule, "minReqs", "agentRate")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "slashCommand", "toolsUsed"),
        rule["id"], "slashCommand/toolsUsed")
    if any(_used_plan_mode(r) for r in turns):
        return None
    if not len(turns) >= t["minReqs"]:
        return None
    # The sample says "never", which over a capped sample is not the claim
    # the rule's own wording makes. Upgrade it: ask whether the tool was ever
    # invoked ANYWHERE on disk. This is the one absence here worth paying for
    # -- a single marker, byte-prefiltered, structurally confirmed. See
    # telemetry.corpus_used_tool for why the prefilter alone would be wrong.
    corpus = telemetry.corpus_used_tool(telemetry.CLAUDE_PLAN_MODE_TOOL, tel.env)
    if corpus is True:
        # Used, just not inside the window. The sample-scoped finding would
        # have been false, and this is the case that makes the scan worth it.
        return None
    if corpus is None:
        # Byte ceiling hit: undetermined, NOT "never". Emit the finding the
        # sample supports, and say that is all it is.
        tel.note_scope(rule["id"], SAMPLE_SCOPE_NOTE.format(
            sessions=tel.session_count, cap=telemetry.MAX_SESSIONS))
    else:
        tel.note_scope(rule["id"], CORPUS_SCOPE_NOTE)
    return len(turns)


def eval_agent_mode_for_asks(rule, tel):
    """ADAPTATION: `agentMode == "agent"` is universally true for a CLI, so
    it is a NO-OP and dropped. The previous skip concluded from that same
    observation that "the rule's ask-mode branch could never fire here",
    which is a logic error -- the other seven conjuncts (a short non-empty
    prompt, no tools, no code, no file references, no edits, not cancelled)
    are all captured and all discriminating.

    The rule as evaluated here means "short questions that consumed a full
    agentic turn and produced nothing". Upstream's remediation names an
    Ask/Chat mode neither CLI has, so it is replaced -- see
    SUGGESTION_OVERRIDES.
    """
    _pin(rule, match='agentMode == "agent" AND messageLength > 0 AND '
                     "messageLength < thresholds.maxMessageLength AND "
                     "length(toolsUsed) == 0 AND length(aiCode) == 0 AND "
                     "length(referencedFiles) == 0 AND "
                     "length(editedFiles) == 0 AND isCanceled == false",
               check="ratio > thresholds.maxRatio AND count > thresholds.minSample")
    t = _thresholds(rule, "maxMessageLength", "minSample", "maxRatio")
    turns = _require_records(
        telemetry.requests_with(tel.turns, "messageLength", "toolsUsed", "aiCode",
                                "referencedFiles", "editedFiles", "isCanceled"),
        rule["id"],
        "messageLength/toolsUsed/aiCode/referencedFiles/editedFiles/isCanceled")
    matched = 0
    for record in turns:
        if not 0 < record["messageLength"] < t["maxMessageLength"]:
            continue
        if record["toolsUsed"] or record["aiCode"]:
            continue
        if record["referencedFiles"] or record["editedFiles"]:
            continue
        if record["isCanceled"]:
            continue
        matched += 1
    ratio = matched / len(turns)
    if not (ratio > t["maxRatio"] and matched > t["minSample"]):
        return None
    return matched


def eval_no_spec_driven_development(rule, tel):
    """Seven OR branches decide whether a session opened spec-driven.

    The old skip said "two of the rule's three OR branches would be dead".
    There are seven, five of them driven by regexes carried in the vendored
    frontmatter, and of the remaining two the slashCommand branch is now
    live for both harnesses and the plan-mode branch is live for Claude
    Code. DISCLOSED: the plan-mode branch is dead for Copilot CLI, which has
    no plan mode -- so a Copilot-only corpus is scored against six branches,
    not seven.
    """
    _pin(rule, check="specSessionTotal >= thresholds.minAgentSessions AND "
                     "specRate < thresholds.specRate")
    t = _thresholds(rule, "minAgentSessions", "specRate")
    patterns = rule["patterns"]
    for key in ("specFileExts", "specKeywords", "bulletList", "numberedList",
                "headings"):
        if key not in patterns:
            raise ValueError(
                "pattern {} missing from the vendored rule; the branch it "
                "drives would silently never match".format(key))
    # The vendored patterns carry JS inline flags -- (?i), (?m) -- at the
    # start, which Python's re accepts with the same meaning. Compiling
    # them rather than re-typing them is the point: a re-sync that changes
    # a pattern changes behaviour here without an edit, and a pattern that
    # stopped being valid Python raises instead of silently never matching.
    try:
        compiled = {key: re.compile(patterns[key])
                    for key in ("specFileExts", "specKeywords", "bulletList",
                                "numberedList", "headings")}
    except re.error as exc:
        raise ValueError(
            "a vendored pattern is not valid Python regex ({}) -- upstream "
            "used a JS-only construct".format(exc))
    turns = _require_records(
        telemetry.requests_with(tel.turns, "messageText", "referencedFiles",
                                "slashCommand", "toolsUsed"),
        rule["id"], "messageText/referencedFiles/slashCommand/toolsUsed")
    eligible = [s for s in telemetry.build_sessions(turns)
                if s["requestCount"] >= 3]
    if not eligible:
        return None
    unstructured = 0
    for session in eligible:
        first = session["requests"][0]
        text = first.get("messageText") or ""
        lines = _line_count(text)
        spec_driven = (
            any(compiled["specFileExts"].search(f)
                for f in (first.get("referencedFiles") or []))
            or compiled["specKeywords"].search(text)
            or (compiled["bulletList"].search(text) and lines >= 3)
            or (compiled["numberedList"].search(text) and lines >= 3)
            or compiled["headings"].search(text)
            or _used_plan_mode(first)
        )
        if not spec_driven:
            unstructured += 1
    spec_rate = (len(eligible) - unstructured) / len(eligible)
    if not (len(eligible) >= t["minAgentSessions"] and spec_rate < t["specRate"]):
        return None
    return unstructured


TELEMETRY_ADAPTERS = {
    "vibe-coding": eval_vibe_coding,
    "copy-paste-blindness": eval_copy_paste_blindness,
    "speed-accept": eval_speed_accept,
    "low-markdown-ratio": eval_low_markdown_ratio,
    "no-language-exploration": eval_no_language_exploration,
    "excessive-file-context": eval_excessive_file_context,
    "model-overreliance": eval_model_overreliance,
    "reasoning-effort-overuse": eval_reasoning_effort_overuse,
    "cache-hit-starvation": eval_cache_hit_starvation,
    "slow-responses": eval_slow_responses,
    "verbose-output": eval_verbose_output,
    "high-cancellation": eval_high_cancellation,
    "runaway-agent-loops": eval_runaway_agent_loops,
    "no-skills": eval_no_skills,
    "agentic-no-tools": eval_agentic_no_tools,
    "verbose-prompt-no-compression": eval_verbose_prompt_no_compression,
    "no-spec-structure": eval_no_spec_structure,
    "premium-waste": eval_premium_waste,
    "premium-for-lookup-questions": eval_premium_for_lookup_questions,
    "auto-avoidance": eval_auto_avoidance,
    "session-drift": eval_session_drift,
    "instruction-bloat": eval_instruction_bloat,
    "no-custom-instructions": eval_no_custom_instructions,
    "context-engineering-gaps": eval_context_engineering_gaps,
    "profanity": eval_profanity,
    "yolo-mode": eval_yolo_mode,
    "auto-approve-terminal": eval_auto_approve_terminal,
    "no-slash-commands": eval_no_slash_commands,
    "no-plan-mode": eval_no_plan_mode,
    "agent-mode-for-asks": eval_agent_mode_for_asks,
    "no-spec-driven-development": eval_no_spec_driven_development,
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
        # Scope notes an adapter recorded for itself this run. Needed because
        # one rule's window depends on what its own scan found: no-plan-mode
        # makes a whole-corpus claim when the corpus scan completed, and a
        # sample-scoped one when it could not. A static table cannot say that.
        self._scopes = {}

    @property
    def env(self):
        return self._env

    def note_scope(self, rule_id, text):
        self._scopes[rule_id] = text

    def recorded_scope(self, rule_id):
        return self._scopes.get(rule_id, "")

    @property
    def turns(self):
        if self._turns is None:
            self._turns = telemetry.build_turn_requests(self._env)
        return self._turns

    @property
    def session_count(self):
        """Distinct (harness, session) pairs actually parsed. Reported in the
        scope note rather than telemetry.MAX_SESSIONS on its own, because a
        corpus smaller than the cap would otherwise be described as "the
        newest 40" when it is the whole history."""
        return len({(r.get("source"), r.get("session_id")) for r in self.turns})

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
            signal = {
                "id": rule_id,
                "severity": rule["severity"],
                "suggestion": SUGGESTION_OVERRIDES.get(rule_id, rule["suggestion"]),
                "count": count,
                "source": "rules",
            }
            scope = _scope_note(rule_id, telemetry_source)
            if scope:
                signal["scope"] = scope
            signals.append(signal)

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
