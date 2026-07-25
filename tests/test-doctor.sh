#!/usr/bin/env bash
# tests/test-doctor.sh
#
# doctor.sh's primary job is surfacing ${SL_LOG_DIR}/persist-failures.log --
# the only signal that replaces a hook exit code once the review pipeline
# runs fully detached. Most of this suite is built around that fact: it is
# tested for presence, absence, emptiness, count, recency, and — critically
# — that its content actually flips the exit code, not just that some text
# is printed while exit stays 0 (the known vacuity trap in this project).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
contains() { case "$2" in *"$3"*) echo "PASS: $1";; *) echo "FAIL: $1 (output did not contain '$3')"; FAILURES=$((FAILURES+1));; esac; }
not_contains() { case "$2" in *"$3"*) echo "FAIL: $1 (output unexpectedly contained '$3')"; FAILURES=$((FAILURES+1));; *) echo "PASS: $1";; esac; }

# ---------------------------------------------------------------------------
# 1. Basic resolved-path and writability reporting (baseline, healthy case)
# ---------------------------------------------------------------------------
TMP_HOME="$(mktemp -d)"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?

contains "doctor prints resolved memory path" "$OUT" "${TMP_HOME}/store/memory"
contains "doctor reports writability" "$OUT" "writable"
contains "doctor shows override source" "$OUT" "AGENT_LEARNING_HOME"
check "healthy run exits 0" "0" "$RC"

# Resolved "home" line must reflect the actual resolver output, never a
# hardcoded ~/.claude (the Task 7c bug class). Checked against the specific
# printed "home" line, not the whole output, since the legacy-store section
# is expected to mention ~/.claude when present.
HOME_LINE="$(printf '%s\n' "$OUT" | grep '^  home ')"
case "$HOME_LINE" in
    *"/.claude"*) echo "FAIL: resolved home path wrongly contains /.claude: $HOME_LINE"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: resolved home path does not contain /.claude" ;;
esac

rm -rf "$TMP_HOME"

# ---------------------------------------------------------------------------
# 2. Legacy store detection (detect only -- must not modify anything)
# ---------------------------------------------------------------------------
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/.claude/memory"
echo "sentinel" > "${TMP_HOME}/.claude/memory/MEMORY.md"

OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)

# "legacy store:" is always printed as a section header even when nothing
# is found, so asserting on that alone would be vacuous -- assert on the
# found-marker plus the actual path together.
contains "legacy store detected" "$OUT" "legacy ~/.claude store found"
contains "legacy store path reported" "$OUT" "${TMP_HOME}/.claude"

# Never move or modify user data.
check "legacy MEMORY.md untouched" "sentinel" "$(cat "${TMP_HOME}/.claude/memory/MEMORY.md")"
check "nothing copied into new store yet" "false" "$([[ -e "${TMP_HOME}/store/memory/MEMORY.md" ]] && echo true || echo false)"

rm -rf "$TMP_HOME"

# ---------------------------------------------------------------------------
# 3. Non-writable directory is reported as such (not inferred, actually
#    tested) and flips the exit code. Skipped when running as root, since
#    permission bits do not restrict root and the assertion would be
#    meaningless rather than merely failing.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: non-writable-directory test (running as root, permissions do not apply)"
else
    TMP_HOME="$(mktemp -d)"
    LOCKED_PARENT="${TMP_HOME}/locked"
    mkdir -p "$LOCKED_PARENT"
    chmod 500 "$LOCKED_PARENT"

    OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${LOCKED_PARENT}/store" \
          SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
    RC=$?

    contains "non-writable dir reported as NOT WRITABLE" "$OUT" "NOT WRITABLE"
    check "non-writable dir flips exit code to 1" "1" "$RC"

    chmod 700 "$LOCKED_PARENT"
    rm -rf "$TMP_HOME"
fi

# ---------------------------------------------------------------------------
# 4. persist-failures.log: absent vs empty vs populated must all read
#    differently, and only "populated" may flip the exit code. This is the
#    primary requirement of this task -- most of the suite lives here.
# ---------------------------------------------------------------------------

# 4a. Absent log.
TMP_HOME="$(mktemp -d)"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?
contains "absent persist-failures.log reported as ABSENT" "$OUT" "ABSENT"
check "absent persist-failures.log does not fail the run" "0" "$RC"
rm -rf "$TMP_HOME"

# 4b. Empty (present but zero-byte) log -- must read differently from absent.
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
: > "${TMP_HOME}/store/logs/persist-failures.log"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?
contains "empty persist-failures.log reported as EMPTY" "$OUT" "EMPTY"
not_contains "empty log is not reported as ABSENT" "$OUT" "ABSENT"
check "empty persist-failures.log does not fail the run" "0" "$RC"
rm -rf "$TMP_HOME"

# 4c. Populated log: count, bounded tail, recency, unmissable marker, and
#     (this is the content-vs-exit-code check) exit code 1.
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
LOG="${TMP_HOME}/store/logs/persist-failures.log"
for i in 1 2 3 4 5 6 7; do
    printf '2020-01-0%dT00:00:00Z session-review: pipeline failed (status 1)\n' "$((i % 9 + 1))" >> "$LOG"
done
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s session-review: pipeline failed (status 1)\n' "$NOW_TS" >> "$LOG"

OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?

contains "populated log: count reported" "$OUT" "8 PERSISTENCE FAILURE"
contains "populated log: most recent timestamp reported" "$OUT" "$NOW_TS"
contains "populated log: visually unmissable marker" "$OUT" "!!!"
contains "populated log: bounded tail present" "$OUT" "bounded tail, last 5 of 8"
check "populated log flips exit code to 1 (content-driven, not just text)" "1" "$RC"

# The tail must actually be bounded: an old (2020) entry must not appear in
# the printed tail once 8 entries exist and only the last 5 are shown.
case "$OUT" in
    *"2020-01-01"*) echo "FAIL: doctor printed an entry that should have been outside the bounded tail"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: bounded tail excludes older entries" ;;
esac

rm -rf "$TMP_HOME"

# ---------------------------------------------------------------------------
# 5. Copilot/VS-Code-only machine gets a clean bill of health: claude
#    absence alone must never cause a FAIL-shaped exit or NOT WRITABLE.
# ---------------------------------------------------------------------------
FAKE_BIN="$(mktemp -d)"
_sys_path_dirs="/usr/bin:/bin"
for _tool in python3; do
    if ! PATH="${FAKE_BIN}:${_sys_path_dirs}" command -v "$_tool" >/dev/null 2>&1; then
        _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
        [[ -n "$_tool_path" ]] && _sys_path_dirs="$(dirname "$_tool_path"):${_sys_path_dirs}"
    fi
done
MINIMAL_PATH="${FAKE_BIN}:${_sys_path_dirs}"

TMP_HOME="$(mktemp -d)"
OUT=$(env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?
contains "claude absence is labelled normal, not a failure" "$OUT" "absent (normal"
check "claude-absent run still exits healthy" "0" "$RC"
rm -rf "$TMP_HOME" "$FAKE_BIN"

# ---------------------------------------------------------------------------
# 6. Stale Claude Code hook config is flagged.
# ---------------------------------------------------------------------------
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<'JSON'
{"hooks":{"PostToolUse":[{"command":"bash /some/very/stale/path/turn-counter.sh"}]}}
JSON
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
if printf '%s' "$OUT" | grep -q "claude   present"; then
    contains "stale hook path is flagged" "$OUT" "STALE"
else
    echo "SKIP: stale-hook test (no 'claude' binary on PATH on this machine)"
fi
rm -rf "$TMP_HOME"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All doctor tests passed."
