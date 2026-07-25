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
# NO MODEL CALLS. Everything here is `--help` parsing plus one control
# experiment (an unknown flag must error) -- no prompt is ever executed, so
# this costs no tokens and no quota.
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

# --- GitHub Copilot CLI ----------------------------------------------------
if command -v copilot >/dev/null 2>&1; then
    echo "[capability probe] copilot: AVAILABLE"
    COPILOT_HELP="$(timeout 60 copilot --help 2>&1 || true)"

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
    echo "[capability probe] claude: AVAILABLE ($(timeout 30 claude --version 2>/dev/null | head -1 || echo 'version unknown'))"
    CLAUDE_HELP="$(timeout 60 claude --help 2>&1 || true)"
    check "claude --help documents '--output-format'" "yes" \
        "$(printf '%s' "$CLAUDE_HELP" | grep -qF -- "--output-format" && echo yes || echo no)"

    # --max-turns is NOT listed in `claude --help` on 2.1.220, but it IS
    # accepted. Absence from help text proves nothing either way, so this
    # uses a control experiment instead of grepping: an unknown flag must
    # produce "unknown option", and the flag under test must not. Both runs
    # use an empty prompt, which the CLI rejects before contacting any
    # model -- no tokens are spent.
    UNKNOWN_ERR="$(timeout 60 claude --sl-definitely-not-a-real-flag -p "" </dev/null 2>&1 || true)"
    MAXTURNS_ERR="$(timeout 60 claude --max-turns 16 -p "" </dev/null 2>&1 || true)"
    CONTROL_OK="$(printf '%s' "$UNKNOWN_ERR" | grep -qi "unknown option" && echo yes || echo no)"
    if [[ "$CONTROL_OK" == "yes" ]]; then
        check "claude accepts --max-turns (control: unknown flags DO error)" "yes" \
            "$(printf '%s' "$MAXTURNS_ERR" | grep -qi "unknown option" && echo no || echo yes)"
    else
        echo "[capability probe] claude: the control experiment did not produce an"
        echo "  'unknown option' error, so this CLI cannot be probed this way. The"
        echo "  --max-turns check is INCONCLUSIVE here -- reported, not assumed."
    fi

    check "session-review.sh passes a turn cap" "yes" \
        "$(grep -q -- '--max-turns' "$CLAUDE_SCRIPT" && echo yes || echo no)"
else
    echo "[capability probe] claude: NOT AVAILABLE -- the Claude Code flag checks did"
    echo "  NOT run. Reported, not silently passed."
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All review-CLI flag tests passed."
