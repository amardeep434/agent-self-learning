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

echo "Removing installed components..."
remove "${HOME}/.claude/scripts/self-learning"
remove "${HOME}/.claude/self-learning.conf"
remove "${HOME}/.claude/self-learning.yaml"
remove "${HOME}/.copilot/hooks/self-learning.json"
remove "${HOME}/.claude/state/self-learning"
remove "${HOME}/.claude/logs/reviews"
remove "${HOME}/.claude/logs/curator"
remove "${HOME}/.claude/backups/curator"

# Strip our hooks from settings.json (backup first, keep everything else intact).
# Best-effort: this runs AFTER files are deleted, so it must never abort the
# uninstall — guard on jq, tolerate both the nested and legacy-flat hook schemas,
# and warn (not fail) if the edit cannot be applied.
SETTINGS="${HOME}/.claude/settings.json"
if [[ -f "$SETTINGS" ]] && grep -q self-learning "$SETTINGS"; then
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
          jq '
            if .hooks then
              .hooks |= map_values(
                map(if has("hooks")
                    then (.hooks |= map(select((.command // "") | test("self-learning") | not)))
                    else . end)
                | map(select(if has("hooks")
                             then ((.hooks | length) > 0)
                             else ((.command // "") | test("self-learning") | not) end))
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
    remove "${HOME}/.claude/memory/MEMORY.md"
    remove "${HOME}/.claude/memory/USER.md"
    remove "${HOME}/.claude/learned-skills"
    remove "${HOME}/.claude/sessions/search.db"
else
    echo "Learned data preserved (--keep-data)."
fi

echo "Uninstall complete."
