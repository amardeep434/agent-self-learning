#!/usr/bin/env bash
# tests/test-config.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Defaults (point SL_CONFIG_FILE at the repo config)
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="${SCRIPT_DIR}/config/self-learning.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_ENABLED|\$SL_COACH_EXPORT_ENABLED\"")
check "both coach flags default false" "false|false" "$OUT"

# Env override wins
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="${SCRIPT_DIR}/config/self-learning.conf" SL_COACH_RULES_ENABLED=true \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_ENABLED\"")
check "env override wins" "true" "$OUT"

# Missing config file is non-fatal, defaults apply
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
check "missing file falls back to defaults" "$HOME/.claude" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All config tests passed."
