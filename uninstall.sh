#!/usr/bin/env bash
#
# Uninstaller for the Claude Code self-learning system.
#
# Removes scripts and state directories. Prompts before removing
# user data (learned skills, session search database).
#
# Usage:
#   bash uninstall.sh          # Interactive uninstall
#   bash uninstall.sh --force  # Remove everything without prompting
#
# Safe by default: user-created data is only removed with explicit consent.

set -euo pipefail

FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --help|-h)
            echo "Usage: bash uninstall.sh [--force]"
            echo ""
            echo "  --force  Remove everything without prompting (including user data)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

echo "=== Claude Code Self-Learning System Uninstaller ==="
echo ""

REMOVED=0

# --- Helper ---

confirm() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    local prompt="$1 [y/N] "
    read -r -p "$prompt" response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

remove_dir() {
    if [[ -d "$1" ]]; then
        rm -rf "$1"
        echo "  Removed: $1"
        REMOVED=$((REMOVED + 1))
    fi
}

remove_file() {
    if [[ -f "$1" ]]; then
        rm -f "$1"
        echo "  Removed: $1"
        REMOVED=$((REMOVED + 1))
    fi
}

# --- Step 1: Remove scripts ---

echo "Step 1: Removing scripts..."
SCRIPT_DIR="${HOME}/.claude/scripts/self-learning"
if [[ -d "$SCRIPT_DIR" ]]; then
    remove_dir "$SCRIPT_DIR"
else
    echo "  Scripts directory not found (already removed?)"
fi
echo ""

# --- Step 2: Remove state ---

echo "Step 2: Removing state files..."
STATE_DIR="${HOME}/.claude/state/self-learning"
if [[ -d "$STATE_DIR" ]]; then
    remove_dir "$STATE_DIR"
else
    echo "  State directory not found (already removed?)"
fi
echo ""

# --- Step 3: Remove logs ---

echo "Step 3: Removing log files..."
REVIEW_LOG_DIR="${HOME}/.claude/logs/reviews"
CURATOR_LOG_DIR="${HOME}/.claude/logs/curator"
remove_dir "$REVIEW_LOG_DIR"
remove_dir "$CURATOR_LOG_DIR"
echo ""

# --- Step 4: Remove backups ---

echo "Step 4: Removing curator backups..."
BACKUP_DIR="${HOME}/.claude/backups/curator"
if [[ -d "$BACKUP_DIR" ]]; then
    if confirm "Remove curator backups ($BACKUP_DIR)?"; then
        remove_dir "$BACKUP_DIR"
    else
        echo "  Skipped: $BACKUP_DIR"
    fi
else
    echo "  Backup directory not found (already removed?)"
fi
echo ""

# --- Step 5: Remove config (if it came from us) ---

echo "Step 5: Checking configuration..."
CONFIG_FILE="${HOME}/.claude/self-learning.yaml"
if [[ -f "$CONFIG_FILE" ]]; then
    if confirm "Remove config file ($CONFIG_FILE)?"; then
        remove_file "$CONFIG_FILE"
    else
        echo "  Skipped: $CONFIG_FILE"
    fi
else
    echo "  Config file not found (already removed?)"
fi
echo ""

# --- Step 6: Learned skills (user data -- prompt before removal) ---

echo "Step 6: Learned skills (contains user data)..."
SKILLS_DIR="${HOME}/.claude/learned-skills"
if [[ -d "$SKILLS_DIR" ]]; then
    SKILL_COUNT=0
    if [[ -f "${SKILLS_DIR}/.usage.json" ]]; then
        SKILL_COUNT=$(jq 'keys | length' "${SKILLS_DIR}/.usage.json" 2>/dev/null || echo 0)
    fi

    echo "  Found: $SKILLS_DIR ($SKILL_COUNT skills tracked)"
    echo "  WARNING: This directory contains learned skills that may be valuable."

    if confirm "  Remove learned skills directory?"; then
        remove_dir "$SKILLS_DIR"
    else
        echo "  Skipped: $SKILLS_DIR (preserved)"
    fi
else
    echo "  Learned skills directory not found"
fi
echo ""

# --- Step 7: Session search database (user data -- prompt before removal) ---

echo "Step 7: Session search database (contains user data)..."
DB_PATH="${HOME}/.claude/sessions/search.db"
if [[ -f "$DB_PATH" ]]; then
    DB_SIZE=$(du -h "$DB_PATH" 2>/dev/null | cut -f1 || echo "unknown size")
    SESSION_COUNT="unknown"
    if command -v sqlite3 &>/dev/null; then
        SESSION_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sessions" 2>/dev/null || echo "unknown")
    fi

    echo "  Found: $DB_PATH ($DB_SIZE, $SESSION_COUNT sessions)"
    echo "  WARNING: This database contains indexed session history."

    if confirm "  Remove session search database?"; then
        remove_file "$DB_PATH"
    else
        echo "  Skipped: $DB_PATH (preserved)"
    fi
else
    echo "  Session search database not found"
fi
echo ""

# --- Step 8: Memory directory ---

echo "Step 8: Memory directory..."
MEMORY_DIR="${HOME}/.claude/memory"
if [[ -d "$MEMORY_DIR" ]]; then
    FILE_COUNT=$(find "$MEMORY_DIR" -type f 2>/dev/null | wc -l || echo 0)
    echo "  Found: $MEMORY_DIR ($FILE_COUNT files)"

    if confirm "  Remove memory directory?"; then
        remove_dir "$MEMORY_DIR"
    else
        echo "  Skipped: $MEMORY_DIR (preserved)"
    fi
else
    echo "  Memory directory not found"
fi
echo ""

# --- Summary ---

echo "========================================"
echo "  Uninstall Summary"
echo "========================================"
echo "  Items removed: $REMOVED"
echo ""

# --- Reminder: hooks ---

echo "IMPORTANT: Remove hooks from ~/.claude/settings.json"
echo ""
echo "Delete these hook entries from your settings.json:"
echo ""
echo '  PostToolUse -> "bash ~/.claude/scripts/self-learning/turn-counter.sh"'
echo '  Stop        -> "bash ~/.claude/scripts/self-learning/session-review.sh"'
echo '  Stop        -> "bash ~/.claude/scripts/self-learning/index-session.sh"'
echo ""
echo "Also remove the weekly curator cron job if you added one:"
echo "  crontab -e  # then delete the curator-run.sh line"
echo ""
echo "Uninstall complete."
