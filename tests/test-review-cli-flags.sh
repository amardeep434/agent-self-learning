#!/usr/bin/env bash
# tests/test-review-cli-flags.sh
#
# Do the flags our review scripts pass actually exist in the installed CLIs?
#
# WHY THIS EXISTS (fix-p9)
# -----------------------
# Both review scripts hand a fixed argv to a third-party binary they do not
# control, from a DETACHED pipeline. If a flag is wrong -- renamed upstream,
# never existed, silently ignored -- the reviewer exits non-zero, the failure
# lands in persist-failures.log, and learning simply stops. Nothing in this
# suite ever checked those flags against a real binary; the claims lived in
# a handoff document ("verify via `copilot --help` whether Copilot CLI has a
# turn cap") and were carried forward on trust.
#
# The trigger for writing it: a review of "unverifiable because the tool is
# absent locally" claims found that `pwsh` was absent HERE but present on
# GitHub's ubuntu runners, and that `claude` and `copilot` were installed on
# the dev box all along. "Absent locally" had been standing in for
# "unverifiable" without anyone checking.
#
# NO MODEL CALLS, AND NO SESSIONS (2026-07-30)
# ---------------------------------------------
# The paragraph that used to sit here claimed "no prompt is ever executed, so
# this costs no tokens and no quota". That was FALSE for one line. The
# acceptance probes were shaped `copilot --max-ai-credits 30 -p ""` and
# `claude --max-turns 16 -p ""` -- a syntactically VALID argv, which each CLI
# parses successfully and then rejects on the empty prompt. Copilot rejects it
# *after* opening a session.
#
# MEASURED 2026-07-30, this suite alone, against the developer's live store:
#   ~/.local/share/agent-learning        30990693 -> 30991006 bytes  (+313)
#   ~/.local/share/agent-learning/logs/persist.log  47045 -> 47358   (+313)
#   ~/.copilot/session-state/                    271 -> 272 entries  (+1)
# The +313 is the user's own installed sessionEnd hook firing on the session
# this test created. A test suite was writing to the store under test.
#
# Isolated in a sandboxed HOME, one invocation form at a time:
#   copilot --max-ai-credits 30 -p ""        sessions 0 -> 1   <-- the cause
#   copilot --sl-not-a-real-flag -p ""       sessions 1 -> 1   (errors first)
#   copilot --max-ai-credits 30 --help       sessions 0 -> 0
#   copilot --max-ai-credits 29 --help       sessions 0 -> 0
#   claude  --max-turns 16 -p ""             $HOME files 0 -> 2 (.claude/sessions)
#   claude  --max-turns 16 mcp list          sessions 0 -> 0
#
# So every probe below now parses the argv under test against a CHEAP
# SUBCOMMAND -- `copilot ... help limits` and `claude ... mcp list`. Both
# validate global options fully before the subcommand runs, both are
# read-only, and neither opens a session or calls a model.
#
# WHY NOT `--help`, THE OBVIOUS CHOICE
# ------------------------------------
# Because it is silently vacuous. MEASURED: `copilot --sl-not-a-real-flag
# --help` and `claude --sl-not-a-real-flag --help` BOTH print usage and exit
# 0, with no "unknown option" error -- commander prints help before it
# validates. An acceptance check phrased as "no error appeared" therefore
# passes for a flag that no longer exists. The first draft of this rewrite
# used `--help` and mutation testing caught it: mutations M3 and M5 (adding a
# flag the CLI rejects to the argv under test) both went UNDETECTED, suite
# exit 0. The subcommand form detects them.
#
# WHY THIS IS A STRONGER GUARD THAN WHAT IT REPLACES
# --------------------------------------------------
# The old control only proved "not rejected as unknown". Each acceptance
# probe here is paired with a deliberately-INVALID VALUE for the same flag:
#   copilot --max-ai-credits 29    -> error: ... argument '29' is invalid.
#                                     Use at least 30 AI credits.
#   claude  --max-turns notanumber -> error: option '--max-turns <turns>'
#                                     argument 'notanumber' is invalid
# Only a DECLARED option has a value validator, so this proves declared AND
# parsed AND validated, and it pins the credit MINIMUM (30) that
# copilot-session-review.sh validates against.
#
# Both invalid-value assertions additionally require the error NOT to be
# "unknown option". Mutation M1 showed why: `copilot help limits` prints the
# string "--max-ai-credits" in its own body, and a removed flag errors with
# "unknown option '--max-turns'" -- which also contains the flag name. A bare
# substring match passes in both cases. The error line must name the option
# AND not be the unknown-option error.
#
# MUTATION-TESTED 2026-07-30, six mutations, all six detected, suite exit 1:
#   M1 --max-ai-credits renamed away        -> control check FAILs
#   M2 credit floor asserted 31 not 30      -> floor check FAILs
#   M3 copilot argv gains a rejected flag   -> argv check FAILs
#   M4 --max-turns gone from claude         -> control check FAILs
#   M5 claude argv gains a rejected flag    -> tool-restriction check FAILs
#   M6 a `-p ""` probe is reintroduced      -> both session guards FAIL
#
# Capability-probed, never platform-branched: where a CLI is absent this
# says so loudly and moves on. Both are absent on CI runners, so in CI this
# suite reports what it could not check rather than pretending to pass.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

