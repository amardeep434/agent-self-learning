#!/usr/bin/env bash
#
# Turn counter for Background Review system.
# Called as a PostToolUse hook after EVERY tool use.
#
# Responsibilities:
# 1. Increment the skill_iterations counter (every tool call)
# 2. Detect assistant responses and increment memory_turns
# 3. Write a signal file when either threshold is reached
# 4. Handle session boundary detection (reset on new session)
#
# Input: Claude Code hook payload JSON on stdin (session_id, tool_name, ...).
# Configuration: scripts/lib/config.sh (env > $SL_HOME/self-learning.conf > defaults).
#
# Performance target: <100ms execution time (pure bash + jq, no Python of its
# own -- config.sh spawns one `python3 lib/paths.py all`, which dominates).
# The <50ms this line used to claim was never met on any machine measured; see
# CLAUDE.md's "All hooks must complete in <100ms" bullet for the measurements
# and for why caching the path resolution was considered and rejected.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

# Recursion guard: never count tool calls made by a spawned background reviewer.
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
SIGNAL_FILE="${STATE_DIR}/review_signal.json"
LOCK_DIR="${STATE_DIR}/counter.lock"
DEGRADED_MARKER="${STATE_DIR}/.counter-degraded"
# Seconds between two reports of a CONTINUOUSLY degraded counter. See
# report_degraded below for why this hook cannot just log every time.
DEGRADED_REPORT_INTERVAL=3600
MEMORY_INTERVAL="${SL_MEMORY_REVIEW_INTERVAL}"
SKILL_INTERVAL="${SL_SKILL_REVIEW_INTERVAL}"
SESSION_ID="${HOOK_SESSION_ID}"
TOOL_NAME="${HOOK_TOOL_NAME}"

mkdir -p "$STATE_DIR"

# --- Atomic read-modify-write with directory lock ---
# mkdir is atomic on POSIX: only one process can create the directory.

