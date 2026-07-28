#!/usr/bin/env bash
#
# End-of-session review trigger.
# Called as a Stop hook when the Claude Code session ends.
#
# This script:
# 1. Checks if the session had enough turns to justify a review
# 2. If yes, spawns a new claude CLI process with the review prompt
# 3. The review runs independently (not blocking session exit)
# 4. Results are written to disk and picked up by the next session
#
# Gate: minimum 5 turns for Stop hook to fire.
# Sessions shorter than this rarely contain enough signal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Recursion guard: a spawned reviewer's own Stop hook must not re-trigger review.
if [[ -n "${SL_REVIEW_ACTIVE:-}" ]]; then
    exit 0
fi

# shellcheck disable=SC1091
source "${LIB_DIR}/config.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/hook-input.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/review-common.sh"

STATE_DIR="${SL_STATE_DIR}"
COUNTER_FILE="${STATE_DIR}/turn_counter.json"
REVIEW_ENABLED="${SL_REVIEW_ENABLED:-true}"
MIN_TURNS_FOR_REVIEW="${SL_REVIEW_MIN_TURNS}"
LOG_DIR="${SL_LOG_DIR}/reviews"

if [[ "$REVIEW_ENABLED" != "true" ]]; then
    exit 0
fi

mkdir -p "$LOG_DIR"

# --- Check if review is worthwhile ---

if [[ ! -f "$COUNTER_FILE" ]]; then
    exit 0
fi

TOTAL_TURNS=$(jq -r '.total_turns_this_session // 0' "$COUNTER_FILE" 2>/dev/null || echo "0")
if (( TOTAL_TURNS < MIN_TURNS_FOR_REVIEW )); then
    exit 0
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Resolve the session transcript from the Stop hook payload's transcript_path ---
# P0b: this script sourced hook-input.sh (above) and captured
# HOOK_TRANSCRIPT_PATH long before this fix, but never read it -- the exact
# same "reviewer sees no transcript" defect P0 fixed on the Copilot path.
# Without this, the reviewer spawned below is asked to review a session it
# has zero information about. A missing/empty/unparseable transcript is
# logged to persist-failures.log (doctor.sh surfaces it), never silently
# swallowed. transcript.py shares its digest truncation/redaction across
# every harness; only resolution and parsing differ (see
# scripts/lib/transcript.py's module docstring).
#
# --harness auto, NOT --harness claude, and this is THE TRAP, not a
# generalisation for its own sake. VS Code's default
# `chat.hookFilesLocations` includes `~/.claude/settings.json` -- the exact
# file install.sh tells users to merge these hooks into -- so VS Code
# Copilot Chat runs THIS script, with a VS Code transcript_path, and the two
# payloads are indistinguishable (same field names, same "Stop" event name;
# verified against 9 real VS Code payloads in the 2026-07-28 spike). The
# collision is not caused by any Claude extension: `chat.hookFilesLocations`
# lives in VS Code's own core bundle, so it exists on a machine with no
# Claude Code installed at all.
#
# Measured, before this line said `auto`: a VS Code transcript parsed by
# summarize_claude_events yields ZERO messages, i.e. OUTCOME_FAILURE -- one
# persist-failures.log line AND one paid, contentless review PER VS CODE
# TURN (VS Code's Stop fires per turn, not per session). `auto` sniffs the
# file's own `type` values instead, which separated the two real corpora
# perfectly (330/330 Claude, 21/21 VS Code) -- see detect_transcript_format.
TRANSCRIPT_DIGEST="$(python3 "${LIB_DIR}/transcript.py" --harness auto "${HOOK_TRANSCRIPT_PATH}" \
    --log-file "${SL_LOG_DIR}/persist-failures.log" \
    2>>"${LOG_DIR}/transcript.err" || true)"

# --- Build the review prompt ---

REVIEW_PROMPT="$(cat <<RPEOF
You are a Background Review agent for Claude Code, performing an end-of-session
review. Read ${SL_MEMORY_DIR}/MEMORY.md, ${SL_MEMORY_DIR}/USER.md, and scan the
learned-skills directory ${SL_SKILLS_DIR}/ for existing skills.

Then perform a combined memory + skill review:

## Task: Combined Review

1. **Memory review**: Scan for user corrections, project facts, user preferences,
   and user profile information worth proposing for MEMORY.md or USER.md.

2. **Skill review**: Scan for reusable patterns, commands, or workflows that
   should be saved as learned skills. Prefer updating existing skills over
   creating new narrow ones. Each proposed skill is persisted (by the
   writer, not by you) as ${SL_SKILLS_DIR}/<skill-name>/SKILL.md, with a
   matching entry in .usage.json created or refreshed automatically -- you
   do not write either file yourself.

