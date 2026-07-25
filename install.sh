#!/usr/bin/env bash
#
# One-command installer for the agent-self-learning system.
#
# Creates directories, copies scripts, initializes the SQLite database,
# and prints instructions for registering hooks with each harness.
#
# Usage:
#   bash install.sh              # Install everything
#   bash install.sh --dry-run    # Preview what would be done
#   bash install.sh --uninstall  # Remove installed files (delegates to uninstall.sh)
#
# Prerequisites:
#   - jq, python3 must be installed
#   - sqlite3 (the CLI) is optional: fix-p6 moved session-search schema
#     init off the CLI and onto python3's own bundled sqlite3 module (which
#     macOS's system CLI often lacks FTS5 support for, unlike Python's), so
#     nothing in this script shells out to the `sqlite3` binary anymore.
#     Only self-learning-health.sh's diagnostic DB check still uses it,
#     already gracefully degrading (a warning, not a failure) if absent.
#
# Install locations are resolved by scripts/lib/paths.py (vendor-neutral;
# never inside ~/.claude by default). Claude Code and GitHub Copilot CLI are
# adapters on top of that shared store, never a dependency of it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --uninstall)
            if [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]; then
                exec bash "${SCRIPT_DIR}/uninstall.sh"
            else
                echo "Error: uninstall.sh not found" >&2
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: bash install.sh [--dry-run | --uninstall]"
            echo ""
            echo "  --dry-run    Preview what would be done without making changes"
            echo "  --uninstall  Remove installed files (delegates to uninstall.sh)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# --- Helpers ---

do_mkdir() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] mkdir -p $1"
    else
        mkdir -p "$1"
        echo "  Created: $1"
    fi
}

do_copy() {
    local src="$1"
    local dst="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] cp $src -> $dst"
    else
        cp "$src" "$dst"
        echo "  Copied:  $(basename "$src") -> $dst"
    fi
}

do_chmod() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] chmod +x $1"
    else
        chmod +x "$1"
    fi
}

# --- Preflight checks ---

echo "=== agent-self-learning Installer ==="
echo ""

MISSING_DEPS=()
for cmd in jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "Error: Missing required dependencies: ${MISSING_DEPS[*]}" >&2
    echo "Install them before running this script." >&2
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN MODE -- no changes will be made]"
    echo ""
fi

# --- Resolve every install path exactly once, through paths.py ---
#
# Global constraint: paths are computed in exactly one place
# (scripts/lib/paths.py). Bash obtains paths by calling it, once, here — never
# by recomputing them or calling paths.py in a loop.

PATHS_PY="${SCRIPT_DIR}/scripts/lib/paths.py"
if [[ ! -f "$PATHS_PY" ]]; then
    echo "Error: ${PATHS_PY} not found" >&2
    exit 1
fi

SL_HOME="" SL_STATE="" SL_SKILLS="" SL_MEMORY="" SL_LOGS="" \
SL_SESSIONS_DB="" SL_CONFIG_FILE="" SL_SCRIPTS=""
while IFS='=' read -r _sl_key _sl_val; do
    # Fix round E, defence in depth: see scripts/lib/config.sh's identical
    # strip for the full rationale -- paths.py's stdout is now forced to
    # LF-only, making this a no-op in practice, but `read` never strips a
    # \r that isn't the record terminator itself, so this stays as a cheap
    # second layer against a stray one corrupting every resolved path.
    _sl_val="${_sl_val%$'\r'}"
    case "$_sl_key" in
        home)        SL_HOME="$_sl_val" ;;
        state)       SL_STATE="$_sl_val" ;;
        skills)      SL_SKILLS="$_sl_val" ;;
        memory)      SL_MEMORY="$_sl_val" ;;
        logs)        SL_LOGS="$_sl_val" ;;
        sessions_db) SL_SESSIONS_DB="$_sl_val" ;;
        config_file) SL_CONFIG_FILE="$_sl_val" ;;
        scripts)     SL_SCRIPTS="$_sl_val" ;;
    esac
done < <(python3 "$PATHS_PY" all)

if [[ -z "$SL_HOME" || -z "$SL_SCRIPTS" ]]; then
    echo "Error: could not resolve install paths via ${PATHS_PY}" >&2
    exit 1
fi

echo "Install target (resolved by paths.py): ${SL_HOME}"
echo ""

