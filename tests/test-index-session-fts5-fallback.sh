#!/usr/bin/env bash
# tests/test-index-session-fts5-fallback.sh
#
# fix-p6 (macOS CI): macOS's bundled `sqlite3` CLI is commonly built without
# the FTS5 extension ("no such module: fts5"). The old
# `sqlite3 "$DB_PATH" < "$SCHEMA_FILE"` CLI invocation in index-session.sh
# failed on that, and failed SILENTLY -- its batch mode did not reliably
# surface a non-zero exit for the mid-script error, so `set -euo pipefail`
# never caught it, and the base sessions/messages tables (which don't need
# FTS5 at all) were never created either. tests/test-index-session-first-run.sh
# caught the symptom (a row that should exist doesn't); this file exercises
# the actual FTS5-unavailable CODE PATH directly and end to end, including
# search, rather than only asserting a row landed.
#
# Simulates "Python's own sqlite3 module also lacks FTS5" -- worse than the
# real macOS CI failure (there, only the CLI lacked it; Python's bundled
# SQLite had it) -- via a `sitecustomize.py` on PYTHONPATH that makes any
# CREATE VIRTUAL TABLE ... USING fts5(...) raise sqlite3.OperationalError,
# the same exception SQLite itself raises when the extension is missing.
# This is a functional-probe simulation (probe_fts5() genuinely calls this
# patched sqlite3 and genuinely gets the failure), not a platform-name
# branch, and it proves the LOUD-degrade path works even in the worse case
# the coordinator's request specifically asked to cover, not just the
# CLI-only gap actually seen in CI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
check_contains() { if [[ "$3" == *"$2"* ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected output to contain '$2')"; FAILURES=$((FAILURES+1)); fi; }
check_not_contains() { if [[ "$3" != *"$2"* ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected output NOT to contain '$2')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
IDX_SCRIPTS="$(mktemp -d)"
NOFTS5_SITE="$(mktemp -d)"
NOFTS5_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME" "$IDX_SCRIPTS" "$NOFTS5_SITE" "$NOFTS5_BIN"' EXIT

mkdir -p "${IDX_SCRIPTS}/lib"
cp "${SCRIPT_DIR}/scripts/index-session.sh" "${SCRIPT_DIR}/scripts/index-session.py" "$IDX_SCRIPTS/"
cp "${SCRIPT_DIR}/scripts/lib/config.sh" "${SCRIPT_DIR}/scripts/lib/paths.py" \
   "${SCRIPT_DIR}/scripts/lib/isotime.py" "${SCRIPT_DIR}/scripts/lib/list-transcripts.py" \
   "${SCRIPT_DIR}/scripts/lib/session_db.py" "${IDX_SCRIPTS}/lib/"
cp "${SCRIPT_DIR}/schema/session-search-schema.sql" \
   "${SCRIPT_DIR}/schema/session-search-fts5.sql" "$IDX_SCRIPTS/"
chmod +x "${IDX_SCRIPTS}/index-session.sh"

REAL_PYTHON3="$(command -v python3)"

# The functional FTS5-failure simulation: a real Python subclass of
# sqlite3.Connection whose execute()/executescript() raise the real
# sqlite3.OperationalError SQLite itself raises when a virtual table
# module is missing, but ONLY for statements that actually create an
# fts5 virtual table -- everything else (including this project's own
# schema comments that merely mention "FTS5" in prose) passes through
# untouched.
cat > "${NOFTS5_SITE}/sitecustomize.py" <<'PYEOF'
import re
import sqlite3

_FTS5_STMT_RE = re.compile(r'\bUSING\s+fts5\s*\(', re.IGNORECASE)

class _NoFTS5Connection(sqlite3.Connection):
    def execute(self, sql, *a, **kw):
        if isinstance(sql, str) and _FTS5_STMT_RE.search(sql):
            raise sqlite3.OperationalError('no such module: fts5')
        return super().execute(sql, *a, **kw)

    def executescript(self, sql, *a, **kw):
        if isinstance(sql, str) and _FTS5_STMT_RE.search(sql):
            raise sqlite3.OperationalError('no such module: fts5')
        return super().executescript(sql, *a, **kw)

_orig_connect = sqlite3.connect
def _patched_connect(*a, **kw):
    kw.setdefault('factory', _NoFTS5Connection)
    return _orig_connect(*a, **kw)
sqlite3.connect = _patched_connect
PYEOF

cat > "${NOFTS5_BIN}/python3" <<EOF
#!/usr/bin/env bash
export PYTHONPATH="${NOFTS5_SITE}\${PYTHONPATH:+:\$PYTHONPATH}"
exec "${REAL_PYTHON3}" "\$@"
EOF
chmod +x "${NOFTS5_BIN}/python3"

# Sanity check on the simulation itself before trusting results below: the
# probe must actually observe UNAVAILABLE through this shim, or the rest of
# this test would be silently testing nothing.
PROBE_RESULT="$(PATH="${NOFTS5_BIN}:${PATH}" "${NOFTS5_BIN}/python3" -c "
import sys
sys.path.insert(0, '${IDX_SCRIPTS}/lib')
import session_db
print('available' if session_db.probe_fts5() else 'unavailable')
")"
check "simulation sanity: probe_fts5() reports unavailable through the shim" "unavailable" "$PROBE_RESULT"

STORE="${TMP_HOME}/store"
mkdir -p "${TMP_HOME}/.claude/projects/demo-project"
cat > "${TMP_HOME}/.claude/projects/demo-project/sess-degraded.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"a message mentioning the word zephyr for search"}}
EOF

IDX_EXIT=0
IDX_OUT="$(env -i HOME="$TMP_HOME" PATH="${NOFTS5_BIN}:${PATH}" AGENT_LEARNING_HOME="$STORE" \
    ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} bash "${IDX_SCRIPTS}/index-session.sh" 2>&1)" || IDX_EXIT=$?

check "index-session.sh exits 0 on FTS5-unavailable (a handled degradation, not a failure)" "0" "$IDX_EXIT"
check_contains "a loud WARNING is printed explaining the degradation" "FTS5" "$IDX_OUT"
check_contains "the WARNING names the LIKE-based fallback" "LIKE" "$IDX_OUT"

DB_PATH="$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$STORE" \
    python3 "${IDX_SCRIPTS}/lib/paths.py" get sessions_db)"

TABLES="$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null || echo ERROR)"
check_contains "base 'sessions' table exists despite FTS5 being unavailable" "sessions" "$TABLES"
check_contains "base 'messages' table exists despite FTS5 being unavailable" "messages" "$TABLES"
check_not_contains "messages_fts virtual table was correctly skipped, not half-created" "messages_fts" "$TABLES"

INDEXED_COUNT="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sessions WHERE session_id='sess-degraded'" 2>/dev/null || echo ERROR)"
check "the session's row was inserted (base tables genuinely usable, not just present)" "1" "$INDEXED_COUNT"

# End-to-end search, not just "a row exists": the whole point of this
# module is that search still works in degraded mode.
SEARCH_OUT="$(env -i HOME="$TMP_HOME" PATH="$PATH" \
    python3 "${IDX_SCRIPTS}/lib/session_db.py" search "$DB_PATH" zephyr)"
check_contains "LIKE-fallback search finds the indexed content end to end" "sess-degraded" "$SEARCH_OUT"
check_contains "LIKE-fallback search returns the matched content" "zephyr" "$SEARCH_OUT"

# A SECOND, distinct scenario: a genuinely broken base schema (not merely
# FTS5 missing) must be FATAL and loud, never silently absorbed the way the
# old `sqlite3` CLI's batch mode absorbed it. This is the "exits 0 while
# doing nothing" pattern this project exists to eliminate, checked directly
# rather than assumed fixed by the FTS5-degradation path above.
GENUINE_FAIL_HOME="$(mktemp -d)"
GENUINE_FAIL_SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME" "$IDX_SCRIPTS" "$NOFTS5_SITE" "$NOFTS5_BIN" "$GENUINE_FAIL_HOME" "$GENUINE_FAIL_SCRIPTS"' EXIT

mkdir -p "${GENUINE_FAIL_SCRIPTS}/lib"
cp "${SCRIPT_DIR}/scripts/index-session.sh" "${SCRIPT_DIR}/scripts/index-session.py" "$GENUINE_FAIL_SCRIPTS/"
cp "${SCRIPT_DIR}/scripts/lib/config.sh" "${SCRIPT_DIR}/scripts/lib/paths.py" \
   "${SCRIPT_DIR}/scripts/lib/isotime.py" "${SCRIPT_DIR}/scripts/lib/list-transcripts.py" \
   "${SCRIPT_DIR}/scripts/lib/session_db.py" "${GENUINE_FAIL_SCRIPTS}/lib/"
# A deliberately invalid base schema -- not an FTS5 problem at all.
printf 'THIS IS NOT VALID SQL !!!\n' > "${GENUINE_FAIL_SCRIPTS}/session-search-schema.sql"
cp "${SCRIPT_DIR}/schema/session-search-fts5.sql" "$GENUINE_FAIL_SCRIPTS/"
chmod +x "${GENUINE_FAIL_SCRIPTS}/index-session.sh"

GENUINE_FAIL_STORE="${GENUINE_FAIL_HOME}/store"
# Deliberately NO session transcripts at all -- isolates the schema-init
# check itself. With zero files to index, index-session.sh's normal
# "nothing to do" path (`[[ -z "$LATEST_SESSION" ]] && exit 0`) is the ONLY
# other way this run could end at exit 0 -- so if the broken schema is
# swallowed instead of caught, this reproduces true silent success with no
# secondary Python crash to accidentally make it loud anyway.
mkdir -p "${GENUINE_FAIL_HOME}/.claude/projects/empty-project"

GENUINE_FAIL_EXIT=0
GENUINE_FAIL_OUT="$(env -i HOME="$GENUINE_FAIL_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$GENUINE_FAIL_STORE" \
    ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} bash "${GENUINE_FAIL_SCRIPTS}/index-session.sh" 2>&1)" || GENUINE_FAIL_EXIT=$?

check "a genuinely broken base schema is FATAL (non-zero exit), not silently absorbed" "1" "$GENUINE_FAIL_EXIT"
check_contains "the FATAL message names the real cause" "FATAL" "$GENUINE_FAIL_OUT"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- index-session.sh output (FTS5-unavailable run) ---"
    printf '%s\n' "$IDX_OUT"
    echo "--- index-session.sh output (genuine schema-failure run) ---"
    printf '%s\n' "$GENUINE_FAIL_OUT"
    exit 1
fi
echo "All index-session FTS5-fallback tests passed."
