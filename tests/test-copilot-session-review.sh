#!/usr/bin/env bash
# tests/test-copilot-session-review.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
# Item 3 (deferred minor): this file allocates additional temp dirs further
# down (TMP_HOME/FAKE_BIN, TMP8/FAKE_BIN8, TMP9) previously cleaned only via
# an explicit `rm -rf` on the success path -- an early `exit 1` leaked them.
# One EXIT trap covering every temp dir this script ever creates, via
# ${VAR:-} so it's safe to register before the later variables are set (the
# trap body is expanded when EXIT fires, not when trap is registered).
# fix-p6: sl_rm_rf_retry, not a bare `rm -rf`, on this trap -- defense in
# depth alongside sl_wait_for_review_complete used below (see
# tests/lib/wait-for-review.sh for why both layers exist).
trap 'sl_rm_rf_retry "$TMP"; sl_rm_rf_retry "${TMP_HOME:-}"; sl_rm_rf_retry "${FAKE_BIN:-}"; sl_rm_rf_retry "${TMP8:-}"; sl_rm_rf_retry "${FAKE_BIN8:-}"; sl_rm_rf_retry "${TMP9:-}"; sl_rm_rf_retry "${TMP10:-}"; sl_rm_rf_retry "${FAKE_BIN10:-}"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE="/nonexistent"
mkdir -p "$TMP/state" "$TMP/bin"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/wait-for-review.sh
source "${SCRIPT_DIR}/tests/lib/wait-for-review.sh"

cat > "$TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_COPILOT_LOG}"
EOF
chmod +x "$TMP/bin/copilot"
export PATH="$TMP/bin:$PATH" FAKE_COPILOT_LOG="$TMP/copilot-calls.log"


# fix-p7 (audit follow-up): the cases below drive the DETACHED review
# pipeline for real and used to assert on its side effects after a bare
# fixed sleep. Re-judged (see the matching note in
# tests/test-session-review.sh): 0.3s is not a wide margin for `nohup bash
# -c` plus a bash shim on a loaded windows-latest runner, and the
# negative-shaped assertions here ("no --model in argv", "hostile model
# string dropped", "spawns nothing") are worse than flaky -- they pass
# vacuously against a log that is empty only because the spawn has not
# happened yet, which is precisely the "green while testing nothing"
# failure this project keeps finding. Each is now gated on the pipeline's
# own unconditional completion marker.

# 1) Spawns copilot with guard, -p, -s, and tool allowances
sl_clear_review_marker "$SL_LOG_DIR"
bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sl_wait_for_review_complete "$SL_LOG_DIR" || true
# The marker itself, asserted rather than merely waited on -- see
# sl_assert_review_marker_or_abort's header for why every wait below is
# `|| true` and what that used to hide (this suite: exit 0 in 372s with the
# marker write deleted). Placed on the first case that expects a review, so
# a broken marker costs one wait budget rather than eleven.
sl_assert_review_marker_or_abort "$SL_LOG_DIR"
check "copilot invoked" "yes" "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"
check "guard env set" "1" "$(grep -m1 '^GUARD:' "$FAKE_COPILOT_LOG" | cut -d: -f2)"
check "headless flags present" "yes" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '-p ' && echo yes || echo no)"
check "no model flag when unset" "no" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--model' && echo yes || echo no)"

# 2) Model flag appears when configured
: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SL_COPILOT_REVIEW_MODEL="cheap-model-x" bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "model flag when set" "yes" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--model cheap-model-x' && echo yes || echo no)"

# 3) Recursion guard on entry
: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
# Bounded watch for a marker that must never arrive -- see
# sl_expect_no_review_spawned's header for why "the log is still empty"
# alone is not evidence the guard worked.
check "no review pipeline was spawned at all" "yes" \
    "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
check "guarded entry spawns nothing" "no" "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"

# 4) Hook template shape
check "hook template version 1" "1" "$(jq -r .version "${SCRIPT_DIR}/config/copilot-hooks.json")"
check "sessionEnd command hook" "command" "$(jq -r '.hooks.sessionEnd[0].type' "${SCRIPT_DIR}/config/copilot-hooks.json")"

