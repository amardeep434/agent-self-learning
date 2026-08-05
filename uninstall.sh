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
# One resolver, shared with install.sh and config.sh: `command -v python3` is
# the wrong question on Windows, where working installs provide `python`/`py -3`
# and a fake Store `python3` may exist without being Python at all. Uninstall is
# where getting this wrong is worst -- the guards below decide whether the
# uninstaller can clean the resolved store at all.
# shellcheck source=scripts/lib/python-resolve.sh
source "${SCRIPT_DIR}/scripts/lib/python-resolve.sh"
sl_resolve_python || true
SL_HOME="" SL_SCRIPTS="" SL_CONFIG_FILE="" SL_STATE="" SL_LOGS=""
if [[ -n "${SL_PYTHON:-}" && -f "$PATHS_PY" ]]; then
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
    done < <("${SL_PYTHON}" "$PATHS_PY" all 2>/dev/null || true)
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
    # The rendered VS Code hook JSON (install.sh Step 4c), for the same
    # reason. Note this does NOT remove the `chat.hookFilesLocations` entry
    # from the user's VS Code settings.json -- this installer never wrote
    # it, so it does not delete it either; a location pointing at a file
    # that no longer exists is inert. Removing the entry is a one-line
    # manual step, printed by uninstall's summary.
    remove "${SL_HOME}/vscode-hooks.json"
fi

# Copilot hook config — harness-owned directory, installed by this project.
remove "${HOME}/.copilot/hooks/self-learning.json"

# Strip our hooks from settings.json (backup first, keep everything else intact).
# Best-effort: this runs AFTER files are deleted, so it must never abort the
# uninstall — guard on python3, tolerate both the nested and legacy-flat hook schemas,
# and warn (not fail) if the edit cannot be applied.
SETTINGS="${HOME}/.claude/settings.json"
# Match our hooks by the SCRIPT NAMES they invoke, not by the literal string
# "self-learning". That string only ever appeared in the pre-Task-7b layout
# (~/.claude/scripts/self-learning/...); a correctly-registered hook today reads
# `bash ~/.local/share/agent-learning/scripts/turn-counter.sh`, which contains
# no such substring -- so both the gate below and the filter used to skip
# right past the hooks they exist to remove, and say nothing. The test only fed
# this the legacy shape, so nothing caught it.
SL_HOOK_PATTERN='self-learning|/(turn-counter|session-review|index-session)\.sh'
if [[ -f "$SETTINGS" ]] && grep -qE "$SL_HOOK_PATTERN" "$SETTINGS"; then
    if [[ -z "${SL_PYTHON:-}" ]]; then
        echo "  no Python 3 found (tried python3, python, py -3) — leaving settings.json unchanged; remove self-learning hooks manually" >&2
    else
        BAK="${SETTINGS}.pre-uninstall-$(date +%s)"
        stripped=false
        # settings.json may hold sensitive values; keep backup/temp files private.
        # The filter handles both schemas: nested groups
        # ({matcher,hooks:[{command}]}) and legacy-flat entries
        # ({matcher,command}). It was a jq program until jq stopped being a
        # dependency of this project; python3 is already required by everything
        # else here.
        ( umask 077
          cp "$SETTINGS" "$BAK" && \
          SL_HOOK_PATTERN="$SL_HOOK_PATTERN" "${SL_PYTHON}" -c '
import json, os, re, sys

pattern = re.compile(os.environ["SL_HOOK_PATTERN"])


def keep(entry):
    if isinstance(entry, dict) and "hooks" in entry:
        entry["hooks"] = [h for h in entry["hooks"]
                          if not pattern.search((h or {}).get("command", ""))]
        return len(entry["hooks"]) > 0
    return not pattern.search((entry or {}).get("command", ""))


with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)
hooks = doc.get("hooks")
if isinstance(hooks, dict):
    doc["hooks"] = {event: [e for e in entries if keep(e)]
                    for event, entries in hooks.items()}
