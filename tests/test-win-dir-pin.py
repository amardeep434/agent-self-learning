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

WHY THE WINDOWS HALF IS SHAPED THE WAY IT IS (learned the hard way)
------------------------------------------------------------------
CI run 30184253819 passed 38 of 39 tests on both Windows cells and failed the
only one that encoded the point: a pinned directory was renamed anyway. The
plumbing tests all passed because they tested plumbing.

So the Windows half now has three layers, and the middle one is the important
one:

  1. `test_guarantee_holds_on_this_runner` -- the headline property, measured
     directly, never conditional and never relaxed. If the guarantee cannot
     be delivered, this test going red is the correct outcome and the module
     should be downgraded rather than the assertion softened.
  2. `test_probe_agrees_with_the_measured_guarantee` -- fails if
     `available()` claims MORE than the machine delivers, and also if it
     claims less. This is what makes a green run mean something: the module
     can no longer be live while advertising protection it does not have.
  3. The narrower properties (rmdir, writes-inside, reparse refusal, release),
     each separated so CI reports which one held.

`available()` itself was changed to mean "the guarantee was measured and
held", not "CreateFileW returned a handle" -- see win_dir_pin's
verify_pin_contract.
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
_PIN_OK, _PIN_WHY = win_dir_pin.probe_detail()
print("[capability probe] win32 directory pinning: {} ({})".format(
    "AVAILABLE" if _PIN_OK else "UNAVAILABLE", _PIN_WHY), flush=True)


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
    def test_share_mode_denies_delete_and_grants_write(self):
        """Both halves, and the asymmetry between them, pinned as values.

        Denying FILE_SHARE_DELETE is the mechanism: MSDN says without it "no
        process can open the file or device if it requests delete access",
        and "delete access allows both delete and rename operations". Adding
        it back silently reopens the race.

        GRANTING FILE_SHARE_WRITE is equally load-bearing, in the other
        direction. Creating a file in a directory is a write to the DIRECTORY
        object -- FILE_ADD_FILE and FILE_WRITE_DATA are both 0x0002 -- so
        denying write sharing denies our own staging. That configuration
        shipped once and broke persistence across 10 of 43 suites on Windows.
        """
        self.assertEqual(win_dir_pin.PIN_SHARE_MODE & win_dir_pin.FILE_SHARE_DELETE, 0,
                         "granting delete sharing reopens the swap race")
        self.assertTrue(win_dir_pin.PIN_SHARE_MODE & win_dir_pin.FILE_SHARE_WRITE,
                        "denying write sharing blocks our own staged writes: "
                        "FILE_ADD_FILE == FILE_WRITE_DATA == 0x0002")
        self.assertTrue(win_dir_pin.PIN_SHARE_MODE & win_dir_pin.FILE_SHARE_READ)

    def test_share_constant_values_are_the_documented_ones(self):
        self.assertEqual(win_dir_pin.FILE_SHARE_READ, 0x0001)
        self.assertEqual(win_dir_pin.FILE_SHARE_WRITE, 0x0002)
        self.assertEqual(win_dir_pin.FILE_SHARE_DELETE, 0x0004)

    def test_pin_flags_include_backup_semantics_and_open_reparse_point(self):
        self.assertTrue(win_dir_pin.PIN_FLAGS & 0x02000000)  # BACKUP_SEMANTICS
        self.assertTrue(win_dir_pin.PIN_FLAGS & 0x00200000)  # OPEN_REPARSE_POINT

    def test_desired_access_requests_read_not_only_attributes(self):
        """The regression that shipped once and must not ship again.

        FILE_READ_ATTRIBUTES alone does not enter the kernel's share-access
        accounting -- Microsoft documents this via the override flag
        IO_CHECK_SHARE_ACCESS_FORCE_CHECK, "force check share access even if
        the request is not read/write/delete access". With attributes-only
        access the handle was held, the share mode was correct, and a pinned
        directory was renamed anyway on Windows CI.
        """
        self.assertTrue(win_dir_pin.PIN_DESIRED_ACCESS & win_dir_pin.FILE_LIST_DIRECTORY,
                        "the pin must request read access or the share mode is never "
                        "consulted by a subsequent opener")
        self.assertTrue(win_dir_pin.PIN_DESIRED_ACCESS & win_dir_pin.FILE_READ_ATTRIBUTES)

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


