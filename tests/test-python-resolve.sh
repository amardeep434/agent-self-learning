#!/usr/bin/env bash
# tests/test-python-resolve.sh
#
# Pins scripts/lib/python-resolve.sh, the project's single point of Python-3
# resolution. It exists because the machine the README tells people to build
# (`winget install Python.Python.3.12` + Git for Windows) has `python.exe`
# and the `py` launcher and NEVER a `python3` -- while Windows ALSO ships a
# fake Microsoft-Store `python3.exe` App Execution Alias that exists on PATH,
# prints nothing useful and fails. So presence of a name proves nothing: a
# candidate counts only if it RUNS and reports Python 3.
#
# The fake-stub case (b) is the one that turns a clear "missing dependency"
# error into a misleading "could not resolve install paths" one on a default
# Windows box, so it is asserted here as its own case, not folded into (a).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

RESOLVER="${SCRIPT_DIR}/scripts/lib/python-resolve.sh"

# The interpreter the fake PATHs below will forward to. Resolved through
# sys.executable, NOT command -v: on a machine with pyenv/asdf, `command -v
# python3` is a SHIM that needs the full ambient PATH to find its target and
# fails silently under the `env -i` PATHs this suite builds -- which would
# make every case here fail for a reason that has nothing to do with the
# resolver. (That shim is itself a live example of why presence != working.)
_SL_PY_NAME="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
REAL_PY=""
[[ -n "$_SL_PY_NAME" ]] && REAL_PY="$("$_SL_PY_NAME" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
# Native Windows python prints \r\n; an unstripped \r here would leak into
# every fake this suite builds and make case (e) assert against TWO CRs.
REAL_PY="${REAL_PY//$'\r'/}"
if [[ -z "$REAL_PY" || ! -x "$REAL_PY" ]]; then
    echo "SKIP: no working Python 3 on this machine -- probed 'python3'/'python' and asked for sys.executable; nothing to resolve TO."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A minimal PATH holding only what the resolver itself needs (it runs
# `command -v` and `--version`, both builtins/execs) plus whichever Python
# names each case deliberately grants. Forwarders, not copies -- a copied
# binary loses its DLL siblings on Git Bash (see tests/lib/path-compare.sh).
mk_bin() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local tool tool_path
    for tool in bash sh grep sed cat printf env; do
        tool_path="$(command -v "$tool" 2>/dev/null || true)"
        [[ -n "$tool_path" ]] && sl_forwarder "$tool_path" "${dir}/${tool}"
    done
}

# ask <bindir> -- source the resolver on a restricted PATH and print SL_PYTHON
# (empty line + rc on failure). SL_PYTHON is deliberately unset in the child
# so each case exercises a real resolution, not an inherited one.
ask() {
    local bindir="$1"
    env -i HOME="$TMP/home" PATH="$bindir" \
        bash -c "source '${RESOLVER}'; if sl_resolve_python; then printf 'rc=0 %s\n' \"\$SL_PYTHON\"; else printf 'rc=1\n'; fi" 2>"$TMP/err"
}

# --- (d) a real python3 present -> picked, and it is the first name tried ---
D_BIN="$TMP/bin-d"; mk_bin "$D_BIN"
sl_forwarder "$REAL_PY" "${D_BIN}/python3"
sl_forwarder "$REAL_PY" "${D_BIN}/python"
OUT="$(ask "$D_BIN")"
# Leading-paren case patterns throughout these substitutions: macOS's default
# bash 3.2 misparses an unparenthesized `)` pattern inside $(...) — measured as
# 5 FAILs on the macos-latest cells; the (pattern) form is POSIX and both parse.
check "(d) real python3 present: resolves" "yes" \
    "$(case "$OUT" in ("rc=0 "*) echo yes ;; (*) echo no ;; esac)"
check "(d) python3 is preferred over python" "yes" \
    "$(case "$OUT" in (*"/python3") echo yes ;; (*) echo no ;; esac)"
