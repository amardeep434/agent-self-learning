#!/usr/bin/env bash
# scripts/lib/hook-input.sh
#
# Source this from a Claude Code hook entry script. Reads the hook payload
# JSON from stdin (the ONLY channel Claude Code delivers hook data on) and
# exports HOOK_* variables. Safe on empty or malformed input.
#
# Claude Code hook payload fields used here:
#   session_id, tool_name, hook_event_name, transcript_path
#
# Reads via lib/stdin-safe.sh's sl_read_stdin_safe rather than a bare `cat`:
# doctor.sh and humans also run hook scripts directly from an interactive
# shell, where a bare `cat` on stdin blocks forever waiting for a Ctrl-D
# that never comes in normal usage.

_HI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_HI_LIB_DIR}/stdin-safe.sh"

_HOOK_RAW="$(sl_read_stdin_safe)"

_hook_field() {
    # $1 = jq field name, $2 = default
    local val
    val=$(printf '%s' "$_HOOK_RAW" | jq -r --arg d "$2" ".${1} // \$d" 2>/dev/null) || val="$2"
    [[ -z "$val" ]] && val="$2"
    printf '%s' "$val"
}

HOOK_SESSION_ID="$(_hook_field session_id unknown)"
HOOK_TOOL_NAME="$(_hook_field tool_name unknown)"
HOOK_EVENT_NAME="$(_hook_field hook_event_name unknown)"
HOOK_TRANSCRIPT_PATH="$(_hook_field transcript_path "")"

export HOOK_SESSION_ID HOOK_TOOL_NAME HOOK_EVENT_NAME HOOK_TRANSCRIPT_PATH
