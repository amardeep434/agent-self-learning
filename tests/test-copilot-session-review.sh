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

# 5) Hostile model string is rejected (no --model in argv)
: > "$FAKE_COPILOT_LOG"
SL_COPILOT_REVIEW_MODEL='x; rm -rf /' bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sleep 0.3
check "hostile model string dropped" "no" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--model' && echo yes || echo no)"

# 6) Untrusted-data framing present in prompt when signals exist.
# The signal is planted as a Route B export fixture with SL_COACH_EXPORT_ENABLED=true
# (same pattern as the session-review test): coach-signals.py, which this script
# invokes before building the prompt, regenerates the managed signals file from the
# export. (A raw pre-built signals file would be deleted by coach-signals.py when
# both routes are off, so it must be planted through an enabled route.)
mkdir -p "$TMP/state"
echo '{"generated_at":"2099-01-01T00:00:00Z","signals":[{"id":"x","severity":"low","suggestion":"s"}]}' > "$TMP/state/coach-signals.json"
export SL_COACH_EXPORT_ENABLED=true SL_COACH_EXPORT_PATH="$TMP/export6.json"
echo '{"antiPatterns":{"totalOccurrences":1,"topPatterns":[{"id":"x","name":"X","severity":"low","group":"g","occurrences":1,"description":"d","suggestion":"s"}]}}' > "$SL_COACH_EXPORT_PATH"
: > "$FAKE_COPILOT_LOG"
SL_COACH_SIGNALS_FILE="$TMP/state/coach-signals.json" bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
unset SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH
sleep 0.3
check "untrusted-data framing in prompt" "yes" "$(grep -q 'untrusted telemetry data' "$FAKE_COPILOT_LOG" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All copilot-session-review tests passed."