## Rules

- Maximum 3 new memory FACTS + 2 skill operations per review cycle. Those
  facts go into at most ONE JSON entry per memory file (there are only two
  legal files, MEMORY.md and USER.md) -- see the OUTPUT CONTRACT below
- Each memory entry must be a single line, under 120 characters
- Never save: secrets, tokens, API keys, passwords, personal data beyond name/role
- Check existing memory before adding -- do not duplicate
- Skill names must match [A-Za-z0-9][A-Za-z0-9_-]{0,63} and be max 64
  characters (case-sensitive, digits/letters/underscore/hyphen only -- no dots)
- Skill descriptions must be max 60 characters, one sentence, end with period
- You may ONLY use Read, Glob, and Grep tools to gather context
- Do NOT use Bash for anything except listing files
- Do NOT make network requests or install packages
RPEOF
)"

# The OUTPUT CONTRACT, the transcript section and the Coach-signals section
# are byte-for-byte identical to what copilot-session-review.sh (and now
# vscode-session-review.sh) send, so all three take them from
# lib/review-common.sh rather than keeping three copies to drift apart. Only
# the harness-specific preamble above stays inline -- it genuinely differs
# (it names this reviewer's tools).
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_output_contract)"
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_transcript_section "${TRANSCRIPT_DIGEST}")"
REVIEW_PROMPT="${REVIEW_PROMPT}$(sl_review_coach_section "
For each Coach signal above, prefer writing ONE memory entry or skill that would
prevent that anti-pattern in future sessions. Do not exceed the write limits.")"

# --- Spawn review process in background ---
# The reviewer proposes; this script persists. The detaching, the positional
# argument passing, the failure log and the completion marker all live in
# lib/review-common.sh's sl_review_launch_detached -- see its header for why
# each is the way it is. Only this reviewer's own argv is built here.

if command -v claude &>/dev/null; then
    # --max-turns bounds the background reviewer's own tool-call loop (this
    # framework exists for cost efficiency; an unbounded background model
    # loop would be exactly the wrong thing to ship). --output-format text
    # is required, not cosmetic: it makes the reviewer emit its plain final
    # message (the fenced json block persist-proposal.py's extract_proposal
    # scans for) rather than a JSON envelope wrapping the response, which
    # would nest the proposal inside another JSON structure and break
    # extraction. Both are passed positionally, same as everything else here.
    #
    # --allowedTools / --disallowedTools enforce the plan's Global Constraint
    # 5 ("the reviewer agent must not be granted file-write tools") on this
    # path, which until now was enforced by prompt text alone while the
    # Copilot path enforced it mechanically with `--allow-tool read`. Both
    # flags were verified against the installed CLI (2.1.220) rather than
    # assumed: they are documented in `claude --help` and are accepted in
    # argv, and the control experiment in tests/test-review-cli-flags.sh
    # establishes that this CLI *does* error on unknown options, so
    # acceptance is real rather than silent-ignore. Comma-separated single
    # tokens (the help text allows comma or space separation) so a variadic
    # option can never swallow the flag that follows it.
    #
    # Read/Glob/Grep are exactly what the prompt above tells the reviewer it
    # may use, and it genuinely needs them: it reads MEMORY.md, USER.md and
    # scans the skills directory. Removing read access would break the
    # review, so the restriction is written as "these reads, no writes",
    # not "no tools".
    #
    # The deny list is not redundant with the allow list. --allowedTools is
    # an auto-approve list; a user's own settings.json `permissions.allow`
    # can still grant Write/Edit to any session on the machine, and this
    # reviewer inherits that settings file. Deny rules take precedence, so
    # --disallowedTools is what actually makes the constraint hold
    # independently of whatever the host has configured.
    sl_review_launch_detached session-review review-stderr.log \
        "$SL_LOG_DIR" "${SCRIPT_DIR}/persist-proposal.py" \
        claude -p "$REVIEW_PROMPT" --max-turns "${SL_REVIEW_MAX_TURNS}" \
        --output-format text \
        --allowedTools "Read,Glob,Grep" \
        --disallowedTools "Write,Edit,NotebookEdit"
fi

# --- Update counter state ---

jq --arg now "$NOW" \
    '.last_review_at = $now | .memory_turns = 0 | .skill_iterations = 0' \
    "$COUNTER_FILE" > "${COUNTER_FILE}.tmp" \
    && mv "${COUNTER_FILE}.tmp" "$COUNTER_FILE"

# --- Remove any pending signal ---
rm -f "${STATE_DIR}/review_signal.json"

# --- Record session end timestamp (used by curator idle gate) ---
echo "$NOW" > "${STATE_DIR}/last-session-end"

exit 0
