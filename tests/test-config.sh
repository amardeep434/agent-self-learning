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
check "missing file falls back to defaults" "$HOME/.local/share/agent-learning" "$OUT"

# Neutral defaults: no ~/.claude anywhere
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
case "$OUT" in
    *.claude*) echo "FAIL: SL_HOME still points into .claude ($OUT)"; FAILURES=$((FAILURES+1)) ;;
    *agent-learning*) echo "PASS: SL_HOME is vendor-neutral" ;;
    *) echo "FAIL: unexpected SL_HOME ($OUT)"; FAILURES=$((FAILURES+1)) ;;
esac

# Explicit override wins over platform default
OUT=$(env -i HOME="$HOME" PATH="$PATH" AGENT_LEARNING_HOME="/tmp/al" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_MEMORY_DIR\"")
check "AGENT_LEARNING_HOME drives SL_MEMORY_DIR" "/tmp/al/memory" "$OUT"

# New review flag defaults on
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED defaults true" "true" "$OUT"

# Legacy variable still honored for one release
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "legacy CLAUDE_REVIEW_ENABLED honored" "false" "$OUT"

# New variable beats legacy when both set
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_REVIEW_ENABLED=true SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED beats legacy" "true" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All config tests passed."
