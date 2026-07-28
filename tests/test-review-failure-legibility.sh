#!/usr/bin/env bash
# tests/test-review-failure-legibility.sh
#
# Regression guard for the first real Claude Code review this project ever ran
# on a user machine (2026-07-28T09:07:43Z), which failed and left behind two
# artifacts that could not be joined:
#
#   logs/persist-failures.log:  "<ts> session-review: pipeline failed (status 1)"
#   logs/persist.log:           "persist-proposal: invalid proposal: duplicate
#                                memory file entries"
#
# The failure line named neither the stage nor the reason, and the reason line
# carried no timestamp and no component, so nothing tied them together --
# diagnosing it required reasoning about the interleaving of an unrelated
# Copilot pipeline's timestamped lines in the same file.
#
# TWO defects, both pinned here:
#
#   1. ROOT CAUSE. Every harness preamble granted the reviewer "3 memory
#      writes" while proposal_schema.ALLOWED_MEMORY_FILES holds exactly TWO
#      filenames and validate_proposal rejects duplicate file entries
#      wholesale. A reviewer that merely spent its stated budget therefore
#      emitted an unvalidatable proposal, and the entire paid review was
#      discarded. Cases C/D below.
#
#   2. LEGIBILITY. sl_review_launch_detached collapsed both pipeline stages
#      into one `$?` under pipefail and printed a status number. Cases A/B/E.
#
# Every case drives the REAL scripts/session-review.sh through a fake `claude`
# on PATH -- no paid model call, and the assertions are on what the pipeline
# writes, not on how it is written.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/wait-for-review.sh
source "${SCRIPT_DIR}/tests/lib/wait-for-review.sh"

FAILURES=0
CASE_DIRS=()
trap 'for d in "${CASE_DIRS[@]:-}"; do [[ -n "$d" ]] && sl_rm_rf_retry "$d"; done' EXIT

check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (expected '$2', got '$3')"
        FAILURES=$((FAILURES + 1))
    fi
}

# Drives one review end-to-end against a throwaway store with a fake reviewer.
#   $1  fake `claude` script body (without the shebang)
# Exports STORE for the caller to assert against.
run_review() {
    local shim_body="$1" R i
    R="$(mktemp -d)"
    CASE_DIRS+=("$R")
    mkdir -p "$R/home" "$R/store/state" "$R/store/logs" "$R/bin"
    { echo '#!/usr/bin/env bash'; printf '%s\n' "$shim_body"; } > "$R/bin/claude"
    chmod +x "$R/bin/claude"
    printf '%s\n' \
        '{"session_id":"leg","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
        > "$R/store/state/turn_counter.json"
    STORE="$R/store"
    PROMPT_LOG="$R/prompt.txt"
    sl_clear_review_marker "$STORE/logs"
    # env -i: the real store on the developer's own machine must never be
    # reachable from this suite, and AGENT_LEARNING_HOME is only authoritative
    # when no inherited XDG_DATA_HOME/HOME can win.
    echo '{"session_id":"leg","hook_event_name":"Stop"}' \
        | env -i HOME="$R/home" AGENT_LEARNING_HOME="$R/store" \
              PATH="$R/bin:/usr/bin:/bin" FAKE_PROMPT_LOG="$R/prompt.txt" \
              bash "${SCRIPT_DIR}/scripts/session-review.sh"
    sl_wait_for_review_complete "$STORE/logs" || true
}

# The failure line for this run, with the "transcript unavailable" line the
# synthetic Stop payload always produces (it carries no transcript_path)
# filtered out -- that line is a separate, already-tested signal.
failure_line() {
    grep -v 'transcript unavailable' "$STORE/logs/persist-failures.log" 2>/dev/null | tail -n 1
}

emits() { grep -qF "$2" <<<"$1" && echo yes || echo no; }

# A reviewer shim emitting a fenced JSON proposal. Heredoc delimiter is QUOTED:
# the payload contains backticks, and an unquoted delimiter turns the fence
# into command substitution (this cost one debugging round while writing this
# suite -- a shim that silently emitted nothing looked exactly like a reviewer
# that had produced no proposal).
proposal_shim() {
    printf 'cat <<%sSHIMEOF%s\n```json\n%s\n```\nSHIMEOF\n' "'" "'" "$1"
}

