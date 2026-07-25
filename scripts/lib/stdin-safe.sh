#!/usr/bin/env bash
# scripts/lib/stdin-safe.sh
#
# sl_read_stdin_safe: print all of stdin, or nothing if stdin is a terminal.
# Both hook.sh (Claude Code) and copilot-hook-input.sh (Copilot CLI) receive
# their entire payload on stdin and nowhere else -- but doctor.sh and humans
# also run the scripts that source them directly from an interactive shell.
# A bare `cat` there blocks forever waiting for a Ctrl-D that normal usage
# never sends. `[[ -t 0 ]]` checks whether fd 0 is a terminal WITHOUT
# consuming any input, so it is safe to check before deciding whether to
# read at all.

sl_read_stdin_safe() {
    if [[ -t 0 ]]; then
        printf ''
        return 0
    fi
    cat 2>/dev/null || true
}
