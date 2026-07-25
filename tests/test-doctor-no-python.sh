#!/usr/bin/env bash
# tests/test-doctor-no-python.sh
#
# Round A fixed this shape (missing python3 -> every hook wrongly reported
# STALE instead of naming the real cause) in self-learning-health.sh only;
# scripts/doctor.sh's _sl_report_hooks() was out of that round's scope and
# still had the bug: with python3 absent, SL_SCRIPTS_DIR silently resolves
# to "", and sl_check_hook_fresh() (lib/config.sh) treats an empty
# scripts_dir as "never fresh" -- so every hook, even a genuinely fresh one,
# was reported STALE with no mention of python3 being the actual blocker.
# This pins the fix: a single clear failure naming python3, and no
# per-hook STALE verdicts that were never actually checked.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

# A real, FRESH turn-counter hook (points at wherever this checkout's
# scripts live) -- if the missing-python3 path silently produced "", this
# would still get misreported STALE despite being genuinely fine.
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<EOF
{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash ${SCRIPT_DIR}/scripts/turn-counter.sh","timeout":3}]}]}}
EOF

# Stub `claude` onto the no-python3 PATH so the harness section actually
# runs (doctor.sh only reports hooks for a harness it detects as present).
_sl_no_python_dir="$(mktemp -d)"
for _tool in mkdir cp chmod sed dirname basename date grep cat mv rm printf touch mktemp bash sqlite3 jq test true false expr tar du; do
    _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
    [[ -n "$_tool_path" ]] && cp "$_tool_path" "${_sl_no_python_dir}/${_tool}" 2>/dev/null || true
done
cat > "${_sl_no_python_dir}/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${_sl_no_python_dir}/claude"

DOCTOR_OUT="$(env -i HOME="$TMP_HOME" PATH="$_sl_no_python_dir" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)" || true
rm -rf "$_sl_no_python_dir"

check "no python3: doctor names python3 as the cause" "yes" \
    "$(printf '%s' "$DOCTOR_OUT" | grep -qF 'python3' && printf '%s' "$DOCTOR_OUT" | grep -qi 'cannot verify hook freshness' && echo yes || echo no)"
check "no python3: doctor does NOT misreport the fresh turn-counter hook as STALE" "no" \
    "$(printf '%s' "$DOCTOR_OUT" | grep -q 'turn-counter.sh: STALE' && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- doctor.sh output for debugging ---"
    printf '%s\n' "$DOCTOR_OUT"
    exit 1
fi
echo "All doctor-no-python tests passed."
