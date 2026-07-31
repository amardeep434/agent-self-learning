#!/usr/bin/env python3
"""scripts/lib/session_db.py

Cross-platform schema initialization and search for the session-search
SQLite database -- fix-p6's follow-up (macOS FTS5 gap) to the
harness-neutral-persistence branch.

WHY THIS EXISTS

index-session.sh and install.sh both used to initialize the search DB via
the `sqlite3` CLI: `sqlite3 "$DB_PATH" < "$SCHEMA_FILE"`. On macOS CI
(GitHub Actions macos-latest), that failed with `no such module: fts5`,
because Apple's bundled `/usr/bin/sqlite3` CLI is commonly built WITHOUT
the FTS5 extension. Two compounding problems, not one:

  1. The failure was silent to the caller. Older `sqlite3` CLI builds do
     not reliably propagate a non-zero exit status for a mid-script error
     unless `.bail on` is set (off by default) -- so `set -euo pipefail`
     in index-session.sh never caught it. The base sessions/messages
     tables (which don't need FTS5 at all) were ALSO never created on
     that run, because the CLI batch-processes top to bottom and the
     virtual-table statement came before them in the old single-file
     schema -- a working, correctly-populated messages table was
     collateral damage of an FTS5-only problem.

  2. Python's bundled `sqlite3` module very often DOES have FTS5 even
     when the OS's `sqlite3` CLI does not -- confirmed on this
     development machine (both system Python 3.13 and the CI-pinned
     3.9.24 report FTS5 available via `sqlite3.connect(":memory:")`),
     and GitHub Actions' macos-latest / ubuntu-latest / windows-latest
     runners all use actions/setup-python's relocatable Python builds,
     which compile their own bundled SQLite with FTS5 enabled regardless
     of what the OS's system `sqlite3` CLI ships with. The old code paid
     the CLI's capability gap even though a capable interpreter was
     sitting right there, already a hard dependency of this project.

THE FIX

Stop shelling out to the `sqlite3` CLI for schema management and
per-session writes entirely (index-session.py already used Python's
sqlite3 module for inserts; only the shell wrapper's schema-init and
already-indexed check/delete still used the CLI -- both moved here and
into index-session.py). `ensure_schema()` applies the BASE schema
(session-search-schema.sql: sessions/messages tables, always required)
via `Connection.executescript()`, which raises immediately on a real
SQL error rather than the CLI's continue-past-errors batch mode -- so a
genuine schema failure is loud and fatal, never silently absorbed.

FTS5 itself is then gated behind probe_fts5(): a FUNCTIONAL probe (try
creating a virtual fts5 table in a throwaway :memory: database) rather
than a version or platform check -- matching this repo's existing
capability-detection discipline (persist-proposal.py's
`os.supports_dir_fd`, test-persist-proposal.py's symlink/hardlink/
O_NOFOLLOW probes). If FTS5 is unavailable, the FTS5-only schema
(session-search-fts5.sql: the messages_fts virtual table + sync
triggers) is simply never applied, and search() below falls back to a
plain `content LIKE '%...%'` query against the same messages table --
degraded (no ranking, no stemming, slower on a large DB) but never
silently empty. Callers (index-session.sh) must surface this loudly:
see its own comments for the WARNING line printed to stderr.

Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys


def probe_fts5() -> bool:
    """Functional probe for FTS5 support: try creating a virtual FTS5
    table in a throwaway in-memory database. Never touches the real
    target database -- a probe that succeeded by accident against
    already-corrupted state would be worse than useless."""
    try:
        conn = sqlite3.connect(":memory:")
    except sqlite3.Error:
        return False
    try:
        conn.execute("CREATE VIRTUAL TABLE probe_fts5 USING fts5(x)")
        return True
    except sqlite3.OperationalError:
        return False
    finally:
        conn.close()


def _apply_schema_file(conn: sqlite3.Connection, path: str) -> None:
    with open(path, "r", encoding="utf-8") as f:
        sql = f.read()
    conn.executescript(sql)


def ensure_schema(
    db_path: str, base_schema_path: str, fts5_schema_path: str | None
) -> tuple[bool, str]:
    """Create/verify the session-search database schema.

    Always applies base_schema_path (sessions/messages tables + plain
    indexes) -- a failure here is a REAL failure and propagates as a
    raised exception; callers must treat that as fatal, not log-and-continue.

    Then probes FTS5 and, only if available, applies fts5_schema_path
    (the messages_fts virtual table + sync triggers).

    Returns (fts5_enabled, message). message explains why FTS5 is
    disabled when fts5_enabled is False; it is not an error by itself --
    a functioning base schema with FTS5 unavailable is a supported,
    intentionally degraded state, not a failure.
    """
    conn = sqlite3.connect(db_path)
    # The DB holds full unredacted session text; never leave it at umask
    # default. Same repair-on-every-run discipline as index-session.py.
    os.chmod(db_path, 0o600)
    try:
        _apply_schema_file(conn, base_schema_path)
        conn.commit()
    finally:
        conn.close()

    if not probe_fts5():
        return False, "SQLite build has no FTS5 extension (functional probe failed)"

    if not fts5_schema_path or not os.path.isfile(fts5_schema_path):
        return False, f"fts5 schema file not found: {fts5_schema_path}"

    conn = sqlite3.connect(db_path)
    try:
        try:
            _apply_schema_file(conn, fts5_schema_path)
            conn.commit()
        except sqlite3.OperationalError as exc:
            # The probe said FTS5 was available but applying the real
            # schema failed anyway (e.g. a stale messages_fts left over
            # from a prior partial run with a different FTS5 build).
            # Base tables already succeeded above -- degrade rather than
            # raise, since correctness of the part that matters (session
            # and message rows) does not depend on this.
            return False, f"fts5 schema apply failed despite probe succeeding: {exc}"
    finally:
        conn.close()

    return True, "fts5 available"


def _has_fts5_table(conn: sqlite3.Connection) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'"
    ).fetchone()
    return row is not None


def search(db_path: str, query: str, limit: int = 20) -> list[dict]:
    """Search indexed session messages for `query`.

    Uses FTS5 MATCH (ranked, stemmed) when messages_fts exists; falls
    back to a plain substring LIKE query (unranked) otherwise -- the
    fallback this whole module exists to guarantee, exercised end to
    end regardless of which path was taken at index time.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        if _has_fts5_table(conn):
            # Deliberately no alias on messages_fts: FTS5's hidden `rank`
            # column (and MATCH itself) is only resolvable through the
            # virtual table's own name, not a query alias -- verified
            # directly (aliasing raises "no such column: f" on the SQLite
            # build used for development here).
            rows = conn.execute(
                """SELECT m.session_id, m.msg_index, m.role, m.content, m.timestamp
                   FROM messages_fts
                   JOIN messages m ON m.id = messages_fts.rowid
                   WHERE messages_fts MATCH ?
                   ORDER BY rank
                   LIMIT ?""",
                (query, limit),
            ).fetchall()
        else:
            like_pattern = "%" + query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            rows = conn.execute(
                """SELECT session_id, msg_index, role, content, timestamp
                   FROM messages
                   WHERE content LIKE ? ESCAPE '\\'
                   ORDER BY id DESC
                   LIMIT ?""",
                (like_pattern, limit),
            ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def _main(argv: list[str]) -> int:
    if not argv:
        print(
            "usage: session_db.py ensure-schema <db_path> <base_schema.sql> [<fts5_schema.sql>]\n"
            "       session_db.py search <db_path> <query> [limit]",
            file=sys.stderr,
        )
        return 2

    cmd = argv[0]

    if cmd == "ensure-schema":
        if len(argv) < 3:
            print("usage: session_db.py ensure-schema <db_path> <base_schema.sql> [<fts5_schema.sql>]",
                  file=sys.stderr)
            return 2
        db_path = argv[1]
        base_schema_path = argv[2]
        fts5_schema_path = argv[3] if len(argv) > 3 else None
        try:
            fts5_ok, message = ensure_schema(db_path, base_schema_path, fts5_schema_path)
        except (sqlite3.Error, OSError) as exc:
            print(f"ensure-schema failed: {exc}", file=sys.stderr)
            return 1
        print(f"fts5:{message}" if fts5_ok else f"no-fts5:{message}")
        return 0

    if cmd == "search":
        if len(argv) < 3:
            print("usage: session_db.py search <db_path> <query> [limit]", file=sys.stderr)
            return 2
        db_path = argv[1]
        query = argv[2]
        limit = int(argv[3]) if len(argv) > 3 else 20
        try:
            results = search(db_path, query, limit)
        except sqlite3.Error as exc:
            print(f"search failed: {exc}", file=sys.stderr)
            return 1
        for row in results:
            print(json.dumps(row))
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
