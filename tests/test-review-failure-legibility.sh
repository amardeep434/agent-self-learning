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
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

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
#   $2  optional: pre-existing memory/MEMORY.md content, seeded before the
#       hook runs. Every call gets a FRESH store, so a case that needs the
#       reviewer to collide with something already on disk (case J) cannot
#       get there by running two reviews in a row -- the second one starts
#       from an empty store. Seeding here is the only way in.
# Exports STORE for the caller to assert against.
run_review() {
    local shim_body="$1" seed_memory="${2:-}" R i
    R="$(mktemp -d)"
    CASE_DIRS+=("$R")
    mkdir -p "$R/home" "$R/store/state" "$R/store/logs" "$R/bin"
    if [[ -n "$seed_memory" ]]; then
        mkdir -p "$R/store/memory"
        printf '%s' "$seed_memory" > "$R/store/memory/MEMORY.md"
    fi
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
    #
    # PATH PREPENDS to the inherited $PATH -- it does NOT replace it, and the
    # difference cost a full Windows CI round. An earlier draft passed a
    # hardcoded PATH="$R/bin:/usr/bin:/bin", reasoning that env -i should be
    # total. On ubuntu/macOS that is fine. On windows-latest under Git Bash,
    # /usr/bin is C:\Program Files\Git\usr\bin, which ships no jq -- jq lives
    # on the runner's native PATH -- so session-review.sh's turn-count gate
    # scored 0 turns, exited 0 at its MIN_TURNS check, and never launched the
    # pipeline. The suite then timed out waiting for a marker that nothing was
    # ever going to write, and the only evidence left on disk was an empty
    # logs/reviews/ directory. Store isolation comes from HOME and
    # AGENT_LEARNING_HOME, not from amputating PATH; every other review suite
    # in this directory already prepends (test-session-review.sh:147,
    # test-copilot-session-review.sh:173, test-vscode-session-review.sh:237)
    # and all three stayed green on Windows in the run this one failed.
    echo '{"session_id":"leg","hook_event_name":"Stop"}' \
        | env -i HOME="$R/home" AGENT_LEARNING_HOME="$R/store" \
              PATH="$R/bin:$PATH" FAKE_PROMPT_LOG="$R/prompt.txt" \
              bash "${SCRIPT_DIR}/scripts/session-review.sh"
    if ! sl_wait_for_review_complete "$STORE/logs"; then
        diagnose_timeout "$R"
    fi
}

