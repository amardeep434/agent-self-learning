#!/usr/bin/env bash
# tests/test-turn-counter.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_CONFIG_FILE="/nonexistent"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

payload() { echo "{\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"hook_event_name\":\"PostToolUse\"}"; }

# 1) First call creates counter with session id from stdin
payload sess-A | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "session id recorded from stdin" "sess-A" "$(jq -r .session_id "$TMP/state/turn_counter.json")"
check "one tool call counted" "1" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 2) Same session increments
payload sess-A | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "increment within session" "2" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 3) New session resets
payload sess-B | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "session boundary resets counter" "1" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"
check "new session id recorded" "sess-B" "$(jq -r .session_id "$TMP/state/turn_counter.json")"

# 4) Recursion guard: no state change when SL_REVIEW_ACTIVE is set
BEFORE=$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")
payload sess-B | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "recursion guard skips counting" "$BEFORE" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All turn-counter tests passed."