# 5) Hostile model string is rejected (no --model in argv)
: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SL_COPILOT_REVIEW_MODEL='x; rm -rf /' bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
# The wait matters MORE here than for a positive check: this assertion is
# "no --model reached argv", which an empty (not-yet-written) log satisfies
# for the wrong reason. Waiting for the pipeline to finish means the log
# genuinely contains the argv that was used.
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "reviewer actually ran (so the argv assertion below is not vacuous)" "yes" \
    "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"
check "hostile model string dropped" "no" "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--model' && echo yes || echo no)"

# 5b) SL_COPILOT_MAX_AI_CREDITS -- the Copilot reviewer's cost ceiling.
# Default-off by design (see the note in scripts/lib/config.sh), so all
# three states are pinned: absent when unset, present when set to a legal
# value, dropped when set to anything the CLI would reject. Same
# marker-gated, argv-recording technique as case 5; the same
# "not vacuous" guard applies to the two negative-shaped assertions.
: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "reviewer ran (credits-unset case is not vacuous)" "yes" \
    "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"
check "no credit ceiling in argv when SL_COPILOT_MAX_AI_CREDITS is unset" "no" \
    "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--max-ai-credits' && echo yes || echo no)"

: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SL_COPILOT_MAX_AI_CREDITS=30 bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "credit ceiling reaches argv when set" "yes" \
    "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--max-ai-credits 30' && echo yes || echo no)"

# Below the CLI's documented minimum of 30, and a non-numeric value: both
# must be refused HERE, with a reason on stderr, rather than handed to a
# binary that would exit non-zero inside a detached pipeline.
: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
CREDIT_ERR="$(SL_COPILOT_MAX_AI_CREDITS='5' bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null 2>&1 >/dev/null)"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "reviewer ran (below-minimum case is not vacuous)" "yes" \
    "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"
check "below-minimum credit value dropped from argv" "no" \
    "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--max-ai-credits' && echo yes || echo no)"
check "below-minimum credit value reported on stderr" "yes" \
    "$(printf '%s' "$CREDIT_ERR" | grep -q 'SL_COPILOT_MAX_AI_CREDITS' && echo yes || echo no)"

: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SL_COPILOT_MAX_AI_CREDITS='30; rm -rf /' bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null 2>/dev/null
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "reviewer ran (hostile-credits case is not vacuous)" "yes" \
    "$([[ -s "$FAKE_COPILOT_LOG" ]] && echo yes || echo no)"
check "hostile credit string dropped" "no" \
    "$(grep -m1 '^ARGS:' "$FAKE_COPILOT_LOG" | grep -q -- '--max-ai-credits' && echo yes || echo no)"

# 6) Untrusted-data framing present in prompt when signals exist.
# The signal is planted as a Route B export fixture with SL_COACH_EXPORT_ENABLED=true
# (same pattern as the session-review test): coach-signals.py, which this script
# invokes before building the prompt, regenerates the managed signals file from the
# export. (A raw pre-built signals file would be deleted by coach-signals.py when
# both routes are off, so it must be planted through an enabled route.)
mkdir -p "$TMP/state"
echo '{"generated_at":"2099-01-01T00:00:00Z","signals":[{"id":"x","severity":"low","suggestion":"s"}]}' > "$TMP/state/coach-signals.json"
export SL_COACH_EXPORT_ENABLED=true SL_COACH_EXPORT_PATH="$TMP/export6.json"
echo '{"antiPatterns":{"totalOccurrences":1,"topPatterns":[{"id":"x","name":"X","severity":"low","group":"g","occurrences":1,"description":"d","suggestion":"s"}]}}' > "$SL_COACH_EXPORT_PATH"
: > "$FAKE_COPILOT_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SL_COACH_SIGNALS_FILE="$TMP/state/coach-signals.json" bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null
unset SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "untrusted-data framing in prompt" "yes" "$(grep -q 'untrusted telemetry data' "$FAKE_COPILOT_LOG" && echo yes || echo no)"

# 7) Copilot reviewer output is persisted, and no write tool is requested.
TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "write" ]]; then
        echo "FAIL_MARKER: write tool was requested" >&2
        exit 3
    fi
done
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "copilot-persisted"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/copilot"

