#!/usr/bin/env bash
# tests/test-no-python3-name.sh
#
# THE MACHINE THE OWNER ACTUALLY HAS. `winget install Python.Python.3.12` (this
# repo's own README) plus Git for Windows produces a box with `python.exe` and
# the `py` launcher and NO `python3` anywhere. Every script here shelled out to
# the literal name `python3`, so install.sh refused a perfectly good machine
# with "Missing required dependencies: python3".
#
# Six green Windows CI cells never saw it because .github/workflows/ci.yml used
# to COPY python.exe to python3.exe first -- CI manufactured the alias real
# Windows lacks. That step is deleted in the same commit as this file; without
# both halves the guard is decorative.
#
# Two variants, because Windows has two flavours of this:
#   (1) no python3 on PATH at all             -- App Execution Aliases off
#   (2) a FAKE Store `python3` in front of a real python -- aliases on, the
#       default. It passes any presence check, prints nothing useful and exits
#       nonzero, which used to turn a clear dependency error into a misleading
#       "could not resolve install paths via paths.py".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

# The real interpreter binary, via sys.executable rather than `command -v`: a
# pyenv/asdf shim needs the full ambient PATH and produces nothing under the
# restricted ones built below, which would make this suite fail for a reason
# that has nothing to do with the name `python3`.
_sl_py_name="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
REAL_PY=""
[[ -n "$_sl_py_name" ]] && REAL_PY="$("$_sl_py_name" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
if [[ -z "$REAL_PY" || ! -x "$REAL_PY" ]]; then
    echo "SKIP: no working Python 3 on this machine (probed python3/python, then sys.executable)."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# build_bin <dir> -- a PATH directory holding the tools the install/hook paths
# need, a real `python`, and DELIBERATELY no `python3`. Forwarders, not copies
# (a copied binary loses its DLL siblings under Git Bash; see
# tests/lib/path-compare.sh).
build_bin() {
    local dir="$1"
    mkdir -p "$dir"
    local tool tool_path
    for tool in bash sh env grep sed awk cat cut tr head tail sort wc date dirname \
                basename mkdir cp mv rm chmod ln find touch mktemp printf sleep \
                jq tar du id uname stat readlink; do
        tool_path="$(command -v "$tool" 2>/dev/null || true)"
        [[ -n "$tool_path" ]] && sl_forwarder "$tool_path" "${dir}/${tool}"
    done
    sl_forwarder "$REAL_PY" "${dir}/python"
}

# Probe-gated, in this project's style: assert the PATH we built really is
# python3-free rather than assuming it (the whole point of the suite is that a
# name's presence is not to be assumed either way).
PROBE_BIN="${TMP}/probe-bin"; build_bin "$PROBE_BIN"
if env -i PATH="$PROBE_BIN" HOME="$TMP" bash -c 'command -v python3' >/dev/null 2>&1; then
    echo "SKIP: could not construct a python3-free PATH here -- something on the"
    echo "  minimal PATH still resolves python3, so this suite would assert nothing."
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq is not installed, and turn-counter.sh refuses (loudly) without it,"
    echo "  so the end-to-end hook assertion below could not distinguish the two causes."
    exit 0
fi

# run_case <label> <bin-dir>
# Runs the three assertions that together describe "this machine works":
#   (a) install.sh gets past preflight
#   (b) config.sh resolves the SAME store paths.py does (round-tripped through
#       AGENT_LEARNING_HOME, so a bash fallback that ignored it would show)
#   (c) one real hook processes one real payload end to end
run_case() {
    local label="$1" bin="$2"
    local home="${TMP}/${label}-home" store="${TMP}/${label}-store"
    mkdir -p "$home" "$store"

    local dry_out dry_rc=0
    dry_out="$(env -i HOME="$home" PATH="$bin" AGENT_LEARNING_HOME="$store" \
        SL_CONFIG_FILE=/nonexistent \
        bash "${SCRIPT_DIR}/install.sh" --dry-run 2>&1)" || dry_rc=$?
    check "${label}: install.sh --dry-run passes preflight" "0" "$dry_rc"
    check "${label}: preflight does not report a missing dependency" "no" \
        "$(printf '%s' "$dry_out" | grep -qi 'Missing required depend' && echo yes || echo no)"
    check "${label}: paths still resolve (no misleading paths.py error)" "no" \
        "$(printf '%s' "$dry_out" | grep -qi 'could not resolve install paths' && echo yes || echo no)"

    local cfg_home
    cfg_home="$(env -i HOME="$home" PATH="$bin" AGENT_LEARNING_HOME="$store" \
        SL_CONFIG_FILE=/nonexistent \
        bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; printf '%s' \"\$SL_HOME\"" 2>/dev/null)"
    sl_check_same_path "${label}: config.sh resolves the store paths.py resolves" \
        "$store" "$cfg_home"

    local hook_rc=0
    printf '%s' '{"session_id":"npn","hook_event_name":"PostToolUse","tool_name":"Bash","transcript_path":"/tmp/x.jsonl"}' \
        | env -i HOME="$home" PATH="$bin" AGENT_LEARNING_HOME="$store" \
              SL_CONFIG_FILE=/nonexistent \
              bash "${SCRIPT_DIR}/scripts/turn-counter.sh" >/dev/null 2>&1 || hook_rc=$?
    check "${label}: turn-counter.sh exits 0 on a real payload" "0" "$hook_rc"
    check "${label}: turn-counter.sh actually wrote the counter" "yes" \
        "$([[ -f "${store}/state/turn_counter.json" ]] && echo yes || echo no)"
    check "${label}: the counter counted the turn" "1" \
        "$(env -i PATH="$bin" HOME="$home" bash -c \
            "jq -r '.total_turns_this_session' '${store}/state/turn_counter.json'" 2>/dev/null)"
    # The session id comes from the PAYLOAD, which only lib/jsonio.py can read
    # (turn-counter.sh's own counter file is jq-based, so counting alone would
    # still work with no interpreter at all and would not prove anything here).
    # Without a resolved interpreter this is the string "unknown", and every
    # per-session boundary downstream -- review triggers, the session index --
    # is computed from it.
    check "${label}: the payload's session id survived (jsonio ran)" "npn" \
        "$(env -i PATH="$bin" HOME="$home" bash -c \
            "jq -r '.session_id' '${store}/state/turn_counter.json'" 2>/dev/null)"
    check "${label}: nothing was recorded as a persistence failure" "no" \
        "$([[ -s "${store}/logs/persist-failures.log" ]] && echo yes || echo no)"
}

# (1) No python3 anywhere.
NOPY_BIN="${TMP}/nopy-bin"; build_bin "$NOPY_BIN"
run_case "no-python3" "$NOPY_BIN"

# (2) The Microsoft-Store stub in front of a real python. It exists, prints its
# advertisement to stderr and exits 9009 (the value cmd reports).
STUB_BIN="${TMP}/stub-bin"; build_bin "$STUB_BIN"
cat > "${STUB_BIN}/python3" <<'STUB'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store" >&2
exit 9009
STUB
chmod +x "${STUB_BIN}/python3"
run_case "store-stub" "$STUB_BIN"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All no-python3-name tests passed."
