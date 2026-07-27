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
# Performance target: <50ms execution time (pure bash + jq, no Python)

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

STATE_DIR="${SL_STATE_DIR}"
COUNTER_FILE="${STATE_DIR}/turn_counter.json"
SIGNAL_FILE="${STATE_DIR}/review_signal.json"
LOCK_DIR="${STATE_DIR}/counter.lock"
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

# --- Load current state ---

if [[ -f "$COUNTER_FILE" ]]; then
    CURRENT_SESSION=$(jq -r '.session_id // "none"' "$COUNTER_FILE" 2>/dev/null || echo "none")
    MEMORY_TURNS=$(jq -r '.memory_turns // 0' "$COUNTER_FILE" 2>/dev/null || echo "0")
    SKILL_ITERS=$(jq -r '.skill_iterations // 0' "$COUNTER_FILE" 2>/dev/null || echo "0")
    TOTAL_TURNS=$(jq -r '.total_turns_this_session // 0' "$COUNTER_FILE" 2>/dev/null || echo "0")
    LAST_REVIEW=$(jq -r '.last_review_at // ""' "$COUNTER_FILE" 2>/dev/null || echo "")
    SESSION_START=$(jq -r '.session_started_at // ""' "$COUNTER_FILE" 2>/dev/null || echo "")
else
    CURRENT_SESSION="none"
    MEMORY_TURNS=0
    SKILL_ITERS=0
    TOTAL_TURNS=0
    LAST_REVIEW=""
    SESSION_START=""
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
