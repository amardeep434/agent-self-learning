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
#   - A suite that is missing, unreadable, hangs past its per-suite timeout,
#     or exits non-zero (including dying before printing anything, or
#     failing at import time before any assertion runs) is recorded as a
#     FAILURE, named individually — never a silent skip.
#   - The exit code is authoritative: 0 only if suites were actually
#     discovered in a plausible number AND every one of them passed.
#
# Exit code note for callers: CI invokes this script directly and checks its
# exit code. If you instead pipe its output (e.g. `bash tests/run-all.sh |
# tee log`), the pipeline's exit status becomes tee's, not this script's,
# unless the calling shell has `set -o pipefail`. Piping without pipefail
# can silently hide a failed run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Enable job control even though this script is non-interactive. This gives
# each backgrounded suite its own process group (pgid == its pid), which is
# what lets the timeout-cleanup below reach children the suite itself
# spawned and left running (e.g. a stray `sleep 300 &`) — killing just the
# suite's own pid would leave those orphaned, which is exactly what a review
# round found: a hung suite outlived an external kill.
set -m

# Minimum number of suites we expect to discover. Guards against a glob that
# matches nothing, or matches only a handful of stragglers, being mistaken
# for "all tests passed". Override via RUN_ALL_MIN_SUITES if suites are
# deliberately removed; a silent drop below this without updating it is
# exactly the failure mode this floor exists to catch.
MIN_SUITES="${RUN_ALL_MIN_SUITES:-15}"

# Per-suite wall-clock limit. The slowest suite measured locally is ~3.1s
# (test-copilot-session-review.sh); test-install-paths.sh (which runs a
# real install.sh) is the likeliest to be slower on other machines/CI
# runners. 120s leaves generous headroom over both while still catching a
# genuinely hung suite (e.g. an accidental `sleep 300`) long before it can
# burn the whole CI job's time budget. Override via RUN_ALL_SUITE_TIMEOUT.
SUITE_TIMEOUT="${RUN_ALL_SUITE_TIMEOUT:-120}"

# Feature-detect a timeout wrapper rather than assuming one. Stock macOS has
# no `timeout` at all (GNU-only), so a bare `timeout` call would break the
# macos-latest CI job this project depends on. Prefer GNU `timeout`, then
# Homebrew coreutils' `gtimeout`, and if neither exists, run every suite
# UNWRAPPED — but say so loudly, every run, so a macOS box (or any box)
# missing both cannot silently lose hang protection without it showing up
# in the log.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "WARNING: neither 'timeout' nor 'gtimeout' is available on this system." >&2
    echo "WARNING: per-suite timeout protection is DISABLED for this run — a hung" >&2
    echo "WARNING: suite will hang this entire run with no automatic recovery." >&2
    echo "WARNING: Install GNU coreutils (e.g. 'brew install coreutils' on macOS)" >&2
    echo "WARNING: to restore it." >&2
fi

shopt -s nullglob
SH_SUITES=(tests/test-*.sh)
PY_SUITES=(tests/test-*.py)
shopt -u nullglob

TOTAL_DISCOVERED=$(( ${#SH_SUITES[@]} + ${#PY_SUITES[@]} ))

FAILED=()
RAN=0

# run_with_timeout <cmd...>
# Runs cmd as a backgrounded job (so it gets its own process group under
# `set -m`), wrapped in the detected timeout binary when one exists, waits
# for it, then always makes a best-effort sweep of that process group so no
# child the suite spawned outlives the suite itself — whether or not a
# timeout actually fired. Sets the global TIMED_OUT to "true"/"false" so
# callers can distinguish "timed out" from "exited non-zero on its own"
# without relying on bash 4.3+ negative array indexing (stock macOS ships
# bash 3.2, which lacks it).
TIMED_OUT="false"
run_with_timeout() {
    local pid rc
    TIMED_OUT="false"
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" --kill-after=5 "$SUITE_TIMEOUT" "$@" &
    else
        "$@" &
    fi
    pid=$!
    wait "$pid"
    rc=$?
    # Best-effort cleanup of the whole process group: TERM, brief grace
    # period, then KILL. Silent no-op if the group is already gone (the
    # overwhelmingly common, non-hung case).
    kill -TERM -- "-${pid}" >/dev/null 2>&1
    sleep 0.2
    kill -KILL -- "-${pid}" >/dev/null 2>&1
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
        TIMED_OUT="true"
    fi
    return "$rc"
}

run_sh() {
    local t="$1" rc
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
    run_with_timeout bash "$t"
    rc=$?
    if [[ "$TIMED_OUT" == "true" ]]; then
        echo "FAIL: $t (exit $rc — timed out after ${SUITE_TIMEOUT}s and was killed)"
        FAILED+=("$t [timeout ${SUITE_TIMEOUT}s]")
    elif [[ "$rc" -ne 0 ]]; then
        echo "FAIL: $t (exit $rc)"
        FAILED+=("$t [exit $rc]")
    fi
}

run_py() {
    local t="$1" rc
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
    # `-u` (and PYTHONUNBUFFERED for anything the suite itself spawns): a
    # suite killed at SUITE_TIMEOUT loses whatever is still sitting in a
    # block-buffered pipe, so without this a timeout can report NOTHING --
    # no dots, no test names -- and "hung immediately" looks identical to
    # "ran fine for 119s then got killed". That happened on windows-latest
    # 3.13 for tests/test-coach-rules-eval.py and cost a full CI round to
    # not-diagnose. Unbuffered output is the difference between a timeout
    # that names the test in flight and one that says nothing at all.
    run_with_timeout env PYTHONUNBUFFERED=1 python3 -u "$t"
    rc=$?
    if [[ "$TIMED_OUT" == "true" ]]; then
        echo "FAIL: $t (exit $rc — timed out after ${SUITE_TIMEOUT}s and was killed)"
        FAILED+=("$t [timeout ${SUITE_TIMEOUT}s]")
    elif [[ "$rc" -ne 0 ]]; then
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