COPILOT_SCRIPT="${SCRIPT_DIR}/scripts/copilot-session-review.sh"
CLAUDE_SCRIPT="${SCRIPT_DIR}/scripts/session-review.sh"

# Feature-detect the timeout wrapper instead of calling `timeout` directly.
# Stock macOS has no `timeout` (GNU-only); Homebrew coreutils installs it as
# `gtimeout`. Every call site here is guarded by `|| true` or `&& ... || ...`,
# so a missing `timeout` does NOT abort under `set -e` -- it does something
# quieter and worse: the capture becomes the shell's own "timeout: command
# not found" text, every grep against it misses, and the suite reports up to
# seven spurious FAILs that read exactly like "the CLI dropped a flag".
# A false negative wearing the costume of a real finding.
#
# CI cannot catch this: neither `copilot` nor `claude` is installed on the
# runners, so both guarded blocks skip entirely and these lines never run.
# It would only ever bite a developer on macOS who has the CLIs -- i.e. the
# exact person this suite exists to serve. Reported by Copilot's review of
# PR #2 (comment 3652407788); the mechanism it named (a `set -e` abort) was
# wrong, the conclusion was right.
#
# Same detection as tests/run-all.sh:54-70, which this suite should have
# reused from the start -- an earlier round of this branch explicitly
# rejected a bare `timeout` wrapper for this reason (see progress.md), and
# this file reintroduced it.
#
# A function, not an array: macOS ships bash 3.2, where "${arr[@]}" on an
# empty array errors under `set -u`.
SL_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    SL_TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    SL_TIMEOUT_BIN="gtimeout"
else
    echo "[capability probe] timeout wrapper: UNAVAILABLE (neither 'timeout' nor" >&2
    echo "  'gtimeout' resolvable) -- CLI probes below run UNWRAPPED. A hung CLI" >&2
    echo "  will hang this suite with no automatic recovery. Install GNU coreutils" >&2
    echo "  ('brew install coreutils' on macOS) to restore it." >&2
fi

# run_probe <seconds> <command...> -- wrapped when a wrapper exists, direct
# otherwise, so the captured output is always the command's own.
run_probe() {
    local secs="$1"; shift
    if [[ -n "$SL_TIMEOUT_BIN" ]]; then
        "$SL_TIMEOUT_BIN" "$secs" "$@"
    else
        "$@"
    fi
}

# --- Regression guard 1 (source level, runs everywhere) --------------------
# The defect this suite carried for months was a single VALID argv ending in
# `-p ""`. It cost a live session dir, a write into the store under test, and
# a paid-credit risk -- and it read as harmless, because the header said so.
# Assert at the source level that no such invocation comes back. This runs on
# CI too, where neither CLI is installed and every runtime probe below skips,
# so it is the only guard that is always in force.
#
# Comment-stripped: the header above quotes the offending forms verbatim.
# Grepping the raw file would flag its own explanation -- the same
# false-positive class the --allow-tool check below already had to fix.
SELF_CODE="$(sed 's/#.*//' "${BASH_SOURCE[0]}")"
# Matches BOTH spellings. It matched only `-p`, so a future edit reintroducing
# `copilot --prompt ""` or `claude --prompt ""` would have kept this guard green
# while recreating the session -- and the runtime half only counts COPILOT
# session dirs, so a Claude long-form regression would have been invisible on
# both checks. Found by an independent (non-Claude) review.
check "this suite starts no CLI session (no '-p' invocation in code)" "yes" \
    "$(printf '%s' "$SELF_CODE" | grep -qE '(copilot|claude)[^|;]*[[:space:]](-p|--prompt)[[:space:]]' && echo no || echo yes)"