# ---------------------------------------------------------------------------
# A) The live failure, verbatim: writer stage rejects the proposal.
#
# Three memory entries over two legal filenames is exactly what the pre-fix
# prompt's "Maximum 3 memory writes" invited. The failure line must now name
# the stage AND carry the writer's own diagnostic, so persist-failures.log
# alone is enough to diagnose it.
# ---------------------------------------------------------------------------
run_review "$(proposal_shim '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "append", "content": "- a\n"}, {"file": "MEMORY.md", "mode": "append", "content": "- b\n"}, {"file": "USER.md", "mode": "append", "content": "- c\n"}]}')"
LINE="$(failure_line)"
check "A: writer-stage failure names the writer stage" "yes" "$(emits "$LINE" "writer stage exited")"
check "A: writer-stage failure carries the writer's reason" "yes" "$(emits "$LINE" "persist-proposal: invalid proposal:")"
check "A: writer-stage failure does not blame the reviewer" "no" "$(emits "$LINE" "reviewer stage")"
# The pre-fix line, pinned negatively: it named no stage and no reason.
check "A: the unattributable pre-fix wording is gone" "no" "$(emits "$LINE" "pipeline failed (status")"
# The reason must still be visible in persist.log too -- splitting the writer's
# stderr off must not have removed it from where it has always appeared.
check "A: writer reason still reaches persist.log" "yes" \
    "$(grep -qF 'persist-proposal: invalid proposal:' "$STORE/logs/persist.log" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# B) Reviewer stage fails (non-zero exit, diagnostic on its own stderr).
#
# Pre-fix this produced a byte-identical log line to case A, which is what
# made the live failure ambiguous between "the model call broke" and "the
# proposal was rejected".
# ---------------------------------------------------------------------------
run_review 'echo "Error: Input must be provided either through stdin or as a prompt argument when using --print" >&2
exit 1'
LINE="$(failure_line)"
check "B: reviewer-stage failure names the reviewer stage" "yes" "$(emits "$LINE" "reviewer stage exited 1")"
check "B: reviewer-stage failure points at its stderr log" "yes" "$(emits "$LINE" "review-stderr.log")"
check "B: reviewer-stage failure does not blame the writer" "no" "$(emits "$LINE" "writer stage")"

# ---------------------------------------------------------------------------
# C) THE ROOT-CAUSE GUARD. The prompt the hook actually sends must tell the
# reviewer that a file may appear at most once. Asserted against the recorded
# argv, not against the source of review-common.sh: the contract only helps if
# it reaches the model.
# ---------------------------------------------------------------------------
run_review 'printf "%s\n" "$*" > "$FAKE_PROMPT_LOG"
exit 0'
PROMPT="$(cat "$PROMPT_LOG")"
check "C: prompt states the one-entry-per-file rule" "yes" "$(emits "$PROMPT" "AT MOST ONE entry per file")"
check "C: prompt warns the whole proposal is discarded" "yes" "$(emits "$PROMPT" "rejected in full")"
# The budget line must no longer read as "3 JSON entries". It is 3 FACTS.
check "C: budget is expressed in facts, not writes" "yes" "$(emits "$PROMPT" "Maximum 3 new memory FACTS")"
check "C: the misleading 'Maximum 3 memory writes' wording is gone" "no" \
    "$(emits "$PROMPT" "Maximum 3 memory writes")"

# ---------------------------------------------------------------------------
# D) The positive case the fixed contract steers the reviewer toward: the same
# three facts, packed into ONE entry per file, must validate and persist. A
# contract that only forbade things could be satisfied by proposing nothing.
# ---------------------------------------------------------------------------
run_review "$(proposal_shim '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "append", "content": "- a\n- b\n"}, {"file": "USER.md", "mode": "append", "content": "- c\n"}]}')"
check "D: conforming 3-fact proposal records no failure" "" "$(failure_line)"
check "D: conforming proposal writes MEMORY.md" "- a
- b" "$(cat "$STORE/memory/MEMORY.md" 2>/dev/null)"
check "D: conforming proposal writes USER.md" "- c" "$(cat "$STORE/memory/USER.md" 2>/dev/null)"

# ---------------------------------------------------------------------------
# E) Both stages fail. One line, not two: doctor.sh reports the line count of
# persist-failures.log as "N persistence failure(s) recorded", so a second
# line for a single broken run would overstate it.
# ---------------------------------------------------------------------------
run_review "echo boom >&2
$(proposal_shim '{"version": 9}')
exit 7"
check "E: both-stage failure records exactly one line" "1" \
    "$(grep -vc 'transcript unavailable' "$STORE/logs/persist-failures.log" 2>/dev/null || echo 0)"
LINE="$(failure_line)"
check "E: both-stage line names the reviewer stage" "yes" "$(emits "$LINE" "reviewer stage exited 7")"
check "E: both-stage line names the writer stage" "yes" "$(emits "$LINE" "writer stage exited 1")"
check "E: both-stage line carries the writer's reason" "yes" "$(emits "$LINE" "version must be 1, got 9")"

# ---------------------------------------------------------------------------
# F) No temp artifact is left behind in the log dir. The writer's stderr is
# captured to logs/.writer-stderr.<pid> so its text can be quoted in the
# failure line; that file must not survive the run (doctor.sh and the curator
# both read this directory).
# ---------------------------------------------------------------------------
check "F: writer stderr temp file is cleaned up" "" \
    "$(find "$STORE/logs" -name '.writer-stderr.*' 2>/dev/null)"

echo
if (( FAILURES > 0 )); then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "All checks passed"
