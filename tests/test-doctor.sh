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
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

# ---------------------------------------------------------------------------
# 1. Basic resolved-path and writability reporting (baseline, healthy case)
# ---------------------------------------------------------------------------
TMP_HOME="$(mktemp -d)"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?

# Fix round E: the memory path doctor.sh prints (SL_MEMORY_DIR, sourced from
# config.sh, which shells out to paths.py) is resolved by a python3.exe
# subprocess -- on Git Bash/MSYS2 that can be a differently-spelled but
# identical directory to the bash-literal "${TMP_HOME}/store/memory" this
# assertion used to compare against verbatim. sl_resolve_path calls the
# EXACT SAME resolver under the identical env, so EXPECTED_MEMORY is
# byte-identical to what doctor.sh will print, on any platform.
EXPECTED_MEMORY="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" memory \
    HOME="$TMP_HOME" AGENT_LEARNING_HOME="${TMP_HOME}/store" PATH="$PATH")"
contains "doctor prints resolved memory path" "$OUT" "$EXPECTED_MEMORY"
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
# Fix round E: doctor.sh's LEGACY_HOME comes from paths.legacy_home() via a
# python3 subprocess, same MSYS-spelling concern as the memory-path fix
# above -- sl_legacy_home runs the identical snippet doctor.sh runs, under
# the identical env, so this is byte-identical to doctor.sh's own output.
EXPECTED_LEGACY="$(sl_legacy_home "${SCRIPT_DIR}/scripts/lib" HOME="$TMP_HOME" PATH="$PATH")"
contains "legacy store path reported" "$OUT" "$EXPECTED_LEGACY"

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
# Scoped to the persist-failures.log section specifically (not the whole
# output): I9 added a SEPARATE persist.log summary further down that
# legitimately prints "ABSENT" for persist.log (which this test never
# seeds) even while persist-failures.log itself correctly reads EMPTY, not
# ABSENT. A whole-output grep would collide with that unrelated, correct
# signal.
FAILURES_LOG_SECTION="$(printf '%s\n' "$OUT" | sed -n '/^persistence failures/,/^$/p')"
not_contains "empty persist-failures.log section is not reported as ABSENT" "$FAILURES_LOG_SECTION" "ABSENT"
check "empty persist-failures.log does not fail the run" "0" "$RC"
rm -rf "$TMP_HOME"

# 4c. Populated log: count, bounded tail, recency, unmissable marker, and
#     (this is the content-vs-exit-code check) exit code 1.
#
# Fixture note: 8 lines with 8 GENUINELY DISTINCT dates (2020-01-01 through
# 2020-01-07, then "now"). An earlier version of this fixture used
# `$((i % 9 + 1))` over `i in 1..7`, which never actually produced
# "2020-01-01" -- so the "old entry excluded from the tail" assertion below
# passed regardless of what doctor.sh did with the log (proven by mutating
# doctor's `tail -n 5` to `head -n 5` -- printing the OLDEST five entries,
# i.e. surfacing six-month-old failures while hiding this morning's -- and
# watching all assertions still pass). Distinct dates make both directions
# of the assertion meaningful: an entry that a correct tail would exclude
# must be genuinely absent, and one it would include must be genuinely
# present.
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
LOG="${TMP_HOME}/store/logs/persist-failures.log"
for i in 1 2 3 4 5 6 7; do
    printf '2020-01-0%dT00:00:00Z session-review: pipeline failed (status 1)\n' "$i" >> "$LOG"
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

# A correct `tail -n 5` over these 8 lines prints 2020-01-04 through
# 2020-01-07 plus "now" -- excluding 2020-01-01 through 2020-01-03. Assert
# BOTH directions: an entry the tail must include is genuinely present, and
# one it must exclude is genuinely absent. Either alone survived the
# tail->head mutation before (see fixture note above); together they do not.
contains "populated log: bounded tail includes a recent-but-not-newest entry" "$OUT" "2020-01-06"
case "$OUT" in
    *"2020-01-01"*) echo "FAIL: doctor printed an entry that should have been outside the bounded tail (tail vs head regression)"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: bounded tail excludes the oldest entry" ;;
