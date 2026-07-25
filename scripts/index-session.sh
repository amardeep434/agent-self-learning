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

# Initialize database if needed.
#
# fix-p6 (macOS CI): this used to be `sqlite3 "$DB_PATH" < "$SCHEMA_FILE"`
# via the `sqlite3` CLI. macOS's bundled CLI is commonly built WITHOUT the
# FTS5 extension ("no such module: fts5"), and its batch mode does not
# reliably propagate a non-zero exit for a mid-script error -- so this
# failed silently: `set -euo pipefail` never caught it, the FTS5 table
# creation failed, and the base sessions/messages tables (which don't even
# need FTS5) were collateral damage since the CLI never reached the
# statements after the failing one. session_db.py replaces the CLI with
# Python's own sqlite3 module (Connection.executescript() raises
# immediately on a real error, no silent continue-past-failures) and
# splits the schema: base tables always applied, FTS5 gated behind a
# functional probe (never a platform-name guess) with a LIKE-based
# fallback in session_db.py's search() when it's unavailable.
if [[ "$DB_EXISTED" -eq 0 ]]; then
    BASE_SCHEMA_FILE="${SCRIPT_DIR}/session-search-schema.sql"
    FTS5_SCHEMA_FILE="${SCRIPT_DIR}/session-search-fts5.sql"
    if [[ -f "$BASE_SCHEMA_FILE" ]]; then
        if ! SCHEMA_RESULT=$(python3 "${SCRIPT_DIR}/lib/session_db.py" \
                ensure-schema "$DB_PATH" "$BASE_SCHEMA_FILE" "$FTS5_SCHEMA_FILE" 2>&1); then
            # A real failure (not merely FTS5 being unavailable -- that
            # case returns 0, see session_db.py) -- loud and fatal, never
            # silently continue with a half-initialized database.
            echo "[index-session] FATAL: failed to initialize session search database ($DB_PATH): $SCHEMA_RESULT" >&2
            exit 1
        fi
        if [[ "$SCHEMA_RESULT" == no-fts5:* ]]; then
            echo "[index-session] WARNING: ${SCHEMA_RESULT#no-fts5:} -- full-text search degraded to substring (LIKE) matching: no ranking, no stemming, slower on a large history." >&2
        fi
    else
        echo "[index-session] Schema file not found: $BASE_SCHEMA_FILE" >&2
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

# Index each new/modified session. The re-index (already-indexed ->
# delete old rows -> insert fresh) decision used to live here, via two more
# `sqlite3` CLI calls; index-session.py now does the equivalent DELETE
# unconditionally (a no-op on a first-time session, necessary on a
# re-index) with Python's sqlite3 module -- one less CLI dependency, one
# less place for the same silent-failure class to recur.
while IFS= read -r SESSION_FILE; do
    PROJECT_PATH=$(dirname "$SESSION_FILE" | sed "s|$SESSIONS_DIR/||")

    # Parse JSONL and insert via Python helper (derives session_id itself
    # from the filename stem)
    python3 "${SCRIPT_DIR}/index-session.py" \
        "$SESSION_FILE" "$DB_PATH" "$PROJECT_PATH"

done <<< "$LATEST_SESSION"

exit 0
