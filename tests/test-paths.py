import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PureWindowsPath
from unittest import mock

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
        # Fix round F: this test does not pass is_windows=/msystem=, so it
        # reads ambient os.environ.get("MSYSTEM") by default. On the real
        # windows-latest CI runner (Git Bash), MSYSTEM genuinely IS set --
        # so without pinning it, this test's own environment silently
        # changes which branch _to_cli_string takes out from under it,
        # correctly producing the MSYS cygdrive form ('/c/Users/...')
        # instead of the plain .as_posix() form this test asserts. The
        # production logic was right; the test never controlled its own
        # environment. Pinned to empty (falsy, same effect as unset) so
        # this test is deterministic on every platform, including the one
        # it used to fail on.
        with mock.patch.dict(os.environ, {"MSYSTEM": ""}):
            p = PureWindowsPath(r"C:\Users\runneradmin\.local\share\agent-learning")
            self.assertEqual(
                paths._to_cli_string(p),
                "C:/Users/runneradmin/.local/share/agent-learning",
            )
            self.assertNotIn("\\", paths._to_cli_string(p))

    def test_posix_path_unaffected(self):
        p = Path("/home/u/.local/share/agent-learning")
        self.assertEqual(paths._to_cli_string(p), "/home/u/.local/share/agent-learning")

    def test_msys_branch_emits_cygdrive_form(self):
        # Fix round D, blocker (b): inside an actual Git Bash / MSYS2 shell
        # (os.name == "nt" AND MSYSTEM set), the CLI must emit '/c/Users/x'
        # -- the form MSYS's own tools (and bash's own path comparisons)
        # expect -- not the plain 'C:/Users/x' from C1's .as_posix() fix,
        # which round A's diagnosis stopped at.
        p = PureWindowsPath(r"C:\Users\runneradmin\.local\share\agent-learning")
        rendered = paths._to_cli_string(p, is_windows=True, msystem="MINGW64")
        self.assertEqual(rendered, "/c/Users/runneradmin/.local/share/agent-learning")
        self.assertNotIn("\\", rendered)
        self.assertNotIn(":", rendered)

    def test_native_windows_without_msystem_keeps_as_posix_form(self):
        # Native cmd.exe / PowerShell never set MSYSTEM. That caller must
        # keep getting the plain .as_posix() form -- switching everyone to
        # cygdrive form unconditionally would break native Windows tools,
        # which do not understand '/c/Users/x'.
        #
        # Fix round F: passing msystem=None here does NOT mean "force no
        # MSYSTEM" -- _to_cli_string treats None as "caller didn't specify,
        # fall back to os.environ.get('MSYSTEM')" (see its signature/docstring),
        # so on the real windows-latest CI runner (Git Bash, MSYSTEM
        # genuinely set) this test's own explicit `msystem=None` was being
        # silently overridden by the ambient environment, defeating the
        # test's whole point. Pin the environment directly instead so
        # "no MSYSTEM" is actually enforced, not merely requested.
        with mock.patch.dict(os.environ, {"MSYSTEM": ""}):
            p = PureWindowsPath(r"C:\Users\runneradmin\.local\share\agent-learning")
            rendered = paths._to_cli_string(p, is_windows=True, msystem=None)
            self.assertEqual(rendered, "C:/Users/runneradmin/.local/share/agent-learning")

    def test_non_windows_ignores_msystem(self):
        # A POSIX platform must never take the MSYS branch even if MSYSTEM
        # somehow ended up in the environment (it should not, but
        # is_windows is the gating condition, not msystem alone).
        p = Path("/home/u/.local/share/agent-learning")
        rendered = paths._to_cli_string(p, is_windows=False, msystem="MINGW64")
        self.assertEqual(rendered, "/home/u/.local/share/agent-learning")

    def test_msys_branch_driveless_path_falls_back_to_as_posix(self):
        p = PureWindowsPath(r"\\server\share\agent-learning")
        rendered = paths._to_cli_string(p, is_windows=True, msystem="MINGW64")
        self.assertEqual(rendered, p.as_posix())

    def test_to_msys_path_direct(self):
        p = PureWindowsPath(r"C:\Users\u\AppData\Local\agent-learning")
        self.assertEqual(paths._to_msys_path(p), "/c/Users/u/AppData/Local/agent-learning")

    def test_to_msys_path_drive_root_only(self):
        p = PureWindowsPath("C:\\")
        self.assertEqual(paths._to_msys_path(p), "/c")

    def test_driveless_absolute_path_renders_forward_slash_not_backslash(self):
        # Fix round F: explicit, pinned decision for a drive-less absolute
        # WindowsPath (e.g. what `Path("/tmp/x")` becomes when constructed
        # on native Windows -- no drive letter, root "\\"). PureWindowsPath.drive
        # is empty for this shape, so _to_msys_path's cygdrive branch cannot
        # apply (there is no single drive letter to build '/x/...' from);
        # it must fall back to plain .as_posix() -- which itself IS
        # guaranteed forward-slash, by definition of .as_posix() -- rather
        # than ever surface the backslash form str()/os.fspath() would give
        # for the same PureWindowsPath. Pinned for both branches (MSYS-form
        # requested and not), since a driveless path has nothing
        # MSYS-specific to convert either way -- the answer must be the
        # same regardless of which branch of _to_cli_string is taken.
        p = PureWindowsPath(r"\tmp\x\memory")
        self.assertEqual(p.drive, "")
        # Explicit "" (not None) for the "no MSYSTEM" cases throughout --
        # None is the ambient-fallback sentinel (see the two fixes above in
        # this class); every case here must be deterministic regardless of
        # this test's own environment.
        for is_windows, msystem in ((True, "MINGW64"), (True, ""), (False, "")):
            with self.subTest(is_windows=is_windows, msystem=msystem):
                rendered = paths._to_cli_string(p, is_windows=is_windows, msystem=msystem)
                self.assertEqual(rendered, "/tmp/x/memory")
                self.assertNotIn("\\", rendered)

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
        # Fix round F: this test does not pass is_windows=/msystem=, so
        # (like test_windows_path_rendered_with_forward_slashes above) it
        # silently read the ambient MSYSTEM env var, which IS set on the
        # real windows-latest CI runner -- pin it so the assertion is
        # deterministic rather than platform-dependent.
        with mock.patch.dict(os.environ, {"MSYSTEM": ""}):
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


