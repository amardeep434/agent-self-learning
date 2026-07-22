#!/usr/bin/env bash
# tests/test-copilot-session-review.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE="/nonexistent"
mkdir -p "$TMP/state" "$TMP/bin"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

cat > "$TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_COPILOT_LOG}"
EOF
chmod +x "$TMP/bin/copilot"
export PATH="$TMP/bin:$PATH" FAKE_COPILOT_LOG="$TMP/copilot-calls.log"

# 1) Spawns copilot with guard, -p, -s, and tool allowances
bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sleep 0.3
check "copilot invoked" "yes" "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"
check "guard env set" "1" "$(grep -m1 '^GUARD:' "$FAKE_COPILOT_LOG" | cut -d: -f2)"
check "headless flags present" "yes" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '-p ' && echo yes || echo no)"
check "no model flag when unset" "no" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--model' && echo yes || echo no)"

# 2) Model flag appears when configured
: > "$FAKE_COPILOT_LOG"
SL_COPILOT_REVIEW_MODEL="cheap-model-x" bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sleep 0.3
check "model flag when set" "yes" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--model cheap-model-x' && echo yes || echo no)"

# 3) Recursion guard on entry
: > "$FAKE_COPILOT_LOG"
SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sleep 0.3
check "guarded entry spawns nothing" "no" "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"

# 4) Hook template shape
check "hook template version 1" "1" "$(jq -r .version "${SCRIPT_DIR}/config/copilot-hooks.json")"
check "sessionEnd command hook" "command" "$(jq -r '.hooks.sessionEnd[0].type' "${SCRIPT_DIR}/config/copilot-hooks.json")"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All copilot-session-review tests passed."
