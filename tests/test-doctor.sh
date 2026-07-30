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

    # Fix round F: verify chmod's premise actually holds on THIS filesystem
    # rather than assuming it, by doing the exact same kind of real
    # create+delete probe doctor.sh's own _sl_test_writable does (see its
    # comment: "actually tested, not inferred"). On Windows, write
    # permission is governed by ACLs, not the POSIX mode bits `chmod`
    # manipulates -- `chmod -w` is largely a no-op there, so the directory
    # stays genuinely writable and doctor.sh reporting it "writable" would
    # be CORRECT, not a bug the test should fail on. Confirmed, not assumed:
    # if this probe file is created successfully despite chmod 500, the
    # premise this test depends on does not hold on this platform, and the
    # two assertions that depend on it are skipped LOUDLY (named reason
    # printed), never silently, per this project's no-silent-skip rule.
    _sl_probe="${LOCKED_PARENT}/.sl-writability-probe-$$"
    if ( : > "$_sl_probe" ) 2>/dev/null; then
        rm -f "$_sl_probe" 2>/dev/null
        echo "SKIP: non-writable-directory assertions (chmod 500 did not make '${LOCKED_PARENT}' non-writable on this platform/filesystem -- verified by actually creating a file in it, not assumed; almost certainly Windows, where write access is governed by ACLs rather than POSIX mode bits, so doctor.sh reporting it writable is CORRECT behavior, not a bug)"
    else
        OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${LOCKED_PARENT}/store" \
              SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
        RC=$?

        contains "non-writable dir reported as NOT WRITABLE" "$OUT" "NOT WRITABLE"
        check "non-writable dir flips exit code to 1" "1" "$RC"
    fi

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

rm -rf "$TMP_HOME"

# ---------------------------------------------------------------------------
# 7. The READ-BACK half: session-start-context.sh.
#
# doctor.sh reported only the capture hooks (turn-counter, session-review,
# index-session). All three config/ templates also register
# session-start-context.sh, which injects learned memory and launches Route A
# skill mirroring -- so an install could have every capture hook green while
# nothing learned was ever delivered back, and doctor.sh said nothing.
#
# The two harnesses are asserted SEPARATELY and with DIFFERENT expected
# wording, because their registration mechanisms genuinely differ:
#   Claude Code -- install.sh only PRINTS the block ("NEXT STEP (Claude Code
#     only): Register hooks in ~/.claude/settings.json", install.sh:642), so an
#     unregistered hook is a normal, recoverable state and must not be called
#     MISSING alongside hooks install.sh writes itself.
#   Copilot CLI -- install.sh writes ~/.copilot/hooks/self-learning.json from
#     config/copilot-hooks.json, which carries session-start-context.sh at
#     lines 7-8, so its absence there IS a broken install.
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

# 7a. Claude Code: capture hooks registered, SessionStart absent.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
RESOLVED_SCRIPTS="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" scripts \
    HOME="$TMP_HOME" AGENT_LEARNING_HOME="$STORE" PATH="$STUB_PATH")"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<JSON
{"hooks":{"PostToolUse":[{"command":"bash ${RESOLVED_SCRIPTS}/turn-counter.sh"}],"Stop":[{"command":"bash ${RESOLVED_SCRIPTS}/session-review.sh"},{"command":"bash ${RESOLVED_SCRIPTS}/index-session.sh"}]}}
JSON
OUT=$(run_doctor "$TMP_HOME" "$STORE")
RC=$?
contains "doctor reports the unregistered SessionStart hook at all" "$OUT" "session-start-context.sh:"
contains "unregistered Claude SessionStart says NOT REGISTERED" "$OUT" "session-start-context.sh: NOT REGISTERED"
contains "unregistered Claude SessionStart names the consequence" "$OUT" "learned memory is not injected"
contains "unregistered Claude SessionStart says registration is manual" "$OUT" "MANUAL"
# The distinction is the whole point of 7a: it must NOT borrow the word used
# for hooks install.sh writes itself.
case "$OUT" in
    *"session-start-context.sh: MISSING"*)
        echo "FAIL: Claude Code SessionStart reported as MISSING; registration there is manual, so that word is wrong"
        FAILURES=$((FAILURES+1)) ;;
    *) echo "PASS: Claude Code SessionStart is not mislabelled MISSING" ;;