class TestCliLineEndings(unittest.TestCase):
    """Fix round E: Python's default text-mode stdout on native Windows
    translates outgoing "\\n" to "\\r\\n" even for a pipe destination, which
    would silently embed a stray \\r in every path this CLI emits (bash's
    `read`/command-substitution strip only the trailing \\n record
    terminator, never a \\r immediately before it). _main() now calls
    sys.stdout.reconfigure(newline="\\n") to force LF-only output regardless
    of platform. This assertion is a no-op strengthening on Linux/macOS
    (which never had \\r\\n translation to begin with) -- it cannot prove the
    Windows behavior from here, but pins the invariant "no \\r ever appears
    in this CLI's raw output bytes" so a future regression that reintroduces
    platform-default text-mode stdout is at least structurally guarded."""

    def test_get_output_has_no_carriage_return_bytes(self):
        env = dict(os.environ, AGENT_LEARNING_HOME="/tmp/x")
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "memory"],
            capture_output=True, env=env, check=True)
        self.assertNotIn(b"\r", r.stdout)

    def test_all_output_has_no_carriage_return_bytes(self):
        env = dict(os.environ, AGENT_LEARNING_HOME="/tmp/x")
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "all"],
            capture_output=True, env=env, check=True)
        self.assertNotIn(b"\r", r.stdout)


class TestCli(unittest.TestCase):
    def test_get_prints_single_path(self):
        # Fix round F: the expected value used to be str(Path("/tmp/x/memory")),
        # which is itself platform-dependent -- on native Windows, Path()
        # constructs a WindowsPath, and str() on a driveless WindowsPath
        # (no drive letter for "/tmp/x", see
        # test_driveless_absolute_path_renders_forward_slash_not_backslash)
        # renders with BACKSLASHES ('\tmp\x\memory'), which is not what the
        # CLI itself ever prints (paths._to_cli_string always renders
        # forward-slash, on every platform -- see that test). The bug was
        # in this test's own ground truth, not the CLI: building the
        # expected value via _to_cli_string directly (in-process, same
        # interpreter/OS the subprocess below also runs on) makes the
        # assertion correct on every platform instead of only on POSIX,
        # where PosixPath's str() happens to already look like
        # _to_cli_string's output.
        env = dict(os.environ, AGENT_LEARNING_HOME="/tmp/x")
        out = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "memory"],
            capture_output=True, text=True, env=env, check=True).stdout.strip()
        self.assertEqual(out, paths._to_cli_string(Path("/tmp/x/memory")))

    def test_get_unknown_key_exits_nonzero(self):
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "paths.py"), "get", "nope"],
            capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
