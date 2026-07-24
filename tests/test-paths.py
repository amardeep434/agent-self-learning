import os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import paths  # noqa: E402


class TestResolveHome(unittest.TestCase):
    def _env(self, **kw):
        base = {k: v for k, v in os.environ.items() if not k.startswith(
            ("AGENT_LEARNING_", "XDG_DATA_HOME", "LOCALAPPDATA", "SL_"))}
        base.update(kw)
        return base

    def test_explicit_override_wins(self):
        env = self._env(AGENT_LEARNING_HOME="/tmp/explicit", XDG_DATA_HOME="/tmp/xdg")
        self.assertEqual(paths.resolve_home(env, platform="linux"), Path("/tmp/explicit"))

    def test_xdg_used_when_set(self):
        env = self._env(XDG_DATA_HOME="/tmp/xdg", HOME="/home/u")
        self.assertEqual(paths.resolve_home(env, platform="linux"),
                         Path("/tmp/xdg/agent-learning"))

    def test_linux_default(self):
        env = self._env(HOME="/home/u")
        self.assertEqual(paths.resolve_home(env, platform="linux"),
                         Path("/home/u/.local/share/agent-learning"))

    def test_windows_uses_localappdata(self):
        env = self._env(LOCALAPPDATA="C:\\Users\\u\\AppData\\Local", HOME="C:\\Users\\u")
        self.assertEqual(paths.resolve_home(env, platform="win32"),
                         Path("C:\\Users\\u\\AppData\\Local") / "agent-learning")

    def test_no_claude_in_any_default(self):
        env = self._env(HOME="/home/u")
        for p in paths.resolve_all(env, platform="linux").values():
            self.assertNotIn(".claude", str(p))

    def test_all_keys_present(self):
        env = self._env(HOME="/home/u")
        self.assertEqual(
            set(paths.resolve_all(env, platform="linux")),
            {"home", "state", "skills", "memory", "logs", "sessions_db", "config_file"})


class TestLegacyDetection(unittest.TestCase):
    def test_legacy_reported_when_present(self):
        with tempfile.TemporaryDirectory() as d:
            legacy = Path(d) / ".claude" / "memory"
            legacy.mkdir(parents=True)
            env = {"HOME": d}
            self.assertEqual(paths.legacy_home(env), Path(d) / ".claude")

    def test_legacy_none_when_absent(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(paths.legacy_home({"HOME": d}))


class TestCli(unittest.TestCase):
    def test_get_prints_single_path(self):
        env = dict(os.environ, AGENT_LEARNING_HOME="/tmp/x")
        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "memory"],
            capture_output=True, text=True, env=env, check=True).stdout.strip()
        self.assertEqual(out, str(Path("/tmp/x/memory")))

    def test_get_unknown_key_exits_nonzero(self):
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "nope"],
            capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
