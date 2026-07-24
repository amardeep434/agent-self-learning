#!/usr/bin/env bash
# tests/test-skillopt-run.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_CONFIG_FILE="/nonexistent"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Fake SkillOpt checkout whose run-sleep.sh just echoes its args
mkdir -p "$TMP/skillopt/plugins" "$TMP/skillopt/skillopt_sleep"
cat > "$TMP/skillopt/plugins/run-sleep.sh" <<'EOF'
#!/usr/bin/env bash
echo "RUNSLEEP:$*"
EOF
chmod +x "$TMP/skillopt/plugins/run-sleep.sh"

run() { bash "${SCRIPT_DIR}/scripts/skillopt-run.sh" "$@" 2>"$TMP/err"; }

# 1) Disabled by default: no-op, exit 0, nothing passed through
OUT=$(SL_SKILLOPT_ENABLED=false run status || echo "EXIT$?")
check "disabled is no-op" "" "$OUT"
check "disabled notes reason" "yes" "$(grep -q 'disabled' "$TMP/err" && echo yes || echo no)"

# 2) Enabled but no repo: graceful stderr, exit 0
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="" run status || echo "EXIT$?")
check "enabled+no-repo exit 0" "" "$OUT"
check "enabled+no-repo explains" "yes" "$(grep -qi 'checkout\|SL_SKILLOPT_REPO' "$TMP/err" && echo yes || echo no)"

# 3) Enabled + repo: cheap verb passes through
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" run harvest --since 1d)
check "harvest passes through" "RUNSLEEP:harvest --since 1d" "$OUT"

# 4) 'run' blocked unless confirmed
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" SL_SKILLOPT_RUN_CONFIRMED=false run run || echo "EXIT$?")
check "run blocked without confirm" "" "$OUT"
check "run block explains gate" "yes" "$(grep -q 'SL_SKILLOPT_RUN_CONFIRMED' "$TMP/err" && echo yes || echo no)"

# 5) 'run' allowed when confirmed
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" SL_SKILLOPT_RUN_CONFIRMED=true run run)
check "run passes when confirmed" "RUNSLEEP:run" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All skillopt-run tests passed."
