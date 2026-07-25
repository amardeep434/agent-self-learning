#!/usr/bin/env bash
# tests/test-doctor-persist-log.sh
#
# I9: the original defect's exact signature (reviewer output wrapped so
# extraction breaks) produces exit 0, a persist.log line of
# {"written": [], "skipped": ["no-proposal"], "bytes": 0}, and NOTHING in
# persist-failures.log -- byte-identical to "genuinely nothing to learn
# this cycle". doctor.sh only ever read persist-failures.log, so a run of
# silent breakage was invisible. This suite pins: doctor now summarizes the
# tail of persist.log, counts a trailing streak of consecutive no-proposal
# results, and flags a streak >= 3 as suspicious (a real, non-cosmetic
# signal, not just a printed word -- it must also flip the exit code).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
contains() { case "$2" in *"$3"*) echo "PASS: $1";; *) echo "FAIL: $1 (output did not contain '$3')"; FAILURES=$((FAILURES+1));; esac; }
not_contains() { case "$2" in *"$3"*) echo "FAIL: $1 (output unexpectedly contained '$3')"; FAILURES=$((FAILURES+1));; *) echo "PASS: $1";; esac; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

run_doctor() {
    env -i HOME="$1" PATH="$PATH" AGENT_LEARNING_HOME="$2" \
        SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1
}

NO_PROPOSAL_LINE='{"written": [], "skipped": ["no-proposal"], "bytes": 0}'
WRITTEN_LINE='{"written": ["memory/MEMORY.md"], "skipped": [], "bytes": 42}'

## 1. Absent persist.log.
TMP_HOME="$(mktemp -d)"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
contains "absent persist.log reported as ABSENT" "$OUT" "ABSENT"
rm -rf "$TMP_HOME"

## 2. Fewer than the threshold of no-proposal results: not suspicious.
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
printf '%s\n%s\n' "$WRITTEN_LINE" "$NO_PROPOSAL_LINE" >> "${TMP_HOME}/store/logs/persist.log"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
STATUS=$?
not_contains "one trailing no-proposal result is not flagged SUSPICIOUS" "$OUT" "SUSPICIOUS"
check "one trailing no-proposal result does not fail the run" "0" "$STATUS"
rm -rf "$TMP_HOME"

## 3. A run of 3+ consecutive no-proposal results at the tail: SUSPICIOUS,
##    and it must flip the exit code (not just print text).
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
{
    printf '%s\n' "$WRITTEN_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
} >> "${TMP_HOME}/store/logs/persist.log"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
STATUS=$?
contains "3 consecutive trailing no-proposal results flagged SUSPICIOUS" "$OUT" "SUSPICIOUS"
check "3 consecutive trailing no-proposal results flips exit code to 1" "1" "$STATUS"
rm -rf "$TMP_HOME"

## 4. A run of 3+ no-proposal results NOT at the tail (interrupted by a real
##    write more recently) must NOT be flagged -- the streak is measured
##    from the most recent entry backward, not merely "3 occurrences
##    anywhere in the tail window".
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
{
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$WRITTEN_LINE"
} >> "${TMP_HOME}/store/logs/persist.log"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
STATUS=$?
not_contains "a non-trailing streak of no-proposal results is not flagged" "$OUT" "SUSPICIOUS"
check "a non-trailing streak does not fail the run" "0" "$STATUS"
rm -rf "$TMP_HOME"

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "All doctor persist-log tests passed."
