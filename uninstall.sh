#!/usr/bin/env bash
# uninstall.sh — single-command complete removal of the self-learning system.
#
# Usage:
#   bash uninstall.sh              # interactive confirm, removes EVERYTHING incl. learned data
#   bash uninstall.sh --keep-data  # keep MEMORY.md/USER.md, learned-skills/, search.db
#   bash uninstall.sh --yes        # skip confirmation (for scripts/CI)

set -euo pipefail

KEEP_DATA=false
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --keep-data) KEEP_DATA=true ;;
        --yes|-y)    ASSUME_YES=true ;;
        --help|-h)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [[ "$ASSUME_YES" != "true" ]]; then
    echo "This removes the self-learning system$([[ "$KEEP_DATA" == "true" ]] || echo " AND all learned data (memory, skills, session index)")."
    read -r -p "Continue? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

remove() { if [[ -e "$1" ]]; then rm -rf "$1"; echo "  removed: $1"; fi; }

# Resolve the vendor-neutral store exactly once, through paths.py — the sole
# resolver (global constraint). Best-effort: if python3 is unavailable this
# still cleans up the legacy ~/.claude location below, it just cannot also
# clean the resolved-path location (nothing to fall back to recompute with).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATHS_PY="${SCRIPT_DIR}/scripts/lib/paths.py"
SL_HOME="" SL_SCRIPTS="" SL_CONFIG_FILE="" SL_STATE="" SL_LOGS=""
if command -v python3 >/dev/null 2>&1 && [[ -f "$PATHS_PY" ]]; then
    while IFS='=' read -r _sl_key _sl_val; do
        # Fix round E, defence in depth: see scripts/lib/config.sh's identical
        # strip for the full rationale.
        _sl_val="${_sl_val%$'\r'}"
        case "$_sl_key" in
            home)        SL_HOME="$_sl_val" ;;
            scripts)     SL_SCRIPTS="$_sl_val" ;;
            config_file) SL_CONFIG_FILE="$_sl_val" ;;
            state)       SL_STATE="$_sl_val" ;;
            logs)        SL_LOGS="$_sl_val" ;;
        esac
    done < <(python3 "$PATHS_PY" all 2>/dev/null || true)
fi

echo "Removing installed components..."

# Legacy location (pre-neutral installs; design decision 5 — clean both).
remove "${HOME}/.claude/scripts/self-learning"
remove "${HOME}/.claude/self-learning.conf"
remove "${HOME}/.claude/self-learning.yaml"
remove "${HOME}/.claude/state/self-learning"
remove "${HOME}/.claude/logs/reviews"
remove "${HOME}/.claude/logs/curator"
remove "${HOME}/.claude/backups/curator"

# Resolved (vendor-neutral) location.
if [[ -n "$SL_SCRIPTS" ]]; then
    remove "$SL_SCRIPTS"
fi
if [[ -n "$SL_CONFIG_FILE" ]]; then
    remove "$SL_CONFIG_FILE"
fi
if [[ -n "$SL_STATE" ]]; then
    remove "$SL_STATE"
fi
if [[ -n "$SL_LOGS" ]]; then
    remove "${SL_LOGS}/reviews"
    remove "${SL_LOGS}/curator"
fi
if [[ -n "$SL_HOME" ]]; then
    remove "${SL_HOME}/backups/curator"
    # The rendered Claude Code hook JSON (install.sh Step 7). Leaving it behind
    # would strand a file whose every path points into the scripts dir removed
    # above -- a merge-me artifact that registers nothing.
    remove "${SL_HOME}/settings-hooks.json"
fi

# Copilot hook config — harness-owned directory, installed by this project.
remove "${HOME}/.copilot/hooks/self-learning.json"

# Strip our hooks from settings.json (backup first, keep everything else intact).
# Best-effort: this runs AFTER files are deleted, so it must never abort the
# uninstall — guard on jq, tolerate both the nested and legacy-flat hook schemas,
# and warn (not fail) if the edit cannot be applied.
SETTINGS="${HOME}/.claude/settings.json"
# Match our hooks by the SCRIPT NAMES they invoke, not by the literal string
# "self-learning". That string only ever appeared in the pre-Task-7b layout
# (~/.claude/scripts/self-learning/...); a correctly-registered hook today reads
# `bash ~/.local/share/agent-learning/scripts/turn-counter.sh`, which contains
# no such substring -- so both the gate below and the jq filter used to skip
# right past the hooks they exist to remove, and say nothing. The test only fed
# this the legacy shape, so nothing caught it.
SL_HOOK_PATTERN='self-learning|/(turn-counter|session-review|index-session)\.sh'
if [[ -f "$SETTINGS" ]] && grep -qE "$SL_HOOK_PATTERN" "$SETTINGS"; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "  jq not found — leaving settings.json unchanged; remove self-learning hooks manually" >&2
    else
        BAK="${SETTINGS}.pre-uninstall-$(date +%s)"
        stripped=false
        # settings.json may hold sensitive values; keep backup/temp files private.
        # Filter handles both schemas: nested groups ({matcher,hooks:[{command}]})
        # and legacy-flat entries ({matcher,command}).
        ( umask 077
          cp "$SETTINGS" "$BAK" && \
          jq --arg pat "$SL_HOOK_PATTERN" '
            if .hooks then
              .hooks |= map_values(
                map(if has("hooks")
                    then (.hooks |= map(select((.command // "") | test($pat) | not)))
                    else . end)
                | map(select(if has("hooks")
                             then ((.hooks | length) > 0)
                             else ((.command // "") | test($pat) | not) end))
              )
            else . end
          ' "$BAK" > "${SETTINGS}.tmp" 2>/dev/null
        ) && [[ -s "${SETTINGS}.tmp" ]] && jq . "${SETTINGS}.tmp" >/dev/null 2>&1 && stripped=true || true
        chmod 600 "$BAK" "${SETTINGS}.tmp" 2>/dev/null || true
        if [[ "$stripped" == "true" ]]; then
            mv "${SETTINGS}.tmp" "$SETTINGS"
            echo "  stripped self-learning hooks from settings.json (backup: $BAK)"
        else
            rm -f "${SETTINGS}.tmp" 2>/dev/null || true
            echo "  WARNING: could not edit settings.json automatically (backup: $BAK) — remove self-learning hooks manually" >&2
        fi
    fi
fi

if [[ "$KEEP_DATA" != "true" ]]; then
    echo "Removing learned data..."
    # Legacy location.
    remove "${HOME}/.claude/memory/MEMORY.md"
    remove "${HOME}/.claude/memory/USER.md"
    remove "${HOME}/.claude/learned-skills"
    remove "${HOME}/.claude/sessions/search.db"
    # Resolved (vendor-neutral) location.
    if [[ -n "$SL_HOME" ]]; then
        remove "${SL_HOME}/memory/MEMORY.md"
        remove "${SL_HOME}/memory/USER.md"
        remove "${SL_HOME}/learned-skills"
        remove "${SL_HOME}/sessions/search.db"
    fi
else
    echo "Learned data preserved (--keep-data)."
fi

echo "Uninstall complete."
