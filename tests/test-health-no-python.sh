#!/usr/bin/env bash
# tests/test-health-no-python.sh
#
# Deferred minor 10: when python3 is unavailable, self-learning-health.sh's
# hook-freshness check used to silently resolve SL_SCRIPTS_DIR to "" and
# then report EVERY Claude Code hook as STALE regardless of whether it
# actually was -- a wrong diagnosis pinned on the hook config when the real
# blocker (missing python3) was never named. This pins the fix: a single,
# clear FAIL naming python3 as the cause, and no per-hook STALE verdicts
# that were never actually checked.
#
# lib/config.sh itself is sourced by self-learning-health.sh and needs
# python3 too (for path resolution) but has its own literal fallback, so
# the script as a whole still runs -- only the hook-freshness section is
# under test here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

# A real, FRESH turn-counter hook (points at wherever this checkout's
# scripts live) -- if the missing-python3 path silently produced "", this
# would still get misreported STALE despite being genuinely fine, which is
# exactly the bug. Using a fresh hook here (not a broken one) is what makes
# the assertion meaningful: it proves the failure is attributed to python3,
# not smuggled in via a hook that would have failed anyway.
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<EOF
{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash ${SCRIPT_DIR}/scripts/turn-counter.sh","timeout":3}]}]}}
EOF

# Minimal PATH with every tool self-learning-health.sh needs EXCEPT python3,
# built the same way as test-config.sh's no-python block (cp, not ln -s --
# portable across platforms, no symlink privilege required).
_sl_no_python_dir="$(mktemp -d)"
for _tool in mkdir cp chmod sed dirname basename date grep cat mv rm printf touch mktemp bash sqlite3 jq test true false expr; do
    _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
    [[ -n "$_tool_path" ]] && cp "$_tool_path" "${_sl_no_python_dir}/${_tool}" 2>/dev/null || true
done

HEALTH_OUT="$(env -i HOME="$TMP_HOME" PATH="$_sl_no_python_dir" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    bash "${SCRIPT_DIR}/scripts/self-learning-health.sh" 2>&1)" || true
rm -rf "$_sl_no_python_dir"

check "no python3: a clear FAIL names python3 as the cause" "yes" \
    "$(printf '%s' "$HEALTH_OUT" | grep -qF 'cannot verify hook freshness -- python3 not found' && echo yes || echo no)"
check "no python3: does NOT misreport the fresh turn-counter hook as STALE" "no" \
    "$(printf '%s' "$HEALTH_OUT" | grep -q 'turn counter hook registered but STALE' && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- self-learning-health.sh output for debugging ---"
    printf '%s\n' "$HEALTH_OUT"
    exit 1
fi
echo "All health-no-python tests passed."
