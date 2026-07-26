#!/usr/bin/env python3
"""Windows directory *pinning*: close the write-path TOCTOU window that
`dir_fd` + `O_NOFOLLOW` closes on POSIX and Windows cannot express.

WHY THIS EXISTS
---------------
persist-proposal.py's `_write_all_fd` anchors every operation to an already
open directory file descriptor opened with `O_NOFOLLOW`, so no path component
is ever re-resolved from a string after being validated. Windows has neither
primitive: CPython documents `os.O_NOFOLLOW` under "extensions ... not present
if they are not defined by the C library" with Availability Linux/macOS/Unix
(https://docs.python.org/3/library/os.html#os.O_NOFOLLOW), and `dir_fd` is a
"some Unix platforms" feature that raises NotImplementedError elsewhere. This
repo's own CI probe on windows-latest prints both as UNAVAILABLE.

So on Windows persist-proposal falls back to `_write_all_path`, which
re-resolves directory paths as strings and carries a race measured at up to
~18% escape under active contention on POSIX. The threat is not theoretical
there: the same CI probe prints "symlink creation: AVAILABLE" on
windows-latest, and directory *junctions* have never required elevation at
all.

THE PRIMITIVE
-------------
Win32 cannot anchor a *path* to a handle without dropping to ntdll
(`NtCreateFile` + `OBJECT_ATTRIBUTES.RootDirectory`, with `UNICODE_STRING`
marshalling and `NTSTATUS` decoding) -- judged too expensive. But it does not
have to. A cheaper documented primitive closes the *same* window: open each
directory in the chain, root-to-leaf, and *hold the handle* across the whole
check -> stage -> rename sequence.

  * `FILE_FLAG_BACKUP_SEMANTICS` (0x02000000) -- MSDN: "You must set this flag
    to obtain a handle to a directory."
  * `FILE_FLAG_OPEN_REPARSE_POINT` (0x00200000) -- MSDN: "Normal reparse point
    processing will not occur; CreateFile will attempt to open the reparse
    point. ... If the file is not a reparse point, then this flag is ignored."
    So the handle is the named directory itself, never whatever a junction
    points at, and "is this a reparse point?" becomes a property of the
    *opened object* rather than of a re-resolved path string.
  * `dwShareMode = FILE_SHARE_READ | FILE_SHARE_WRITE` -- granting write
    sharing, denying ONLY FILE_SHARE_DELETE. MSDN, dwShareMode:
      FILE_SHARE_DELETE -- "Enables subsequent open operations on a file or
      device to request delete access. Otherwise, no process can open the file
      or device if it requests delete access. ... Note  Delete access allows
      both delete and rename operations."
    https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew

So while the handle is held, renaming or deleting the pinned directory is
*prevented by the kernel*, not detected afterwards. That is strictly stronger
than a check, and it is the swap the measured ~18% TOCTOU race performs.

WHAT IS CLAIMED, AND WHAT IS NOT
--------------------------------
Claimed: a pinned directory cannot be RENAMED OR DELETED while held.
NOT claimed: that it cannot be converted in place to a junction via
FSCTL_SET_REPARSE_POINT. That needs a write handle, and denying write sharing
is impossible here -- see PIN_SHARE_MODE. An earlier version of this docstring
claimed both; it was describing a configuration that cannot coexist with
writing anything at all.

TWO CORRECTIONS OF RECORD (2026-07-26)
--------------------------------------
This module has been wrong on Windows twice, and both times every test passed
except the one that mattered. Recording them because the shape repeats:

  1. It requested `FILE_READ_ATTRIBUTES` as its desired access. CI opened the
     handle, read attributes back correctly, reported AVAILABLE -- and the
     pinned directory was renamed anyway. The share mode reached the kernel
     intact; the open never entered the share-access accounting, which is
     engaged only for opens requesting read/write/delete access. See
     PIN_DESIRED_ACCESS.
  2. With that fixed the guarantee held -- and 10 of 43 suites failed, because
     the pin blocked THIS PROCESS's own writes. Creating a file in a directory
     is a *write to the directory object* (FILE_ADD_FILE == FILE_WRITE_DATA ==
     0x0002), so denying FILE_SHARE_WRITE denied our own staging. See
     PIN_SHARE_MODE.

Both were reasoned from correct documentation applied one level away from the
actual operation. In particular, the claim that holding a directory handle
cannot block writes inside it was argued from Windows' own current-directory
handle -- a handle held for *traversal*, under a share mode that does not deny
write. The precedent was real and the inference from it was not.

The lesson is encoded structurally rather than in prose: `available()` does
not mean "CreateFileW worked". It means BOTH halves of the contract were
measured on this machine -- an attacker's rename is refused AND our own staged
replace inside the pinned directory still succeeds (see verify_pin_contract).
Anything else DISABLES pinning and `_write_all_path` keeps its previously
documented race. A race described honestly beats a protection advertised and
absent, and both beat a write path that silently stops working.

VERIFICATION
------------
`GetFileInformationByHandle` fills BY_HANDLE_FILE_INFORMATION, whose
`dwFileAttributes` carries FILE_ATTRIBUTE_REPARSE_POINT and
FILE_ATTRIBUTE_DIRECTORY, and whose `dwVolumeSerialNumber` +
`nFileIndexHigh`/`nFileIndexLow` "uniquely identify a file on a single
computer".
https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information

FAIL-SAFE POSTURE (deliberate, and asymmetric on purpose)
---------------------------------------------------------
  * Availability is a real *functional* probe (`available()`), never a
    platform-name branch. On POSIX it is False and this module is inert --
    `PinSet.pin()` becomes a no-op, so nothing about the POSIX write path
    changes at all.
  * If a directory cannot be pinned (network share, antivirus holding an
    exclusive handle, unusual filesystem), we degrade to the *existing*
    unpinned behaviour rather than refusing the write. Turning a working
    Windows install into a failing one to close a race would be a worse
    regression than the race -- and that is not hypothetical, it is what
    correction 2 above actually did to 10 of 43 suites.
  * `_write_all_path` additionally releases every pin and retries the whole
    transaction unpinned if STAGING fails while pins are held. The probe
    should make that unreachable; it exists so that "pinning can break
    persistence" is impossible by construction rather than by measurement,
    since the probe necessarily runs against a temp directory and the store
    may live on another volume.
  * If a pin *succeeds* and the handle says the object is a reparse point, we
    refuse hard. That is an attack signal, and it is the same verdict
    persist-proposal's `_reject_if_symlink` already returns for the path-based
    check -- just derived from the opened object instead of a path string.

WHAT THIS DOES NOT COVER
------------------------
The ancestors of `dirs[0]` (the store root itself, resolved by paths.py and
never proposal-derived) are not pinned; the chain is pinned from the first
directory persist-proposal is asked to write into, downward. `_write_all_fd`
has exactly the same boundary -- it opens `dirs[0]` by full path too -- so
this is a consistent limitation, not a new one.
"""
from __future__ import annotations

