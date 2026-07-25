#!/usr/bin/env bash
# tests/test-doctor-strict.sh
#
# Item 2: doctor.sh currently exits non-zero only for non-writable paths and
# a non-empty persist-failures.log. A STALE hook (a genuinely broken state --
# the installed hook points at a scripts dir that is no longer resolved) is
# printed loudly but never flips the exit code, so a CI job or wrapper script
# checking doctor's exit code passes with broken hook wiring. --strict closes
# that gap. Default behaviour (no flag) must stay exactly as it was: this
# suite proves both the new flag AND that the old default is untouched.
#
# Deliberate carry-over, tested here explicitly: a detected legacy ~/.claude
# store must NOT be fatal even under --strict -- every upgraded machine would
# go red forever otherwise.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
contains() { case "$2" in *"$3"*) echo "PASS: $1";; *) echo "FAIL: $1 (output did not contain '$3')"; FAILURES=$((FAILURES+1));; esac; }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

run_env() {
    env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
        SL_CONFIG_FILE="/nonexistent/x.conf" bash "$@"
}

# ---------------------------------------------------------------------------
# 1. No harness registered at all: neither default nor --strict should ever
#    fail purely because ~/.claude/settings.json doesn't exist.
# ---------------------------------------------------------------------------
OUT="$(run_env "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)"; RC=$?
check "no-harness default exits 0" "0" "$RC"
OUT_STRICT="$(run_env "${SCRIPT_DIR}/scripts/doctor.sh" --strict 2>&1)"; RC_STRICT=$?
check "no-harness --strict exits 0 (nothing stale to fail on)" "0" "$RC_STRICT"

# ---------------------------------------------------------------------------
# 2. A STALE hook: settings.json registers turn-counter.sh under a scripts
#    dir that is NOT the resolved one (AGENT_LEARNING_HOME/store/scripts).
# ---------------------------------------------------------------------------
mkdir -p "${TMP_HOME}/.claude"
STALE_SCRIPTS_DIR="${TMP_HOME}/old-scripts-dir-that-no-longer-resolves"
cat > "${TMP_HOME}/.claude/settings.json" <<EOF
{"hooks":{"PostToolUse":[{"hooks":[{"command":"bash ${STALE_SCRIPTS_DIR}/turn-counter.sh"}]}]}}
EOF

# Fake `claude` on PATH so doctor.sh's "claude present" branch runs and
# actually inspects the hook config above.
FAKE_BIN="$(mktemp -d)"
cat > "${FAKE_BIN}/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FAKE_BIN}/claude"

run_env_with_claude() {
    env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
        SL_CONFIG_FILE="/nonexistent/x.conf" bash "$@"
}

DEFAULT_OUT="$(run_env_with_claude "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)"; DEFAULT_RC=$?
contains "default run reports the hook as STALE" "$DEFAULT_OUT" "STALE"
check "stale hook under DEFAULT mode still exits 0 (behaviour unchanged)" "0" "$DEFAULT_RC"
contains "default run's overall status is HEALTHY (stale hook alone does not fail it)" "$DEFAULT_OUT" "overall: HEALTHY"

STRICT_OUT="$(run_env_with_claude "${SCRIPT_DIR}/scripts/doctor.sh" --strict 2>&1)"; STRICT_RC=$?
contains "--strict run also reports the hook as STALE" "$STRICT_OUT" "STALE"
check "stale hook under --strict exits 1" "1" "$STRICT_RC"
contains "--strict run's overall status is UNHEALTHY" "$STRICT_OUT" "overall: UNHEALTHY"
contains "--strict run names hook staleness as the reason" "$STRICT_OUT" "STALE hook found above -- failing"

# ---------------------------------------------------------------------------
# 3. Legacy ~/.claude store detected: must NOT be fatal, even under --strict,
#    and even in the presence of the stale hook from step 2 (isolate legacy
#    from staleness by removing the stale hook for this check).
# ---------------------------------------------------------------------------
rm -f "${TMP_HOME}/.claude/settings.json"
mkdir -p "${TMP_HOME}/.claude/memory" "${TMP_HOME}/.claude/learned-skills"

LEGACY_STRICT_OUT="$(run_env "${SCRIPT_DIR}/scripts/doctor.sh" --strict 2>&1)"; LEGACY_STRICT_RC=$?
contains "legacy store detected in --strict output" "$LEGACY_STRICT_OUT" "legacy ~/.claude store found"
check "legacy store alone does not fail --strict" "0" "$LEGACY_STRICT_RC"

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "All doctor --strict tests passed."