class StagedReplaceProbeTest(unittest.TestCase):
    """The write half of the contract, executed for real on any platform.

    `staged_replace_probe` is pure stdlib filesystem work, so unlike the pin
    itself it runs here. It must perform the SAME three operations the writer
    does -- create a destination, mkstemp alongside it, replace over it --
    because those are the three that open the parent directory requesting
    FILE_ADD_FILE and are therefore the three a share mode can refuse. A probe
    that tested something weaker is how the previous round shipped a
    "verified" guarantee that broke every write.
    """

    def test_succeeds_and_leaves_the_replaced_destination(self):
        with tempfile.TemporaryDirectory() as d:
            win_dir_pin.staged_replace_probe(d)
            target = os.path.join(d, "pin-probe-target")
            self.assertTrue(os.path.exists(target))
            with open(target) as handle:
                self.assertEqual(handle.read(), "y", "the replace must have landed")

    def test_replaces_an_existing_destination_not_just_creates_one(self):
        """os.replace over an EXISTING file is the operation that needs delete
        access on the destination entry; replacing nothing would not exercise
        it."""
        with tempfile.TemporaryDirectory() as d:
            calls = []
            real_replace = os.replace

            def spy(src, dst):
                calls.append(os.path.exists(dst))
                return real_replace(src, dst)
            os.replace = spy
            try:
                win_dir_pin.staged_replace_probe(d)
            finally:
                os.replace = real_replace
            self.assertEqual(calls, [True], "destination must already exist")

    def test_leaves_no_stray_temp_file(self):
        with tempfile.TemporaryDirectory() as d:
            win_dir_pin.staged_replace_probe(d)
            self.assertEqual(sorted(os.listdir(d)), ["pin-probe-target"])

    def test_raises_oserror_when_the_directory_is_unwritable(self):
        if os.geteuid() == 0:
            self.skipTest("[skip] running as root; mode bits do not deny writes")
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "ro")
            os.mkdir(sub, 0o500)
            try:
                with self.assertRaises(OSError):
                    win_dir_pin.staged_replace_probe(sub)
            finally:
                os.chmod(sub, 0o700)


