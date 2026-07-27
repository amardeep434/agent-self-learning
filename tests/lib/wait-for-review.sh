#!/usr/bin/env bash
# tests/lib/wait-for-review.sh
#
# fix-p6 (macOS CI, tests/test-e2e-skill-visibility.sh): both session-review.sh
# and copilot-session-review.sh detach their ENTIRE pipeline (nohup + disown)
# because a real review can take minutes while the hook that launched it has
# a short timeout. A test driving either path for real therefore cannot know
# "the pipeline is done" from the parent `bash .../session-review.sh` call
# returning -- that call returns almost instantly, well before the detached
# grandchild has finished writing anything.
#
# Every test exercising this used to poll for ONE target file to appear
# (e.g. `[[ -f "$SKILLS_DIR/.../SKILL.md" ]]`) and treat that as "done".
# That is "a write started", not "the pipeline finished" -- persist-proposal.py
# can still be mid-write on OTHER files (a second skill, .usage.json, the
# memory file) when the polled-for file first appears. tests that only READ
# further state after that point got away with it by luck; a test that
# TEARS DOWN the tree right after (test-e2e-skill-visibility.sh's second
# scenario: `rm -rf "$TMP_HOME2"` immediately following its poll) raced a
# still-running writer directly: CI log showed `rm: .../store/logs:
# Directory not empty` -- a file appeared mid-delete. macOS 3.13 passed the
# same suite purely on timing; this is a race, not a version difference.
#
# The fix: scripts/session-review.sh and scripts/copilot-session-review.sh
# each now write an unconditional (success or failure) completion marker
# -- "$SL_LOG_DIR/.review-complete" -- as the LAST statement of their
# detached pipeline. sl_wait_for_review_complete polls for THAT, not for
# any file the pipeline's own OUTPUT might produce, so it is correct
# regardless of what the proposal did or didn't contain.
#
# Sourced by, never copied into, every shell suite that drives either
# review pipeline for real and then reads or deletes what it wrote.

# sl_wait_for_review_complete <log_dir> [max_iterations]
#
# Removes any pre-existing marker from a prior run in the same log_dir
# BEFORE the caller launches the pipeline (so a stale marker from an
# earlier invocation against the same store can never be mistaken for this
# run's completion) -- call this ONCE, right before launching the pipeline,
# then call sl_wait_for_review_complete after.
#
# Bounded polling with a sleep between checks (this repo's existing idiom,
# e.g. tests/test-copilot-session-review.sh, tests/test-session-review.sh),
# not a bare `sleep <N>`: a fixed sleep is either wastefully long on a fast
# runner or too short on a loaded one (this project's own fix-round-E note
# on windows-latest process-spawn overhead applies here too). Prints a full
# log-dir listing on timeout so a genuine hang is visible, not just "the
# assertion after this didn't find what it expected" -- which looks
# identical to a plain assertion failure in a bare CI log otherwise.
#
# Returns 0 if the marker appeared within budget, 1 on timeout (caller
# decides whether that's fatal).
sl_review_marker_path() {
    printf '%s/.review-complete' "$1"
}

sl_clear_review_marker() {
    rm -f "$(sl_review_marker_path "$1")" 2>/dev/null || true
}

sl_wait_for_review_complete() {
    local log_dir="$1"
    local max_iterations="${2:-150}"  # 150 * 0.2s = 30s, matching fix round E's widened budget
    local marker
    marker="$(sl_review_marker_path "$log_dir")"
    local _i
    for _i in $(seq 1 "$max_iterations"); do
        [[ -f "$marker" ]] && return 0
        sleep 0.2
    done
    echo "--- timed out waiting for ${marker} (detached review pipeline never signaled completion) ---"
    find "$log_dir" 2>&1 || echo "(log dir not even created: $log_dir)"
    return 1
}

# sl_expect_no_review_spawned <log_dir> [max_iterations]
#
# The mirror image of sl_wait_for_review_complete, for the cases that assert
# the pipeline was NOT launched (the recursion guard). Those cannot wait for
# a marker that is never supposed to arrive, but they must not simply assert
# "the log is still empty" a fixed 0.3s after the hook returned either: on a
# slow runner that passes even if the guard is broken and the spawn is merely
# late, i.e. it can only ever false-PASS. Watching for the marker for a
# bounded window and requiring that it never appears turns "we didn't see it
# yet" into "we looked for it for N*0.2s and it never came".
#
# Returns 0 when no marker appeared within the budget (the expected outcome),
# 1 if one did.
sl_expect_no_review_spawned() {
    local log_dir="$1"
    local max_iterations="${2:-10}"  # 10 * 0.2s = 2s
    local marker
    marker="$(sl_review_marker_path "$log_dir")"
    local _i
    for _i in $(seq 1 "$max_iterations"); do
        if [[ -f "$marker" ]]; then
            echo "--- a review pipeline DID run: ${marker} appeared ---"
            return 1
        fi
        sleep 0.2
    done
    return 0
}

# sl_rm_rf_retry <path> [max_tries]
#
# Defense in depth alongside sl_wait_for_review_complete, not a replacement
# for it: even after the marker confirms the pipeline's own last statement
# ran, `rm -rf` walks the tree top-down and a straggling write (e.g. the
# OS still flushing a just-closed file handle, or an unrelated background
# writer) can still occasionally lose the race by a few milliseconds. GNU
# and BSD `rm` both simply fail loudly ("Directory not empty" / similar) on
# this rather than retrying themselves, which is exactly what turned a
# fully-passing macOS suite into exit 1 under `set -euo pipefail`. A short,
# bounded retry absorbs that residual jitter without masking a REAL
# persistent failure (permissions, a stuck process still holding the dir
# open) -- those keep failing every retry and still error out at the end,
# loud, not silently swallowed.
#
# No GNU-only flags (`rm -rf` is POSIX); works identically under BSD rm
# (macOS) and GNU rm (Linux, Git Bash/MSYS on Windows).
sl_rm_rf_retry() {
    local path="$1"
    local max_tries="${2:-5}"
    local _t
    for _t in $(seq 1 "$max_tries"); do
        if rm -rf "$path" 2>/dev/null; then
            [[ -e "$path" ]] || return 0
        fi
        [[ -e "$path" ]] || return 0
        sleep 0.2
    done
    # Final attempt, not suppressed -- if this is a genuine (non-race)
    # failure, surface it rather than silently leaving the temp dir behind.
    rm -rf "$path"
}