# On timeout, say WHY offline. The Windows round this suite already cost was
# diagnosable only by comparing `find` output against a local simulation; the
# two things that had to be ruled out were (H1) the marker being written to a
# different spelling of the same directory, and (H2) the detached body dying
# before its last statement. Both are answerable on the runner itself.
diagnose_timeout() {
    local R="$1"
    echo "--- self-diagnosis -------------------------------------------------"
    echo "polled log dir : $STORE/logs"
    # H1: does the product's own resolution of the store agree with the path
    # this suite polls? sl_check_same_path compares by identity, not spelling,
    # which is the whole point on MSYS.
    local resolved
    # sl_resolve_path, not a hand-rolled python3 call: it goes through the
    # identical subprocess/env/OS-path-conversion pipeline config.sh uses, so
    # the string is comparable to what the product actually resolved.
    # sl_same_path (the predicate), NOT sl_check_same_path -- the latter prints
    # PASS/FAIL and mutates FAILURES, which would corrupt this suite's tally
    # from inside a diagnostic.
    resolved="$(sl_resolve_path "${SCRIPT_DIR}/scripts/lib/paths.py" logs \
        HOME="$R/home" AGENT_LEARNING_HOME="$R/store" PATH="$R/bin:$PATH")"
    echo "paths.py logs  : ${resolved:-<paths.py produced nothing>}"
    if sl_same_path "$STORE/logs" "$resolved"; then
        echo "same path?     : YES -- H1 (path-spelling mismatch) is ruled out"
    else
        echo "same path?     : NO  -- H1 (path-spelling mismatch) is LIVE"
    fi
    echo "ls -la polled  :"; ls -la "$STORE/logs" 2>&1 | sed 's/^/    /'
    echo "ls -la resolved:"; ls -la "$resolved" 2>&1 | sed 's/^/    /'
    # H2: if the detached body ran at all, these exist (their redirects create
    # them even when empty). All absent => the pipeline was never launched, so
    # the hook exited before reaching it.
    echo "pipeline ran?  : review-stderr.log=$([[ -e "$STORE/logs/review-stderr.log" ]] && echo yes || echo no)" \
         "persist.log=$([[ -e "$STORE/logs/persist.log" ]] && echo yes || echo no)"
    echo "leftover tmp   : $(find "$STORE/logs" -name '.writer-stderr.*' 2>/dev/null | tr '\n' ' ')"
    echo "persist-failures.log:"; sed 's/^/    /' "$STORE/logs/persist-failures.log" 2>&1 || echo "    (absent)"
    # The precondition gates the hook can exit through, and the tools they need.
    # `command` is a shell BUILTIN, so `env -i ... command -v jq` cannot work --
    # env execs a file and there is none. It must go through a shell. Caught by
    # running this diagnostic under mutation M7 rather than by reading it.
    local probe
    for probe in jq python3 claude; do
        printf '%-15s: %s\n' "$probe" \
            "$(env -i PATH="$R/bin:$PATH" bash -c "command -v $probe" 2>&1 || echo '<NOT FOUND>')"
    done
    echo "fake claude -x : $([[ -x "$R/bin/claude" ]] && echo yes || echo no)"
    echo "--------------------------------------------------------------------"
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
# I) THE SECOND ROOT-CAUSE GUARD, read off the user's real accumulated
# MEMORY.md rather than off a failure log. Two shapes had accumulated there
# that the contract had never said anything about:
#
#   - 15 of 52 lines carried `[Title](some-lesson.md)` links. Memory is ONE
#     flat file; no such file exists, or ever will, so every one is dead.
#   - The same lesson appeared twice, and nothing told the Copilot CLI or
#     VS Code reviewers to read the file before proposing (that rule lived
#     only in session-review.sh's Claude Code preamble).
#
# Asserted against the recorded argv for the same reason case C is: a rule
# that does not reach the model is not a rule.
# ---------------------------------------------------------------------------
run_review 'printf "%s\n" "$*" > "$FAKE_PROMPT_LOG"
exit 0'
PROMPT="$(cat "$PROMPT_LOG")"
check "I: prompt forbids markdown file links in memory" "yes" \
    "$(emits "$PROMPT" "NO markdown file links")"
check "I: prompt says why (one flat file, no per-entry file)" "yes" \
    "$(emits "$PROMPT" "there is no")"
check "I: prompt requires reading the existing file first" "yes" \
    "$(emits "$PROMPT" "READ the existing file first")"
check "I: prompt says a repeated line is refused, not silently dropped" "yes" \
    "$(emits "$PROMPT" "Appending a line it already contains is")"

# ---------------------------------------------------------------------------
# J) The two enforcement halves end-to-end, which are deliberately DIFFERENT:
#
#   - a dangling markdown link is STRIPPED and the entry kept, because the
#     visible text carries the lesson and the target carried nothing. Refusing
#     it cost a whole paid review on 2026-07-29 (the live persist-failures.log
#     read "'](capture-exit-code-separately.md)' points at a file that does not
#     exist") -- memory AND skills discarded over one malformed line.
#
#   - a line already present in MEMORY.md is still REFUSED loudly (exit 2,
#     file untouched), because dropping it silently would discard something a
#     reader might have wanted and would hide a reviewer that never read the
#     file.
#
# Asserting both here is the point: it pins that "be lenient" was applied to
# the case that loses nothing, and NOT generalised to the case that does.
# ---------------------------------------------------------------------------
run_review "$(proposal_shim '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "append", "content": "- [Wait for CI](wait-for-ci.md) - dead link.\n"}]}')"
check "J: a dangling memory link no longer fails the review" "" "$(failure_line)"
check "J: the entry is written, not discarded" "yes" \
    "$([[ -e "$STORE/memory/MEMORY.md" ]] && echo yes || echo no)"
check "J: the lesson text survives the strip" "yes" \
    "$(grep -q -- "- Wait for CI - dead link." "$STORE/memory/MEMORY.md" && echo yes || echo no)"
check "J: the dead target is gone" "0" \
    "$(grep -c "wait-for-ci.md" "$STORE/memory/MEMORY.md" || true)"

run_review "$(proposal_shim '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "append", "content": "- already known\n"}]}')" \
    '- already known
'
LINE="$(failure_line)"
check "J: a duplicate line is refused loudly" "yes" "$(emits "$LINE" "already present in")"
# Pattern kept inside the writer's own repr() quotes on purpose: `emits` runs
# `grep -F "$2"`, and a pattern beginning with "- " is parsed as an option,
# not as text (this check reported a false FAIL until the quotes were added).
check "J: the refusal quotes the repeated line" "yes" "$(emits "$LINE" "'- already known'")"
check "J: the seeded file is left exactly as it was" "- already known" \
    "$(cat "$STORE/memory/MEMORY.md")"

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

# ---------------------------------------------------------------------------
# G) THE WINDOWS-CI GUARD. When the turn count cannot be READ, the hook must
# say so -- not score it as 0 turns and exit 0.
#
# `jq ... 2>/dev/null || echo "0"` collapsed "the JSON reader is broken or
# absent" into "0 turns", which is below every review threshold, so the hook
# exited 0 and the entire review pipeline was silently off. That is precisely
# what happened on windows-latest: Git Bash's /usr/bin carries no jq, this suite
# had amputated PATH, and the only trace left on disk was an empty logs/reviews/.
#
# The counter is now read by python3 (lib/jsonio.py) rather than jq, so the shim
# below breaks python3 instead -- the tool whose failure the guard must survive.
# It exits 127, exactly how the `|| echo` fallback behaved with the reader
# absent, and unlike a truly emptied PATH it is portable to every runner in the
# matrix.
# ---------------------------------------------------------------------------
G_DIR="$(mktemp -d)"
CASE_DIRS+=("$G_DIR")
mkdir -p "$G_DIR/home" "$G_DIR/store/state" "$G_DIR/store/logs" "$G_DIR/bin"
printf '#!/usr/bin/env bash\nexit 127\n' > "$G_DIR/bin/python3"
printf '#!/usr/bin/env bash\nexit 0\n' > "$G_DIR/bin/claude"
chmod +x "$G_DIR/bin/python3" "$G_DIR/bin/claude"
printf '%s\n' \
    '{"session_id":"g","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "$G_DIR/store/state/turn_counter.json"
sl_clear_review_marker "$G_DIR/store/logs"
echo '{"session_id":"g","hook_event_name":"Stop"}' \
    | env -i HOME="$G_DIR/home" AGENT_LEARNING_HOME="$G_DIR/store" \
          PATH="$G_DIR/bin:$PATH" bash "${SCRIPT_DIR}/scripts/session-review.sh"
check "G: an unreadable turn counter spawns no review" "0" \
    "$(sl_expect_no_review_spawned "$G_DIR/store/logs" >/dev/null 2>&1; echo $?)"
G_LOG="$(cat "$G_DIR/store/logs/persist-failures.log" 2>/dev/null || true)"
check "G: an unreadable turn counter is REPORTED, not scored as zero" "yes" \
    "$(emits "$G_LOG" "review NOT attempted")"
check "G: the report names the counter file it could not read" "yes" \
    "$(emits "$G_LOG" "total_turns_this_session")"

# ---------------------------------------------------------------------------
# H) A missing reviewer CLI must be reported. `if command -v claude; then ...
# fi` with no else branch is the same silent-no-op shape; review-common.sh has
# shipped sl_review_no_reviewer_available for it since Task 6, but only
# vscode-session-review.sh called it.
# ---------------------------------------------------------------------------
H_DIR="$(mktemp -d)"
CASE_DIRS+=("$H_DIR")
mkdir -p "$H_DIR/home" "$H_DIR/store/state" "$H_DIR/store/logs"
printf '%s\n' \
    '{"session_id":"h","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "$H_DIR/store/state/turn_counter.json"
# A PATH carrying the base tools but no `claude`, built the way
# tests/test-vscode-session-review.sh builds its NO_REVIEWER_PATH: the real
# directory of each tool, never a symlink farm (a symlinked python3 breaks
# outright when python3 is a pyenv/asdf shim, and this case would then "pass"
# for the wrong reason -- a missing interpreter, not a missing reviewer).
# A directory named `claude` on PATH does NOT work as a shadow: command -v
# skips non-executables and finds the real CLI further along. Measured here.
NO_CLAUDE_PATH=""
for tool in bash jq python3 date mkdir rm mv cat grep sed cut head tail find \
            dirname basename nohup sleep env chmod touch; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$tp" ]]; then
        echo "FAIL: H setup is wrong -- '$tool' is not resolvable on this machine"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    td="$(dirname "$tp")"
    case ":${NO_CLAUDE_PATH}:" in
        *":${td}:"*) ;;
        *) NO_CLAUDE_PATH="${NO_CLAUDE_PATH:+${NO_CLAUDE_PATH}:}${td}" ;;
    esac
