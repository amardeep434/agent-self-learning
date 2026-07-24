import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "persist-proposal.py"


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


if __name__ == "__main__":
    unittest.main()