# --- Regression guard 2 (runtime, only where copilot is installed) ---------
# Belt and braces: count Copilot's session directories before and after. A
# BYTE/ENTRY COUNT, not the emptiness of a command's output -- reading silence
# as absence is the exact verification defect that let the original claim
# ("no tokens and no quota") stand unchallenged in this file's own header.
COPILOT_SESSION_DIR="${HOME}/.copilot/session-state"
# `2>/dev/null` silences ls's MESSAGE but not its EXIT STATUS. With
# `set -euo pipefail`, a missing session-state directory made `ls` fail,
# pipefail propagated it, and the assignment below aborted the whole suite --
# exit 2 (ls's own code) after a single PASS and with no FAIL line, which reads
# as a crash rather than a failed assertion. Green on this developer's machine,
# red on all six CI cells, because CI has no ~/.copilot at all.
#
# A machine that has never run Copilot has zero sessions; that is the answer,
# not an error. Guard on the directory instead of swallowing the status.
count_copilot_sessions() {
    [[ -d "$COPILOT_SESSION_DIR" ]] || { printf '0'; return 0; }
    ls -1 "$COPILOT_SESSION_DIR" | wc -l | tr -d ' '
}
SESSIONS_BEFORE="$(count_copilot_sessions)"

# --- GitHub Copilot CLI ----------------------------------------------------
if command -v copilot >/dev/null 2>&1; then
    echo "[capability probe] copilot: AVAILABLE"
    COPILOT_HELP="$(run_probe 60 copilot --help 2>&1 || true)"

    for flag in "--allow-tool" "--model" "-p, --prompt" "-s, --silent"; do
        check "copilot --help documents '${flag}'" "yes" \
            "$(printf '%s' "$COPILOT_HELP" | grep -qF -- "$flag" && echo yes || echo no)"
    done

    # The handoff required this to be STATED rather than silently omitted:
    # Copilot CLI has no turn cap, so copilot-session-review.sh cannot pass
    # one, and its cost control is the reviewer prompt plus --allow-tool
    # read. Pinned as a fact here so an upstream addition is noticed rather
    # than leaving us permanently without the cap we do apply to Claude Code.
    HAS_TURN_CAP="$(printf '%s' "$COPILOT_HELP" | grep -ciE 'max[-_]turns' || true)"
    if [[ "$HAS_TURN_CAP" == "0" ]]; then
        echo "PASS: copilot has no turn-cap flag (confirmed against the installed CLI,"
        echo "      which is why copilot-session-review.sh passes none)"
    else
        echo "FAIL: copilot NOW has a turn-cap flag -- wire SL_REVIEW_MAX_TURNS to it"
        FAILURES=$((FAILURES+1))
    fi

    # The cost ceiling the turn cap cannot provide. An earlier round
    # enumerated this CLI's flags and concluded --max-ai-credits did not
    # exist; re-derived here against 1.0.75, it does -- documented under
    # `copilot help limits`, with a stated minimum of 30. That minimum is
    # what scripts/copilot-session-review.sh validates against, so pin BOTH
    # the flag and the number: if either moves upstream, the knob's
    # validation is wrong and this must say so rather than silently drift.
    check "copilot documents '--max-ai-credits' (help topic: limits)" "yes" \
        "$(run_probe 60 copilot help limits 2>&1 | grep -qF -- '--max-ai-credits' && echo yes || echo no)"
    check "copilot's documented credit minimum is still 30" "yes" \
        "$(run_probe 60 copilot help limits 2>&1 | grep -qiE 'minimum: *30' && echo yes || echo no)"
    # PARSE TARGET: `help limits`. See the header for why it is not `--help`
    # and not `-p ""`. Global options are validated fully before the
    # subcommand runs, and no session is opened.
    #
    # Control: the CLI must reject an unknown option here, or "accepted"
    # below means nothing.
    COPILOT_UNKNOWN="$(run_probe 60 copilot --sl-definitely-not-a-real-flag help limits </dev/null 2>&1 || true)"
    check "copilot control: unknown flags DO error" "yes" \
        "$(printf '%s' "$COPILOT_UNKNOWN" | grep -qi "unknown option" && echo yes || echo no)"

    # EXISTENCE + FLOOR, from one probe. A value below the documented minimum
    # must be rejected by an error line that NAMES the option -- and must not
    # be the "unknown option" error, which is what a removed flag would give.
    # Those two conditions together are what separate "declared, parsed and
    # validated" from "gone upstream"; `help limits` PRINTS the string
    # "--max-ai-credits" in its own body, so a bare substring match on the
    # whole output passes even when the flag has been deleted (this exact
    # false pass was caught by mutation M1 before it shipped).
    COPILOT_CREDITS_LOW="$(run_probe 60 copilot --max-ai-credits 29 help limits </dev/null 2>&1 || true)"
    check "copilot control: --max-ai-credits validator still rejects 29" "yes" \
        "$(printf '%s' "$COPILOT_CREDITS_LOW" | grep -qiE 'error:.*max-ai-credits' && \
           ! printf '%s' "$COPILOT_CREDITS_LOW" | grep -qi 'unknown option' && echo yes || echo no)"
    check "copilot's rejection still names 30 as the floor" "yes" \
        "$(printf '%s' "$COPILOT_CREDITS_LOW" | grep -qiE 'error:.*at least 30' && echo yes || echo no)"

    # The full argv shape copilot-session-review.sh builds, parsed end to end.
    COPILOT_ARGV_ERR="$(run_probe 60 copilot --allow-tool read --max-ai-credits 30 help limits </dev/null 2>&1 || true)"
    check "copilot accepts the argv copilot-session-review.sh builds" "yes" \
        "$(printf '%s' "$COPILOT_ARGV_ERR" | grep -qiE 'error:|unknown option' && echo no || echo yes)"

    # And the script must not be passing anything the CLI does not accept.
    # Comment-stripped: the script CONTAINS the string "--allow-tool write"
    # in the comment explaining why it must never be passed. Grepping the
    # raw file flags that comment (it did, on this check's first run -- the
    # same false-positive class that the AST rewrite fixed in
    # test-store-lock-writers.py). Only code lines count.
    check "copilot-session-review.sh does not request the write tool" "yes" \
        "$(sed 's/#.*//' "$COPILOT_SCRIPT" | grep -q -- '--allow-tool write' && echo no || echo yes)"
