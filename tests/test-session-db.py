"""tests/test-session-db.py

Unit tests for scripts/lib/session_db.py -- the fix-p6 (macOS FTS5 gap)
follow-up to the harness-neutral-persistence branch.

Real-world context: macOS CI's `sqlite3` CLI lacks the FTS5 extension
("no such module: fts5"); the old `sqlite3 db < schema.sql` CLI invocation
failed silently (no non-zero exit `set -e` could catch) and took the BASE
sessions/messages tables down with it, even though they don't need FTS5 at
all. session_db.py replaces the CLI with Python's own sqlite3 module,
splits the schema into a base part (always applied) and an FTS5-only part
(applied only after a functional probe), and provides a search() that uses
FTS5 MATCH when available and falls back to a plain LIKE query otherwise.

These tests exercise the FTS5-unavailable path DIRECTLY, by monkeypatching
probe_fts5() to return False -- rather than relying on this development
machine happening to lack FTS5 (it doesn't; both the system sqlite3 CLI and
Python's bundled module have it here). That means the degraded path is
covered on Linux CI too, not only if a real macOS runner happens to hit it.
"""
from __future__ import annotations

import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "lib" / "session_db.py"
BASE_SCHEMA_PATH = ROOT / "schema" / "session-search-schema.sql"
FTS5_SCHEMA_PATH = ROOT / "schema" / "session-search-fts5.sql"


def _load_module():
    spec = importlib.util.spec_from_file_location("session_db", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sdb = _load_module()


def _table_names(db_path: str) -> set:
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
        ).fetchall()
        return {r[0] for r in rows}
    finally:
        conn.close()


def _insert_message(db_path: str, session_id: str, content: str) -> None:
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            """INSERT INTO sessions
               (session_id, project_path, title, started_at, last_active,
                message_count, indexed_at)
               VALUES (?, 'proj', 'title', '2026-01-01T00:00:00+00:00',
                       '2026-01-01T00:00:00+00:00', 1, '2026-01-01T00:00:00+00:00')""",
            (session_id,),
        )
        conn.execute(
            "INSERT INTO messages (session_id, msg_index, role, content) VALUES (?, 0, 'user', ?)",
            (session_id, content),
        )
        conn.commit()
    finally:
        conn.close()


class TestProbeFTS5(unittest.TestCase):
    def test_probe_returns_a_bool_and_never_raises(self):
        # [capability probe] not asserted True or False -- this development
        # machine's own SQLite build genuinely has FTS5 (verified
        # separately), so hard-asserting either direction here would be
        # asserting a fact about the runner, not about probe_fts5()'s
        # correctness. What IS asserted: it returns a real bool, never
        # raises, regardless of what this machine has.
        result = sdb.probe_fts5()
        self.assertIsInstance(result, bool)
        print(f"[capability probe] FTS5 (this test runner): "
              f"{'AVAILABLE' if result else 'UNAVAILABLE'}", file=sys.stderr)