# Legacy-install detection (design decision 4): preserve-and-notify, never
# migrate. This only reads ~/.claude to decide whether to print a note; it
# never writes to or moves anything under it.
# fix-p6: the lib directory used to be baked into the -c source string as
# a bash-interpolated literal (`sys.path.insert(0, '${SCRIPT_DIR}/...')`).
# Git Bash only auto-translates POSIX-style paths to Windows form when they
# appear as their own argv token passed to a native executable, not when
# baked into the middle of a quoted -c string -- passed as sys.argv[1]
# instead, the same safe pattern doctor.sh's own legacy-home probe and
# tests/lib/path-compare.sh's sl_legacy_home already use.
LEGACY_HOME="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import paths
found = paths.legacy_home()
print(found or '')
" "${SCRIPT_DIR}/scripts/lib" 2>/dev/null || true)"

if [[ -n "$LEGACY_HOME" ]]; then
    echo "NOTE: a legacy install was found at ${LEGACY_HOME}."
    echo "      It is left untouched and will keep working as-is."
    echo "      This install writes to the vendor-neutral store above instead;"
    echo "      the two are independent until you migrate deliberately."
    echo ""
fi

# --- Step 1: Create directories ---

echo "Step 1: Creating directories..."

DIRS=(
    "$SL_STATE"
    "$SL_SKILLS"
    "${SL_SKILLS}/.archive"
    "$(dirname "$SL_SESSIONS_DB")"
    "${SL_LOGS}/reviews"
    "${SL_LOGS}/curator"
    "${SL_HOME}/backups/curator"
    "$SL_SCRIPTS"
    "${SL_SCRIPTS}/prompts"
    "$SL_MEMORY"
)

for dir in "${DIRS[@]}"; do
    do_mkdir "$dir"
done

echo ""

# --- Step 2: Copy scripts ---

echo "Step 2: Copying scripts..."

SCRIPTS=(
    "turn-counter.sh"
    "session-review.sh"
    "index-session.sh"
    "index-session.py"
    "scan-threats.py"
    "skill-lifecycle.py"
    "curator-run.sh"
    "self-learning-health.sh"
    "copilot-session-review.sh"
    "inject-agents-md.py"
    "coach-rules-eval.py"
    "coach-export-read.py"
    "coach-signals.py"
    "skillopt-run.sh"
    "persist-proposal.py"
    "doctor.sh"
)

DEST_DIR="$SL_SCRIPTS"

for script in "${SCRIPTS[@]}"; do
    src="${SCRIPT_DIR}/scripts/${script}"
    if [[ -f "$src" ]]; then
        do_copy "$src" "${DEST_DIR}/${script}"
        do_chmod "${DEST_DIR}/${script}"
    else
        # M14: this used to print a [WARN] and continue, exiting 0 -- a
        # missing script (potentially the writer itself, or something it
        # imports) became a warning buried in a long log plus a successful
        # exit. A script named in this file's own SCRIPTS array that is
        # missing from the source tree means the install is broken; report
        # that as fatal, not cosmetic.
        echo "  [FAIL] Script not found: $src" >&2
        echo "Error: install.sh's SCRIPTS array names '${script}', but it does not exist" >&2
        echo "at ${src}. This install is incomplete; refusing to continue." >&2
        exit 1
    fi
done

echo ""
echo "Step 2b: Copying shared libraries..."
do_mkdir "${DEST_DIR}/lib"
for lib in "${SCRIPT_DIR}/scripts/lib/"*.sh; do
    if [[ -f "$lib" ]]; then
        do_copy "$lib" "${DEST_DIR}/lib/$(basename "$lib")"
    fi
done
# Python libraries too (e.g. paths.py, proposal_schema.py) — a loop, not a
# hand-listed file, so a future library is never silently dropped the way
# proposal_schema.py originally was: persist-proposal.py (in SCRIPTS above)
# imports it from its own installed directory's lib/, and a missing import
# fails the whole persistence pipeline on a real install with no error
# surfaced above the hook layer — exactly the defect this project exists to
# eliminate.
for lib in "${SCRIPT_DIR}/scripts/lib/"*.py; do
    if [[ -f "$lib" ]]; then
        do_copy "$lib" "${DEST_DIR}/lib/$(basename "$lib")"
    fi
done

echo ""

# --- Step 3: Copy prompts (if present) ---

