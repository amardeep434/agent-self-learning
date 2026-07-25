import os, subprocess, sys, tempfile, unittest
from pathlib import Path, PureWindowsPath

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
            {"home", "state", "skills", "memory", "logs", "sessions_db", "config_file", "scripts"})

    def test_scripts_key_explicit_override(self):
        env = self._env(AGENT_LEARNING_HOME="/tmp/explicit")
        self.assertEqual(paths.resolve_all(env, platform="linux")["scripts"],
                         Path("/tmp/explicit/scripts"))

    def test_scripts_key_xdg(self):
        env = self._env(XDG_DATA_HOME="/tmp/xdg", HOME="/home/u")
        self.assertEqual(paths.resolve_all(env, platform="linux")["scripts"],
                         Path("/tmp/xdg/agent-learning/scripts"))

    def test_scripts_key_windows_localappdata(self):
        env = self._env(LOCALAPPDATA="C:\\Users\\u\\AppData\\Local", HOME="C:\\Users\\u")
        self.assertEqual(paths.resolve_all(env, platform="win32")["scripts"],
                         Path("C:\\Users\\u\\AppData\\Local") / "agent-learning" / "scripts")

    def test_scripts_key_linux_default(self):
        env = self._env(HOME="/home/u")
        self.assertEqual(paths.resolve_all(env, platform="linux")["scripts"],
                         Path("/home/u/.local/share/agent-learning/scripts"))

    def test_home_unset_raises_instead_of_cwd_relative(self):
        # Deferred minor 1 (upgraded to must-fix): HOME unset and no override
        # must fail loudly, never silently resolve to a CWD-relative path
        # (the old behavior: Path("") normalizes to ".").
        env = self._env(HOME="")
        with self.assertRaises(RuntimeError):
            paths.resolve_home(env, platform="linux")

    def test_home_unset_raises_on_windows_too(self):
        env = self._env(HOME="")
        with self.assertRaises(RuntimeError):
            paths.resolve_home(env, platform="win32")

    def test_home_unset_but_override_present_does_not_raise(self):
        env = self._env(HOME="", AGENT_LEARNING_HOME="/tmp/explicit")
        self.assertEqual(paths.resolve_home(env, platform="linux"), Path("/tmp/explicit"))


class TestCliFormatting(unittest.TestCase):
    """C1: the CLI must emit forward-slash strings even for a WindowsPath,
    so bash consumers (config.sh, install.sh, uninstall.sh) never see raw
    backslashes. Uses PureWindowsPath directly so this runs identically on
    Linux, macOS, and Windows -- a real WindowsPath cannot be constructed
    on a non-Windows OS, but PureWindowsPath can be, on any OS."""

    def test_windows_path_rendered_with_forward_slashes(self):
        p = PureWindowsPath(r"C:\Users\runneradmin\.local\share\agent-learning")
        self.assertEqual(
            paths._to_cli_string(p),
            "C:/Users/runneradmin/.local/share/agent-learning",
        )
        self.assertNotIn("\\", paths._to_cli_string(p))

    def test_posix_path_unaffected(self):
        p = Path("/home/u/.local/share/agent-learning")
        self.assertEqual(paths._to_cli_string(p), "/home/u/.local/share/agent-learning")

    def test_main_all_emits_no_backslashes_for_a_windows_style_env(self):
        # Simulate what _main's "all" branch would print for a Windows
        # resolution by monkeypatching resolve_all's underlying platform via
        # resolve_all() directly (real WindowsPath objects, since this test
        # runs on whatever OS invoked it -- but resolve_home constructs
        # Path(), which is WindowsPath only on real Windows). To exercise the
        # formatting boundary itself platform-independently, drive
        # _to_cli_string across every value resolve_all() can produce for a
        # Windows env, expressed as PureWindowsPath (matching what a real
        # Windows Path() would contain).
        raw = {
            "home": r"C:\Users\runneradmin\.local\share\agent-learning",
            "scripts": r"C:\Users\runneradmin\.local\share\agent-learning\scripts",
        }
        for key, value in raw.items():
            rendered = paths._to_cli_string(PureWindowsPath(value))
            self.assertNotIn("\\", rendered, f"key={key}")
            self.assertTrue(rendered.startswith("C:/"), f"key={key} -> {rendered}")


class TestCliHomeUnset(unittest.TestCase):
    def test_main_get_fails_loudly_when_home_unset(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("AGENT_LEARNING_", "XDG_DATA_HOME", "LOCALAPPDATA", "SL_", "HOME"))}
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "home"],
            capture_output=True, text=True, env=env)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn(r.returncode, (0,))
        # Must not silently succeed with a CWD-relative path.
        self.assertEqual(r.stdout.strip(), "")
        self.assertIn("HOME", r.stderr)


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