check "(d) resolved interpreter actually runs and is Python 3" "yes" \
    "$(P="${OUT#rc=0 }"; [[ -x "$P" ]] && "$P" --version 2>&1 | grep -q '^Python 3' && echo yes || echo no)"

# --- (a) only a real `python` (no python3 anywhere) -> resolves to it ---
A_BIN="$TMP/bin-a"; mk_bin "$A_BIN"
sl_forwarder "$REAL_PY" "${A_BIN}/python"
OUT="$(ask "$A_BIN")"
check "(a) python-only PATH: resolves" "yes" \
    "$(case "$OUT" in ("rc=0 "*) echo yes ;; (*) echo no ;; esac)"
check "(a) python-only PATH: points at the python shim" "yes" \
    "$(case "$OUT" in (*"/python") echo yes ;; (*) echo no ;; esac)"

# --- (b) fake Microsoft-Store python3 stub in front of a real python ---
# The real stub prints "Python was not found; run without arguments to
# install from the Microsoft Store" to stderr and exits nonzero (9009 via
# cmd). Presence-only resolution picks it and everything downstream then
# fails with a wrong error message.
B_BIN="$TMP/bin-b"; mk_bin "$B_BIN"
cat > "${B_BIN}/python3" <<'STUB'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store" >&2
exit 9009
STUB
chmod +x "${B_BIN}/python3"
sl_forwarder "$REAL_PY" "${B_BIN}/python"
OUT="$(ask "$B_BIN")"
check "(b) Store stub skipped, real python chosen" "yes" \
    "$(case "$OUT" in (*"/python") echo yes ;; (*) echo no ;; esac)"
check "(b) resolved interpreter actually runs and is Python 3" "yes" \
    "$(P="${OUT#rc=0 }"; [[ -x "$P" ]] && "$P" --version 2>&1 | grep -q '^Python 3' && echo yes || echo no)"

# --- (c) no Python at all -> nonzero, and the error names all three names ---
C_BIN="$TMP/bin-c"; mk_bin "$C_BIN"
OUT="$(ask "$C_BIN")"
ERR="$(cat "$TMP/err")"
check "(c) no Python at all: resolver fails" "rc=1" "$OUT"
check "(c) failure names python3" "yes" "$(grep -q 'python3' <<<"$ERR" && echo yes || echo no)"
check "(c) failure names python"  "yes" "$(grep -q '\bpython\b' <<<"$ERR" && echo yes || echo no)"
check "(c) failure names py -3"   "yes" "$(grep -q 'py -3' <<<"$ERR" && echo yes || echo no)"
check "(c) failure names the Store-stub trap" "yes" \
    "$(grep -qi 'store' <<<"$ERR" && echo yes || echo no)"

# --- (e) py-launcher path arrives CRLF-terminated (native Windows py) ---
# `py -3 -c 'print(sys.executable)'` emits \r\n on native Windows; $() strips
# only the \n, so an unstripped capture stores "C:\...\python.exe\r" and every
# later "${SL_PYTHON}" invocation fails with a name no filesystem has. Fake py
# reproduces that byte-exactly; the resolver must hand back a \r-free path.
E_BIN="$TMP/bin-e"; mk_bin "$E_BIN"
cat > "${E_BIN}/py" <<PYEOF
#!/bin/sh
case "\$*" in
    (*--version*) printf 'Python 3.12.0\n' ;;
    (*) printf '%s\r\n' "${REAL_PY}" ;;
esac
PYEOF
chmod +x "${E_BIN}/py"
OUT="$(ask "$E_BIN")"
check "(e) py-launcher CRLF path: resolves" "yes" \
    "$(case "$OUT" in ("rc=0 "*) echo yes ;; (*) echo no ;; esac)"
check "(e) stored path carries no carriage return" "yes" \
    "$(case "$OUT" in (*$'\r'*) echo no ;; (*) echo yes ;; esac)"
check "(e) stored path is executable as stored" "yes" \
    "$(P="${OUT#rc=0 }"; [[ -x "$P" ]] && echo yes || echo no)"

# --- idempotence: an already-exported SL_PYTHON short-circuits (hook budget) ---
# Every hook fire sources config.sh; re-probing per call would add spawns to
# the <100ms budget. A pre-set SL_PYTHON must be honored verbatim, with no
# probe at all -- asserted by pre-setting it to a value the PATH cannot
# produce and requiring it back unchanged.
OUT="$(env -i HOME="$TMP/home" PATH="$D_BIN" SL_PYTHON="/preset/interpreter" \
    bash -c "source '${RESOLVER}'; sl_resolve_python && printf '%s\n' \"\$SL_PYTHON\"")"
check "already-resolved SL_PYTHON is not re-probed" "/preset/interpreter" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All python-resolve tests passed."
