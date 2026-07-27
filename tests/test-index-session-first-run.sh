#!/usr/bin/env bash
# tests/test-index-session-first-run.sh
#
# Item 3 (deferred minor): index-session.sh's `-newer "$DB_PATH"` test can
# miss pre-existing transcripts on the FIRST run against a fresh store -- the
# DB is created with "now" as its mtime, so any transcript that already
# existed under SESSIONS_DIR (e.g. migrating an existing ~/.claude/projects
# history onto a fresh AGENT_LEARNING_HOME store) predates the DB and is
# never "newer" than it. That is a silent, permanent skip: the hook exits 0,
# nothing errors, and the pre-existing session is simply never indexed.
#
# This test seeds a transcript BEFORE the first index-session.sh run (so its
# mtime necessarily predates DB creation) and asserts it gets indexed anyway.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
IDX_SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME" "$IDX_SCRIPTS"' EXIT

mkdir -p "${IDX_SCRIPTS}/lib"
cp "${SCRIPT_DIR}/scripts/index-session.sh" "${SCRIPT_DIR}/scripts/index-session.py" "$IDX_SCRIPTS/"
cp "${SCRIPT_DIR}/scripts/lib/config.sh" "${SCRIPT_DIR}/scripts/lib/paths.py" \
   "${SCRIPT_DIR}/scripts/lib/isotime.py" "${SCRIPT_DIR}/scripts/lib/list-transcripts.py" \
   "${SCRIPT_DIR}/scripts/lib/session_db.py" "${IDX_SCRIPTS}/lib/"
cp "${SCRIPT_DIR}/schema/session-search-schema.sql" \
   "${SCRIPT_DIR}/schema/session-search-fts5.sql" "$IDX_SCRIPTS/"
chmod +x "${IDX_SCRIPTS}/index-session.sh"

STORE="${TMP_HOME}/store"
mkdir -p "${TMP_HOME}/.claude/projects/demo-project"

# Seed a transcript that ALREADY EXISTS before index-session.sh ever runs --
# so on a fresh store, the about-to-be-created DB is necessarily younger than
# this file, reproducing the exact first-run ordering that used to be missed.
cat > "${TMP_HOME}/.claude/projects/demo-project/sess-preexisting.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"a transcript that predates the search DB"},"timestamp":"2026-01-01T00:00:00Z"}
EOF

run_idx() {
    env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} bash "${IDX_SCRIPTS}/index-session.sh" "$@"
}

IDX_OUT="$(run_idx 2>&1)" || true

DB_PATH="$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
    python3 "${IDX_SCRIPTS}/lib/paths.py" get sessions_db)"

check "DB was created on first run" "yes" "$([[ -f "$DB_PATH" ]] && echo yes || echo no)"

INDEXED_COUNT="$(env -i HOME="$TMP_HOME" PATH="$PATH" \
    sqlite3 "$DB_PATH" "SELECT count(*) FROM sessions WHERE session_id='sess-preexisting'" 2>/dev/null || echo ERROR)"
check "pre-existing transcript is indexed on the very first run" "1" "$INDEXED_COUNT"

# fix-p6: verify SEARCH actually works end to end, not just that a row
# landed in the table -- the macOS CI failure this branch caught was
# exactly "a row inserted" while search itself (FTS5 schema creation) had
# silently failed. On whatever SQLite build this test happens to run
# under -- real FTS5 or the LIKE fallback -- the content must be findable.
SEARCH_OUT="$(env -i HOME="$TMP_HOME" PATH="$PATH" \
    python3 "${IDX_SCRIPTS}/lib/session_db.py" search "$DB_PATH" predates)"
if [[ "$SEARCH_OUT" == *"sess-preexisting"* ]]; then
    echo "PASS: search finds the pre-existing transcript's content end to end"
else
    echo "FAIL: search finds the pre-existing transcript's content end to end (got: '$SEARCH_OUT')"
    FAILURES=$((FAILURES+1))
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- index-session.sh first-run output ---"
    printf '%s\n' "$IDX_OUT"
    exit 1
fi
echo "All index-session first-run tests passed."