import ctypes
import os
import tempfile

# --- Win32 constants (documented values; see module docstring for citations)
FILE_READ_ATTRIBUTES = 0x0080
# 0x0001 is FILE_READ_DATA on a file and FILE_LIST_DIRECTORY on a directory --
# the same bit. Requesting it is what makes the open participate in the
# kernel's share-access accounting at all; see PIN_DESIRED_ACCESS below.
FILE_LIST_DIRECTORY = 0x0001
FILE_SHARE_READ = 0x00000001
# Named even though FILE_SHARE_DELETE is never granted: the omission is the
# mechanism, and a named constant lets a test assert the bit is absent rather
# than assert against a magic number.
FILE_SHARE_WRITE = 0x00000002
FILE_SHARE_DELETE = 0x00000004
OPEN_EXISTING = 3
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
FILE_ATTRIBUTE_DIRECTORY = 0x00000010
FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400

_INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

# WHY FILE_SHARE_WRITE IS GRANTED AND FILE_SHARE_DELETE IS NOT.
#
# The second Windows CI run (30184755246) had the guarantee holding -- and 10
# of 43 suites failing, because the pin blocked THIS PROCESS's own writes.
# Persistence was completely broken whenever pinning engaged.
#
# The cause is a single documented equivalence:
#
#   FILE_WRITE_DATA (0x0002) -- "For a file object, the right to write data to
#   the file. For a directory object, the right to create a file in the
#   directory (FILE_ADD_FILE)."
#   FILE_ADD_FILE   (0x0002) -- "For a directory, the right to create a file
#   in the directory."
#   https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants
#
# Creating a file inside a directory IS a write to the directory object. So
# `tempfile.mkstemp(dir=...)` and the commit-phase `os.replace` both open the
# pinned directory requesting FILE_ADD_FILE == FILE_WRITE_DATA, which makes
# the share-access check see WriteAccess -- and a share mode omitting
# FILE_SHARE_WRITE refuses it. We were denying ourselves the one operation
# this module exists to protect.
#
# The two properties need DIFFERENT flags, which is why they are not mutually
# exclusive:
#
#   deny FILE_SHARE_DELETE -> an attacker cannot rename or delete the pinned
#                             directory (MSDN: delete access "allows both
#                             delete and rename operations")
#   allow FILE_SHARE_WRITE -> we can still create and replace files INSIDE it
#
# WHAT THIS COSTS, STATED PLAINLY. Granting FILE_SHARE_WRITE means a
# concurrent process can still open the directory for write, so converting it
# in place to a junction via FSCTL_SET_REPARSE_POINT is no longer blocked.
# This module therefore claims exactly one thing: the pinned directory cannot
# be RENAMED OR DELETED while held. That is the swap the measured ~18% TOCTOU
# race actually performs. In-place reparse conversion is a different, narrower
# attack, and it is NOT covered -- the earlier docstring claiming otherwise was
# describing a configuration that cannot coexist with writing anything.
#
# Naming the mode makes the asymmetry legible instead of looking like a
# forgotten flag, and lets a test assert the value directly.
PIN_SHARE_MODE = FILE_SHARE_READ | FILE_SHARE_WRITE
PIN_FLAGS = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT

