#!/usr/bin/env bash
#
# Stop hook wrapper: indexes the just-completed session into SQLite FTS5.
# Called as a Stop hook to make session content searchable.
#
# Finds recently modified JSONL session files and passes them to
# index-session.py for parsing and insertion into the search database.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/config.sh"

DB_PATH="$SL_SEARCH_DB"
# SESSIONS_DIR is Claude Code's OWN transcript directory -- the session
# *source* this script reads, not the framework's store. It is legitimately
# Claude-specific and must stay hardcoded; neutralizing it would break
# session indexing.
SESSIONS_DIR="${HOME}/.claude/projects"

mkdir -p "$(dirname "$DB_PATH")"

# Deferred minor (Item 3): DB_EXISTED must be captured BEFORE the
# initialize-if-needed block below creates the file, and used to decide the
# find strategy just after. A first run against a fresh store creates
# DB_PATH with "now" as its mtime; every transcript that already existed
# under SESSIONS_DIR (e.g. a machine migrating an existing ~/.claude/projects
# history onto a fresh AGENT_LEARNING_HOME store) therefore predates the DB
# and is NEVER newer than it -- "-newer $DB_PATH" would silently skip every
# one of them forever, on the very first run, with no error and no log line.
# That is the exact "exits 0 while doing nothing" pattern this project
# exists to eliminate.
DB_EXISTED=0
[[ -f "$DB_PATH" ]] && DB_EXISTED=1

# Initialize database if needed
if [[ "$DB_EXISTED" -eq 0 ]]; then
    SCHEMA_FILE="${SCRIPT_DIR}/session-search-schema.sql"
    if [[ -f "$SCHEMA_FILE" ]]; then
        sqlite3 "$DB_PATH" < "$SCHEMA_FILE"
    else
        echo "[index-session] Schema file not found: $SCHEMA_FILE" >&2
        exit 0
    fi
fi

# On a first run (DB just created above), there is no meaningful "newer than
# the DB" comparison -- index whatever transcripts already exist, bounded to
# the most recent 20 by mtime so a large pre-existing history cannot make a
# Stop hook run unboundedly long. On every subsequent run, only the
# session(s) modified since the last index pass.
#
# fix-p6: this used to be a hand-rolled `find | stat | sort` shell pipeline
# (GNU `stat -c` vs. BSD/macOS `stat -f`, plus `find -newer`'s own
# filesystem-timestamp comparator for the subsequent-run case) -- three
# independently platform-varying pieces in one line, one of which produced
# a real macOS-only false negative in CI (tests/test-index-session-first-run.sh
# passed on Linux, failed on macOS: the pre-existing transcript was silently
# excluded from the listing). list-transcripts.py replaces all three with a
# single `os.path.getmtime()` call per file and one Python-side numeric
# comparison -- same syscall on every platform Python supports, no CLI text
# parsing, no second comparator to disagree with the first. python3 is
# already a hard dependency of this project (config.sh shells out to it on
# every hook invocation via lib/paths.py), so this adds no new dependency.
if [[ "$DB_EXISTED" -eq 0 ]]; then
    LATEST_SESSION=$(python3 "${SCRIPT_DIR}/lib/list-transcripts.py" "$SESSIONS_DIR" --limit 20)
else
    DB_MTIME=$(python3 -c "import os, sys; print(os.path.getmtime(sys.argv[1]))" "$DB_PATH")
    LATEST_SESSION=$(python3 "${SCRIPT_DIR}/lib/list-transcripts.py" "$SESSIONS_DIR" \
        --since-mtime "$DB_MTIME" --limit 20)
fi

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