esac
check "a merely-unregistered SessionStart does not flip the exit code" "0" "$RC"
rm -rf "$TMP_HOME"

# 7b. Claude Code: SessionStart registered and pointing at the resolved dir.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
RESOLVED_SCRIPTS="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" scripts \
    HOME="$TMP_HOME" AGENT_LEARNING_HOME="$STORE" PATH="$STUB_PATH")"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<JSON
{"hooks":{"SessionStart":[{"command":"bash ${RESOLVED_SCRIPTS}/session-start-context.sh"}],"PostToolUse":[{"command":"bash ${RESOLVED_SCRIPTS}/turn-counter.sh"}],"Stop":[{"command":"bash ${RESOLVED_SCRIPTS}/session-review.sh"},{"command":"bash ${RESOLVED_SCRIPTS}/index-session.sh"}]}}
JSON
OUT=$(run_doctor "$TMP_HOME" "$STORE")
contains "registered SessionStart reported as fresh" "$OUT" \
    "session-start-context.sh: registered, points at resolved scripts dir"
not_contains "registered SessionStart is not reported NOT REGISTERED" "$OUT" "NOT REGISTERED"
rm -rf "$TMP_HOME"

# 7c. Claude Code: SessionStart registered but pointing somewhere else. Stale
# is stale regardless of how registration happened -- assert the shared verdict
# was not lost when the wording was made caller-specific.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"command":"bash /some/very/stale/path/session-start-context.sh"}]}}
JSON
OUT=$(run_doctor "$TMP_HOME" "$STORE")
contains "stale SessionStart path is flagged STALE" "$OUT" "session-start-context.sh: STALE"
# --strict exists to fail on staleness; a hook it does not know about cannot
# reach it. Assert the new hook is wired into that path too.
OUT_STRICT=$(env -i HOME="$TMP_HOME" PATH="$STUB_PATH" AGENT_LEARNING_HOME="$STORE" \
    SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" --strict 2>&1)
RC_STRICT=$?
check "--strict fails on a stale SessionStart hook" "1" "$RC_STRICT"
rm -rf "$TMP_HOME"

# 7d. Copilot: install.sh writes that file, so absence there IS "MISSING".
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
RESOLVED_SCRIPTS="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" scripts \
    HOME="$TMP_HOME" AGENT_LEARNING_HOME="$STORE" PATH="$STUB_PATH")"
mkdir -p "${TMP_HOME}/.copilot/hooks"
cat > "${TMP_HOME}/.copilot/hooks/self-learning.json" <<JSON
{"hooks":{"sessionEnd":[{"bash":"bash '${RESOLVED_SCRIPTS}/copilot-session-review.sh'"}]}}
JSON
OUT=$(run_doctor "$TMP_HOME" "$STORE")
COPILOT_SECTION="$(printf '%s\n' "$OUT" | sed -n '/hooks (~\/.copilot/,/^  vscode\|^  claude/p')"
contains "Copilot SessionStart absence reported as MISSING" "$COPILOT_SECTION" \
    "session-start-context.sh: MISSING"
rm -rf "$TMP_HOME" "$STUB_BIN"

# ---------------------------------------------------------------------------
# 8. Route A delivery: the skill mirror.
#
# mirror-skills.py runs detached, --quiet, both streams to /dev/null. A mirror
# that has never run logs nothing at all and was indistinguishable from a
# healthy one. These cases assert doctor.sh counts what is actually on disk.
#
# No `claude`/`copilot` stubs here on purpose: the mirror section is about
# DIRECTORIES (hard rule 3 -- a root is active only if its parent exists,
# probed), not about which binaries are on PATH.
# ---------------------------------------------------------------------------

