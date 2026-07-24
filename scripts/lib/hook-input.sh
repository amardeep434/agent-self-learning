#!/usr/bin/env bash
# scripts/lib/hook-input.sh
#
# Source this from a Claude Code hook entry script. Reads the hook payload
# JSON from stdin (the ONLY channel Claude Code delivers hook data on) and
# exports HOOK_* variables. Safe on empty or malformed input.
#
# Claude Code hook payload fields used here:
#   session_id, tool_name, hook_event_name, transcript_path

_HOOK_RAW="$(cat 2>/dev/null || true)"

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
