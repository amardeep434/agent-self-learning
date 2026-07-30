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

# Diagnostics go to persist-failures.log, never stdout. Resolving that path
# needs the store, and if python3 is missing we cannot resolve it -- so this
# one case writes to stderr, which hooks show to the user without corrupting
# the JSON contract on stdout.
if ! command -v python3 >/dev/null 2>&1; then
    echo "session-start-context: python3 is not on PATH -- no learned context injected" >&2
    exit 0
fi

exec python3 "${SCRIPT_DIR}/session-start-context.py"
