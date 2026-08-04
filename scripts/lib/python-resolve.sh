#!/usr/bin/env bash
# scripts/lib/python-resolve.sh
#
# Single point of Python-3 resolution. python.org/winget/Store installs on
# Windows create `python.exe` and the `py` launcher but never `python3`;
# Windows also ships a fake Store `python3.exe` App Execution Alias that
# prints nothing useful and fails. So: presence is NOT enough -- a candidate
# counts only if `--version` succeeds and reports Python 3 (rule 3: probe,
# never infer from a platform name).
#
# Sourced by config.sh (every hook fire) and install.sh (preflight). Exports
# SL_PYTHON as an absolute path so `"${SL_PYTHON}"` stays one word
# everywhere -- including inside process substitutions and quoted command
# positions where a two-token `py -3` would word-split wrongly.

sl_resolve_python() {
    if [[ -n "${SL_PYTHON:-}" ]]; then
        return 0    # already resolved this process tree; keep hook cost flat
    fi
    local candidate resolved version
    for candidate in python3 python; do
        resolved="$(command -v "$candidate" 2>/dev/null)" || continue
        version="$("$resolved" --version 2>&1)" || continue
        [[ "$version" == Python\ 3* ]] || continue
        SL_PYTHON="$resolved"
        export SL_PYTHON
        return 0
    done
    # Windows py launcher last: `py -3` is two words, so ask it once for the
    # absolute interpreter path and store that instead.
    if command -v py >/dev/null 2>&1 && py -3 --version 2>&1 | grep -q '^Python 3'; then
        SL_PYTHON="$(py -3 -c 'import sys; print(sys.executable)')" \
            && [[ -n "$SL_PYTHON" ]] && export SL_PYTHON && return 0
    fi
    SL_PYTHON=""
    echo "agent-self-learning: no Python 3 found (tried: python3, python, py -3)." >&2
    echo "  On Windows: winget install Python.Python.3.12 -- and beware the fake" >&2
    echo "  Microsoft-Store 'python3' alias, which exists but is not Python." >&2
    return 1
}