class VerifyGuaranteeTest(unittest.TestCase):
    """`verify_pin_contract`'s decision logic, driven with fakes.

    This is the function that decides whether the module is allowed to claim
    anything at all, so it is the one piece that most needs to be executable
    where the Win32 backend cannot run.
    """

    def _run(self, rename_impl):
        log = []
        pin = FakePin("/d/dir", log)
        result = win_dir_pin.verify_pin_contract(
            "/d/dir", "/d/moved", opener=lambda p: pin, rename=rename_impl,
            write_probe=lambda directory: None)
        return result, pin, log

    def test_blocked_while_pinned_and_allowed_after_release_is_held(self):
        state = {"released": False}
        pin_holder = {}

        def rename(src, dst):
            if not state["released"]:
                raise OSError(32, "sharing violation")

        def opener(path):
            pin = FakePin(path, [])
            original_close = pin.close

            def close():
                state["released"] = True
                original_close()
            pin.close = close
            pin_holder["pin"] = pin
            return pin

        result = win_dir_pin.verify_pin_contract(
            "/d/dir", "/d/moved", opener=opener, rename=rename,
            write_probe=lambda directory: None)
        self.assertEqual(result, win_dir_pin.GUARANTEE_HELD)
        self.assertTrue(pin_holder["pin"].closed)

    def test_blocked_writes_are_reported_before_anything_else(self):
        """The failure that broke persistence on Windows CI 30184755246.

        A pin that refuses our own staged replace must disable the module,
        and must say so in its own terms -- not be rounded up to HELD because
        the rename half happened to pass, which is exactly what the previous
        single-property probe did.
        """
        pin = FakePin("/d/dir", [])

        def blocked_writes(directory):
            raise OSError(32, "sharing violation")

        result = win_dir_pin.verify_pin_contract(
            "/d/dir", "/d/moved", opener=lambda p: pin,
            rename=lambda src, dst: (_ for _ in ()).throw(OSError(32, "blocked")),
            write_probe=blocked_writes)
        self.assertEqual(result, win_dir_pin.GUARANTEE_BLOCKS_OUR_WRITES)
        self.assertTrue(pin.closed)

    def test_write_probe_runs_while_the_pin_is_still_held(self):
        """Measuring writes after release would measure nothing at all."""
        events = []
        pin = FakePin("/d/dir", events)
        win_dir_pin.verify_pin_contract(
            "/d/dir", "/d/moved", opener=lambda p: pin,
            rename=lambda src, dst: (_ for _ in ()).throw(OSError(32, "blocked")),
            write_probe=lambda directory: events.append(("write", directory)))
        self.assertLess(events.index(("write", "/d/dir")),
                        [e[0] for e in events].index("close"))

    def test_rename_succeeding_while_pinned_is_not_enforced(self):
        """The exact Windows CI failure. Must disable the module, not be
        rounded up to 'probably fine'."""
        result, pin, _log = self._run(lambda src, dst: None)
        self.assertEqual(result, win_dir_pin.GUARANTEE_NOT_ENFORCED)
        self.assertTrue(pin.closed)

    def test_rename_failing_both_times_is_inconclusive_not_held(self):
        """A read-only volume, a permission problem or an antivirus lock
        fails the rename for reasons that have nothing to do with the pin.
        Without the control experiment that reads as protection."""
        def always_fails(src, dst):
            raise OSError(5, "access denied")
        result, pin, _log = self._run(always_fails)
        self.assertEqual(result, win_dir_pin.GUARANTEE_INCONCLUSIVE)
        self.assertTrue(pin.closed)

    def test_the_directory_is_restored_before_the_control_experiment(self):
        """When the rename is NOT blocked the directory has moved; leaving it
        moved would make the control run against a path that no longer
        exists, and the answer would be an artefact of the probe."""
        calls = []
        win_dir_pin.verify_pin_contract(
            "/d/dir", "/d/moved", opener=lambda p: FakePin(p, []),
            rename=lambda src, dst: calls.append((src, dst)),
            write_probe=lambda directory: None)
        self.assertEqual(calls, [("/d/dir", "/d/moved"), ("/d/moved", "/d/dir")])

    def test_pin_is_released_even_if_rename_raises_something_unexpected(self):
        pin = FakePin("/d/dir", [])

        def explode(src, dst):
            raise RuntimeError("not an OSError")
        with self.assertRaises(RuntimeError):
            win_dir_pin.verify_pin_contract(
                "/d/dir", "/d/moved", opener=lambda p: pin, rename=explode,
                write_probe=lambda directory: None)
        self.assertTrue(pin.closed, "a leaked handle would make the directory "
                                    "undeletable for the life of the process")

    def test_reason_constants_are_distinct(self):
        reasons = {win_dir_pin.GUARANTEE_HELD, win_dir_pin.GUARANTEE_NO_BACKEND,
                   win_dir_pin.GUARANTEE_NOT_ENFORCED,
                   win_dir_pin.GUARANTEE_INCONCLUSIVE,
                   win_dir_pin.GUARANTEE_BLOCKS_OUR_WRITES}
        self.assertEqual(len(reasons), 5)


