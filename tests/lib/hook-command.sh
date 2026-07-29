#!/usr/bin/env bash
# tests/lib/hook-command.sh
#
# Recover the script path out of a rendered hook command string.
#
# Several suites used to do this with `script="${cmd#bash }"` -- strip the
# literal interpreter prefix, treat everything after it as a path. That was
# only ever correct while the templates rendered an UNQUOTED path, which is
# the very defect the shell-level quoting fixes: with
# `bash '/home/u/My Store/scripts/x.sh'` the prefix strip yields a path with
# a leading and trailing apostrophe, `[[ -f ]]` says no, and the suite fails
# on a hook file that is entirely correct.
#
# Widening the strip by hand (peel a `'`, peel a `"`, peel a `bash -lc`) is
# the same character-class mistake lib/normalize-hook-path.py was written to
# get away from: the question is "how would the SHELL tokenize this", and
# only a tokenizer answers it. `shlex` in POSIX mode is that tokenizer, and
# python3 is already a hard prerequisite of every suite here.
#
# The command string goes in on STDIN, never as argv: python3 is a NATIVE
# Windows binary under Git Bash, so MSYS auto-converts POSIX-looking argv
# values crossing into it and would rewrite `/c/Users/...` to `C:/Users/...`
# on the way in -- changing the very string the caller is about to compare.
# Same reason install.sh feeds $SL_SCRIPTS to render-template.py on stdin.

# sl_hook_script_path <hook-command-string>
#
# Prints the last token of the command as the shell would tokenize it. A
# `-c`/`-lc` wrapper is unwrapped once (Copilot CLI's `powershell` value is
# `bash -lc "<a shell command>"`, so its last token is itself a command
# string, not a path). Prints nothing and returns 1 if the string does not
# tokenize -- a caller comparing against a real path then fails loudly
# rather than silently comparing against the empty string.
sl_hook_script_path() {
    printf '%s' "$1" | python3 -c '
import shlex, sys

def last_token(text):
    parts = shlex.split(text, posix=True)
    if not parts:
        raise ValueError("no tokens")
    # `bash -lc "<command>"` carries a nested command string, not a path.
    if len(parts) >= 3 and parts[-2].startswith("-") and "c" in parts[-2]:
        return last_token(parts[-1])
    return parts[-1]

sys.stdout.write(last_token(sys.stdin.read()))
' 2>/dev/null
}

# sl_hook_powershell_inner <powershell-hook-value>
#
# Model the PowerShell -> bash boundary for Copilot CLI's `powershell` field,
# which no machine in this project's CI can execute (docs/verification-log.md
# records the same limitation for the form itself).
#
# PowerShell parses the stored value as a command line, so the double quotes
# around the argument are PowerShell's own: they are consumed there, and
# `bash -lc` receives the text BETWEEN them as one argv element. bash then
# parses that element as shell input. Whatever quoting must survive to bash
# therefore has to be INSIDE those double quotes -- which is exactly why the
# outer `\"` the template already carried never protected anything.
#
# Prints the inner string, i.e. what bash's -c actually receives.
sl_hook_powershell_inner() {
    printf '%s' "$1" | python3 -c '
import re, sys
m = re.fullmatch(r"bash -lc \"(.*)\"", sys.stdin.read())
sys.stdout.write(m.group(1) if m else "")
' 2>/dev/null
}