# fix-p6: wait for the detached pipeline's own completion marker (see
# tests/lib/wait-for-review.sh), not only for MEMORY.md to appear.
sl_clear_review_marker "${TMP_HOME}/store/logs"
env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

sl_wait_for_review_complete "${TMP_HOME}/store/logs" || true

for _ in $(seq 1 50); do
    [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]] && break
    sleep 0.2
done

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "copilot proposal persisted" "copilot-persisted" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: Copilot path did not persist"; FAILURES=$((FAILURES+1))
fi

# I8: same self-contradiction fixed in session-review.sh's prompt.
check "prompt states the real schema regex" "yes" \
    "$(grep -qF '[A-Za-z0-9][A-Za-z0-9_-]{0,63}' "${SCRIPT_DIR}/scripts/copilot-session-review.sh" && echo yes || echo no)"
check "prompt no longer states the dot-inclusive contradiction" "no" \
    "$(grep -qE '\[a-z0-9\]\[a-z0-9\._-\]' "${SCRIPT_DIR}/scripts/copilot-session-review.sh" && echo yes || echo no)"

# 8) P0 fix: a real sessionEnd payload + a seeded events.jsonl actually
# reaches the reviewer's prompt. Uses the argv-recording shim technique from
# case 1 above, but now feeds a realistic sessionId JSON payload on stdin and
# a matching ~/.copilot/session-state/<id>/events.jsonl fixture, then asserts
# the transcript's placeholder content shows up in what "copilot" was
# invoked with (the -p prompt argument).
TMP8="$(mktemp -d)"; FAKE_BIN8="$(mktemp -d)"
cat > "${FAKE_BIN8}/copilot" <<'EOF'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-p" ]]; then
        j=$((i+1))
        printf '%s' "${!j}" > "${FAKE_COPILOT_PROMPT_FILE}"
    fi
done
printf '{"version": 1}\n'
EOF
chmod +x "${FAKE_BIN8}/copilot"

SESSION_ID="d60c51bf-e2e8-case8-0000-000000000008"
STATE_DIR="${TMP8}/.copilot/session-state/${SESSION_ID}"
mkdir -p "$STATE_DIR"
cat > "${STATE_DIR}/events.jsonl" <<EOF
{"type":"session.start","data":{"sessionId":"${SESSION_ID}"},"id":"e0","parentId":null,"timestamp":"2026-07-25T12:00:00Z"}
{"type":"user.message","data":{"content":"UNIQUE_MARKER_USER_TURN_CASE8"},"id":"e1","parentId":"e0","timestamp":"2026-07-25T12:00:01Z"}
{"type":"assistant.message","data":{"content":"UNIQUE_MARKER_ASSISTANT_TURN_CASE8"},"id":"e2","parentId":"e1","timestamp":"2026-07-25T12:00:02Z"}
{"type":"session.shutdown","data":{"shutdownType":"complete"},"id":"e3","parentId":"e2","timestamp":"2026-07-25T12:00:03Z"}
EOF

FAKE_COPILOT_PROMPT_FILE="${TMP8}/prompt.txt"
export FAKE_COPILOT_PROMPT_FILE
sl_clear_review_marker "${TMP8}/store/logs"
echo "{\"sessionId\":\"${SESSION_ID}\",\"timestamp\":1784982920820,\"cwd\":\"/tmp\",\"reason\":\"complete\"}" \
    | env -i HOME="$TMP8" PATH="${FAKE_BIN8}:${PATH}" \
        AGENT_LEARNING_HOME="${TMP8}/store" SL_CONFIG_FILE="/nonexistent/x.conf" \
        FAKE_COPILOT_PROMPT_FILE="$FAKE_COPILOT_PROMPT_FILE" \
        bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" >/dev/null 2>&1 || true

sl_wait_for_review_complete "${TMP8}/store/logs" || true

for _ in $(seq 1 50); do
    [[ -s "$FAKE_COPILOT_PROMPT_FILE" ]] && break
    sleep 0.2
done

check "transcript user turn reached the prompt" "yes" \
    "$(grep -q 'UNIQUE_MARKER_USER_TURN_CASE8' "$FAKE_COPILOT_PROMPT_FILE" 2>/dev/null && echo yes || echo no)"