class ProbeVerdictMappingTest(unittest.TestCase):
    """`_probe`'s verdict -> availability mapping, executed on any platform.

    Without this the mapping is only reachable on Windows, and a mutation
    making `_probe` return available regardless of the measured verdict
    survived the whole suite: on POSIX the function returns early at the
    no-backend branch and never reaches the line. That is precisely the
    "module claims protection it does not have" failure this round exists to
    prevent, so it must be provable here.
    """

    def setUp(self):
        self._orig_win32 = win_dir_pin._win32
        self._orig_verify = win_dir_pin.verify_pin_contract
        self._orig_cache = win_dir_pin._PROBE

        def restore():
            win_dir_pin._win32 = self._orig_win32
            win_dir_pin.verify_pin_contract = self._orig_verify
            win_dir_pin._PROBE = self._orig_cache
        self.addCleanup(restore)

    def _probe_with(self, reason):
        win_dir_pin._win32 = lambda: object()          # pretend kernel32 exists
        win_dir_pin.verify_pin_contract = lambda *a, **k: reason
        return win_dir_pin._probe()

    def test_held_is_the_only_verdict_that_yields_available(self):
        ok, why = self._probe_with(win_dir_pin.GUARANTEE_HELD)
        self.assertTrue(ok)
        self.assertEqual(why, win_dir_pin.GUARANTEE_HELD)

    def test_not_enforced_yields_unavailable(self):
        ok, why = self._probe_with(win_dir_pin.GUARANTEE_NOT_ENFORCED)
        self.assertFalse(ok, "a kernel that allows the swap must disable pinning")
        self.assertEqual(why, win_dir_pin.GUARANTEE_NOT_ENFORCED)

    def test_blocked_writes_yield_unavailable(self):
        """THE non-negotiable: a probe verdict of "our writes are blocked"
        must never produce an available module. If this ever inverts,
        persistence breaks on every Windows write."""
        ok, why = self._probe_with(win_dir_pin.GUARANTEE_BLOCKS_OUR_WRITES)
        self.assertFalse(ok)
        self.assertEqual(why, win_dir_pin.GUARANTEE_BLOCKS_OUR_WRITES)

    def test_inconclusive_yields_unavailable(self):
        ok, _why = self._probe_with(win_dir_pin.GUARANTEE_INCONCLUSIVE)
        self.assertFalse(ok, "an unmeasurable guarantee is not a guarantee")

    def test_no_backend_short_circuits_without_touching_the_filesystem(self):
        win_dir_pin._win32 = lambda: None

        def must_not_run(*a, **k):
            raise AssertionError("verification attempted with no backend")
        win_dir_pin.verify_pin_contract = must_not_run
        ok, why = win_dir_pin._probe()
        self.assertFalse(ok)
        self.assertEqual(why, win_dir_pin.GUARANTEE_NO_BACKEND)

    def test_an_exception_during_verification_is_unavailable_not_a_crash(self):
        win_dir_pin._win32 = lambda: object()

        def boom(*a, **k):
            raise OSError(5, "access denied")
        win_dir_pin.verify_pin_contract = boom
        ok, why = win_dir_pin._probe()
        self.assertFalse(ok)
        self.assertIn("OSError", why)

    def test_probe_detail_caches_and_available_agrees_with_it(self):
        win_dir_pin._PROBE = None
        win_dir_pin._win32 = lambda: object()
        calls = []

        def once(*a, **k):
            calls.append(1)
            return win_dir_pin.GUARANTEE_NOT_ENFORCED
        win_dir_pin.verify_pin_contract = once
        self.assertFalse(win_dir_pin.available())
        self.assertFalse(win_dir_pin.probe_detail()[0])
        self.assertEqual(len(calls), 1, "the probe must run at most once per process")


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


