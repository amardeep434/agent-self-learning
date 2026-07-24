import importlib.util
import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "persist-proposal.py"


def _load_writer_module():
    """Import persist-proposal.py directly (hyphenated filename, no import)."""
    spec = importlib.util.spec_from_file_location("persist_proposal", WRITER)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ROOT / "scripts" / "lib"))
    spec.loader.exec_module(module)
    return module


def run(stdin_text, home, extra_args=()):
    env = dict(os.environ, AGENT_LEARNING_HOME=str(home))
    return subprocess.run([sys.executable, str(WRITER), *extra_args],
                          input=stdin_text, capture_output=True, text=True, env=env)


class TestWrites(unittest.TestCase):
    def test_writes_memory_and_skill(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "remembered"}],
                                  "skills": [{"name": "alpha", "content": "# Alpha"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "remembered")
            self.assertEqual((home / "learned-skills" / "alpha.md").read_text(), "# Alpha")

    def test_append_mode_appends(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory").mkdir(parents=True)
            (home / "memory" / "MEMORY.md").write_text("first\n")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "second\n"}]})
            self.assertEqual(run(payload, home).returncode, 0)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "first\nsecond\n")

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home, extra_args=("--dry-run",))
            self.assertEqual(r.returncode, 0)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_no_json_is_success_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            r = run("the model just chatted at us", home)
            self.assertEqual(r.returncode, 0)
            self.assertFalse((home / "memory").exists())


class TestRejects(unittest.TestCase):
    def test_invalid_proposal_exits_1_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "../escape.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((Path(d).parent / "escape.md").exists())

    def test_partial_validity_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "ok"}],
                                  "skills": [{"name": "../evil", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_symlinked_target_is_refused(self):
        if sys.platform.startswith("win"):
            self.skipTest("symlink creation requires privilege on Windows")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("original")
            (home / "memory" / "MEMORY.md").symlink_to(outside)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "original")


class TestFixRound1Regressions(unittest.TestCase):
    """Regression coverage for findings from the round-1 adversarial review.

    Each of these reproduces a scenario found during manual adversarial
    testing (not part of the original 7); without the corresponding
    protection in persist-proposal.py, each of these fails.
    """

    def test_symlinked_root_directory_is_refused(self):
        if sys.platform.startswith("win"):
            self.skipTest("symlink creation requires privilege on Windows")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            home.mkdir()
            outside_dir = Path(d) / "outside_dir"
            outside_dir.mkdir()
            (home / "memory").symlink_to(outside_dir, target_is_directory=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(list(outside_dir.iterdir()), [])

    def test_target_is_a_directory_is_refused_without_traceback(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory" / "MEMORY.md").mkdir(parents=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertNotIn("Traceback", r.stderr)

    def test_directory_collision_on_second_entry_leaves_first_uncommitted(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "learned-skills").mkdir(parents=True)
            (home / "learned-skills" / "beta.md").mkdir()
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace",
                                              "content": "should-not-persist"}],
                                  "skills": [{"name": "beta", "content": "# Beta"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_append_through_symlinked_existing_file_is_refused(self):
        if sys.platform.startswith("win"):
            self.skipTest("symlink creation requires privilege on Windows")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("original")
            (home / "memory" / "MEMORY.md").symlink_to(outside)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "original")

    def test_append_through_hardlinked_existing_file_is_refused(self):
        if sys.platform.startswith("win"):
            self.skipTest("hardlink creation semantics differ on Windows")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("SECRET")
            os.link(outside, home / "memory" / "MEMORY.md")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "SECRET")

    def test_append_on_non_utf8_existing_file_is_refused_without_traceback(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory").mkdir(parents=True)
            (home / "memory" / "MEMORY.md").write_bytes(b"\xff\xfe not valid utf-8")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertNotIn("Traceback", r.stderr)


class TestInternalGuardsUnreachableThroughSchema(unittest.TestCase):
    """Direct unit tests for defence-in-depth checks the current schema makes
    unreachable through the public CLI.

    proposal_schema's exact allow-listed memory filenames and slash-free
    skill-name regex mean a subprocess call can never actually produce a
    `target` outside `root`, nor a filename containing a path separator --
    so `_assert_inside`'s parent-comparison branch and `_open_nofollow_fd`'s
    O_NOFOLLOW/ELOOP handling can't be exercised black-box. Call them
    directly so a regression in either is still caught, even though neither
    is adversarially reachable while proposal_schema's current guarantees
    hold.
    """

    def setUp(self):
        self.mod = _load_writer_module()

    def test_assert_inside_rejects_target_outside_root(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "root"
            root.mkdir()
            outside = Path(d) / "outside" / "file.md"
            outside.parent.mkdir()
            with self.assertRaises(self.mod.PersistError):
                self.mod._assert_inside(root, outside)

    def test_open_nofollow_fd_rejects_symlink(self):
        if sys.platform.startswith("win"):
            self.skipTest("O_NOFOLLOW is POSIX-only")
        with tempfile.TemporaryDirectory() as d:
            outside = Path(d) / "outside.md"
            outside.write_text("data")
            link = Path(d) / "link.md"
            link.symlink_to(outside)
            with self.assertRaises(self.mod.PersistError):
                self.mod._open_nofollow_fd(link, os.O_RDONLY)

    def test_read_existing_rejects_symlink_even_without_o_nofollow(self):
        """Isolates _read_existing's explicit is_symlink() pre-check from the
        redundant O_NOFOLLOW protection that also happens to catch a
        symlinked target on POSIX. We simulate the Windows case (no
        O_NOFOLLOW available) by monkeypatching it away, so this only passes
        if the explicit check -- the sole protection on that platform --
        is actually still there.
        """
        if sys.platform.startswith("win"):
            self.skipTest("this test simulates Windows by removing O_NOFOLLOW")
        with tempfile.TemporaryDirectory() as d:
            outside = Path(d) / "outside.md"
            outside.write_text("data")
            link = Path(d) / "link.md"
            link.symlink_to(outside)
            original = getattr(self.mod.os, "O_NOFOLLOW", None)
            self.mod.os.O_NOFOLLOW = 0
            try:
                with self.assertRaises(self.mod.PersistError):
                    self.mod._read_existing(link)
            finally:
                if original is None:
                    del self.mod.os.O_NOFOLLOW
                else:
                    self.mod.os.O_NOFOLLOW = original


if __name__ == "__main__":
    unittest.main()
