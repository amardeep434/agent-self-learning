#!/usr/bin/env bash
# tests/test-health-copilot-hooks.sh
#
# Deferred minor 11: self-learning-health.sh -- the installed, user-facing
# diagnostic tool -- checked Claude Code's hook registration but not
# Copilot's; only doctor.sh (not shipped to run by default, per
# install.sh's own instructions which point users at self-learning-health.sh
# first) checked both. A Copilot-only install with a stale or missing hook
# registration got no signal from the tool users are told to run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
contains() { case "$2" in *"$3"*) echo "PASS: $1";; *) echo "FAIL: $1 (output did not contain '$3')"; FAILURES=$((FAILURES+1));; esac; }
not_contains() { case "$2" in *"$3"*) echo "FAIL: $1 (output unexpectedly contained '$3')"; FAILURES=$((FAILURES+1));; *) echo "PASS: $1";; esac; }
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

run_health() {
    env -i HOME="$1" PATH="$PATH" AGENT_LEARNING_HOME="$2" \
        SL_CONFIG_FILE="/nonexistent/x.conf" \
        bash "${SCRIPT_DIR}/scripts/self-learning-health.sh" 2>&1
}

## 1. No ~/.copilot at all -- must WARN, never FAIL (normal on a
##    Claude-Code-only or VS-Code-only machine).
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
mkdir -p "${STORE}/state" "${STORE}/learned-skills" "${STORE}/sessions" "${STORE}/logs/reviews" "${STORE}/logs/curator" "${STORE}/scripts"
OUT="$(run_health "$TMP_HOME" "$STORE")"
contains "no ~/.copilot: labelled Copilot-specific" "$OUT" "Hook Registration (Copilot CLI)"
contains "no ~/.copilot: reported as a WARN, not a FAIL" "$OUT" "self-learning.json not found"
rm -rf "$TMP_HOME"

## 2. Fresh Copilot hook config -- must PASS.
#
# Fix round E: RESOLVED_SCRIPTS used to be a bash-literal "${STORE}/scripts"
# concatenation, compared textually (via sl_check_hook_fresh) against what
# self-learning-health.sh independently resolves via python3 -- a mismatch
# on Git Bash/MSYS2's differently-spelled-but-identical paths. Resolve it
# through the same tool instead.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
RESOLVED_SCRIPTS="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" scripts \
    HOME="$TMP_HOME" AGENT_LEARNING_HOME="$STORE" PATH="$PATH")"
mkdir -p "${STORE}/state" "${STORE}/learned-skills" "${STORE}/sessions" "${STORE}/logs/reviews" "${STORE}/logs/curator" "$RESOLVED_SCRIPTS"
mkdir -p "${TMP_HOME}/.copilot/hooks"
cat > "${TMP_HOME}/.copilot/hooks/self-learning.json" <<EOF
{"hooks":{"sessionEnd":[{"bash":"bash ${RESOLVED_SCRIPTS}/copilot-session-review.sh"}]}}
EOF
OUT="$(run_health "$TMP_HOME" "$STORE")"
contains "fresh copilot hook: reported registered" "$OUT" "copilot-session-review.sh hook registered and points at the resolved scripts dir"
not_contains "fresh copilot hook: never flagged STALE" "$OUT" "copilot-session-review.sh hook registered but STALE"
rm -rf "$TMP_HOME"

## 3. Stale Copilot hook config (points at a non-resolved path) -- must FAIL.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
mkdir -p "${STORE}/state" "${STORE}/learned-skills" "${STORE}/sessions" "${STORE}/logs/reviews" "${STORE}/logs/curator" "${STORE}/scripts"
mkdir -p "${TMP_HOME}/.copilot/hooks"
cat > "${TMP_HOME}/.copilot/hooks/self-learning.json" <<'EOF'
{"hooks":{"sessionEnd":[{"bash":"bash /some/very/stale/path/copilot-session-review.sh"}]}}
EOF
OUT="$(run_health "$TMP_HOME" "$STORE")"
STATUS=$?
contains "stale copilot hook: flagged STALE" "$OUT" "copilot-session-review.sh hook registered but STALE"
check "stale copilot hook flips health to unhealthy" "1" "$STATUS"
rm -rf "$TMP_HOME"

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "All health copilot-hooks tests passed."
