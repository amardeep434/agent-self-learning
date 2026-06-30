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

STATE_DIR="${HOME}/.claude/state/self-learning"
COUNTER_FILE="${STATE_DIR}/turn_counter.json"
REVIEW_ENABLED="${CLAUDE_REVIEW_ENABLED:-true}"
MIN_TURNS_FOR_REVIEW=5
LOG_DIR="${HOME}/.claude/logs/reviews"

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

NOW=$(date -Iseconds)

# --- Build the review prompt ---

REVIEW_PROMPT="$(cat <<'RPEOF'
You are a Background Review agent for Claude Code, performing an end-of-session
review. Read ~/.claude/memory/MEMORY.md, ~/.claude/memory/USER.md, and scan the
learned-skills directory ~/.claude/learned-skills/ for existing skills.

Then perform a combined memory + skill review:

## Task: Combined Review

1. **Memory review**: Scan for user corrections, project facts, user preferences,
   and user profile information. Write to MEMORY.md or USER.md as appropriate.

2. **Skill review**: Scan for reusable patterns, commands, or workflows that
   should be saved as learned skills. Prefer updating existing skills over
   creating new narrow ones.

## Rules

- Maximum 3 memory writes + 2 skill operations per review cycle
- Each memory entry must be a single line, under 120 characters
- Never save: secrets, tokens, API keys, passwords, personal data beyond name/role
- Check existing memory before adding -- do not duplicate
- Skill names must match ^[a-z0-9][a-z0-9._-]*$ and be max 64 characters
- Skill descriptions must be max 60 characters, one sentence, end with period
- Set created_by="agent" in .usage.json for any new skill
- You may ONLY use Read, Write, Edit, Glob, and Grep tools
- Do NOT use Bash for anything except mkdir and listing files
- Do NOT make network requests or install packages
RPEOF
)"

# --- Spawn review process in background ---
# The review runs as a detached process so it does not block session exit.

REVIEW_LOG="${LOG_DIR}/$(date +%Y%m%d-%H%M%S)-session-review.log"

if command -v claude &>/dev/null; then
    nohup claude -p "$REVIEW_PROMPT" \
        --max-turns 16 \
        --output-format text \
        > "$REVIEW_LOG" 2>&1 &
    disown
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