json.dump(doc, sys.stdout, indent=2)
sys.stdout.write("\n")
' "$BAK" > "${SETTINGS}.tmp" 2>/dev/null
        ) && [[ -s "${SETTINGS}.tmp" ]] \
          && "${SL_PYTHON}" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "${SETTINGS}.tmp" >/dev/null 2>&1 \
          && stripped=true || true
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

# --- Mirrored skills (Route A) ---
#
# mirror-skills.py publishes learned skills into each harness's own skills
# directory, which is the only place a harness discovers them. Those copies are
# DELIVERY artifacts, not the data, so they go even with --keep-data: the store
# copy under learned-skills/ is the data and survives that flag. Leaving them
# behind would have the harness keep loading learned skills with nothing left to
# manage, prune or update them.
#
# Removal is gated on the marker file mirror-skills.py writes, so this can only
# ever delete directories that script created. ~/.claude/skills is the user's own
# namespace -- it already held 21 hand-written skills on the machine this was
# built on, and an unmarked directory is never touched.
#
# The gate is DELEGATED to mirror-skills.py --uninstall-mirrors rather than
# reimplemented here. This block used to carry its own copy:
#
#     if [[ -f "${_dir}.self-learning-managed" ]]; then remove "${_dir%/}"; fi
#
# which is the bare filename-existence test mirror-skills.py's is_ours() was
# forced to ABANDON: an adversarial review destroyed real directories with it in
# three ways (a renamed user copy carrying a valid marker; a hand-dropped file of
# that name -- the name is documented in README.md and in this very file; a
# SYMLINK named that, because `.is_file()` follows links). The hardening landed in
# is_ours() and never reached here, so the delete loop with the WEAKER gate was
# the one pointed at the user's own directories. One implementation, one place to
# harden.
#
# Degraded, never silent, and never destructive: with no python3 (or no
# mirror-skills.py -- this file's sibling in the checkout it is run from; the
# store copy is deleted above) we CANNOT evaluate the gate, so we delete nothing
# and say so. Falling back to the weak test would be choosing the exact rule that
# destroyed data.
MIRROR_PY="${SCRIPT_DIR}/scripts/mirror-skills.py"
if [[ -n "${SL_PYTHON:-}" && -f "$MIRROR_PY" ]]; then
    "${SL_PYTHON}" "$MIRROR_PY" --uninstall-mirrors || \
        echo "  WARNING: some mirrored skill directories could not be removed" >&2
else
    # Deliberately does NOT say "delete any directory containing a
    # .self-learning-managed file". That is precisely the filename-only rule
    # this code refuses to apply, because it destroyed five user directories in
    # testing: a renamed copy of a mirrored skill carries a valid-looking
    # marker, as does a hand-dropped or symlinked one. Refusing to run the
    # unsafe rule ourselves and then instructing the human to run it by hand
    # would be the same data loss with an extra step.
    echo "  WARNING: no Python 3 (tried python3, python, py -3) or mirror-skills.py unavailable — mirrored skill" >&2
    echo "  directories under ~/.claude/skills and ~/.copilot/skills were NOT" >&2
    echo "  removed, and CANNOT be identified safely without Python 3: the" >&2
    echo "  marker file alone does not prove a directory is ours, so deleting" >&2
    echo "  on that basis can destroy your own skills." >&2
    echo "  To finish: install Python 3 and re-run this script, or run" >&2
    echo "    python <repo>/scripts/mirror-skills.py --uninstall-mirrors" >&2
    echo "  (use python3 or 'py -3' if that is the name your machine has)" >&2
    echo "  which applies the verified check." >&2
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
# The one registration this uninstaller cannot undo, said out loud rather
# than left for the user to discover: install.sh never edited VS Code's
# settings.json (it only printed the entry to add), so there is nothing here
# it may safely edit back out.
echo "If you registered the VS Code adapter, remove the ${SL_HOME:-<store>}/vscode-hooks.json"
echo "entry from \"chat.hookFilesLocations\" in your VS Code settings.json."