class PinCannotBreakPersistenceTest(WriterIntegrationTest):
    """The structural guarantee: pinning must be UNABLE to break the write.

    win_dir_pin's probe checks that our own staged replace works while
    pinned, but it can only check it in a temp directory -- the store may be
    on another volume. So `_write_all_path` also releases every pin and
    retries the whole transaction unpinned if STAGING fails while pins are
    held. Staging touches no real target, which is what makes the retry safe.

    CI run 30184755246 is why this exists: a probe reported a verified
    guarantee and persistence was broken across 10 of 43 suites.
    """

    def _stage_fails_once(self):
        """Make the first staging attempt fail the way a sharing violation
        would, then behave normally."""
        state = {"failed": False}
        original = self.mod._stage

        def flaky(root, data):
            if not state["failed"]:
                state["failed"] = True
                raise OSError(32, "simulated sharing violation")
            return original(root, data)
        self.mod._stage = flaky
        self.addCleanup(setattr, self.mod, "_stage", original)
        return state

    def test_staging_failure_while_pinned_retries_unpinned_and_succeeds(self):
        opener = FakeOpener()
        self._install(opener)
        self._stage_fails_once()
        written, _total = self._run(MEMORY_PROPOSAL)
        self.assertEqual(len(written), 1)
        self.assertIn("- pinned", Path(written[0]).read_text())
        self.assertTrue(opener.closed_all(),
                        "pins must be released BEFORE the retry, not after it")

    def test_the_retry_runs_with_pinning_disabled(self):
        """Retrying while still pinned would hit the same wall."""
        opener = FakeOpener()
        self._install(opener)
        self._stage_fails_once()
        self._run(MEMORY_PROPOSAL)
        opens = [e for e in opener.log if e[0] == "open"]
        self.assertEqual(len(opens), 1,
                         "the second attempt must not pin anything: %r" % opener.log)

    def test_staging_failure_with_no_pins_still_propagates(self):
        """The retry must not swallow ordinary staging failures. With nothing
        pinned, pinning cannot be the cause and the original OSError has to
        surface exactly as it always did."""
        opener = FakeOpener(unopenable=("memory", "learned-skills"))
        self._install(opener)
        self._stage_fails_once()
        with self.assertRaises(OSError) as ctx:
            self._run(MEMORY_PROPOSAL)
        self.assertEqual(ctx.exception.errno, 32)

    def test_the_internal_marker_never_escapes(self):
        opener = FakeOpener(unopenable=("memory", "learned-skills"))
        self._install(opener)
        self._stage_fails_once()
        try:
            self._run(MEMORY_PROPOSAL)
        except self.mod._StagingFailed:  # pragma: no cover - the bug we forbid
            self.fail("_StagingFailed leaked to the caller")
        except OSError:
            pass

    def _count_attempts(self):
        attempts = []
        original = self.mod._write_all_path_once

        def counting(planned, pins):
            attempts.append(pins)
            return original(planned, pins)
        self.mod._write_all_path_once = counting
        self.addCleanup(setattr, self.mod, "_write_all_path_once", original)
        return attempts

    def test_a_confinement_refusal_is_never_retried_after_a_pin_was_taken(self):
        """A PersistError is an attack signal. Retrying one WITHOUT pins would
        be the single worst thing this path could do.

        The leaf of the skill chain is the reparse point, so `learned-skills`
        is pinned successfully first -- `pinned_paths()` is non-empty and the
        retry branch is genuinely reachable. Mutation-found: with the refusal
        on the FIRST chain element nothing is pinned, the retry is skipped for
        an unrelated reason, and making PersistError retryable went unnoticed.
        """
        opener = FakeOpener(reparse=("pin-demo",))
        self._install(opener)
        attempts = self._count_attempts()
        with self.assertRaises(self.mod.PersistError):
            self._run(SKILL_PROPOSAL)
        self.assertTrue(opener.opened, "a pin must have been taken before the refusal")
        self.assertEqual(len(attempts), 1, "a refusal must not be retried")

    def test_a_confinement_refusal_on_the_first_directory_is_not_retried_either(self):
        opener = FakeOpener(reparse=("memory",))
        self._install(opener)
        attempts = self._count_attempts()
        with self.assertRaises(self.mod.PersistError):
            self._run(MEMORY_PROPOSAL)
        self.assertEqual(len(attempts), 1)

    def test_commit_phase_failure_is_not_retried(self):
        """Past the first rename, entries are committed. Re-running an append
        there would double-apply it -- worse than the failure."""
        opener = FakeOpener()
        self._install(opener)
        attempts = []
        original = self.mod._write_all_path_once

        def counting(planned, pins):
            attempts.append(pins)
            return original(planned, pins)
        self.mod._write_all_path_once = counting
        self.addCleanup(setattr, self.mod, "_write_all_path_once", original)

        real_replace = os.replace

        def boom(*a, **k):
            raise OSError(5, "simulated commit failure")
        os.replace = boom
        try:
            with self.assertRaises(OSError):
                self._run(MEMORY_PROPOSAL)
        finally:
            os.replace = real_replace
        self.assertEqual(len(attempts), 1, "commit failures must not be retried")


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

    @staticmethod
    def _measure_guarantee(directory):
        """Directly measure whether a pinned directory can be renamed.

        Deliberately does NOT go through win_dir_pin.available() -- this is
        the independent measurement that available() is checked against.
        """
        parent = os.path.dirname(directory)
        moved = os.path.join(parent, "measured-move")
        pin = win_dir_pin.open_pin(directory)
        try:
            try:
                os.rename(directory, moved)
            except OSError as exc:
                return True, exc
            os.rename(moved, directory)
            return False, None
        finally:
            pin.close()

    def test_guarantee_holds_on_this_runner(self):
        """THE headline property. Not weakened, not conditional.

        If this fails, the module's entire value proposition does not hold on
        this platform and the honest response is to downgrade or remove it --
        never to relax this assertion. It failed once already, on CI run
        30184253819, with FILE_READ_ATTRIBUTES-only desired access.
        """
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            blocked, exc = self._measure_guarantee(sub)
            self.assertTrue(
                blocked,
                "a pinned directory was RENAMED while its handle was held. "
                "The share mode denies FILE_SHARE_DELETE and MSDN says delete "
                "access covers rename, so either the desired access still does "
                "not engage the kernel's share-access accounting, or renaming a "
                "directory does not take delete access on the directory itself. "
                "Either way this module cannot claim kernel-level protection. "
                "Measured error: {!r}".format(exc))

    def test_probe_agrees_with_the_measured_guarantee(self):
        """available() must never claim more than the machine delivers.

        This is the guard that makes a green run meaningful in BOTH
        directions: it fails if the module reports AVAILABLE while the kernel
        allows the swap, and equally if it reports UNAVAILABLE while the
        kernel blocks it (which would silently give up real protection).
        """
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            blocked, _exc = self._measure_guarantee(sub)
        ok, why = win_dir_pin.probe_detail()
        self.assertEqual(
            ok, blocked,
            "probe says available={} ({!r}) but the measured guarantee was "
            "blocked={}".format(ok, why, blocked))

    def test_module_is_inert_when_the_guarantee_does_not_hold(self):
        """If the property is not delivered, nothing may be pinned -- the
        write path must fall back to its documented race rather than run
        while advertising a protection it does not have."""
        if win_dir_pin.available():
            self.skipTest("[skip] guarantee holds here; inertness is the other branch")
        pins = win_dir_pin.PinSet()
        self.assertFalse(pins.enabled)
        with tempfile.TemporaryDirectory() as d:
            pins.pin(d)
        self.assertEqual(pins.pinned_paths(), [])

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

    def test_the_real_writer_operations_work_inside_a_pinned_directory(self):
        """Exactly what broke on CI run 30184755246, as its own assertion.

        `test_writes_inside_a_pinned_directory_still_work` above passed on the
        run BEFORE that one -- while the pin was completely inert -- and its
        replace target did not previously exist. This uses the probe the
        module itself relies on, which replaces over an existing file.
        """
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            pin = win_dir_pin.open_pin(sub)
            try:
                win_dir_pin.staged_replace_probe(sub)
            finally:
                pin.close()

    def test_pinned_directory_cannot_be_removed(self):
        """Split out from the rename assertion on purpose.

        They were one test, and the rename failed first -- so CI never
        reported whether rmdir was blocked. Deletion and rename are enforced
        by different mechanisms on Windows (an open handle blocks directory
        deletion outright; rename goes through the share-access check), so
        one holding tells you nothing about the other.
        """
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            pin = win_dir_pin.open_pin(sub)
            try:
                with self.assertRaises(OSError):
                    os.rmdir(sub)
            finally:
                pin.close()
            os.rmdir(sub)  # released -> allowed

    def test_rename_is_allowed_again_once_the_pin_is_released(self):
        """The control experiment, as a test: protection that never lifts is
        indistinguishable from an unwritable volume."""
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "real")
            os.mkdir(sub)
            pin = win_dir_pin.open_pin(sub)
            pin.close()
            os.rename(sub, os.path.join(d, "swapped"))
            self.assertTrue(os.path.isdir(os.path.join(d, "swapped")))

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