esac
case "$OUT" in
    *"2020-01-02"*) echo "FAIL: doctor printed an entry that should have been outside the bounded tail (tail vs head regression)"; FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: bounded tail excludes the second-oldest entry" ;;
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
# 6. Stale/fresh Claude Code hook config is flagged -- and doctor.sh and
#    self-learning-health.sh must reach the SAME verdict on the same file,
#    since they share sl_check_hook_fresh() from scripts/lib/config.sh.
#
#    Stub `claude` (and `copilot`, for good measure) onto PATH so this runs
#    unconditionally instead of silently skipping on any CI runner that
#    happens not to have the real binary installed -- a check that only
#    sometimes runs is this project's signature failure mode one level
#    removed. Content of the stubs is irrelevant: both scripts only ever
#    call `command -v claude` / `command -v copilot` to test presence, never
#    execute them.
# ---------------------------------------------------------------------------
STUB_BIN="$(mktemp -d)"
for _bin in claude copilot; do
    cat > "${STUB_BIN}/${_bin}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${STUB_BIN}/${_bin}"
done
STUB_PATH="${STUB_BIN}:${PATH}"

run_doctor() {
    env -i HOME="$1" PATH="$STUB_PATH" AGENT_LEARNING_HOME="$2" \
        SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1
}
# Deliberately NOT run with --quiet: that suppresses pass() lines, which
# would make the "fresh hook reported as registered" assertion below
# vacuous (nothing to match against).
run_health() {
    env -i HOME="$1" PATH="$STUB_PATH" AGENT_LEARNING_HOME="$2" \
        SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/self-learning-health.sh" 2>&1
}

# 6a. Stale: hook command points at a path that is not the resolved scripts dir.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<'JSON'
{"hooks":{"PostToolUse":[{"command":"bash /some/very/stale/path/turn-counter.sh"}]},"Stop":[{"command":"bash /some/very/stale/path/session-review.sh"},{"command":"bash /some/very/stale/path/index-session.sh"}]}
JSON

DOCTOR_OUT="$(run_doctor "$TMP_HOME" "$STORE")"
HEALTH_OUT="$(run_health "$TMP_HOME" "$STORE")"

contains "doctor: stale hook path is flagged" "$DOCTOR_OUT" "STALE"
contains "self-learning-health: stale hook path is flagged" "$HEALTH_OUT" "STALE"

# The actual contradiction the review round found: health.sh reporting
# [PASS] for a hook it never verified the path of. Assert it no longer does
# so for the specific hook under test.
if printf '%s' "$HEALTH_OUT" | grep -q "turn-counter hook registered and points"; then
    echo "FAIL: self-learning-health.sh reported turn-counter hook as fresh/registered despite a stale path"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: self-learning-health.sh does not falsely report the stale turn-counter hook as fresh"
fi

rm -rf "$TMP_HOME"

# 6b. Fresh: hook command points exactly at the resolved scripts dir. Both
# tools must agree it is healthy, with neither reporting STALE.
#
# Fix round E: RESOLVED_SCRIPTS used to be a bash-literal "${STORE}/scripts"
# concatenation. sl_check_hook_fresh() (lib/config.sh) does a TEXTUAL grep
# match between the hook command in this fixture and the scripts dir doctor.sh/
# self-learning-health.sh independently resolve via python3 -- so on Git
# Bash/MSYS2, a bash-literal fixture path would never textually match the
# MSYS-spelled resolved path even though they name the same real directory,
# making a genuinely fresh hook read STALE. Resolve it via the exact same
# tool (paths.py get scripts) under the same env instead.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
RESOLVED_SCRIPTS="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" scripts \
    HOME="$TMP_HOME" AGENT_LEARNING_HOME="$STORE" PATH="$STUB_PATH")"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<JSON
{"hooks":{"PostToolUse":[{"command":"bash ${RESOLVED_SCRIPTS}/turn-counter.sh"}],"Stop":[{"command":"bash ${RESOLVED_SCRIPTS}/session-review.sh"},{"command":"bash ${RESOLVED_SCRIPTS}/index-session.sh"}]}}
JSON

DOCTOR_OUT="$(run_doctor "$TMP_HOME" "$STORE")"
HEALTH_OUT="$(run_health "$TMP_HOME" "$STORE")"

not_contains "doctor: fresh hook path is not flagged STALE" "$DOCTOR_OUT" "STALE"
not_contains "self-learning-health: fresh hook path is not flagged STALE" "$HEALTH_OUT" "STALE"
contains "doctor: fresh hook path reported as registered/resolved" "$DOCTOR_OUT" "points at resolved scripts dir"
contains "self-learning-health: fresh hook path reported as registered/resolved" "$HEALTH_OUT" "registered and points at the resolved scripts dir"

rm -rf "$TMP_HOME" "$STUB_BIN"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All doctor tests passed."
