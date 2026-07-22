#!/usr/bin/env bash
# tests/test-hook-input.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
        FAILURES=$((FAILURES + 1))
    fi
}

# Case 1: full payload
OUT=$(echo '{"session_id":"abc-123","tool_name":"Bash","hook_event_name":"PostToolUse","transcript_path":"/tmp/t.jsonl"}' \
    | bash -c "source '${SCRIPT_DIR}/scripts/lib/hook-input.sh'; echo \"\$HOOK_SESSION_ID|\$HOOK_TOOL_NAME|\$HOOK_EVENT_NAME|\$HOOK_TRANSCRIPT_PATH\"")
check "full payload" "abc-123|Bash|PostToolUse|/tmp/t.jsonl" "$OUT"

# Case 2: empty stdin
OUT=$(printf '' | bash -c "source '${SCRIPT_DIR}/scripts/lib/hook-input.sh'; echo \"\$HOOK_SESSION_ID|\$HOOK_TOOL_NAME\"")
check "empty stdin" "unknown|unknown" "$OUT"

# Case 3: invalid JSON
OUT=$(echo 'not json' | bash -c "source '${SCRIPT_DIR}/scripts/lib/hook-input.sh'; echo \"\$HOOK_SESSION_ID\"")
check "invalid JSON" "unknown" "$OUT"

# Case 4: partial payload
OUT=$(echo '{"session_id":"s1"}' | bash -c "source '${SCRIPT_DIR}/scripts/lib/hook-input.sh'; echo \"\$HOOK_SESSION_ID|\$HOOK_TOOL_NAME\"")
check "partial payload" "s1|unknown" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "All hook-input tests passed."