# WHY FILE_LIST_DIRECTORY IS HERE AND NOT JUST FILE_READ_ATTRIBUTES.
#
# The first version of this module requested FILE_READ_ATTRIBUTES alone --
# minimal privilege, and enough for GetFileInformationByHandle. Every test
# passed on Windows CI except the one that mattered: a pinned directory could
# still be renamed. The share mode was reaching the kernel correctly; the
# problem was our OWN desired access.
#
# Windows tracks sharing in a per-file SHARE_ACCESS structure (OpenCount,
# Readers, Writers, Deleters, SharedRead, SharedWrite, SharedDelete), and the
# check is only engaged for opens that request read, write or delete access.
# Microsoft documents this by way of the flag that overrides it --
# IoCheckLinkShareAccess's IO_CHECK_SHARE_ACCESS_FORCE_CHECK (0x00000020),
# "indicate to force check share access even if the request is not
# read/write/delete access":
# https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-iochecklinkshareaccess
#
# That flag only makes sense because the DEFAULT is to skip the check for
# requests that are not read/write/delete. FILE_READ_ATTRIBUTES (0x0080) is
# none of those, so a pin opened with it alone never registered in the
# directory's share-access accounting -- it held a handle that no other
# opener's sharing check ever consulted. FILE_LIST_DIRECTORY (0x0001) is the
# directory spelling of FILE_READ_DATA, so requesting it makes the open a
# genuine reader and puts it into the accounting a subsequent rename's
# DELETE-access open has to clear.
#
# This is a REASONED fix to a MEASURED failure, and reasoning is exactly what
# produced the original bug. So it is not trusted: available() now verifies
# BOTH halves of the contract at runtime (see verify_pin_contract).
PIN_DESIRED_ACCESS = FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES


class ReparsePointError(Exception):
    """The pinned handle refers to a reparse point (junction/symlink).

    Raised only when the *handle* says so, which -- unlike a path-based
    lstat -- cannot have been swapped out from under the answer.
    """


class _Win32:
    """Lazily bound kernel32 entry points. Absent entirely on POSIX."""

    def __init__(self) -> None:
        from ctypes import wintypes  # noqa: PLC0415 -- Windows-only import

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class BY_HANDLE_FILE_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("dwFileAttributes", wintypes.DWORD),
                ("ftCreationTime", wintypes.FILETIME),
                ("ftLastAccessTime", wintypes.FILETIME),
                ("ftLastWriteTime", wintypes.FILETIME),
                ("dwVolumeSerialNumber", wintypes.DWORD),
                ("nFileSizeHigh", wintypes.DWORD),
                ("nFileSizeLow", wintypes.DWORD),
                ("nNumberOfLinks", wintypes.DWORD),
                ("nFileIndexHigh", wintypes.DWORD),
                ("nFileIndexLow", wintypes.DWORD),
            ]

        self.BY_HANDLE_FILE_INFORMATION = BY_HANDLE_FILE_INFORMATION

        self.CreateFileW = k32.CreateFileW
        self.CreateFileW.argtypes = [
            wintypes.LPCWSTR,   # lpFileName
            wintypes.DWORD,     # dwDesiredAccess
            wintypes.DWORD,     # dwShareMode
            wintypes.LPVOID,    # lpSecurityAttributes
            wintypes.DWORD,     # dwCreationDisposition
            wintypes.DWORD,     # dwFlagsAndAttributes
            wintypes.HANDLE,    # hTemplateFile
        ]
        self.CreateFileW.restype = wintypes.HANDLE

        self.GetFileInformationByHandle = k32.GetFileInformationByHandle
        self.GetFileInformationByHandle.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(BY_HANDLE_FILE_INFORMATION),
        ]
        self.GetFileInformationByHandle.restype = wintypes.BOOL

        self.CloseHandle = k32.CloseHandle
        self.CloseHandle.argtypes = [wintypes.HANDLE]
        self.CloseHandle.restype = wintypes.BOOL


