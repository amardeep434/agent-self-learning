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

## 5. fix-empty-session. A store whose ONLY history is sessions that ended
##    without a turn is HEALTHY. This is the defect that prompted the change:
##    ~53% of Copilot sessions never converse, and reporting them as
##    persistence failures made doctor read UNHEALTHY on a perfectly fine
##    machine -- which trains the user to ignore the one channel a genuinely
##    broken detached review can reach.
NO_CONVERSATION_LINE='{"bytes": 0, "component": "copilot-session-review", "reason": "not applicable -- session ended without a turn", "skipped": ["no-conversation"], "timestamp": "2026-07-26T17:26:48Z", "written": []}'
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
for _ in 1 2 3 4 5; do printf '%s\n' "$NO_CONVERSATION_LINE"; done \
    >> "${TMP_HOME}/store/logs/persist.log"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
STATUS=$?
not_contains "empty sessions alone are not SUSPICIOUS" "$OUT" "SUSPICIOUS"
not_contains "empty sessions alone are not a PERSISTENCE FAILURE" "$OUT" "PERSISTENCE FAILURE"
contains "empty sessions are still reported, not invisible" "$OUT" "ended without a turn"
check "a store whose only history is empty sessions is healthy" "0" "$STATUS"
rm -rf "$TMP_HOME"

## 6. no-conversation lines must be EXCLUDED from the streak window, not
##    counted in it and not allowed to break it. Interleaving them with a
##    real trailing run of no-proposal results must still be flagged --
##    otherwise this change would silently disable the check from case 3.
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
{
    printf '%s\n' "$WRITTEN_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_CONVERSATION_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_CONVERSATION_LINE"
    printf '%s\n' "$NO_CONVERSATION_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_CONVERSATION_LINE"
} >> "${TMP_HOME}/store/logs/persist.log"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
STATUS=$?
contains "no-conversation lines do not break a real no-proposal streak" "$OUT" "SUSPICIOUS"
check "an interleaved real streak still flips the exit code" "1" "$STATUS"
rm -rf "$TMP_HOME"

## 7. ...and they must not be counted AS no-proposal results either: a tail
##    of nothing but empty sessions plus two real no-proposal runs is below
##    the threshold and must stay quiet.
TMP_HOME="$(mktemp -d)"
mkdir -p "${TMP_HOME}/store/logs"
{
    printf '%s\n' "$NO_CONVERSATION_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_CONVERSATION_LINE"
    printf '%s\n' "$NO_PROPOSAL_LINE"
    printf '%s\n' "$NO_CONVERSATION_LINE"
} >> "${TMP_HOME}/store/logs/persist.log"
OUT="$(run_doctor "$TMP_HOME" "${TMP_HOME}/store")"
STATUS=$?
not_contains "empty sessions are not counted as no-proposal results" "$OUT" "SUSPICIOUS"
check "two real no-proposal runs padded with empty sessions stay healthy" "0" "$STATUS"
rm -rf "$TMP_HOME"

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "All doctor persist-log tests passed."
