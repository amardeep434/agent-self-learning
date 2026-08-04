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

# One resolver for the interpreter (scripts/lib/python-resolve.sh):
# `python3` is a name real Windows Python installs never provide.
# Sourced here, not assumed from config.sh, because this file is also
# sourced directly (by its own suite, and by scripts that predate
# config.sh in their own load order). Re-resolution is free once
# SL_PYTHON is exported.
# shellcheck source=scripts/lib/python-resolve.sh
source "${_HI_LIB_DIR}/python-resolve.sh"
sl_resolve_python || true
# shellcheck disable=SC1091
source "${_HI_LIB_DIR}/stdin-safe.sh"

_HOOK_RAW="$(sl_read_stdin_safe)"

# ONE python3 spawn for all four fields, replacing four jq spawns (and the jq
# dependency). lib/jsonio.py prints exactly one line per requested key --
# missing or null included -- so these four reads never shift out of step.
# None of these fields can contain a newline: session ids and hook event names
# are schema-constrained, and a transcript path with an embedded newline would
# already have been unusable everywhere else in this project.
{
    IFS= read -r HOOK_SESSION_ID || true
    IFS= read -r HOOK_TOOL_NAME || true
    IFS= read -r HOOK_EVENT_NAME || true
    IFS= read -r HOOK_TRANSCRIPT_PATH || true
} < <(printf '%s' "$_HOOK_RAW" | "${SL_PYTHON}" "${_HI_LIB_DIR}/jsonio.py" get - \
        session_id tool_name hook_event_name transcript_path 2>/dev/null)

# Defaults, applied identically whether the field was absent, null, empty, or
# the payload was unparseable (in which case jsonio.py printed nothing at all
# and the reads above left these unset).
: "${HOOK_SESSION_ID:=unknown}"
: "${HOOK_TOOL_NAME:=unknown}"
: "${HOOK_EVENT_NAME:=unknown}"
: "${HOOK_TRANSCRIPT_PATH:=}"

export HOOK_SESSION_ID HOOK_TOOL_NAME HOOK_EVENT_NAME HOOK_TRANSCRIPT_PATH