acquire_lock() {
    local max_wait=2  # seconds
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [[ "$waited" -ge "$max_wait" ]]; then
            # Stale lock -- remove and retry
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || true
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

trap release_lock EXIT
acquire_lock

# --- Degraded-state reporting (throttled) ---
#
# Every other script in this project reports a broken precondition by calling
# sl_review_precondition_failed, which appends one line to
# persist-failures.log -- the one channel doctor.sh reads. This hook may NOT
# do that unconditionally: it runs on EVERY tool use, so an unthrottled call
# would append thousands of identical lines per session and turn doctor.sh's
# "N persistence failure(s) recorded" into unreadable noise. That would
# destroy the diagnostic instead of using it.
#
# So the FORMATTING and DESTINATION stay shared (one message format across the
# project, one file for doctor.sh to read) and only the THROTTLE lives here,
# because only this script has the per-tool-use constraint. Reusing
# sl_review_precondition_failed's wording is deliberate too: it reads "review
# NOT attempted -- <reason>", and a counter that cannot be read is exactly the
# reason no review will ever be attempted.
#
# The throttle is a marker file holding the epoch of the last report:
#
#   * First entry into the degraded state always reports immediately -- the
#     transition is the interesting event.
#   * While it stays degraded, at most one line per DEGRADED_REPORT_INTERVAL.
#     A machine broken for a day leaves ~24 lines, not ~50,000; still loud
#     enough that a human running doctor.sh cannot miss it, and it keeps
#     accruing rather than being a single line that scrolls into history.
#   * Recovery deletes the marker, so the NEXT breakage is reported at once
#     instead of being swallowed by a stale cooldown.
#
# Cost is paid only when already degraded (one `date` spawn); the healthy path
# adds one `[[ -f ]]` builtin test.
report_degraded() {
    local reason="$1" now last=0
    now=$(date +%s)
    if [[ -f "$DEGRADED_MARKER" ]]; then
        read -r last < "$DEGRADED_MARKER" || last=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if (( now - last < DEGRADED_REPORT_INTERVAL )); then
            return 0
        fi
    fi
    printf '%s\n' "$now" > "$DEGRADED_MARKER"
    sl_review_precondition_failed turn-counter "$SL_LOG_DIR" "$reason"
}

# Explicit `return 0`: `[[ -f ... ]] && rm` alone returns 1 when the marker is
# absent (the normal case), which under `set -e` would kill the hook.
clear_degraded() {
    [[ -f "$DEGRADED_MARKER" ]] && rm -f "$DEGRADED_MARKER"
    return 0
}

# --- Load current state ---
#
# These six values used to be read with six separate
# `jq -r '<field> // <default>' ... 2>/dev/null || echo <default>` calls. That
# collapsed three different situations onto the same answer: "the field is
# absent" (legitimate), "the file is unparseable", and "jq cannot run at all".
# The last two are fatal and were completely silent -- measured on this branch
# before the fix, with jq off PATH, eight consecutive tool uses each rewrote
# total_turns_this_session as 1, so the count could never reach any review
# threshold, no review_signal.json was ever written, and nothing was recorded
# anywhere on disk. Same defect session-review.sh carried until 9dfb956, one
# layer earlier and permanent rather than per-session.
#
# One jq call now emits all six fields as @tsv, so jq's EXIT STATUS answers
# "could I read this file at all?" while `// <default>` still answers "is this
# field present?" -- the two questions the old form could not tell apart. It
# is also five fewer process spawns per tool use.

CURRENT_SESSION="none"
MEMORY_TURNS=0
SKILL_ITERS=0
TOTAL_TURNS=0
LAST_REVIEW=""
SESSION_START=""

if ! command -v jq >/dev/null 2>&1; then
    # Without jq nothing here can count, and overwriting the counter file with
    # defaults would additionally destroy whatever real state a previous,
    # working jq had accumulated. Report and leave the file alone.
    report_degraded \
        "jq is not on PATH, so ${COUNTER_FILE} can be neither read nor maintained -- turns are not being counted and no review can ever trigger"
    exit 0
fi

if [[ -f "$COUNTER_FILE" ]]; then
    # @tsv (not raw newlines) so a session_id containing a tab or newline
    # cannot shift the remaining fields: jq escapes those as \t and \n inside
    # the field rather than emitting a real separator.
    #
    # Every field is prefixed with a literal "x", stripped again below, so that
    # NO field is ever empty. Tab is an IFS *whitespace* character, and bash
    # `read` collapses runs of IFS whitespace into one delimiter -- so an empty
    # last_review_at (the normal state until the first review) made the two
    # adjacent tabs read as one and shifted session_started_at into
    # LAST_REVIEW. Caught by writing this fix: the empty field is exactly the
    # common case, and the cooldown gate reads LAST_REVIEW.
    if ! STATE_TSV=$(jq -r '["x" + (.session_id // "none" | tostring),
                             "x" + (.memory_turns // 0 | tostring),
                             "x" + (.skill_iterations // 0 | tostring),
                             "x" + (.total_turns_this_session // 0 | tostring),
                             "x" + (.last_review_at // "" | tostring),
                             "x" + (.session_started_at // "" | tostring)] | @tsv' \
                        "$COUNTER_FILE" 2>/dev/null); then
        # Deliberately names both causes: a jq that EXISTS but exits nonzero
        # (broken build, wrapper script, shim) is indistinguishable here from
        # a genuinely malformed counter file, and claiming only one would be a
        # guess. Unlike the jq-absent branch this one does NOT preserve the
        # file -- a truly corrupt counter would otherwise wedge counting
        # forever, and the accumulated state is unreadable either way.
        report_degraded \
            "${COUNTER_FILE} could not be read: either it is malformed or jq failed on it -- this session's turn count was reset to 0 and the file rewritten"
    else
        IFS=$'\t' read -r _sess _mem _skill _total _last _start <<< "$STATE_TSV" || true
        # Strip the "x" guard prefix added above.
        _sess="${_sess#x}"; _mem="${_mem#x}"; _skill="${_skill#x}"
        _total="${_total#x}"; _last="${_last#x}"; _start="${_start#x}"
        # A non-numeric counter would silently evaluate to 0 inside $(( )) --
        # the same collapse in a different disguise, so it is reported too.
        if [[ "$_mem" =~ ^[0-9]+$ && "$_skill" =~ ^[0-9]+$ && "$_total" =~ ^[0-9]+$ ]]; then
            CURRENT_SESSION="$_sess"
            MEMORY_TURNS="$_mem"
            SKILL_ITERS="$_skill"
            TOTAL_TURNS="$_total"
            LAST_REVIEW="$_last"
            SESSION_START="$_start"
            clear_degraded
        else
            report_degraded \
                "${COUNTER_FILE} parses as JSON but its counters are not numbers (memory_turns=${_mem}, skill_iterations=${_skill}, total_turns_this_session=${_total}) -- reset to 0"
        fi
    fi
else
    # No counter file on the first tool use of a session is NORMAL. The
    # defaults above are the right answer and this case must stay silent.
    clear_degraded
fi

# --- Session boundary detection ---
# When the session ID changes, reset all counters for the new session.

if [[ "$SESSION_ID" != "$CURRENT_SESSION" && "$SESSION_ID" != "unknown" ]]; then
    MEMORY_TURNS=0
    SKILL_ITERS=0
    TOTAL_TURNS=0
    LAST_REVIEW=""
    SESSION_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    CURRENT_SESSION="$SESSION_ID"
fi

# --- Increment counters ---

# Every tool call increments skill_iterations
SKILL_ITERS=$((SKILL_ITERS + 1))
TOTAL_TURNS=$((TOTAL_TURNS + 1))

# Heuristic: certain tools indicate a "turn boundary" (assistant responded).
# We increment memory_turns every 3 tool calls as an approximation of one
# user-visible turn. A more precise approach would detect actual user messages,
# but PostToolUse hooks do not receive that signal.
if (( TOTAL_TURNS % 3 == 0 )); then
    MEMORY_TURNS=$((MEMORY_TURNS + 1))
fi

# --- Check thresholds ---

REVIEW_MEMORY=false
REVIEW_SKILLS=false

if (( MEMORY_TURNS >= MEMORY_INTERVAL )); then
    REVIEW_MEMORY=true
    MEMORY_TURNS=0
fi

if (( SKILL_ITERS >= SKILL_INTERVAL )); then
    REVIEW_SKILLS=true
    SKILL_ITERS=0
fi

# --- Write updated state ---
# Use atomic temp-file-then-rename to prevent corruption on concurrent access.

cat > "${COUNTER_FILE}.tmp" <<CEOF
{
  "session_id": "${CURRENT_SESSION}",
  "memory_turns": ${MEMORY_TURNS},
  "skill_iterations": ${SKILL_ITERS},
  "last_review_at": "${LAST_REVIEW}",
  "session_started_at": "${SESSION_START}",
  "total_turns_this_session": ${TOTAL_TURNS}
}
CEOF
mv "${COUNTER_FILE}.tmp" "$COUNTER_FILE"

# --- Signal review if threshold reached ---

if [[ "$REVIEW_MEMORY" == "true" || "$REVIEW_SKILLS" == "true" ]]; then
    # Prevent rapid re-triggering (minimum 60 seconds between reviews)
    if [[ -n "$LAST_REVIEW" ]]; then
        LAST_EPOCH=$(sl_iso_to_epoch "$LAST_REVIEW")
        NOW_EPOCH=$(date +%s)
        if (( NOW_EPOCH - LAST_EPOCH < 60 )); then
            exit 0
        fi
    fi

    # Write the signal file for the review system to pick up
    cat > "${SIGNAL_FILE}.tmp" <<SEOF
{
  "review_memory": ${REVIEW_MEMORY},
  "review_skills": ${REVIEW_SKILLS},
  "triggered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "session_id": "${CURRENT_SESSION}",
  "total_turns": ${TOTAL_TURNS}
}
SEOF
    mv "${SIGNAL_FILE}.tmp" "$SIGNAL_FILE"
fi

exit 0
