#!/usr/bin/env bash
#
# One-command installer for the Claude Code self-learning system.
#
# Creates directories, copies scripts, initializes the SQLite database,
# and prints instructions for registering hooks in settings.json.
#
# Usage:
#   bash install.sh              # Install everything
#   bash install.sh --dry-run    # Preview what would be done
#   bash install.sh --uninstall  # Remove installed files (delegates to uninstall.sh)
#
# Prerequisites:
#   - jq, sqlite3, python3 must be installed
#   - ~/.claude/ directory must exist (created by Claude Code)

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

echo "=== Claude Code Self-Learning System Installer ==="
echo ""

if [[ ! -d "${HOME}/.claude" ]]; then
    echo "Error: ~/.claude/ does not exist. Install Claude Code first." >&2
    exit 1
fi

MISSING_DEPS=()
for cmd in jq sqlite3 python3; do
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

# --- Step 1: Create directories ---

echo "Step 1: Creating directories..."

DIRS=(
    "${HOME}/.claude/state/self-learning"
    "${HOME}/.claude/learned-skills"
    "${HOME}/.claude/learned-skills/.archive"
    "${HOME}/.claude/sessions"
    "${HOME}/.claude/logs/reviews"
    "${HOME}/.claude/logs/curator"
    "${HOME}/.claude/backups/curator"
    "${HOME}/.claude/scripts/self-learning"
    "${HOME}/.claude/scripts/self-learning/prompts"
    "${HOME}/.claude/memory"
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
)

DEST_DIR="${HOME}/.claude/scripts/self-learning"

for script in "${SCRIPTS[@]}"; do
    src="${SCRIPT_DIR}/scripts/${script}"
    if [[ -f "$src" ]]; then
        do_copy "$src" "${DEST_DIR}/${script}"
        do_chmod "${DEST_DIR}/${script}"
    else
        echo "  [WARN] Script not found: $src"
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

# --- Step 4: Copy config (if present) ---

echo "Step 4: Copying configuration..."

CONFIG_SRC="${SCRIPT_DIR}/config/self-learning.conf"
CONFIG_DST="${HOME}/.claude/self-learning.conf"

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
    COPILOT_HOOK_DST="${HOME}/.copilot/hooks/self-learning.json"
    if [[ -f "$COPILOT_HOOK_DST" ]]; then
        echo "  Already exists: $COPILOT_HOOK_DST (skipping)"
    else
        do_copy "${SCRIPT_DIR}/config/copilot-hooks.json" "$COPILOT_HOOK_DST"
    fi
else
    echo "  ~/.copilot not found — Copilot CLI not installed; skipping (re-run install.sh after installing it)"
fi

echo ""

# --- Step 5: Copy and initialize SQLite schema ---

echo "Step 5: Initializing session search database..."

SCHEMA_SRC="${SCRIPT_DIR}/schema/session-search-schema.sql"
SCHEMA_DST="${DEST_DIR}/session-search-schema.sql"
DB_PATH="${HOME}/.claude/sessions/search.db"

if [[ -f "$SCHEMA_SRC" ]]; then
    do_copy "$SCHEMA_SRC" "$SCHEMA_DST"

    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ ! -f "$DB_PATH" ]]; then
            sqlite3 "$DB_PATH" < "$SCHEMA_DST"
            echo "  Initialized: $DB_PATH"
        else
            echo "  Database already exists: $DB_PATH (skipping)"
        fi
    else
        echo "[DRY RUN] sqlite3 $DB_PATH < $SCHEMA_DST"
    fi
else
    echo "  No schema/session-search-schema.sql found"
    echo "  Database will be initialized on first use by index-session.sh"
fi

echo ""

# --- Step 6: Initialize .usage.json (if missing) ---

echo "Step 6: Initializing learned skills tracker..."

USAGE_FILE="${HOME}/.claude/learned-skills/.usage.json"
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
echo "NEXT STEP: Register hooks in ~/.claude/settings.json"
echo ""
echo "Add the following to your settings.json (merge with existing hooks):"
echo ""
echo '{'
echo '  "hooks": {'
echo '    "PostToolUse": ['
echo '      {'
echo '        "matcher": "",'
echo '        "command": "bash ~/.claude/scripts/self-learning/turn-counter.sh",'
echo '        "timeout": 3000'
echo '      }'
echo '    ],'
echo '    "Stop": ['
echo '      {'
echo '        "matcher": "",'
echo '        "command": "bash ~/.claude/scripts/self-learning/session-review.sh",'
echo '        "timeout": 10000'
echo '      },'
echo '      {'
echo '        "matcher": "",'
echo '        "command": "bash ~/.claude/scripts/self-learning/index-session.sh",'
echo '        "timeout": 15000'
echo '      }'
echo '    ]'
echo '  }'
echo '}'
echo ""
echo "Optional: Add weekly curator cron job:"
echo "  0 3 * * 0 bash ~/.claude/scripts/self-learning/curator-run.sh >> ~/.claude/logs/curator/cron.log 2>&1"
echo ""
echo "Verify installation:"
echo "  bash ~/.claude/scripts/self-learning/self-learning-health.sh"
echo ""
