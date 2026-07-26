#!/usr/bin/env python3
"""Tests for lib/win_dir_pin.py and its integration into persist-proposal.py.

WHAT CAN AND CANNOT BE PROVEN HERE, STATED UP FRONT
---------------------------------------------------
The CreateFileW backend cannot execute on a POSIX host at all: `ctypes.WinDLL`
does not exist there. So this suite is split deliberately.

  * Provable here (and proven below): the *sequencing* -- pin order is
    root-to-leaf, every chain directory gets pinned, duplicates are pinned
    once, every handle is released on success AND on failure, a
    ReparsePointError from the handle aborts the write with exit 2 and touches
    nothing, an un-openable directory degrades to the previous unpinned
    behaviour instead of failing the write, and the whole thing is inert when
    the probe says unavailable. Also provable: the constant values, the
    extended-path mapping, and that the probe is functional rather than a
    platform-name branch.

  * Provable only on Windows CI: that CreateFileW with these exact flags
    actually opens a directory handle on the runner, that the share mode
    genuinely makes the kernel refuse a concurrent rename/junction swap, and
    that holding the handles does not interfere with our own writes into
    those directories. `WindowsBackendTest` below runs the real backend and is
    skipped -- loudly, naming what is skipped -- everywhere else.

The fake opener used for the sequencing tests is intentionally dumb: it
records and returns, so a test failure means the *caller's* sequencing is
wrong, which is the only part of this that a POSIX host can be authoritative
about.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import win_dir_pin  # noqa: E402

# Printed unconditionally, in the same shape the rest of the suite uses, so a
# CI log answers the one question a POSIX host cannot: does CreateFileW
# directory pinning actually work on the runner? UNAVAILABLE on Windows would
# mean the write path silently fell back to the old unpinned race.
print("[capability probe] win32 directory pinning: {}".format(
    "AVAILABLE" if win_dir_pin.available()
    else "UNAVAILABLE (no kernel32 -- expected on POSIX, a defect on Windows)"),
    flush=True)


def _load_writer_module():
    spec = importlib.util.spec_from_file_location(
        "persist_proposal_pin", ROOT / "scripts" / "persist-proposal.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakePin:
    def __init__(self, path, log):
        self.path = path
        self._log = log
        self.closed = False

    def close(self):
        self.closed = True
        self._log.append(("close", self.path))


class FakeOpener:
    """Records opens; optionally raises for chosen paths."""

    def __init__(self, reparse=(), unopenable=()):
        self.log = []
        self.opened = []
        self.reparse = set(reparse)
        self.unopenable = set(unopenable)

    def __call__(self, path):
        self.log.append(("open", path))
        base = os.path.basename(path)
        if base in self.reparse or path in self.reparse:
            raise win_dir_pin.ReparsePointError(
                "refusing to use reparse-point store directory: %s" % path)
        if base in self.unopenable or path in self.unopenable:
            raise OSError(0, "CreateFileW failed", path, 5)
        pin = FakePin(path, self.log)
        self.opened.append(pin)
        return pin

    def closed_all(self):
        return all(p.closed for p in self.opened)


# ---------------------------------------------------------------------------
# Constants and pure helpers
# ---------------------------------------------------------------------------

class ConstantsTest(unittest.TestCase):
    def test_share_mode_omits_delete_and_write(self):
        """The whole mechanism is the omission. Pin it as a value, not prose.

        MSDN: without FILE_SHARE_DELETE "no process can open the file or
        device if it requests delete access", and "delete access allows both
        delete and rename operations". Adding either flag back would silently
        reopen the exact race this module closes while every other test here
        still passed.
        """
        self.assertEqual(win_dir_pin.PIN_SHARE_MODE, win_dir_pin.FILE_SHARE_READ)
        self.assertEqual(win_dir_pin.PIN_SHARE_MODE & 0x00000004, 0)  # FILE_SHARE_DELETE
        self.assertEqual(win_dir_pin.PIN_SHARE_MODE & 0x00000002, 0)  # FILE_SHARE_WRITE

    def test_pin_flags_include_backup_semantics_and_open_reparse_point(self):
        self.assertTrue(win_dir_pin.PIN_FLAGS & 0x02000000)  # BACKUP_SEMANTICS
        self.assertTrue(win_dir_pin.PIN_FLAGS & 0x00200000)  # OPEN_REPARSE_POINT

    def test_documented_constant_values(self):
        self.assertEqual(win_dir_pin.OPEN_EXISTING, 3)
        self.assertEqual(win_dir_pin.FILE_READ_ATTRIBUTES, 0x0080)
        self.assertEqual(win_dir_pin.FILE_ATTRIBUTE_DIRECTORY, 0x10)
        self.assertEqual(win_dir_pin.FILE_ATTRIBUTE_REPARSE_POINT, 0x400)


class ExtendedPathTest(unittest.TestCase):
    def test_drive_rooted_path_gets_extended_prefix(self):
        self.assertEqual(win_dir_pin.extended_path("C:\\store\\memory"),
                         "\\\\?\\C:\\store\\memory")

    def test_forward_slashes_are_normalised_before_prefixing(self):
        self.assertEqual(win_dir_pin.extended_path("C:/store/memory"),
                         "\\\\?\\C:\\store\\memory")

    def test_unc_path_uses_the_unc_form(self):
        self.assertEqual(win_dir_pin.extended_path("\\\\srv\\share\\x"),
                         "\\\\?\\UNC\\srv\\share\\x")

    def test_already_extended_path_is_untouched(self):
        for p in ("\\\\?\\C:\\x", "\\\\.\\C:\\x"):
            self.assertEqual(win_dir_pin.extended_path(p), p)

    def test_unrecognised_shape_is_returned_untouched(self):
        """Guessing a prefix for an exotic path is the silent-wrong-location
        bug class this project exists to eliminate; an unprefixed path still
        works below MAX_PATH."""
        for p in ("relative\\path", "/posix/path", "C:relative"):
            self.assertEqual(win_dir_pin.extended_path(p), p)


class InterpretInfoTest(unittest.TestCase):
    """The handle-verification verdict, exercised without a handle.

    This is the security decision the Windows path rests on. Keeping it pure
    is what lets a POSIX host prove it at all -- before the split, deleting
    the reparse-point refusal was a mutation nothing here could kill.
    """

    D = win_dir_pin.FILE_ATTRIBUTE_DIRECTORY
    R = win_dir_pin.FILE_ATTRIBUTE_REPARSE_POINT

    def test_plain_directory_is_accepted_and_identity_composed(self):
        serial, index = win_dir_pin.interpret_info("C:\\s", self.D, 0xABCD, 2, 7)
        self.assertEqual(serial, 0xABCD)
        self.assertEqual(index, (2 << 32) | 7)

    def test_reparse_point_directory_is_refused(self):
        """A junction: FILE_ATTRIBUTE_DIRECTORY is *also* set on one, so
        checking "is a directory" alone would wave it straight through."""
        with self.assertRaises(win_dir_pin.ReparsePointError) as ctx:
            win_dir_pin.interpret_info("C:\\s", self.D | self.R, 1, 0, 0)
        self.assertIn("reparse-point", str(ctx.exception))

    def test_reparse_point_without_directory_bit_is_refused(self):
        with self.assertRaises(win_dir_pin.ReparsePointError):
            win_dir_pin.interpret_info("C:\\s", self.R, 1, 0, 0)

    def test_non_directory_is_refused(self):
        with self.assertRaises(win_dir_pin.ReparsePointError) as ctx:
            win_dir_pin.interpret_info("C:\\s", 0x80, 1, 0, 0)  # FILE_ATTRIBUTE_NORMAL
        self.assertIn("non-directory", str(ctx.exception))

    def test_other_attributes_do_not_change_the_verdict(self):
        noisy = self.D | 0x2 | 0x4 | 0x2000  # hidden | system | not-content-indexed
        serial, _index = win_dir_pin.interpret_info("C:\\s", noisy, 9, 0, 0)
        self.assertEqual(serial, 9)

    def test_high_index_word_is_not_truncated(self):
        _serial, index = win_dir_pin.interpret_info("C:\\s", self.D, 0, 0xFFFFFFFF, 0xFFFFFFFF)
        self.assertEqual(index, (1 << 64) - 1)


class ProbeTest(unittest.TestCase):
    def test_availability_is_functional_not_platform_named(self):
        """On any host without ctypes.WinDLL the probe must be False, and it
        must reach that answer by failing to bind kernel32 -- not by reading
        sys.platform. Asserted by checking the module never consults it."""
        import io
        import tokenize
        source = (ROOT / "scripts" / "lib" / "win_dir_pin.py").read_text()
        # Strip comments AND string literals (docstrings discuss sys.platform
        # precisely to explain why it is not used) so this asserts about code,
        # not prose. A naive substring check over the raw file passes for the
        # wrong reason.
        code = "".join(
            tok.string for tok in tokenize.generate_tokens(io.StringIO(source).readline)
            if tok.type not in (tokenize.COMMENT, tokenize.STRING))
        for banned in ("sys.platform", "os.name", "platform.system"):
            self.assertNotIn(banned, code,
                             "capability must be probed, never branched on a platform name")

    def test_probe_matches_backend_presence(self):
        has_backend = hasattr(__import__("ctypes"), "WinDLL")
        if not has_backend:
            self.assertFalse(win_dir_pin.available())

    def test_open_pin_raises_oserror_without_a_backend(self):
        if hasattr(__import__("ctypes"), "WinDLL"):
            self.skipTest("[skip] Windows backend present; covered by WindowsBackendTest")
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(OSError):
                win_dir_pin.open_pin(d)


# ---------------------------------------------------------------------------
# PinSet sequencing -- the part a POSIX host CAN be authoritative about
# ---------------------------------------------------------------------------

class PinSetTest(unittest.TestCase):
    def test_disabled_pinset_never_calls_the_opener(self):
        opener = FakeOpener()
        pins = win_dir_pin.PinSet(opener=opener, enabled=False)
        pins.pin("/a")
        pins.pin("/a/b")
        pins.close_all()
        self.assertEqual(opener.log, [])
        self.assertEqual(pins.pinned_paths(), [])

    def test_real_pinset_is_inert_on_this_host_when_probe_is_false(self):
        if win_dir_pin.available():
            self.skipTest("[skip] pinning available here; sequencing covered elsewhere")
        pins = win_dir_pin.PinSet()
        self.assertFalse(pins.enabled)
        pins.pin("/nonexistent/should/not/matter")
        self.assertEqual(pins.pinned_paths(), [])
        pins.close_all()

    def test_pins_in_root_to_leaf_order(self):
        opener = FakeOpener()
        pins = win_dir_pin.PinSet(opener=opener, enabled=True)
        for p in ("/s", "/s/skills", "/s/skills/foo"):
            pins.pin(p)
        self.assertEqual([e[1] for e in opener.log if e[0] == "open"],
                         ["/s", "/s/skills", "/s/skills/foo"])
        self.assertEqual(pins.pinned_paths(), ["/s", "/s/skills", "/s/skills/foo"])

    def test_duplicate_paths_are_opened_once(self):
        opener = FakeOpener()
        pins = win_dir_pin.PinSet(opener=opener, enabled=True)
        pins.pin("/s/skills")
        pins.pin("/s/skills")
        pins.pin("/s/skills")
        self.assertEqual(len([e for e in opener.log if e[0] == "open"]), 1)

    def test_close_all_releases_every_handle_and_clears(self):
        opener = FakeOpener()
        pins = win_dir_pin.PinSet(opener=opener, enabled=True)
        pins.pin("/a")
        pins.pin("/a/b")
        pins.close_all()
        self.assertTrue(opener.closed_all())
        self.assertEqual(pins.pinned_paths(), [])

    def test_close_all_is_idempotent(self):
        opener = FakeOpener()
        pins = win_dir_pin.PinSet(opener=opener, enabled=True)
        pins.pin("/a")
        pins.close_all()
        pins.close_all()

    def test_close_all_never_raises_even_if_a_handle_close_fails(self):
        """close_all() runs in a `finally`; if it raised it would mask the
        real exception -- the exact silent-failure shape this project bans."""
        class Exploding(FakePin):
            def close(self):
                raise RuntimeError("CloseHandle blew up")

        opener = FakeOpener()
        opener.__call__ = None  # unused; build the set by hand
        pins = win_dir_pin.PinSet(opener=lambda p: Exploding(p, []), enabled=True)
        pins.pin("/a")
        pins.close_all()  # must not raise

    def test_reparse_point_propagates(self):
        opener = FakeOpener(reparse=("evil",))
        pins = win_dir_pin.PinSet(opener=opener, enabled=True)
        pins.pin("/s")
        with self.assertRaises(win_dir_pin.ReparsePointError):
            pins.pin("/s/evil")

    def test_unopenable_directory_degrades_instead_of_failing(self):
        """A network share or an antivirus holding a handle must not turn a
        working install into a failing one. Degrade to the older unpinned
        behaviour -- the race, not an outage."""
        opener = FakeOpener(unopenable=("locked",))
        pins = win_dir_pin.PinSet(opener=opener, enabled=True)
        pins.pin("/s")
        pins.pin("/s/locked")          # must not raise
        pins.pin("/s/locked/deeper")
        self.assertEqual(pins.pinned_paths(), ["/s", "/s/locked/deeper"])


# ---------------------------------------------------------------------------
# persist-proposal.py integration, driven through the injection seam
# ---------------------------------------------------------------------------

MEMORY_PROPOSAL = json.dumps({
    "version": 1,
    "memory": [{"file": "MEMORY.md", "mode": "append", "content": "- pinned\n"}],
    "skills": [],
})

SKILL_PROPOSAL = json.dumps({
    "version": 1,
    "memory": [],
    "skills": [{"name": "pin-demo", "mode": "replace", "content": "# pin demo\n"}],
})


class WriterIntegrationTest(unittest.TestCase):
    """Runs the real writer in-process with a recording PinSet."""

    def setUp(self):
        self.mod = _load_writer_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self._orig_factory = self.mod._PIN_SET_FACTORY

        def restore():
            self.mod._PIN_SET_FACTORY = self._orig_factory
        self.addCleanup(restore)

    def _install(self, opener):
        made = {}

        def factory():
            pins = win_dir_pin.PinSet(opener=opener, enabled=True)
            made["set"] = pins
            return pins
        self.mod._PIN_SET_FACTORY = factory
        return made

    def _run(self, proposal):
        os.environ["AGENT_LEARNING_HOME"] = str(self.home)
        self.addCleanup(os.environ.pop, "AGENT_LEARNING_HOME", None)
        resolved = self.mod.paths.resolve_all()
        proposal_obj = json.loads(proposal)
        memory_dir = Path(resolved["memory"])
        skills_dir = Path(resolved["skills"])
        planned = self.mod._plan(proposal_obj, memory_dir, skills_dir)
        return self.mod._write_all_path(planned)

    def test_default_factory_is_the_real_pinset(self):
        """The production default must not be a test double."""
        self.assertIs(self._orig_factory, win_dir_pin.PinSet)

    def test_every_chain_directory_is_pinned_root_to_leaf(self):
        opener = FakeOpener()
        self._install(opener)
        written, _total = self._run(SKILL_PROPOSAL)
        opens = [e[1] for e in opener.log if e[0] == "open"]
        self.assertEqual(len(opens), 2, opens)
        self.assertTrue(opens[1].startswith(opens[0]),
                        "leaf must be pinned after (and under) its parent: %r" % opens)
        self.assertTrue(opens[1].endswith("pin-demo"))
        self.assertEqual(len(written), 2)  # SKILL.md + .usage.json

    def test_handles_released_after_a_successful_write(self):
        opener = FakeOpener()
        self._install(opener)
        self._run(MEMORY_PROPOSAL)
        self.assertTrue(opener.closed_all())
        self.assertEqual(opener.log[-1][0], "close")

    def test_handles_released_when_the_write_fails(self):
        """Leaking a pin would leave the store directory undeletable for the
        life of the process -- a denial of service caused by the fix."""
        opener = FakeOpener()
        self._install(opener)
        os.environ["AGENT_LEARNING_HOME"] = str(self.home)
        self.addCleanup(os.environ.pop, "AGENT_LEARNING_HOME", None)
        resolved = self.mod.paths.resolve_all()
        memory_dir = Path(resolved["memory"])
        skills_dir = Path(resolved["skills"])
        planned = self.mod._plan(json.loads(MEMORY_PROPOSAL), memory_dir, skills_dir)
        # Make the commit phase fail after staging succeeded.
        orig_replace = os.replace

        def boom(*a, **k):
            raise OSError(5, "simulated commit failure")
        os.replace = boom
        try:
            with self.assertRaises(OSError):
                self.mod._write_all_path(planned)
        finally:
            os.replace = orig_replace
        self.assertTrue(opener.opened, "expected at least one pin to have been taken")
        self.assertTrue(opener.closed_all())

    def test_reparse_point_on_a_chain_directory_refuses_the_write(self):
        opener = FakeOpener(reparse=("memory",))
        self._install(opener)
        os.environ["AGENT_LEARNING_HOME"] = str(self.home)
        self.addCleanup(os.environ.pop, "AGENT_LEARNING_HOME", None)
        resolved = self.mod.paths.resolve_all()
        memory_dir = Path(resolved["memory"])
        skills_dir = Path(resolved["skills"])
        planned = self.mod._plan(json.loads(MEMORY_PROPOSAL), memory_dir, skills_dir)
        with self.assertRaises(self.mod.PersistError) as ctx:
            self.mod._write_all_path(planned)
        self.assertIn("reparse-point", str(ctx.exception))
        self.assertFalse((memory_dir / "MEMORY.md").exists(),
                         "nothing may be written after a reparse-point refusal")
        self.assertTrue(opener.closed_all())

    def test_unopenable_chain_directory_still_completes_the_write(self):
        opener = FakeOpener(unopenable=("memory",))
        self._install(opener)
        written, _total = self._run(MEMORY_PROPOSAL)
        self.assertEqual(len(written), 1)
        self.assertIn("- pinned", Path(written[0]).read_text())

    def test_posix_dispatch_is_unchanged(self):
        """`_write_all` must still choose the dir_fd writer wherever dir_fd
        works. Pinning is additive to the fallback, never a replacement for
        the stronger POSIX path."""
        if not self.mod.DIR_FD_SUPPORTED:
            self.skipTest("[skip] dir_fd unavailable here (expected on Windows)")
        calls = []
        orig = self.mod._write_all_fd

        def spy(planned):
            calls.append(planned)
            return orig(planned)
        self.mod._write_all_fd = spy
        try:
            os.environ["AGENT_LEARNING_HOME"] = str(self.home)
            self.addCleanup(os.environ.pop, "AGENT_LEARNING_HOME", None)
            resolved = self.mod.paths.resolve_all()
            planned = self.mod._plan(json.loads(MEMORY_PROPOSAL),
                                     Path(resolved["memory"]), Path(resolved["skills"]))
            self.mod._write_all(planned)
        finally:
            self.mod._write_all_fd = orig
        self.assertEqual(len(calls), 1)


class EndToEndUnpinnedTest(unittest.TestCase):
    """The writer as a subprocess, with the real (inert on POSIX) PinSet.

    Guards the thing a mocked test cannot: that adding pinning did not change
    the observable behaviour of a normal run on this platform.
    """

    def test_normal_write_still_succeeds(self):
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, AGENT_LEARNING_HOME=d)
            proc = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "persist-proposal.py")],
                input=MEMORY_PROPOSAL, capture_output=True, text=True, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            payload = json.loads(proc.stdout)
            self.assertEqual(len(payload["written"]), 1)
            self.assertIn("- pinned", Path(payload["written"][0]).read_text())


@unittest.skipUnless(hasattr(__import__("ctypes"), "WinDLL"),
                     "[skip] real CreateFileW backend: Windows only "
                     "(kernel32 pin/verify/release cycle -- CI-only coverage)")
class WindowsBackendTest(unittest.TestCase):
    """The half only Windows CI can execute. Skipped loudly elsewhere."""

    def test_probe_reports_available(self):
        self.assertTrue(win_dir_pin.available(),
                        "CreateFileW directory pinning must work on Windows; "
                        "if this fails the fallback is silently the old race")

    def test_pin_a_real_directory_and_read_its_identity(self):
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            pin = win_dir_pin.open_pin(sub)
            try:
                serial, index = pin.identity()
                self.assertIsInstance(serial, int)
                self.assertIsInstance(index, int)
            finally:
                pin.close()

    def test_writes_inside_a_pinned_directory_still_work(self):
        """The make-or-break Windows behaviour: the share mode restricts opens
        of the *directory*, not creation of children inside it."""
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            pin = win_dir_pin.open_pin(sub)
            try:
                staged = os.path.join(sub, "tmp")
                with open(staged, "w") as fh:
                    fh.write("x")
                os.replace(staged, os.path.join(sub, "final"))
                self.assertTrue(os.path.exists(os.path.join(sub, "final")))
            finally:
                pin.close()

    def test_pinned_directory_cannot_be_renamed_or_removed(self):
        """The kernel-level guarantee this module buys."""
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            pin = win_dir_pin.open_pin(sub)
            try:
                with self.assertRaises(OSError):
                    os.rename(sub, os.path.join(d, "swapped"))
                with self.assertRaises(OSError):
                    os.rmdir(sub)
            finally:
                pin.close()
            os.rename(sub, os.path.join(d, "swapped"))  # released -> allowed

    def test_a_reparse_point_is_refused_by_the_handle(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "real")
            os.mkdir(real)
            link = os.path.join(d, "link")
            try:
                os.symlink(real, link, target_is_directory=True)
            except OSError:
                self.skipTest("[skip] symlink creation unavailable on this runner")
            with self.assertRaises(win_dir_pin.ReparsePointError):
                win_dir_pin.open_pin(link)


if __name__ == "__main__":
    unittest.main(verbosity=1)
