#!/usr/bin/env bash
#
# Stop hook wrapper: indexes the just-completed session into SQLite FTS5.
# Called as a Stop hook to make session content searchable.
#
# Finds recently modified JSONL session files and passes them to
# index-session.py for parsing and insertion into the search database.

set -euo pipefail

SCRIPT_DIR="${HOME}/.claude/scripts/self-learning"
DB_PATH="${HOME}/.claude/sessions/search.db"
SESSIONS_DIR="${HOME}/.claude/projects"

mkdir -p "$(dirname "$DB_PATH")"

# Initialize database if needed
if [[ ! -f "$DB_PATH" ]]; then
    SCHEMA_FILE="${SCRIPT_DIR}/session-search-schema.sql"
    if [[ -f "$SCHEMA_FILE" ]]; then
        sqlite3 "$DB_PATH" < "$SCHEMA_FILE"
    else
        echo "[index-session] Schema file not found: $SCHEMA_FILE" >&2
        exit 0
    fi
fi

# Find the most recently modified JSONL file (the session that just ended)
LATEST_SESSION=$(find "$SESSIONS_DIR" -name "*.jsonl" -newer "$DB_PATH" \
    -type f 2>/dev/null | head -20)

if [[ -z "$LATEST_SESSION" ]]; then
    exit 0
fi

# Index each new/modified session
while IFS= read -r SESSION_FILE; do
    SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
    PROJECT_PATH=$(dirname "$SESSION_FILE" | sed "s|$SESSIONS_DIR/||")

    # Skip if already indexed and file has not changed
    INDEXED_AT=$(sqlite3 "$DB_PATH" \
        "SELECT indexed_at FROM sessions WHERE session_id='$SESSION_ID'" 2>/dev/null)

    if [[ -n "$INDEXED_AT" ]]; then
        # Re-index: delete old data first
        sqlite3 "$DB_PATH" "DELETE FROM messages WHERE session_id='$SESSION_ID'"
        sqlite3 "$DB_PATH" "DELETE FROM sessions WHERE session_id='$SESSION_ID'"
    fi

    # Parse JSONL and insert via Python helper
    python3 "${SCRIPT_DIR}/index-session.py" \
        "$SESSION_FILE" "$DB_PATH" "$PROJECT_PATH"

done <<< "$LATEST_SESSION"

exit 0