# 8a. Skills in the store, a Claude skills root that exists, nothing mirrored.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
mkdir -p "${STORE}/learned-skills/alpha" "${STORE}/learned-skills/beta" "${TMP_HOME}/.claude/skills"
printf 'alpha body\n' > "${STORE}/learned-skills/alpha/SKILL.md"
printf 'beta body\n'  > "${STORE}/learned-skills/beta/SKILL.md"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?
contains "mirror section reports the store count" "$OUT" "store: 2 learned skill(s)"
contains "unmirrored root reported as 0 of 2" "$OUT" "0 of 2 learned skill(s) published"
contains "shortfall is named" "$OUT" "SHORTFALL"
# Deliberately not fatal: see the section comment in doctor.sh. A newly
# installed machine would otherwise be permanently UNHEALTHY.
check "a mirror shortfall alone does not flip the exit code" "0" "$RC"
# hard rule 3: ~/.copilot does not exist here, so Copilot must read as
# "not installed", never as a broken mirror.
contains "absent harness reported as not installed, not broken" "$OUT" \
    "harness not installed"
not_contains "absent harness is not reported as a shortfall" \
    "$(printf '%s\n' "$OUT" | grep 'copilot:')" "SHORTFALL"

# 8b. Now actually run the mirror and re-check. This is the direction that
# proves the count is real: the same store, the same doctor, a different
# number, driven only by files mirror-skills.py wrote.
env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
    SL_SKILLS_DIR="${STORE}/learned-skills" SL_LOG_DIR="${STORE}/logs" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    python3 "${SCRIPT_DIR}/scripts/mirror-skills.py" --quiet
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
contains "mirrored root reported as 2 of 2" "$OUT" "2 of 2 learned skill(s) published"
not_contains "a fully mirrored root reports no shortfall" \
    "$(printf '%s\n' "$OUT" | sed -n '/skill mirror/,/^$/p')" "SHORTFALL"

# 8c. The count must use mirror-skills.py's own is_ours(), which is
# content-verified AND name-bound -- not `test -f .self-learning-managed`.
# A copy of a mirrored skill under a DIFFERENT name carries a valid-looking
# marker that names the original; is_ours() rejects it (that is what protects a
# user's customised copy from being pruned), so doctor.sh must not count it
# either, or the two tools disagree about the same directory.
cp -r "${TMP_HOME}/.claude/skills/alpha" "${TMP_HOME}/.claude/skills/user-copy"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
contains "a renamed copy carrying the original's marker is NOT counted as ours" \
    "$OUT" "2 of 2 learned skill(s) published"

# 8d. A directory we really did create, for a skill the store no longer has,
# is still auto-loaded by the harness until the next prune -- report it.
mkdir -p "${TMP_HOME}/.claude/skills/orphan"
printf 'agent-self-learning:mirrored-skill\nskill: orphan\n' \
    > "${TMP_HOME}/.claude/skills/orphan/.self-learning-managed"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
contains "an orphaned mirrored skill is counted and named" "$OUT" "ORPHANS: 3 > 2"
rm -rf "$TMP_HOME"

# 8e. No harness skill root at all: correct, and must say so rather than
# printing a bare "0 of N" that reads like breakage.
TMP_HOME="$(mktemp -d)"
STORE="${TMP_HOME}/store"
mkdir -p "${STORE}/learned-skills/alpha"
printf 'alpha body\n' > "${STORE}/learned-skills/alpha/SKILL.md"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1)
RC=$?
contains "no harness root at all is explained, not counted as failure" "$OUT" \
    "no harness skill directory exists on this machine"
check "no harness root does not flip the exit code" "0" "$RC"
rm -rf "$TMP_HOME"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All doctor tests passed."
