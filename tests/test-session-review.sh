#!/usr/bin/env bash
# tests/test-session-review.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE="/nonexistent"
export SL_COACH_SIGNALS_FILE="$TMP/state/coach-signals.json"
mkdir -p "$TMP/state" "$TMP/bin"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Fake `claude` binary that records its argv and env
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_CLAUDE_LOG}"
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" FAKE_CLAUDE_LOG="$TMP/claude-calls.log"

# Counter above the min-turns gate
echo '{"session_id":"s1","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' > "$TMP/state/turn_counter.json"

# 1) Review spawns with recursion guard set
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
sleep 0.3
check "claude was invoked" "yes" "$([[ -s "$FAKE_CLAUDE_LOG" ]] && echo yes || echo no)"
check "guard env set for reviewer" "1" "$(grep -m1 '^GUARD:' "$FAKE_CLAUDE_LOG" | cut -d: -f2)"

# 2) Recursion guard on entry: guarded call spawns nothing
: > "$FAKE_CLAUDE_LOG"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/session-review.sh"
sleep 0.3
check "guarded entry spawns nothing" "no" "$([[ -s "$FAKE_CLAUDE_LOG" ]] && echo yes || echo no)"

# 3) Coach signals appear in the prompt when signals exist.
# The signal is planted BOTH as a pre-built signals file (valid before Task 12
# wires coach-signals.py into this script) AND as a Route B export fixture with
# SL_COACH_EXPORT_ENABLED=true (valid after Task 12, when coach-signals.py
# regenerates the signals file from the export before the prompt is built).
echo '{"session_id":"s1","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' > "$TMP/state/turn_counter.json"
echo '{"generated_at":"2099-01-01T00:00:00Z","signals":[{"id":"mega-sessions","severity":"high","suggestion":"Break large tasks into focused conversations."}]}' > "$SL_COACH_SIGNALS_FILE"
export SL_COACH_EXPORT_ENABLED=true SL_COACH_EXPORT_PATH="$TMP/export.json"
echo '{"antiPatterns":{"totalOccurrences":1,"topPatterns":[{"id":"mega-sessions","name":"Mega Sessions","severity":"high","group":"session-hygiene","occurrences":1,"description":"d","suggestion":"Break large tasks into focused conversations."}]}}' > "$SL_COACH_EXPORT_PATH"
: > "$FAKE_CLAUDE_LOG"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
unset SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH
sleep 0.3
check "coach signal id reaches prompt" "yes" "$(grep -q 'mega-sessions' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"

# 4) settings-hooks.json uses the valid nested schema
SCHEMA_OK=$(jq -e '.hooks.PostToolUse[0].hooks[0].type == "command" and (.hooks.Stop | length) >= 1' \
    "${SCRIPT_DIR}/config/settings-hooks.json" >/dev/null && echo yes || echo no)
check "settings-hooks.json nested schema" "yes" "$SCHEMA_OK"
ROLLING=$(grep -c 'rolling-transcript' "${SCRIPT_DIR}/config/settings-hooks.json" || true)
check "no reference to nonexistent rolling-transcript.sh" "0" "$ROLLING"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All session-review tests passed."
