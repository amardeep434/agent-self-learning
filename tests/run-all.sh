#!/usr/bin/env bash
# tests/run-all.sh
#
# Discovers and runs every tests/test-*.sh and tests/test-*.py suite, then
# reports a summary. This project's signature failure mode is a component
# that appears to run fine while doing nothing — so this runner is built to
# never be able to lie about that:
#
#   - Suites are discovered by glob, never hardcoded, so a newly added test
#     file cannot be silently omitted.
#   - A glob that matches nothing is a hard FAILURE, not a pass. The total
#     suite count is also checked against a sanity floor, so a glob that
#     matches "almost nothing" is caught too, not just "nothing".
#   - Every suite runs to completion regardless of earlier failures; nothing
#     stops at the first red suite, and nothing is masked.
#   - A suite that is missing, unreadable, or exits non-zero (including
#     dying before printing anything, or failing at import time before any
#     assertion runs) is recorded as a FAILURE, named individually — never a
#     silent skip.
#   - The exit code is authoritative: 0 only if suites were actually
#     discovered in a plausible number AND every one of them passed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Minimum number of suites we expect to discover. Guards against a glob that
# matches nothing, or matches only a handful of stragglers, being mistaken
# for "all tests passed". Override via RUN_ALL_MIN_SUITES if suites are
# deliberately removed; a silent drop below this without updating it is
# exactly the failure mode this floor exists to catch.
MIN_SUITES="${RUN_ALL_MIN_SUITES:-15}"

shopt -s nullglob
SH_SUITES=(tests/test-*.sh)
PY_SUITES=(tests/test-*.py)
shopt -u nullglob

TOTAL_DISCOVERED=$(( ${#SH_SUITES[@]} + ${#PY_SUITES[@]} ))

FAILED=()
RAN=0

run_sh() {
    local t="$1"
    RAN=$((RAN + 1))
    echo "=== $t ==="
    if [[ ! -f "$t" ]]; then
        echo "FAIL: $t (vanished between discovery and run)"
        FAILED+=("$t [missing]")
        return
    fi
    if [[ ! -r "$t" ]]; then
        echo "FAIL: $t (not readable)"
        FAILED+=("$t [unreadable]")
        return
    fi
    bash "$t"
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "FAIL: $t (exit $rc)"
        FAILED+=("$t [exit $rc]")
    fi
}

run_py() {
    local t="$1"
    RAN=$((RAN + 1))
    echo "=== $t ==="
    if [[ ! -f "$t" ]]; then
        echo "FAIL: $t (vanished between discovery and run)"
        FAILED+=("$t [missing]")
        return
    fi
    if [[ ! -r "$t" ]]; then
        echo "FAIL: $t (not readable)"
        FAILED+=("$t [unreadable]")
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "FAIL: $t (python3 not found on PATH — cannot run)"
        FAILED+=("$t [no python3]")
        return
    fi
    python3 "$t"
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "FAIL: $t (exit $rc)"
        FAILED+=("$t [exit $rc]")
    fi
}

for t in "${SH_SUITES[@]}"; do
    run_sh "$t"
done

for t in "${PY_SUITES[@]}"; do
    run_py "$t"
done

echo
echo "--- Summary ---"
echo "Discovered ${TOTAL_DISCOVERED} suite(s): ${#SH_SUITES[@]} shell, ${#PY_SUITES[@]} python. Ran ${RAN}."

EXIT=0

if [[ "$TOTAL_DISCOVERED" -eq 0 ]]; then
    echo "FAIL: discovered zero test suites under tests/test-*.sh or tests/test-*.py." \
         " A glob matching nothing is a failure, not a pass."
    EXIT=1
elif [[ "$TOTAL_DISCOVERED" -lt "$MIN_SUITES" ]]; then
    echo "FAIL: discovered only ${TOTAL_DISCOVERED} suite(s), below the sanity floor of" \
         " ${MIN_SUITES} (override with RUN_ALL_MIN_SUITES). A broken glob or an" \
         " accidentally-deleted suite directory would look exactly like this."
    EXIT=1
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo
    echo "FAILED (${#FAILED[@]}/${RAN}):"
    printf '  - %s\n' "${FAILED[@]}"
    EXIT=1
fi

if [[ "$EXIT" -eq 0 ]]; then
    echo "All ${RAN} suites passed."
fi

exit "$EXIT"