check "transcript assistant turn reached the prompt" "yes" \
    "$(grep -q 'UNIQUE_MARKER_ASSISTANT_TURN_CASE8' "$FAKE_COPILOT_PROMPT_FILE" 2>/dev/null && echo yes || echo no)"
check "transcript section framed as untrusted data" "yes" \
    "$(grep -q 'untrusted conversation data' "$FAKE_COPILOT_PROMPT_FILE" 2>/dev/null && echo yes || echo no)"
unset FAKE_COPILOT_PROMPT_FILE

# 9) Missing transcript is logged visibly to persist-failures.log, never a
# silent empty review -- a sessionId with no matching session-state dir.
TMP9="$(mktemp -d)"
mkdir -p "${TMP9}/store/logs"
sl_clear_review_marker "${TMP9}/store/logs"
echo '{"sessionId":"session-with-no-transcript-on-disk","reason":"complete"}' \
    | env -i HOME="$TMP9" PATH="$PATH" \
        AGENT_LEARNING_HOME="${TMP9}/store" SL_CONFIG_FILE="/nonexistent/x.conf" \
        bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" >/dev/null 2>&1 || true
FAILURE_LOG="${TMP9}/store/logs/persist-failures.log"
check "missing transcript logged to persist-failures.log" "yes" \
    "$([[ -f "$FAILURE_LOG" ]] && grep -q 'transcript unavailable' "$FAILURE_LOG" && echo yes || echo no)"
# The assertion above cannot race: transcript.py runs SYNCHRONOUSLY at
# copilot-session-review.sh:44 and writes that line before the script continues.
# But the script does not stop there -- its own comment is explicit that "a real
# transcript failure still logs loudly AND still spawns the review; only the
# provably-empty case short-circuits" -- so on a machine with `copilot` on PATH
# this case DOES leave a detached pipeline writing into ${TMP9}/store while the
# suite moves on to teardown. sl_rm_rf_retry made that survivable; it did not
# make it correct. Gate on the same condition the script gates on, so the wait
# is real where a pipeline exists and the no-spawn case is asserted (2s) rather
# than waited out (30s) where it does not.
if command -v copilot >/dev/null 2>&1; then
    sl_wait_for_review_complete "${TMP9}/store/logs" || true
else
    sl_expect_no_review_spawned "${TMP9}/store/logs" \
        || { echo "FAIL: review spawned with no copilot on PATH"; FAILURES=$((FAILURES+1)); }
fi

# 10) fix-empty-session. A session that started and ended without ever taking
# a turn is NOT a persistence failure. `sessionEnd` fires for those too, and
# on the machine that surfaced this they were 95 of 179 sessions; routing them
# into persist-failures.log flipped doctor to UNHEALTHY on a healthy store and
# devalued the one channel a genuinely broken detached review can reach.
#
# The fixture is the real shape of such a dir (checkpoints/, empty files/ and
# research/, a workspace.yaml with no `name:` key, and NEITHER events.jsonl
# NOR session.db), taken from the dirs behind the reported failures.
make_silent_session_dir() {
    local root="$1" sid="$2" dir
    dir="${root}/.copilot/session-state/${sid}"
    mkdir -p "${dir}/checkpoints" "${dir}/files" "${dir}/research"
    printf '# checkpoints\n' > "${dir}/checkpoints/index.md"
    printf 'id: %s\ncwd: /tmp\nclient_name: github/cli\nuser_named: false\nsummary_count: 0\n' \
        "$sid" > "${dir}/workspace.yaml"
    printf '%s' "$dir"
}

TMP10="$(mktemp -d)"
FAKE_BIN10="$(mktemp -d)"
cat > "${FAKE_BIN10}/copilot" <<'EOF'
#!/usr/bin/env bash
printf 'SPAWNED\n' >> "${FAKE_COPILOT_SPAWN_LOG}"
printf '{"version": 1}\n'
EOF
chmod +x "${FAKE_BIN10}/copilot"
SPAWN_LOG="${TMP10}/spawned.log"

