#!/usr/bin/env bash
# scripts/lib/copilot-hook-input.sh
#
# Source this from the Copilot CLI sessionEnd hook entry script. Reads the
# hook payload JSON from stdin -- the ONLY channel Copilot CLI delivers it
# on; no argv arguments are passed (observed directly: a probe hook logged
# `ARGV: bash` with nothing further) -- and exports COPILOT_HOOK_* variables.
# Safe on empty, malformed, or absent (terminal) stdin.
#
# Copilot CLI sessionEnd payload, observed directly against a real session
# (Copilot CLI 1.0.75):
#   {"sessionId": "...", "timestamp": 1784982920820, "cwd": "...", "reason": "complete"}
# This is a DIFFERENT shape from Claude Code's hook payload (session_id,
# tool_name, hook_event_name, transcript_path -- see hook-input.sh), so it
# is parsed separately rather than shoehorned into that helper's field
# names.

_CHI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_CHI_LIB_DIR}/stdin-safe.sh"

_COPILOT_HOOK_RAW="$(sl_read_stdin_safe)"

COPILOT_HOOK_RAW="$_COPILOT_HOOK_RAW"

# ONE python3 spawn for all three fields, replacing three jq spawns (and the jq
# dependency). lib/jsonio.py prints exactly one line per requested key --
# missing or null included -- so these reads never shift out of step. None of
# these fields can contain a newline: sessionId is a uuid and cwd/reason are
# harness-generated.
{
    IFS= read -r COPILOT_HOOK_SESSION_ID
    IFS= read -r COPILOT_HOOK_CWD
    IFS= read -r COPILOT_HOOK_REASON
} < <(printf '%s' "$_COPILOT_HOOK_RAW" | python3 "${_CHI_LIB_DIR}/jsonio.py" get - \
        sessionId cwd reason 2>/dev/null)

# Empty default for every field, applied identically whether it was absent,
# null, empty, or the payload was unparseable (jsonio.py then printed nothing
# and the reads above left these unset).
: "${COPILOT_HOOK_SESSION_ID:=}"
: "${COPILOT_HOOK_CWD:=}"
: "${COPILOT_HOOK_REASON:=}"

export COPILOT_HOOK_RAW COPILOT_HOOK_SESSION_ID COPILOT_HOOK_CWD COPILOT_HOOK_REASON