_WIN32: "_Win32 | None" = None


def _win32() -> "_Win32 | None":
    """Bind kernel32 once, or return None where it does not exist.

    `ctypes.WinDLL` is defined only on Windows builds of CPython, so its
    absence -- not `sys.platform` -- is what gates this module.
    """
    global _WIN32
    if _WIN32 is None:
        if not hasattr(ctypes, "WinDLL"):
            return None
        try:
            _WIN32 = _Win32()
        except (OSError, AttributeError, ImportError):
            return None
    return _WIN32


def extended_path(path: str) -> str:
    """Return `path` in a form CreateFileW accepts for arbitrary length.

    CreateFileW's `lpFileName` is capped at MAX_PATH unless the extended
    "\\\\?\\" prefix is used, which also disables all path parsing -- so the
    path must already be fully qualified and backslash-separated.
    https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation

    Anything that is not a plain drive-rooted or UNC absolute path is returned
    untouched: guessing a prefix for an exotic path shape would be exactly the
    silent-wrong-location class of bug this project exists to eliminate, and
    an unprefixed path still works for every path under MAX_PATH.
    """
    if path.startswith("\\\\?\\") or path.startswith("\\\\.\\"):
        return path
    norm = path.replace("/", "\\")
    if norm.startswith("\\\\"):
        return "\\\\?\\UNC\\" + norm[2:]
    if len(norm) >= 3 and norm[1] == ":" and norm[2] == "\\" and norm[0].isalpha():
        return "\\\\?\\" + norm
    return path


def interpret_info(path: str, attributes: int, volume_serial: int,
                   index_high: int, index_low: int) -> "tuple[int, int]":
    """Decide the verdict for one BY_HANDLE_FILE_INFORMATION, purely.

    Split out of `open_pin` on purpose: this is the part that decides whether
    a pinned object is acceptable, and keeping it free of ctypes means it can
    be executed -- and mutation-tested -- on a POSIX host, where the kernel32
    backend can never run. Without this split, deleting the reparse-point
    refusal was a mutation that no non-Windows test could kill.

    Raises ReparsePointError for a reparse point (junction or symlink: the
    handle was opened with FILE_FLAG_OPEN_REPARSE_POINT, so it refers to the
    link itself, never its target) or for anything that is not a directory.
    Returns MSDN's documented identity pair on success.
    """
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT:
        raise ReparsePointError(f"refusing to use reparse-point store directory: {path}")
    if not (attributes & FILE_ATTRIBUTE_DIRECTORY):
        raise ReparsePointError(f"refusing to use non-directory store directory: {path}")
    return (volume_serial, (index_high << 32) | index_low)


class Pin:
    """An open, held directory handle. Closing it releases the kernel's lock."""

    __slots__ = ("path", "handle", "volume_serial", "file_index", "_win32")

    def __init__(self, path: str, handle: int, volume_serial: int, file_index: int,
                 win32: "_Win32") -> None:
        self.path = path
        self.handle = handle
        self.volume_serial = volume_serial
        self.file_index = file_index
        self._win32 = win32

    def identity(self) -> "tuple[int, int]":
        """(volume serial, 64-bit file index) -- MSDN's documented pair for
        deciding whether two handles refer to the same object."""
        return (self.volume_serial, self.file_index)

    def close(self) -> None:
        if self.handle is not None:
            try:
                self._win32.CloseHandle(self.handle)
            finally:
                self.handle = None