echo "Step 3: Copying prompt templates..."

PROMPTS_SRC="${SCRIPT_DIR}/prompts"
PROMPTS_DST="${DEST_DIR}/prompts"

if [[ -d "$PROMPTS_SRC" ]]; then
    PROMPT_COUNT=0
    for prompt_file in "${PROMPTS_SRC}"/*.md; do
        if [[ -f "$prompt_file" ]]; then
            do_copy "$prompt_file" "${PROMPTS_DST}/$(basename "$prompt_file")"
            PROMPT_COUNT=$((PROMPT_COUNT + 1))
        fi
    done
    if [[ "$PROMPT_COUNT" -eq 0 ]]; then
        echo "  No prompt templates found in ${PROMPTS_SRC}/"
    fi
else
    echo "  No prompts/ directory found (optional)"
fi

echo ""

# --- Step 3b: Copy vendored Coach rules (if present) ---

echo "Step 3b: Copying vendored Coach rules..."

COACH_RULES_SRC="${SCRIPT_DIR}/vendor/coach-rules"
COACH_RULES_DST="${DEST_DIR}/coach-rules"

if [[ -d "$COACH_RULES_SRC" ]]; then
    do_mkdir "$COACH_RULES_DST"
    COACH_RULE_COUNT=0
    for rule_file in "${COACH_RULES_SRC}"/*.md; do
        if [[ -f "$rule_file" ]]; then
            do_copy "$rule_file" "${COACH_RULES_DST}/$(basename "$rule_file")"
            COACH_RULE_COUNT=$((COACH_RULE_COUNT + 1))
        fi
    done
    if [[ "$COACH_RULE_COUNT" -eq 0 ]]; then
        echo "  No Coach rule files found in ${COACH_RULES_SRC}/"
    fi
else
    echo "  No vendor/coach-rules/ directory found (optional)"
fi

echo ""

# --- Step 4: Copy config (if present) ---

echo "Step 4: Copying configuration..."

CONFIG_SRC="${SCRIPT_DIR}/config/self-learning.conf"
CONFIG_DST="$SL_CONFIG_FILE"

if [[ -f "$CONFIG_SRC" ]]; then
    if [[ -f "$CONFIG_DST" ]]; then
        echo "  Config already exists at $CONFIG_DST -- skipping (will not overwrite)"
    else
        do_copy "$CONFIG_SRC" "$CONFIG_DST"
    fi
else
    echo "  No config/self-learning.conf found (optional)"
fi

echo ""
echo "Step 4b: Copilot CLI adapter (optional)..."
if [[ -d "${HOME}/.copilot" ]]; then
    do_mkdir "${HOME}/.copilot/hooks"
    COPILOT_HOOK_SRC="${SCRIPT_DIR}/config/copilot-hooks.json"
    COPILOT_HOOK_DST="${HOME}/.copilot/hooks/self-learning.json"
    if [[ -f "$COPILOT_HOOK_DST" ]]; then
        echo "  Already exists: $COPILOT_HOOK_DST (skipping)"
    elif [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] render ${COPILOT_HOOK_SRC} -> ${COPILOT_HOOK_DST} (__SL_SCRIPTS_DIR__ -> ${SL_SCRIPTS})"
    else
        sed "s|__SL_SCRIPTS_DIR__|${SL_SCRIPTS}|g" "$COPILOT_HOOK_SRC" > "$COPILOT_HOOK_DST"
        echo "  Rendered: copilot-hooks.json -> $COPILOT_HOOK_DST"
    fi
else
    echo "  ~/.copilot not found — Copilot CLI not installed; skipping (re-run install.sh after installing it)"
fi

echo ""

# --- Step 5: Copy and initialize SQLite schema ---

echo "Step 5: Initializing session search database..."

SCHEMA_SRC="${SCRIPT_DIR}/schema/session-search-schema.sql"
SCHEMA_DST="${DEST_DIR}/session-search-schema.sql"
FTS5_SCHEMA_SRC="${SCRIPT_DIR}/schema/session-search-fts5.sql"
FTS5_SCHEMA_DST="${DEST_DIR}/session-search-fts5.sql"
DB_PATH="$SL_SESSIONS_DB"

if [[ -f "$SCHEMA_SRC" ]]; then
    do_copy "$SCHEMA_SRC" "$SCHEMA_DST"
    [[ -f "$FTS5_SCHEMA_SRC" ]] && do_copy "$FTS5_SCHEMA_SRC" "$FTS5_SCHEMA_DST"

    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ ! -f "$DB_PATH" ]]; then
            # fix-p6 (macOS CI): this used to be `sqlite3 "$DB_PATH" <
            # "$SCHEMA_DST"` via the `sqlite3` CLI, which failed silently
            # on macOS -- its bundled CLI commonly lacks FTS5, and its
            # batch mode does not reliably surface a non-zero exit for a
            # mid-script error. session_db.py applies the same schema via
            # Python's own sqlite3 module (raises immediately on a real
            # failure) and gates the FTS5-only part behind a functional
            # probe -- see scripts/lib/session_db.py's module docstring.
            if ! SCHEMA_RESULT=$(python3 "${DEST_DIR}/lib/session_db.py" \
                    ensure-schema "$DB_PATH" "$SCHEMA_DST" "$FTS5_SCHEMA_DST" 2>&1); then
                echo "  FATAL: failed to initialize session search database ($DB_PATH): $SCHEMA_RESULT" >&2
                exit 1
            fi
            if [[ "$SCHEMA_RESULT" == no-fts5:* ]]; then
                echo "  WARNING: ${SCHEMA_RESULT#no-fts5:} -- full-text search degraded to substring (LIKE) matching."
            fi
            echo "  Initialized: $DB_PATH"
        else
            echo "  Database already exists: $DB_PATH (skipping)"
        fi
    else
        echo "[DRY RUN] python3 ${DEST_DIR}/lib/session_db.py ensure-schema $DB_PATH $SCHEMA_DST $FTS5_SCHEMA_DST"
    fi
else
    echo "  No schema/session-search-schema.sql found"
    echo "  Database will be initialized on first use by index-session.sh"
fi

echo ""

# --- Step 6: Initialize .usage.json (if missing) ---

echo "Step 6: Initializing learned skills tracker..."

USAGE_FILE="${SL_SKILLS}/.usage.json"
if [[ ! -f "$USAGE_FILE" ]]; then
    if [[ "$DRY_RUN" != "true" ]]; then
        echo '{}' > "$USAGE_FILE"
        echo "  Created: $USAGE_FILE"
    else
        echo "[DRY RUN] echo '{}' > $USAGE_FILE"
    fi
else
    echo "  Already exists: $USAGE_FILE (skipping)"
fi

echo ""

# --- Step 7: Print hook registration instructions ---

echo "========================================"
echo "  Installation complete!"
echo "========================================"
echo ""
echo "NEXT STEP (Claude Code only): Register hooks in ~/.claude/settings.json"
echo "This is Claude Code's own config directory (not this project's store)."
echo ""
echo "Add the following to your settings.json (merge with existing hooks):"
echo ""
echo '{'
echo '  "hooks": {'
echo '    "PostToolUse": ['
echo '      {'
echo '        "matcher": "",'
echo "        \"command\": \"bash ${SL_SCRIPTS}/turn-counter.sh\","
echo '        "timeout": 3000'
echo '      }'
echo '    ],'
echo '    "Stop": ['
echo '      {'
echo '        "matcher": "",'
echo "        \"command\": \"bash ${SL_SCRIPTS}/session-review.sh\","
echo '        "timeout": 10000'
echo '      },'
echo '      {'
echo '        "matcher": "",'
echo "        \"command\": \"bash ${SL_SCRIPTS}/index-session.sh\","
echo '        "timeout": 15000'
echo '      }'
echo '    ]'
echo '  }'
echo '}'
echo ""
echo "Optional: Add weekly curator cron job:"
echo "  0 3 * * 0 bash ${SL_SCRIPTS}/curator-run.sh >> ${SL_LOGS}/curator/cron.log 2>&1"
echo ""
echo "Verify installation:"
echo "  bash ${SL_SCRIPTS}/self-learning-health.sh"
echo ""
echo "Diagnose state at any time (resolved paths, writability, detected"
echo "harnesses, legacy store, and any silent persistence failures):"
echo "  bash ${SL_SCRIPTS}/doctor.sh"
echo ""
if [[ -d "${HOME}/.copilot" ]]; then
    echo "GitHub Copilot CLI: hooks were installed to ~/.copilot/hooks/self-learning.json"
    echo ""
fi