done
# PROBE, not an assumption: where claude shares a directory with the base
# tools this construction cannot express "no reviewer", so skip with the
# reason printed rather than assert against a false premise.
if PATH="$NO_CLAUDE_PATH" command -v claude >/dev/null 2>&1; then
    echo "SKIP: H -- claude shares a directory with the base tools on this"
    echo "      machine (PATH=${NO_CLAUDE_PATH}), so a claude-free PATH cannot"
    echo "      be constructed this way."
else
    sl_clear_review_marker "$H_DIR/store/logs"
    echo '{"session_id":"h","hook_event_name":"Stop"}' \
        | env -i HOME="$H_DIR/home" AGENT_LEARNING_HOME="$H_DIR/store" \
              PATH="$NO_CLAUDE_PATH" bash "${SCRIPT_DIR}/scripts/session-review.sh"
    check "H: a missing reviewer CLI spawns no review" "0" \
        "$(sl_expect_no_review_spawned "$H_DIR/store/logs" >/dev/null 2>&1; echo $?)"
    check "H: a missing reviewer CLI is REPORTED" "yes" \
        "$(emits "$(cat "$H_DIR/store/logs/persist-failures.log" 2>/dev/null || true)" \
            "no reviewer CLI on PATH")"
fi

echo
if (( FAILURES > 0 )); then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "All checks passed"
