#!/usr/bin/env bash
# session-start-context.sh — SessionStart hook entry point.
#
# A three-line wrapper around session-start-context.py, which does the work.
# It exists so that EVERY hook this project registers has the same shape,
# `bash '<scripts-dir>/<name>.sh'`:
#
#   - config/*.json carry a __SL_SCRIPTS_DIR__ placeholder that install.sh
#     substitutes, and the surrounding machinery (lib/normalize-hook-path.py,
#     tests/lib/hook-command.sh, the quoting suites) all assumes that form.
#     A `python3 '<...>.py'` command is a second shape for that machinery to
#     understand, and the MSYS/native argv boundary has already broken this
#     project four times in one day. One shape, one set of quoting rules.
#   - Copilot's config additionally needs a `powershell` sibling for the same
#     hook; keeping the payload a bash script means the Windows variant stays
#     the same `bash -lc "'...'"` form used by the existing hooks.
#
# Costs one extra process (~5ms). Measured budget for the whole hook is 43ms
# with a native python3.
#
# `exec` matters: the Python process inherits this hook's stdin (the payload)
# and its stdout IS the hook's stdout. Nothing may be echoed here -- Copilot
# concatenates all non-progress stdout and runs a single JSON.parse, so one
# stray line silently kills the injection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The interpreter is resolved by name-independent probe, not by `command -v
# python3`: real Windows Python installs provide `python`/`py -3` and never
# `python3`. This script does not source config.sh (it must stay a three-line
# wrapper), so it sources the resolver directly -- same single resolver.
# shellcheck source=scripts/lib/python-resolve.sh
source "${SCRIPT_DIR}/lib/python-resolve.sh"
sl_resolve_python || true

# Diagnostics go to persist-failures.log, never stdout. Resolving that path
# needs the store, and if Python is missing we cannot resolve it -- so this
# one case writes to stderr, which hooks show to the user without corrupting
# the JSON contract on stdout.
if [[ -z "${SL_PYTHON:-}" ]]; then
    # `{}` on STDOUT, not just a note on stderr. session-start-context.py exists
    # to guarantee "exactly one JSON object" precisely because printing nothing
    # is indistinguishable from the hook never running -- and this branch, the
    # one nothing tested, violated that contract. stderr still carries the
    # reason for a human.
    echo "{}"
    echo "session-start-context: no Python 3 on PATH (tried python3, python, py -3) -- no learned context injected" >&2
    exit 0
fi

# Publish learned skills where each harness natively looks (Route A). Launched
# DETACHED and after the JSON is on stdout, for three reasons:
#   - the hook budget is <100ms and the injection above already spends ~43ms;
#     mirroring 46 skill directories has no business inside that budget;
#   - its stdout must never reach this hook's stdout. Copilot concatenates all
#     non-progress stdout and runs one JSON.parse, so a single summary line from
#     the mirror would silently kill the injection;
#   - it is idempotent and self-healing, so missing a run costs nothing: the
#     next session start picks up whatever the last review wrote and prunes
#     whatever the curator archived.
# `|| _status=$?` and NOT a bare call: under `set -e` a failing simple command
# exits the shell immediately, so with a bare call everything below here --
# including the mirror launch and this file's own `exit` -- was unreachable on
# any nonzero exit from the injector. Measured: the wrapper exited 3 and printed
# nothing after. Route A was silently skipped as collateral damage whenever
# Route B failed, which is precisely the coupling the detached launch exists to
# avoid.
_status=0
"${SL_PYTHON}" "${SCRIPT_DIR}/session-start-context.py" || _status=$?

# Launched UNCONDITIONALLY and before the exit: mirroring skills does not depend
# on the memory injection having succeeded, and the two failing together was a
# bug, not a policy.
if [[ -f "${SCRIPT_DIR}/mirror-skills.py" ]]; then
    nohup "${SL_PYTHON}" "${SCRIPT_DIR}/mirror-skills.py" --quiet >/dev/null 2>&1 &
    disown 2>/dev/null || true
fi

# The hook's exit status is the injector's. A nonzero status here is not fatal to
# a session -- the harness treats it as "no context" -- but it must not be
# swallowed, or a persistently broken injector looks identical to an empty store.
exit "$_status"
