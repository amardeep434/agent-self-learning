#!/usr/bin/env bash
# tests/test-path-compare-lib.sh
#
# Fix round E: pins tests/lib/path-compare.sh, the shared helper extracted
# so every suite comparing a bash-spelled path against a python-resolved one
# (the shape behind 13 of 27 suites failing on windows-latest CI) uses one
# implementation instead of a pasted-per-suite copy.
#
# This cannot exercise the actual MSYS auto-conversion this helper exists
# for (that only happens on real Git Bash/MSYS2) -- what it CAN verify on
# any platform: the helper's own logic is correct (symlink/nonexistent-path
# canonicalization, forwarder scripts actually forward and preserve exit
# codes, sl_resolve_path/sl_legacy_home produce exactly what paths.py itself
# produces under the same env). See tests/lib/path-compare.sh's own comment
# for what remains reasoning-only without a live Windows run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- sl_canon_path -----------------------------------------------------

REAL_DIR="${TMP}/real"
mkdir -p "$REAL_DIR"
check "sl_canon_path resolves an existing directory to itself" \
    "$(cd "$REAL_DIR" && pwd -P)" "$(sl_canon_path "$REAL_DIR")"

LINK_DIR="${TMP}/link"
ln -s "$REAL_DIR" "$LINK_DIR"
check "sl_canon_path resolves a symlink to its real target" \
    "$(sl_canon_path "$REAL_DIR")" "$(sl_canon_path "$LINK_DIR")"

check "sl_canon_path normalizes .. components without requiring existence" \
    "$(sl_canon_path "${TMP}/a")" "$(sl_canon_path "${TMP}/a/b/..")"

NONEXISTENT="${TMP}/does/not/exist/yet"
check "sl_canon_path does not crash on a nonexistent path" \
    "yes" "$([[ -n "$(sl_canon_path "$NONEXISTENT")" ]] && echo yes || echo no)"

# --- sl_same_path --------------------------------------------------------

check "sl_same_path: identical literal strings" "yes" \
    "$(sl_same_path "$REAL_DIR" "$REAL_DIR" && echo yes || echo no)"
check "sl_same_path: real dir vs. symlink to it" "yes" \
    "$(sl_same_path "$REAL_DIR" "$LINK_DIR" && echo yes || echo no)"
check "sl_same_path: two genuinely different existing dirs" "no" \
    "$(mkdir -p "${TMP}/other" && sl_same_path "$REAL_DIR" "${TMP}/other" && echo yes || echo no)"
check "sl_same_path: two genuinely different NONEXISTENT paths" "no" \
    "$(sl_same_path "${TMP}/nope1" "${TMP}/nope2" && echo yes || echo no)"
check "sl_same_path: same nonexistent path spelled two ways (trailing slash)" "yes" \
    "$(sl_same_path "${TMP}/futuredir" "${TMP}/futuredir/" && echo yes || echo no)"

# --- sl_check_same_path (check-shaped wrapper) ----------------------------

_before=$FAILURES
sl_check_same_path "same-path wrapper: equal case" "$REAL_DIR" "$LINK_DIR"
check "sl_check_same_path did not increment FAILURES on a real match" "$_before" "$FAILURES"

# The mismatch case deliberately drives sl_check_same_path's FAIL branch to
# prove it increments FAILURES -- captured in a subshell so its own
# intentional "FAIL:" line and FAILURES increment never leak into this
# suite's real output/count (which would misleadingly look like a real
# failure in the log).
_before=$FAILURES
_mismatch_out="$(FAILURES=0; sl_check_same_path "same-path wrapper: mismatch case" "$REAL_DIR" "${TMP}/other"; echo "FAILURES=$FAILURES")"
_mismatch_failures="${_mismatch_out##*FAILURES=}"
check "sl_check_same_path incremented FAILURES on a real mismatch" "1" "$_mismatch_failures"
check "FAILURES unaffected by the subshelled mismatch self-test" "$_before" "$FAILURES"

# --- sl_resolve_path -------------------------------------------------------
# Must produce exactly what `python3 paths.py get <key>` produces for the
# same env -- trivially true on Linux (no MSYS layer to reconcile), but
# pins that the wrapper does not itself introduce any transformation.

DIRECT="$(env -i HOME="$TMP" AGENT_LEARNING_HOME="${TMP}/store" PATH="$PATH" \
    python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get memory)"
VIA_HELPER="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" memory \
    HOME="$TMP" AGENT_LEARNING_HOME="${TMP}/store" PATH="$PATH")"
check "sl_resolve_path matches a direct paths.py get call" "$DIRECT" "$VIA_HELPER"

# --- sl_legacy_home ---------------------------------------------------------

LEGACY_HOME_DIR="${TMP}/legacy-home"
mkdir -p "${LEGACY_HOME_DIR}/.claude/memory"
DIRECT_LEGACY="$(env -i HOME="$LEGACY_HOME_DIR" PATH="$PATH" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import paths
h = paths.legacy_home()
print(h if h else "")
' "${SCRIPT_DIR}/scripts/lib")"
VIA_HELPER_LEGACY="$(sl_legacy_home "${SCRIPT_DIR}/scripts/lib" HOME="$LEGACY_HOME_DIR" PATH="$PATH")"
check "sl_legacy_home matches a direct paths.legacy_home() call (present case)" \
    "$DIRECT_LEGACY" "$VIA_HELPER_LEGACY"
check "sl_legacy_home found the seeded legacy store" "yes" \
    "$([[ -n "$VIA_HELPER_LEGACY" ]] && echo yes || echo no)"

NO_LEGACY_HOME_DIR="${TMP}/no-legacy-home"
mkdir -p "$NO_LEGACY_HOME_DIR"
check "sl_legacy_home returns empty when nothing legacy exists" "" \
    "$(sl_legacy_home "${SCRIPT_DIR}/scripts/lib" HOME="$NO_LEGACY_HOME_DIR" PATH="$PATH")"

# --- sl_forwarder ------------------------------------------------------------

REAL_ECHO="$(command -v echo || echo /bin/echo)"
FWD_DIR="${TMP}/forwarders"
mkdir -p "$FWD_DIR"
sl_forwarder "$REAL_ECHO" "${FWD_DIR}/echo"
check "sl_forwarder wrote an executable file" "yes" \
    "$([[ -x "${FWD_DIR}/echo" ]] && echo yes || echo no)"
check "sl_forwarder's script correctly forwards args" "hello world" \
    "$("${FWD_DIR}/echo" hello world)"

# Exit-code preservation: forward to a tool guaranteed to fail (`false`),
# proving the wrapper does not swallow or normalize a nonzero exit.
REAL_FALSE="$(command -v false || echo /bin/false)"
sl_forwarder "$REAL_FALSE" "${FWD_DIR}/false"
"${FWD_DIR}/false"
check "sl_forwarder's script preserves a nonzero exit code" "1" "$?"

# The whole point: a restricted PATH containing ONLY forwarders for tools
# this test explicitly created must resolve those tools but correctly fail
# to resolve anything else (e.g. python3), exactly like test-config.sh's
# no-python3 fallback tests need.
check "restricted PATH resolves the forwarded tool" "yes" \
    "$(PATH="$FWD_DIR" command -v echo >/dev/null 2>&1 && echo yes || echo no)"
check "restricted PATH correctly fails to resolve a non-forwarded tool" "no" \
    "$(PATH="$FWD_DIR" command -v python3 >/dev/null 2>&1 && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All path-compare-lib tests passed."
