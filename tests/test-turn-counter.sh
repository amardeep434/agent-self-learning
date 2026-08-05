#!/usr/bin/env bash
# tests/test-turn-counter.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# SL_LOG_DIR is NOT optional here even though cases 1-6 never read a log:
# without it config.sh resolves it through paths.py to the developer's REAL
# store, and turn-counter.sh now writes failure lines there. Measured the hard
# way -- a mutation run of this suite appended a line to the live install's
# persist-failures.log, which doctor.sh reports on. Harmless before this
# round only because the script had no failure channel at all.
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" \
       SL_CONFIG_FILE="/nonexistent"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

payload() { echo "{\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"hook_event_name\":\"PostToolUse\"}"; }

# 1) First call creates counter with session id from stdin
payload sess-A | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "session id recorded from stdin" "sess-A" "$(jq -r .session_id "$TMP/state/turn_counter.json")"
check "one tool call counted" "1" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 2) Same session increments
payload sess-A | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "increment within session" "2" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 3) New session resets
payload sess-B | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "session boundary resets counter" "1" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"
check "new session id recorded" "sess-B" "$(jq -r .session_id "$TMP/state/turn_counter.json")"

# 4) Recursion guard: no state change when SL_REVIEW_ACTIVE is set
BEFORE=$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")
payload sess-B | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "recursion guard skips counting" "$BEFORE" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 5) Cooldown gate wiring, end-to-end, with a non-empty last_review_at.
#
# Fix round 1 (reviewer finding): tests/test-config.sh now covers
# sl_iso_to_epoch in isolation, but the reviewer also asked for a test that
# exercises a CALLER gate — this one is turn-counter.sh's "no re-trigger
# within 60s of last_review_at" cooldown (scripts/turn-counter.sh line
# ~146). A helper can be individually correct and still be wired up wrong
# (or not wired up at all); this proves the wiring, not just the helper.
#
# A recent last_review_at (a few seconds ago) must suppress the signal even
# though the skill-review threshold is met. If sl_iso_to_epoch regressed to
# always return 0 (the reviewer's mutation), every last_review_at would look
# ~56 years old and this assertion would flip from PASS to FAIL.
RECENT=$(date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
cat > "$TMP/state/turn_counter.json" <<EOF
{
  "session_id": "sess-cooldown",
  "memory_turns": 0,
  "skill_iterations": 0,
  "last_review_at": "${RECENT}",
  "session_started_at": "${RECENT}",
  "total_turns_this_session": 5
}
EOF
rm -f "$TMP/state/review_signal.json"
payload sess-cooldown | SL_SKILL_REVIEW_INTERVAL=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
if [[ -f "$TMP/state/review_signal.json" ]]; then
    echo "FAIL: cooldown gate did not suppress the signal despite last_review_at being ${RECENT} (a few seconds ago)"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: cooldown gate suppresses the signal within 60s of a real last_review_at"
fi

# 6) Same gate, opposite direction: a genuinely stale last_review_at must
# allow the signal to fire again. Without this half, a broken gate that
# ALWAYS suppresses (e.g. an inverted comparison) would slip through case 5.
STALE="2020-01-01T00:00:00Z"
cat > "$TMP/state/turn_counter.json" <<EOF
{
  "session_id": "sess-cooldown",
  "memory_turns": 0,
  "skill_iterations": 0,
  "last_review_at": "${STALE}",
  "session_started_at": "${STALE}",
  "total_turns_this_session": 5
}
EOF
rm -f "$TMP/state/review_signal.json"
payload sess-cooldown | SL_SKILL_REVIEW_INTERVAL=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
if [[ -f "$TMP/state/review_signal.json" ]]; then
    echo "PASS: cooldown gate allows the signal once last_review_at is genuinely stale"
else
    echo "FAIL: cooldown gate incorrectly suppressed the signal for a stale last_review_at (${STALE})"
    FAILURES=$((FAILURES+1))
fi

# ---------------------------------------------------------------------------
# 7-14) Silent-default collapse.
#
# turn-counter.sh used to read its six state fields with six separate
# `jq -r '<field> // <default>' ... 2>/dev/null || echo <default>` calls --
# the same defect 9dfb956 fixed in session-review.sh, but one layer earlier
# and permanent rather than per-session. Measured on this branch before the
# fix: with jq off PATH, eight consecutive tool uses each rewrote
# total_turns_this_session as 1, so no threshold could ever be reached, no
# review_signal.json was ever written, and NOTHING was recorded anywhere.
#
# The hard part is that this hook runs on EVERY tool use, so the fix must be
# loud without flooding persist-failures.log (which doctor.sh reports on).
# Cases 7-11 pin "loud", 12-13 pin "not flooding", 14 pins the one case that
# must stay silent.
#
# INVERTED (WP8): the counter no longer touches jq at all -- lib/
# turn_counter_core.py does the payload read, the state read and both writes
# in the one Python process this hook already pays for, and jq stopped being
# a runtime dependency of this project entirely. So the cases below that used
# to pin "jq broken/absent => degrade loudly" now pin the opposite, which is
# the whole point of the change: a machine with no jq COUNTS NORMALLY and
# says nothing, because nothing is wrong. What must stay loud is a counter
# file that genuinely cannot be read or written, and cases 8/9 drive the
# throttle from that instead.
# ---------------------------------------------------------------------------

# A fresh, isolated store per case: these assertions count log LINES, so they
# cannot share the state or log directory the cases above have written to.
new_store() {
    local d
    d=$(mktemp -d "${TMP}/store.XXXXXX")
    mkdir -p "$d/state" "$d/logs"
    printf '%s' "$d"
}
run_hook() {  # run_hook <store> <session> [env assignments...]
    local store="$1" sess="$2"; shift 2
    payload "$sess" | env "$@" SL_HOME="$store" SL_STATE_DIR="$store/state" \
        SL_LOG_DIR="$store/logs" SL_CONFIG_FILE=/nonexistent \
        bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
}
log_lines() {  # log_lines <store>
    if [[ -f "$1/logs/persist-failures.log" ]]; then wc -l < "$1/logs/persist-failures.log" | tr -d ' [:space:]'; else echo 0; fi
}

# A jq that exists but exits 127 -- the portable stand-in for "jq is broken or
# absent" used by tests/test-review-failure-legibility.sh (Git Bash's /usr/bin
# ships no jq, so amputating PATH is not portable; a shim is).
BROKEN_DIR="${TMP}/brokenjq"; mkdir -p "$BROKEN_DIR"
printf '#!/usr/bin/env bash\nexit 127\n' > "$BROKEN_DIR/jq"
chmod +x "$BROKEN_DIR/jq"

# A counter PATH that can never be written: a directory where the file should
# be. Unlike a corrupt counter file (case 11) -- which is reported once and
# then REPAIRED, so the next fire is healthy -- this failure persists across
# every fire, which is what the throttle cases need. A permission-based
# version of the same thing was considered and rejected: it behaves
# differently for root and would need a probe to stay honest.
wedge_counter() {  # wedge_counter <store>
    rm -f "$1/state/turn_counter.json"
    mkdir -p "$1/state/turn_counter.json"
}

# A counter file from a session already in progress. Cases 7 and 9 need one:
# with a jq that merely FAILS (rather than being absent from PATH) the breakage
# is only discovered when there is state to read, so a store with no counter
# file yet takes the legitimately-silent first-tool-use path and reports on the
# following call instead. Case 8 exercises that delayed discovery; these two
# want the steady state, which is also the realistic one -- jq breaking under
# an install that already has a store.
seed_counter() {
    printf '{"session_id":"%s","memory_turns":4,"skill_iterations":7,"last_review_at":"","session_started_at":"2020-01-01T00:00:00Z","total_turns_this_session":42}\n' \
        "$2" > "$1/state/turn_counter.json"
}

# 7) A broken jq is now a NON-EVENT. This case used to assert the opposite;
# it is inverted deliberately, and it is the assertion that would catch a
# reintroduced jq dependency on this path.
S=$(new_store); seed_counter "$S" sess-brokenjq
run_hook "$S" sess-brokenjq "PATH=${BROKEN_DIR}:${PATH}"
check "a broken jq no longer degrades the counter" "0" "$(log_lines "$S")"
check "a broken jq still counts the turn (43 = seeded 42 + 1)" "43" \
    "$(jq -r .total_turns_this_session "$S/state/turn_counter.json")"

# 8) Throttle: the SAME broken state across many tool uses must NOT append a
# line per tool use. That would put thousands of lines in the one file
# doctor.sh reports on ("N persistence failure(s) recorded") and destroy it as
# a diagnostic -- which is why this hook cannot simply log every failure.
S=$(new_store); wedge_counter "$S"
for _ in 1 2 3 4 5 6 7 8 9 10; do run_hook "$S" sess-flood; done
check "10 tool uses in the same broken state append exactly one line" "1" "$(log_lines "$S")"
if grep -q "turn-counter" "$S/logs/persist-failures.log" 2>/dev/null; then
    echo "PASS: the failure line names turn-counter as the component"
else
    echo "FAIL: failure line does not name the component: $(cat "$S/logs/persist-failures.log" 2>/dev/null)"
    FAILURES=$((FAILURES+1))
fi

# 9) ...but the throttle is a cooldown, not a one-shot: a machine that stays
# broken must keep saying so, or a single line scrolls into history and the
# breakage goes quiet again. Age the marker past the interval.
S=$(new_store); wedge_counter "$S"
run_hook "$S" sess-cool
echo $(( $(date +%s) - 7200 )) > "$S/state/.counter-degraded"
run_hook "$S" sess-cool
check "a still-broken counter re-reports once the cooldown expires" "2" "$(log_lines "$S")"

# 10) THE POINT OF WP8. On a machine where jq is genuinely absent -- which is
# every default Windows box, and the reason the docs used to say
# `winget install jqlang.jq` -- the counter must simply WORK. This case used
# to assert "absent jq is reported"; that was the correct behaviour while the
# hook needed jq, and it is the wrong behaviour now.
#
# Selecting whole directories the way tests/test-review-failure-legibility.sh
# does cannot work here: on this machine jq lives in /usr/bin alongside every
# base tool, so any PATH holding coreutils holds jq too. Symlink the
# individual tools into a private directory instead, and skip only if a PROBE
# shows the result is unusable (Git Bash without developer mode turns `ln -s`
# into a copy, which can break a copied binary's DLL lookup) rather than
# assuming it from the platform name.
#
# `python3` is linked from sys.executable, NOT from `command -v python3`: on a
# pyenv/asdf machine that name is a SHIM which needs the full ambient PATH and
# produces nothing on a restricted one -- the hook would then exit early on an
# unresolvable interpreter and this case would silently stop testing jq at all.
NOJQ_DIR="${TMP}/nojq-bin"; mkdir -p "$NOJQ_DIR"
for tool in bash date mkdir rm mv cat grep sed tr wc env sleep \
            dirname basename printf uname cut head tail find chmod ln; do
    tp="$(command -v "$tool" 2>/dev/null)" || continue
    ln -s "$tp" "${NOJQ_DIR}/${tool}" 2>/dev/null || cp "$tp" "${NOJQ_DIR}/${tool}" 2>/dev/null || true
done
REAL_PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
[[ -n "$REAL_PY" ]] && { ln -s "$REAL_PY" "${NOJQ_DIR}/python3" 2>/dev/null || cp "$REAL_PY" "${NOJQ_DIR}/python3" 2>/dev/null || true; }
NOJQ_PATH="$NOJQ_DIR"
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1 \
   || ! PATH="$NOJQ_PATH" bash -c 'python3 --version >/dev/null && date -u +%s >/dev/null' 2>/dev/null; then
    echo "SKIP: could not build a usable jq-free PATH on this machine"
    echo "      (probe: jq still reachable, or the linked tools do not run)."
    echo "      Case 7 already covers a jq that is present but cannot run."
else
    S=$(new_store); seed_counter "$S" sess-nojq
    run_hook "$S" sess-nojq "PATH=${NOJQ_PATH}"
    check "no jq on PATH is not a failure any more" "0" "$(log_lines "$S")"
    check "no jq on PATH still counts the turn (43 = seeded 42 + 1)" "43" \
        "$(jq -r .total_turns_this_session "$S/state/turn_counter.json")"
    check "no jq on PATH still records the session boundary" "sess-nojq" \
        "$(jq -r .session_id "$S/state/turn_counter.json")"
fi

# 11) A counter file that exists but cannot be parsed is NOT normal and must
# be reported -- then repaired, so a corrupt file cannot wedge counting.
S=$(new_store)
printf '{ this is not json' > "$S/state/turn_counter.json"
run_hook "$S" sess-corrupt
check "an unparseable counter file is reported" "1" "$(log_lines "$S")"
check "an unparseable counter file is then repaired" "1" \
    "$(jq -r .total_turns_this_session "$S/state/turn_counter.json")"

# 12) Recovery clears the throttle marker, so the NEXT breakage is reported
# immediately instead of being swallowed by a stale cooldown.
run_hook "$S" sess-corrupt
if [[ -f "$S/state/.counter-degraded" ]]; then
    echo "FAIL: the degraded marker survived a healthy read, so a later breakage would be suppressed"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: a healthy read clears the degraded marker"
fi
check "recovery adds no further failure lines" "1" "$(log_lines "$S")"

# 13) `// 0` only substitutes for null/false, so a counter stored as a STRING
# flows straight through -- and then evaluates to 0 inside $(( )), because
# bash treats a non-numeric word there as an unset variable name. Same silent
# collapse wearing a different hat. (The core rejects it in Python now, but
# the collapse it prevents is identical, so the case stays.)
S=$(new_store)
printf '{"session_id":"s","memory_turns":"abc","skill_iterations":3,"total_turns_this_session":9,"last_review_at":"","session_started_at":""}\n' \
    > "$S/state/turn_counter.json"
run_hook "$S" sess-nonnumeric
check "a non-numeric counter is reported rather than silently read as 0" "1" "$(log_lines "$S")"
check "a non-numeric counter is then reset, not left to wedge counting" "1" \
    "$(jq -r .total_turns_this_session "$S/state/turn_counter.json")"

# 14) The one case that must stay SILENT: no counter file at all is simply the
# first tool use of a session. Defaults are correct there, and a failure line
# per new session would train everyone to ignore the file.
S=$(new_store)
run_hook "$S" sess-fresh
check "a first-tool-use with no counter file logs nothing" "0" "$(log_lines "$S")"
if [[ -f "$S/state/.counter-degraded" ]]; then
    echo "FAIL: a healthy first tool use left a degraded marker behind"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: a healthy first tool use leaves no degraded marker"
fi

# 15) Field alignment across the single combined jq read. The six fields are
# now read from ONE `jq ... | @tsv` call instead of six separate jq calls, and
# tab is an IFS *whitespace* character -- bash `read` collapses runs of those
# into a single delimiter. An empty last_review_at (the normal state until the
# first review ever runs) therefore shifted session_started_at one field left,
# silently populating the cooldown gate's timestamp with the session start.
# Caught while writing this fix; pinned here because the empty field is the
# COMMON case and cases 1-6 above all happen to read fields before it.
S=$(new_store)
run_hook "$S" sess-align
STARTED=$(jq -r .session_started_at "$S/state/turn_counter.json")
run_hook "$S" sess-align
check "last_review_at stays empty when no review has run" "" \
    "$(jq -r .last_review_at "$S/state/turn_counter.json")"
check "session_started_at survives the round trip unshifted" "$STARTED" \
    "$(jq -r .session_started_at "$S/state/turn_counter.json")"
check "counting still accumulates across the combined read" "2" \
    "$(jq -r .total_turns_this_session "$S/state/turn_counter.json")"

# ---------------------------------------------------------------------------
# 16) The threshold crossing itself, end to end and across TWO fires. Cases 5
# and 6 pin the cooldown gate; nothing pinned the signal file's own contents,
# so a core that wrote `review_skills: false` on a skill-triggered review, or
# never wrote the file at all until some later fire, would pass everything
# above.
# ---------------------------------------------------------------------------
S=$(new_store)
rm -f "$S/state/review_signal.json"
run_hook "$S" sess-threshold SL_SKILL_REVIEW_INTERVAL=2 SL_MEMORY_REVIEW_INTERVAL=99
check "one fire below the skill threshold writes no signal" "no" \
    "$([[ -f "$S/state/review_signal.json" ]] && echo yes || echo no)"
run_hook "$S" sess-threshold SL_SKILL_REVIEW_INTERVAL=2 SL_MEMORY_REVIEW_INTERVAL=99
check "the fire that crosses the skill threshold writes the signal" "yes" \
    "$([[ -f "$S/state/review_signal.json" ]] && echo yes || echo no)"
check "signal says review_skills" "true" "$(jq -r .review_skills "$S/state/review_signal.json")"
check "signal does NOT say review_memory" "false" "$(jq -r .review_memory "$S/state/review_signal.json")"
check "signal carries the session id" "sess-threshold" "$(jq -r .session_id "$S/state/review_signal.json")"
check "signal carries the turn count" "2" "$(jq -r .total_turns "$S/state/review_signal.json")"
check "crossing the threshold resets skill_iterations" "0" \
    "$(jq -r .skill_iterations "$S/state/turn_counter.json")"

# 17) The cooldown as it is actually reached in practice: a signal has just
# been written, last_review_at is set, and the threshold is crossed again
# immediately. Case 5 seeds last_review_at by hand; this one arrives there the
# way a real session does, which is the wiring case 5 cannot see.
LAST_TRIGGER=$(jq -r .triggered_at "$S/state/review_signal.json")
jq --arg t "$LAST_TRIGGER" '.last_review_at = $t' "$S/state/turn_counter.json" > "$S/state/tc.tmp"
mv "$S/state/tc.tmp" "$S/state/turn_counter.json"
rm -f "$S/state/review_signal.json"
run_hook "$S" sess-threshold SL_SKILL_REVIEW_INTERVAL=1 SL_MEMORY_REVIEW_INTERVAL=99
check "a second crossing within 60s of the first is suppressed" "no" \
    "$([[ -f "$S/state/review_signal.json" ]] && echo yes || echo no)"
check "the suppressed fire still advanced the turn count" "3" \
    "$(jq -r .total_turns_this_session "$S/state/turn_counter.json")"

# 18) No jq ANYWHERE in the shipped hook path. This is the assertion that
# fails if someone reintroduces the dependency the WP8 change removed --
# behavioural cases can be satisfied by a jq call that merely happens to work
# on the developer's machine.
#
# Comment lines are stripped first: both files EXPLAIN at length why jq is
# gone, and a naive `grep jq` matches that prose. Whole-line comments only --
# a trailing `# ...` cannot hide a real call earlier on the same line.
no_jq_code() {  # no_jq_code <file>
    if sed 's/^[[:space:]]*[#].*$//' "$1" \
        | grep -qE '(^|[^-[:alnum:]_./])jq([^-[:alnum:]_]|$)'; then echo yes; else echo no; fi
}
check "turn-counter.sh invokes no jq" "no" "$(no_jq_code "${SCRIPT_DIR}/scripts/turn-counter.sh")"
# The guard must actually be able to SEE a jq call, or it is decorative.
_jq_probe="${TMP}/jq-probe.sh"; printf 'x=$(jq -r .a f.json)\n' > "$_jq_probe"
check "the no-jq guard detects a real jq call" "yes" "$(no_jq_code "$_jq_probe")"

# The core is asserted the stronger way -- it must spawn NOTHING. Grepping it
# for "jq" is useless (its own docstring explains at length why jq is gone),
# and "no subprocesses at all" is the property that actually protects the
# budget: this whole change is worthwhile only because the work happens in one
# process rather than several.
check "turn_counter_core.py spawns no subprocess of any kind" "no" \
    "$(grep -qE '^[[:space:]]*(import|from)[[:space:]]+(subprocess|os\.system)|subprocess\.|os\.system\(|os\.popen\(|os\.exec' \
        "${SCRIPT_DIR}/scripts/lib/turn_counter_core.py" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All turn-counter tests passed."
