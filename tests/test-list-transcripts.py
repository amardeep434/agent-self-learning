"""tests/test-list-transcripts.py

Unit tests for scripts/lib/list-transcripts.py's list_transcripts(), the
fix-p6 replacement for index-session.sh's previous
`find | stat | sort -rn | cut | head` shell pipeline (GNU vs. BSD `stat`
flags/output, plus `find -newer`'s own comparator -- one macOS-only false
negative in CI, see the module docstring for the full story).

These exercise the DECISION FUNCTION directly with os.utime()-controlled
mtimes rather than real wall-clock ordering (create a file, sleep, create
another) -- both because sleeping between file creations to get distinct
mtimes is slow, and because it is not deterministic: a fast filesystem or a
loaded CI runner can create two files within the same timestamp-resolution
window, exactly the flakiness class this project's cross-platform rules
exist to prevent. Controlling mtime explicitly makes the ordering assertion
exact and repeatable on every platform, including the tie case that a real
create-then-sleep fixture could never reliably produce on demand.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "lib" / "list-transcripts.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("list_transcripts", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lt = _load_module()


def _touch(path: Path, mtime: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('{"type":"user","message":{"role":"user","content":"x"}}\n')
    os.utime(path, (mtime, mtime))


class TestListTranscripts(unittest.TestCase):
    def test_missing_root_returns_empty(self):
        self.assertEqual(lt.list_transcripts("/no/such/dir/at/all", None, 20), [])

    def test_empty_root_returns_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(lt.list_transcripts(d, None, 20), [])

    def test_first_run_includes_files_older_than_any_reference_point(self):
        # Reproduces the exact regression: a transcript with an mtime far in
        # the past (predating a just-created DB) must still be listed when
        # since_mtime is None (the first-run case -- no comparison at all).
        with tempfile.TemporaryDirectory() as d:
            old = Path(d) / "proj" / "sess-old.jsonl"
            _touch(old, mtime=1000.0)  # 1970 -- as old as a timestamp gets
            result = lt.list_transcripts(d, None, 20)
            self.assertEqual(result, [str(old)])

    def test_since_mtime_excludes_files_at_or_before_the_floor(self):
        with tempfile.TemporaryDirectory() as d:
            older = Path(d) / "sess-older.jsonl"
            same = Path(d) / "sess-same.jsonl"
            newer = Path(d) / "sess-newer.jsonl"
            _touch(older, mtime=100.0)
            _touch(same, mtime=200.0)
            _touch(newer, mtime=300.0)

            result = lt.list_transcripts(d, since_mtime=200.0, limit=20)

            self.assertEqual(result, [str(newer)])
            self.assertNotIn(str(older), result)
            # Strict inequality (matches find -newer's own strict semantics,
            # not >=): a file with mtime EQUAL to the floor is excluded.
            self.assertNotIn(str(same), result)

    def test_sorted_newest_first(self):
        with tempfile.TemporaryDirectory() as d:
            a = Path(d) / "a.jsonl"
            b = Path(d) / "b.jsonl"
            c = Path(d) / "c.jsonl"
            _touch(a, mtime=10.0)
            _touch(b, mtime=30.0)
            _touch(c, mtime=20.0)

            result = lt.list_transcripts(d, None, 20)

            self.assertEqual(result, [str(b), str(c), str(a)])

    def test_limit_caps_result_count_keeping_newest(self):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for i in range(5):
                p = Path(d) / f"sess-{i}.jsonl"
                _touch(p, mtime=float(i))
                paths.append(p)

            result = lt.list_transcripts(d, None, limit=2)

            # Newest two: sess-4 (mtime 4), sess-3 (mtime 3).
            self.assertEqual(result, [str(paths[4]), str(paths[3])])

    def test_non_jsonl_files_are_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            _touch(Path(d) / "sess.jsonl", mtime=50.0)
            other = Path(d) / "notes.txt"
            other.parent.mkdir(parents=True, exist_ok=True)
            other.write_text("not a transcript")
            os.utime(other, (999.0, 999.0))

            result = lt.list_transcripts(d, None, 20)

            self.assertEqual(len(result), 1)
            self.assertTrue(result[0].endswith("sess.jsonl"))

    def test_recurses_into_project_subdirectories(self):
        with tempfile.TemporaryDirectory() as d:
            nested = Path(d) / "proj-a" / "nested" / "sess.jsonl"
            _touch(nested, mtime=42.0)

            result = lt.list_transcripts(d, None, 20)

            self.assertEqual(result, [str(nested)])


if __name__ == "__main__":
    unittest.main()