SILENT_ID="aaaaaaaa-0000-4000-8000-00000000000a"
make_silent_session_dir "$TMP10" "$SILENT_ID" >/dev/null
sl_clear_review_marker "${TMP10}/store/logs"
echo "{\"sessionId\":\"${SILENT_ID}\",\"reason\":\"complete\"}" \
    | env -i HOME="$TMP10" PATH="${FAKE_BIN10}:${PATH}" \
        AGENT_LEARNING_HOME="${TMP10}/store" SL_CONFIG_FILE="/nonexistent/x.conf" \
        FAKE_COPILOT_SPAWN_LOG="$SPAWN_LOG" \
        bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" >/dev/null 2>&1 || true

check "empty session writes NOTHING to persist-failures.log" "yes" \
    "$([[ ! -s "${TMP10}/store/logs/persist-failures.log" ]] && echo yes || echo no)"
check "empty session is still visible in persist.log" "yes" \
    "$(grep -q '"skipped": \["no-conversation"\]' "${TMP10}/store/logs/persist.log" 2>/dev/null && echo yes || echo no)"
# It must not burn a paid model call reviewing a session with nothing in it.
# Give the (correctly suppressed) detached spawn a chance to appear before
# asserting its absence, so this negative is not vacuously green.
check "empty session does not spawn the reviewer" "yes" \
    "$(sl_expect_no_review_spawned "${TMP10}/store/logs" && [[ ! -s "$SPAWN_LOG" ]] && echo yes || echo no)"

# 11) MUTATION GUARD for 10: the same dir, plus session.db -- i.e. a session
# that genuinely DID converse but whose events.jsonl is gone. This must stay
# loud. If the discriminator ever loosens to "no events.jsonl => empty", this
# case is what fails.
CONVERSED_ID="bbbbbbbb-0000-4000-8000-00000000000b"
CONVERSED_DIR="$(make_silent_session_dir "$TMP10" "$CONVERSED_ID")"
printf 'SQLite format 3\000' > "${CONVERSED_DIR}/session.db"
rm -f "${TMP10}/store/logs/persist-failures.log" "${TMP10}/store/logs/persist.log"
sl_clear_review_marker "${TMP10}/store/logs"
echo "{\"sessionId\":\"${CONVERSED_ID}\",\"reason\":\"complete\"}" \
    | env -i HOME="$TMP10" PATH="${FAKE_BIN10}:${PATH}" \
        AGENT_LEARNING_HOME="${TMP10}/store" SL_CONFIG_FILE="/nonexistent/x.conf" \
        FAKE_COPILOT_SPAWN_LOG="$SPAWN_LOG" \
        bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" >/dev/null 2>&1 || true

check "lost transcript for a session that DID converse is still a failure" "yes" \
    "$(grep -q 'transcript unavailable' "${TMP10}/store/logs/persist-failures.log" 2>/dev/null && echo yes || echo no)"
# The reviewer IS still spawned on the failure path (unchanged behavior), so
# persist.log may legitimately gain a line from persist-proposal.py. What must
# never appear there is a no-conversation classification for a session that
# actually conversed.
check "a genuine failure is NOT reclassified as no-conversation" "yes" \
    "$(grep -q 'no-conversation' "${TMP10}/store/logs/persist.log" 2>/dev/null && echo no || echo yes)"

# This block spawns the real detached pipeline (above), so the reviewer may
# still be writing into ${TMP10} when we tear it down. Every other launch site
# in this file waits on the completion marker and tears down with
# sl_rm_rf_retry; this one -- added with the empty-session work -- did neither,
# and a bare `rm -rf` losing that race aborts the whole suite under `set -e`
# with EVERY assertion already passed and the final "all tests passed" line
# never printed. That is exactly the signature seen on ubuntu-latest 3.13 in
# CI run 30254909461 while the other five cells were green: not a failed
# check, an exit code from teardown.
#
# fix-p6 introduced sl_wait_for_review_complete + sl_rm_rf_retry for this
# class after the same race broke tests/test-e2e-skill-visibility.sh on macOS.
# This site reintroduced it; both layers are applied here now for the same
# reason they exist there (see tests/lib/wait-for-review.sh).
sl_wait_for_review_complete "${TMP10}/store/logs" || true
sl_rm_rf_retry "$TMP10"
sl_rm_rf_retry "$FAKE_BIN10"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All copilot-session-review tests passed."
