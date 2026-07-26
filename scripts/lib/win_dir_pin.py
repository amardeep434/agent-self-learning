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
  * `dwShareMode = FILE_SHARE_READ` -- deliberately omitting
    FILE_SHARE_DELETE and FILE_SHARE_WRITE. This is the load-bearing part.
    MSDN, dwShareMode:
      FILE_SHARE_DELETE -- "Enables subsequent open operations on a file or
      device to request delete access. Otherwise, no process can open the file
      or device if it requests delete access. ... Note  Delete access allows
      both delete and rename operations."
      FILE_SHARE_WRITE -- "... Otherwise, no process can open the file or
      device if it requests write access."
    https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew

Swapping a directory for a junction requires deleting or renaming it first
(needs delete access -> blocked) or converting it in place via
FSCTL_SET_REPARSE_POINT (needs write access -> blocked). So while the handle
is held the swap is *prevented by the kernel*, not detected afterwards. That
is strictly stronger than a check.

WHY HOLDING THE HANDLE DOES NOT BLOCK OUR OWN WRITES
----------------------------------------------------
The share mode governs subsequent opens *of that same object* -- the
directory. Creating, renaming and replacing files *inside* a pinned directory
opens the child objects, not the parent, and is unaffected. The dispositive
precedent is Windows itself: the OS holds an open handle to every process's
current directory for the life of the process ("The primary consequence of
this curse is that you can't delete a directory if it is the current directory
of a running process." -- Raymond Chen, The Old New Thing,
https://devblogs.microsoft.com/oldnewthing/20101109-00/?p=12323) and yet every
process on the machine creates files in its own working directory.

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
    regression than the race.
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
FILE_SHARE_READ = 0x00000001
OPEN_EXISTING = 3
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
FILE_ATTRIBUTE_DIRECTORY = 0x00000010
FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400

_INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

# Share mode is the whole point of this module; naming it makes the omission
# of FILE_SHARE_DELETE/FILE_SHARE_WRITE legible instead of looking like a
# forgotten flag, and lets a test assert the value directly.
PIN_SHARE_MODE = FILE_SHARE_READ
PIN_FLAGS = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT


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
        FILE_READ_ATTRIBUTES,
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


def _probe() -> bool:
    """Real functional probe: pin a throwaway directory and read it back.

    Mirrors persist-proposal's `_probe_dir_fd_support` in spirit and for the
    same reason -- this codebase has been bitten repeatedly by assuming what a
    platform *name* implies. A capability that cannot complete an actual
    open/verify/close cycle is not a capability.
    """
    if _win32() is None:
        return False
    try:
        with tempfile.TemporaryDirectory() as d:
            sub = os.path.join(d, "probe-dir")
            os.mkdir(sub)
            pin = open_pin(sub)
            try:
                # An identity of (0, 0) means the filesystem does not report
                # file IDs; the *pin* still works, so this is not fatal, but
                # a failed open or a bogus attribute set is.
                pin.identity()
            finally:
                pin.close()
        return True
    except (OSError, ReparsePointError, ValueError):
        return False


_AVAILABLE: "bool | None" = None


def available() -> bool:
    """Cached functional probe result. Never a platform-name check."""
    global _AVAILABLE
    if _AVAILABLE is None:
        _AVAILABLE = _probe()
    return _AVAILABLE


if __name__ == "__main__":  # pragma: no cover - diagnostic surface
    print("AVAILABLE" if available() else "UNAVAILABLE")