def open_pin(path: str) -> Pin:
    """Open and hold `path` as a directory, refusing reparse points.

    Raises OSError if the directory cannot be opened at all (caller degrades),
    ReparsePointError if the opened object is a reparse point or is not a
    directory (caller refuses).
    """
    win32 = _win32()
    if win32 is None:
        raise OSError("CreateFileW unavailable on this platform")

    handle = win32.CreateFileW(
        extended_path(path),
        PIN_DESIRED_ACCESS,
        PIN_SHARE_MODE,
        None,
        OPEN_EXISTING,
        PIN_FLAGS,
        None,
    )
    if handle == _INVALID_HANDLE_VALUE or not handle:
        err = ctypes.get_last_error()
        raise OSError(0, f"CreateFileW failed for {path}", path, err)

    try:
        info = win32.BY_HANDLE_FILE_INFORMATION()
        if not win32.GetFileInformationByHandle(handle, ctypes.byref(info)):
            err = ctypes.get_last_error()
            raise OSError(0, f"GetFileInformationByHandle failed for {path}", path, err)
        serial, index = interpret_info(path, info.dwFileAttributes,
                                       info.dwVolumeSerialNumber,
                                       info.nFileIndexHigh, info.nFileIndexLow)
        pin = Pin(path, handle, serial, index, win32)
    except BaseException:
        win32.CloseHandle(handle)
        raise
    return pin


class PinSet:
    """Holds every pinned directory for the duration of one write transaction.

    Deliberately *not* a context manager alone: persist-proposal pins
    directories incrementally as it mkdir's its way down the chain, so this
    grows during the transaction and is released in one `close_all()`.

    `opener` exists so the sequencing logic -- pin order, dedupe, refusal on
    reparse point, release-everything-on-failure -- is unit-testable on a
    POSIX host, where the real opener can never run. `enabled` likewise: it
    defaults to the functional probe and is overridden only by tests.
    """

    def __init__(self, opener=None, enabled: "bool | None" = None) -> None:
        self._opener = opener if opener is not None else open_pin
        self._enabled = available() if enabled is None else enabled
        self._pins: "dict[str, object]" = {}

    @property
    def enabled(self) -> bool:
        return self._enabled

    def pinned_paths(self) -> "list[str]":
        """Insertion-ordered, which is root-to-leaf by construction."""
        return list(self._pins)

    def pin(self, path) -> None:
        """Pin `path`, or do nothing where pinning is unavailable.

        Degrades silently on OSError (see the module docstring's fail-safe
        section); propagates ReparsePointError, which is an attack signal.
        """
        if not self._enabled:
            return
        key = os.fspath(path)
        if key in self._pins:
            return
        try:
            pin = self._opener(key)
        except ReparsePointError:
            raise
        except OSError:
            return
        self._pins[key] = pin

    def close_all(self) -> None:
        """Release every handle. Never raises -- this runs in `finally`."""
        for pin in self._pins.values():
            try:
                pin.close()
            except Exception:  # noqa: BLE001 -- releasing must not mask the real error
                pass
        self._pins.clear()


GUARANTEE_HELD = (
    "verified: a pinned directory could not be renamed, and our own staged "
    "replace inside it still succeeded")
GUARANTEE_NO_BACKEND = "no kernel32 -- expected on POSIX"
GUARANTEE_NOT_ENFORCED = (
    "kernel32 present, but the kernel did NOT block a rename of a pinned "
    "directory -- pinning disabled, the write path keeps its documented race")
GUARANTEE_INCONCLUSIVE = (
    "kernel32 present, but the control rename failed too -- cannot tell "
    "protection from an unwritable volume, so pinning is disabled")
GUARANTEE_BLOCKS_OUR_WRITES = (
    "kernel32 present and the pin engages, but it also blocks this process's "
    "own staged replace inside the pinned directory -- pinning disabled, "
    "because hardening that breaks persistence is worse than the race it closes")


def staged_replace_probe(directory):
    """Perform exactly what `_write_all_path` does inside a store directory.

    Not an approximation of it: create a destination, stage a temp file
    alongside it with `tempfile.mkstemp(dir=...)`, and `os.replace` the temp
    file OVER the existing destination. Those are the three operations that
    open the parent directory requesting FILE_ADD_FILE, and therefore the
    three a share mode can refuse. Raises OSError if any is refused.

    A probe that tested a weaker operation would be the same mistake this
    module has now made twice: verifying something adjacent to the property
    that actually matters.
    """
    target = os.path.join(directory, "pin-probe-target")
    with open(target, "w") as handle:
        handle.write("x")
    fd, tmp = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write("y")
    except BaseException:
        os.close(fd)
        raise
    os.replace(tmp, target)