else
    echo "[capability probe] copilot: NOT AVAILABLE -- the Copilot CLI flag checks did"
    echo "  NOT run. Reported, not silently passed. (CI runners have no copilot; this"
    echo "  suite is meaningful on a developer machine that does.)"
fi

# --- Claude Code CLI -------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
    echo "[capability probe] claude: AVAILABLE ($(run_probe 30 claude --version 2>/dev/null | head -1 || echo 'version unknown'))"
    CLAUDE_HELP="$(run_probe 60 claude --help 2>&1 || true)"
    check "claude --help documents '--output-format'" "yes" \
        "$(printf '%s' "$CLAUDE_HELP" | grep -qF -- "--output-format" && echo yes || echo no)"

    # --max-turns is NOT listed in `claude --help` on 2.1.220, but it IS
    # accepted. Absence from help text proves nothing either way, so this
    # uses a control experiment instead of grepping.
    #
    # The control used to be `claude --sl-not-a-real-flag -p ""` paired with
    # `claude --max-turns 16 -p ""`. The empty prompt is rejected before any
    # model call, so no tokens were spent -- but MEASURED 2026-07-30 in a
    # sandboxed HOME, the second form still created $HOME/.claude/sessions
    # (2 files) before erroring. A test for a vendor-neutral project should
    # not materialise a harness's private state directory to run.
    #
    # PARSE TARGET: `mcp list` -- read-only, no model call, no session, and
    # (measured) it validates global options before running. `--help` will
    # NOT do: `claude --sl-not-a-real-flag --help` prints usage and exits 0.
    UNKNOWN_ERR="$(run_probe 60 claude --sl-definitely-not-a-real-flag mcp list </dev/null 2>&1 || true)"
    CONTROL_OK="$(printf '%s' "$UNKNOWN_ERR" | grep -qi "unknown option" && echo yes || echo no)"
    if [[ "$CONTROL_OK" == "yes" ]]; then
        # --max-turns is NOT listed in `claude --help` on 2.1.220, but it IS
        # accepted, so grepping help text proves nothing either way. Probe the
        # declaration instead: a non-numeric argument must draw a validator
        # error that names the option AND is not "unknown option". A removed
        # --max-turns yields "error: unknown option '--max-turns'", which
        # names the option too -- excluding that string is what makes this
        # detect removal rather than rubber-stamp it.
        MAXTURNS_BAD="$(run_probe 60 claude --max-turns notanumber mcp list </dev/null 2>&1 || true)"
        check "claude control: --max-turns is a declared, validated option" "yes" \
            "$(printf '%s' "$MAXTURNS_BAD" | grep -qiE 'error:.*max-turns' && \
               ! printf '%s' "$MAXTURNS_BAD" | grep -qi 'unknown option' && echo yes || echo no)"
        MAXTURNS_OK="$(run_probe 60 claude --max-turns 16 mcp list </dev/null 2>&1 || true)"
        check "claude accepts --max-turns 16" "yes" \
            "$(printf '%s' "$MAXTURNS_OK" | grep -qiE 'error:|unknown option' && echo no || echo yes)"
    else
        echo "[capability probe] claude: the control experiment did not produce an"
        echo "  'unknown option' error, so this CLI cannot be probed this way. The"
        echo "  --max-turns checks are INCONCLUSIVE here -- reported, not assumed."
        printf '%s\n' "$UNKNOWN_ERR" | head -3 | sed 's/^/    /'
    fi

    check "session-review.sh passes a turn cap" "yes" \
        "$(grep -q -- '--max-turns' "$CLAUDE_SCRIPT" && echo yes || echo no)"

    # Global Constraint 5, checked against the REAL binary the same way
    # --max-turns is: both tool-restriction flags are documented in --help
    # here, and the control experiment above already established that this
    # CLI errors on unknown options -- so "documented and accepted" is a
    # real capability claim, not an assumption that an unknown flag would
    # be ignored.
    for flag in "--allowedTools" "--disallowedTools"; do
        check "claude --help documents '${flag}'" "yes" \
            "$(printf '%s' "$CLAUDE_HELP" | grep -qF -- "$flag" && echo yes || echo no)"
    done
    if [[ "$CONTROL_OK" == "yes" ]]; then
        RESTRICT_ERR="$(run_probe 60 claude --allowedTools "Read,Glob,Grep" \
            --disallowedTools "Write,Edit,NotebookEdit" --max-turns 16 mcp list </dev/null 2>&1 || true)"
        check "claude accepts the tool-restriction argv session-review.sh builds" "yes" \
            "$(printf '%s' "$RESTRICT_ERR" | grep -qiE 'error:|unknown option' && echo no || echo yes)"
    fi
else
    echo "[capability probe] claude: NOT AVAILABLE -- the Claude Code flag checks did"
    echo "  NOT run. Reported, not silently passed."
fi

# --- Regression guard 2, the measurement ------------------------------------
SESSIONS_AFTER="$(count_copilot_sessions)"
if [[ "$SESSIONS_BEFORE" == "$SESSIONS_AFTER" ]]; then
    echo "PASS: no Copilot session created by this suite (${COPILOT_SESSION_DIR}:" \
         "${SESSIONS_BEFORE} entries before and after)"
else
    echo "FAIL: this suite created Copilot session state -- ${COPILOT_SESSION_DIR}" \
         "went ${SESSIONS_BEFORE} -> ${SESSIONS_AFTER}. A probe above is running a"
    echo "      real session (and firing the user's sessionEnd hook into the live"
    echo "      store). Use the '<argv> --help' form instead of '-p'."
    FAILURES=$((FAILURES+1))
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All review-CLI flag tests passed."