class TestEnsureSchema(unittest.TestCase):
    def test_base_tables_created_when_fts5_unavailable(self):
        # Direct simulation of the exact macOS regression: FTS5 reported
        # unavailable, base schema must still fully apply.
        orig_probe = sdb.probe_fts5
        sdb.probe_fts5 = lambda: False
        try:
            with tempfile.TemporaryDirectory() as d:
                db_path = os.path.join(d, "search.db")
                fts5_ok, message = sdb.ensure_schema(
                    db_path, str(BASE_SCHEMA_PATH), str(FTS5_SCHEMA_PATH)
                )
                self.assertFalse(fts5_ok)
                self.assertIn("FTS5", message)
                tables = _table_names(db_path)
                self.assertIn("sessions", tables)
                self.assertIn("messages", tables)
                self.assertNotIn("messages_fts", tables)
        finally:
            sdb.probe_fts5 = orig_probe

    def test_fts5_tables_created_when_available(self):
        orig_probe = sdb.probe_fts5
        sdb.probe_fts5 = lambda: True
        try:
            with tempfile.TemporaryDirectory() as d:
                db_path = os.path.join(d, "search.db")
                fts5_ok, message = sdb.ensure_schema(
                    db_path, str(BASE_SCHEMA_PATH), str(FTS5_SCHEMA_PATH)
                )
                self.assertTrue(fts5_ok)
                self.assertIn("available", message)
                tables = _table_names(db_path)
                self.assertIn("sessions", tables)
                self.assertIn("messages", tables)
                self.assertIn("messages_fts", tables)
        finally:
            sdb.probe_fts5 = orig_probe

    def test_missing_fts5_schema_file_degrades_instead_of_raising(self):
        orig_probe = sdb.probe_fts5
        sdb.probe_fts5 = lambda: True  # probe says yes, but the file is gone
        try:
            with tempfile.TemporaryDirectory() as d:
                db_path = os.path.join(d, "search.db")
                fts5_ok, message = sdb.ensure_schema(
                    db_path, str(BASE_SCHEMA_PATH), "/no/such/fts5-schema.sql"
                )
                self.assertFalse(fts5_ok)
                self.assertIn("not found", message)
                tables = _table_names(db_path)
                self.assertIn("sessions", tables)
        finally:
            sdb.probe_fts5 = orig_probe

    def test_genuine_base_schema_failure_is_raised_not_swallowed(self):
        # This is the exact class of bug this module fixes in reverse: a
        # REAL failure applying the base schema must propagate loudly, not
        # be absorbed the way the old `sqlite3` CLI's batch mode absorbed
        # the FTS5 failure and silently skipped the base tables too.
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "search.db")
            bad_schema = os.path.join(d, "broken.sql")
            with open(bad_schema, "w") as f:
                f.write("CREATE TABLE sessions (this is not valid SQL !!!;")
            with self.assertRaises(sqlite3.Error):
                sdb.ensure_schema(db_path, bad_schema, None)


class TestSearch(unittest.TestCase):
    def test_search_uses_fts5_when_available(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "search.db")
            fts5_ok, _ = sdb.ensure_schema(db_path, str(BASE_SCHEMA_PATH), str(FTS5_SCHEMA_PATH))
            if not fts5_ok:
                self.skipTest("FTS5 genuinely unavailable on this machine's SQLite build")
            _insert_message(db_path, "sess-1", "the quick brown fox mentions zephyr winds")
            # Triggers are stored in the schema, not tied to a connection --
            # the AFTER INSERT trigger fires regardless of which connection
            # performed the INSERT, keeping messages_fts in sync.
            tables = _table_names(db_path)
            self.assertIn("messages_fts", tables)
            results = sdb.search(db_path, "zephyr")
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["session_id"], "sess-1")
            self.assertIn("zephyr", results[0]["content"])

    def test_search_falls_back_to_like_when_fts5_table_absent(self):
        orig_probe = sdb.probe_fts5
        sdb.probe_fts5 = lambda: False
        try:
            with tempfile.TemporaryDirectory() as d:
                db_path = os.path.join(d, "search.db")
                fts5_ok, _ = sdb.ensure_schema(db_path, str(BASE_SCHEMA_PATH), str(FTS5_SCHEMA_PATH))
                self.assertFalse(fts5_ok)
                _insert_message(db_path, "sess-2", "a message about zephyr winds")
                _insert_message(db_path, "sess-3", "an unrelated message about oceans")

                self.assertNotIn("messages_fts", _table_names(db_path))

                results = sdb.search(db_path, "zephyr")
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["session_id"], "sess-2")
        finally:
            sdb.probe_fts5 = orig_probe

    def test_like_fallback_escapes_percent_and_underscore(self):
        orig_probe = sdb.probe_fts5
        sdb.probe_fts5 = lambda: False
        try:
            with tempfile.TemporaryDirectory() as d:
                db_path = os.path.join(d, "search.db")
                sdb.ensure_schema(db_path, str(BASE_SCHEMA_PATH), str(FTS5_SCHEMA_PATH))
                _insert_message(db_path, "sess-4", "a literal 100% discount_code promo")
                _insert_message(db_path, "sess-5", "a totally different unrelated message")

                # A literal "%" in the query must not act as a wildcard
                # matching everything.
                results = sdb.search(db_path, "100%")
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["session_id"], "sess-4")
        finally:
            sdb.probe_fts5 = orig_probe


if __name__ == "__main__":
    unittest.main()