def verify_pin_contract(directory, moved, opener=None, rename=None,
                        write_probe=None):
    """Measure BOTH halves of the contract, as one check. Returns a GUARANTEE_*.

    The module needs two properties simultaneously, and either one alone is
    misleading:

      (a) an attacker cannot rename or delete the pinned directory, and
      (b) THIS process can still stage and replace files inside it.

    Verifying only (a) is what shipped last round: the probe reported
    AVAILABLE, the guarantee genuinely held, and 10 of 43 suites failed
    because persistence was broken on every Windows write. A "verified"
    hardening that silently costs the user every write is worse than the race
    it closes, so (b) is now part of the same verdict rather than a separate
    concern nobody checked.

    Order matters: (b) is measured first and while pinned. If our own writes
    are refused there is nothing to discuss about (a), and reporting
    BLOCKS_OUR_WRITES names the real problem instead of a downstream symptom.

    Outcomes:

      * writes refused while pinned                        -> BLOCKS_OUR_WRITES
      * writes fine, rename SUCCEEDS while pinned          -> NOT_ENFORCED
      * writes fine, rename blocked, blocked after release -> INCONCLUSIVE
        (the control experiment: without it a read-only volume, a permissions
        problem or an antivirus lock looks exactly like protection)
      * writes fine, rename blocked, allowed after release -> HELD

    `opener`/`rename`/`write_probe` are injectable so this decision logic is
    executable on a POSIX host, where CreateFileW cannot run.
    """
    opener = opener or open_pin
    rename = rename or os.rename
    write_probe = write_probe or staged_replace_probe

    pin = opener(directory)
    try:
        try:
            write_probe(directory)
        except OSError:
            return GUARANTEE_BLOCKS_OUR_WRITES
        try:
            rename(directory, moved)
        except OSError:
            blocked = True
        else:
            blocked = False
            rename(moved, directory)  # restore, so the control below is fair
    finally:
        pin.close()

    if not blocked:
        return GUARANTEE_NOT_ENFORCED
    try:
        rename(directory, moved)
    except OSError:
        return GUARANTEE_INCONCLUSIVE
    return GUARANTEE_HELD


def _probe() -> "tuple[bool, str]":
    """Functional probe for the GUARANTEE, not merely for the plumbing.

    Mirrors persist-proposal's `_probe_dir_fd_support` in spirit and for the
    same reason -- this codebase has been bitten repeatedly by assuming what
    a platform *name* implies. It goes further than that probe because this
    module has already been wrong TWICE in ways a narrower probe could not
    detect. First: the handle opened, the attributes read back correctly, and
    the directory was renamed out from under it anyway. Then, after that was
    fixed: the guarantee held and the pin blocked this process's own writes,
    breaking persistence on every Windows run.

    So availability now MEANS "the kernel demonstrably refuses the swap AND
    our own staged replace inside the pinned directory still works". Anything
    else disables pinning, which returns `_write_all_path` to exactly its
    previous behaviour -- a documented race rather than an advertised
    protection that is not there, and never a broken write path.
    """
    if _win32() is None:
        return (False, GUARANTEE_NO_BACKEND)
    try:
        with tempfile.TemporaryDirectory() as d:
            target = os.path.join(d, "probe-dir")
            os.mkdir(target)
            reason = verify_pin_contract(target, os.path.join(d, "probe-moved"))
        return (reason == GUARANTEE_HELD, reason)
    except (OSError, ReparsePointError, ValueError) as exc:
        return (False, "probe raised {}: {}".format(type(exc).__name__, exc))


_PROBE: "tuple[bool, str] | None" = None


def probe_detail() -> "tuple[bool, str]":
    """Cached (available, reason). The reason is what CI logs, so a run can
    never look green while the guarantee silently does not hold."""
    global _PROBE
    if _PROBE is None:
        _PROBE = _probe()
    return _PROBE


def available() -> bool:
    """Cached functional probe result. Never a platform-name check.

    True means the guarantee was measured and held on THIS machine.
    """
    return probe_detail()[0]


if __name__ == "__main__":  # pragma: no cover - diagnostic surface
    ok, why = probe_detail()
    print("{} ({})".format("AVAILABLE" if ok else "UNAVAILABLE", why))
