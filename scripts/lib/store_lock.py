#!/usr/bin/env python3
"""Cross-process exclusive lock for the store's read-modify-write spans.

WHY THIS EXISTS
---------------
persist-proposal.py's append mode does read-existing -> concatenate ->
stage -> rename. Every individual step is safe, and the rename is atomic,
but the *span* is not: two processes that both read the same MEMORY.md and
then both rename their own concatenation over it produce a file containing
only one of the two appends. Both processes exit 0 and print a success
JSON. Measured on Linux with a barrier-synchronised harness: 30-38 of 40
concurrent appends lost. `.usage.json` (skill telemetry) has the same span
inside "replace"-mode skill writes -- measured 38 of 40 records lost while
all 40 SKILL.md files were written -- so this is not an append-only defect.

This needs no attacker: both harnesses' review hooks can fire near
simultaneously and the review pipeline is detached by design. It is the
ordinary-use case, and it silently destroys data the user already had.

DESIGN
------
One coarse, whole-store exclusive lock, held across the entire plan+write
transaction rather than per file. Writes here are rare (once per review)
and short (milliseconds), so there is nothing to gain from finer
granularity and a great deal to lose: per-file locks would have to be
acquired in a canonical order to avoid deadlock between a proposal that
writes MEMORY.md then .usage.json and one that writes them in the other
order. A single lock cannot deadlock against itself.

The lock file lives in the store's `state/` directory -- never inside
`memory/` or `learned-skills/`, whose contents are enumerated by
consumers (inject-agents-md.py, curator-run.sh, skill-lifecycle.py); a
stray file there would be read as content. `state/` already hosts exactly
this kind of thing (turn-counter.sh's `counter.lock`).

BACKENDS, CHOSEN BY FUNCTIONAL PROBE -- NEVER BY PLATFORM NAME
--------------------------------------------------------------
This codebase has been wrong about what a platform name implies before
(Windows *can* create symlinks; `os.supports_dir_fd` lists `os.rename` but
not `os.replace` even though both work), so each backend is selected by
actually performing a disposable lock/unlock in a temp directory:

  1. "flock"      -- fcntl.flock(LOCK_EX|LOCK_NB). POSIX.
  2. "msvcrt"     -- msvcrt.locking(LK_NBLCK). Windows.
  3. "exclusive"  -- O_CREAT|O_EXCL lockfile protocol. Last resort, used
                     only where neither kernel primitive works (e.g. some
                     network filesystems).

STALE LOCKS
-----------
Backends 1 and 2 are kernel-held locks tied to an open file descriptor:
the OS releases them when the holding process exits, including SIGKILL and
a hard crash. A crashed reviewer therefore cannot wedge future reviews --
no timeout heuristic is involved, and the lock file itself is deliberately
never unlinked (unlinking a flock'd path is what creates the classic
"two processes hold locks on two different inodes with the same name"
race; an empty 0-byte file left in state/ costs nothing).

Backend 3 has no such guarantee -- an O_EXCL lockfile outlives its
creator -- so it, and only it, breaks a lock whose mtime is older than
STALE_SECONDS. That threshold is an order of magnitude above any
legitimate hold time (a write is milliseconds; the acquire timeout is
seconds).

TIMEOUT
-------
Acquisition is bounded and, on expiry, fails loudly: the caller raises,
exits non-zero, and logs to persist-failures.log, which doctor.sh
surfaces. Silently giving up and returning success would be another
instance of the exact silent-failure pattern this project exists to
eliminate.
"""
from __future__ import annotations

import errno
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# The lock file, relative to the store's state/ directory.
LOCK_FILENAME = "persist.lock"

# Bounded wait. A real hold is milliseconds; this only has to cover a
# pathologically slow machine writing a ~1 MiB file, plus queueing behind a
# few other reviews. Overridable via $SL_PERSIST_LOCK_TIMEOUT for tests and
# for anyone whose store lives on very slow storage.
DEFAULT_TIMEOUT_SECONDS = 20.0
TIMEOUT_ENV_VAR = "SL_PERSIST_LOCK_TIMEOUT"

# Only the "exclusive" fallback backend uses this; see STALE LOCKS above.
STALE_SECONDS = 300.0

_POLL_SECONDS = 0.02


def default_lock_dir(env: "dict | None" = None) -> Path:
    """The one directory every writer must agree on for the lock file.

    A lock only serialises processes that pick the SAME path, so this is
    deliberately the single definition all three writers use
    (persist-proposal.py, skill-lifecycle.py, and the `run` CLI that
    curator-run.sh calls) rather than three copies of the same expression
    that can drift -- the same reasoning as lib/skill_layout.py.

    $SL_STATE_DIR first (config.sh exports it, so a bash caller and a Python
    caller in the same run cannot disagree), then paths.py's resolver.
    """
    env = os.environ if env is None else env
    explicit = env.get("SL_STATE_DIR")
    if explicit:
        return Path(explicit)
    import paths  # local import: keeps this module importable standalone
    return paths.resolve_all(env)["state"]


class LockTimeout(Exception):
    """Bounded wait expired with the lock still held elsewhere."""


class LockUnavailable(Exception):
    """The lock file itself could not be created/opened (e.g. unwritable
    state directory). Distinct from LockTimeout: nothing was contended,
    the lock could not be established at all."""


def _probe_flock() -> bool:
    try:
        import fcntl
    except ImportError:
        return False
    try:
        with tempfile.TemporaryDirectory() as d:
            fd = os.open(os.path.join(d, "probe"), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
        return True
    except (OSError, AttributeError, NotImplementedError):
        return False


def _probe_msvcrt() -> bool:
    try:
        import msvcrt
    except ImportError:
        return False
    try:
        with tempfile.TemporaryDirectory() as d:
            fd = os.open(os.path.join(d, "probe"), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                os.write(fd, b"\0")
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
            finally:
                os.close(fd)
        return True
    except (OSError, AttributeError, NotImplementedError):
        return False


def _select_backend() -> str:
    if _probe_flock():
        return "flock"
    if _probe_msvcrt():
        return "msvcrt"
    return "exclusive"


BACKEND = _select_backend()

# True when the selected backend's lock is released by the OS on process
# death (so a crash can never wedge the store). False only for the
# "exclusive" fallback, which relies on STALE_SECONDS instead. Surfaced so
# doctor.sh and the tests can report which guarantee is in force rather
# than assuming one.
BACKEND_RELEASES_ON_CRASH = BACKEND in ("flock", "msvcrt")


def _timeout_from_env(env: "dict | None" = None) -> float:
    env = os.environ if env is None else env
    raw = env.get(TIMEOUT_ENV_VAR)
    if raw is None or not str(raw).strip():
        return DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    # A zero/negative timeout would mean "never wait", which for a lock
    # whose normal hold time is milliseconds turns ordinary contention into
    # a hard failure. Clamp to a single poll interval instead of honouring
    # a value that can only produce spurious timeouts.
    return max(value, _POLL_SECONDS)


class StoreLock:
    """Context manager holding the whole-store write lock.

    Usage:
        with StoreLock(state_dir) as lock:   # raises LockTimeout on expiry
            ...read-modify-write the store...
    """

    def __init__(self, state_dir: "Path | str", timeout: "float | None" = None,
                 backend: "str | None" = None) -> None:
        self.state_dir = Path(state_dir)
        self.path = self.state_dir / LOCK_FILENAME
        self.timeout = _timeout_from_env() if timeout is None else max(timeout, _POLL_SECONDS)
        self.backend = BACKEND if backend is None else backend
        self.waited = 0.0
        self._fd: "int | None" = None

    # -- acquisition -----------------------------------------------------

    def _open_lock_fd(self) -> int:
        try:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            return os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as exc:
            raise LockUnavailable(f"cannot open lock file {self.path}: {exc}") from exc

    def _try_flock(self, fd: int) -> bool:
        import fcntl
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as exc:
            if exc.errno in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
                return False
            raise LockUnavailable(f"flock failed on {self.path}: {exc}") from exc

    def _try_msvcrt(self, fd: int) -> bool:
        import msvcrt
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError as exc:
            if exc.errno in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                return False
            raise LockUnavailable(f"msvcrt lock failed on {self.path}: {exc}") from exc

    def _try_exclusive(self) -> bool:
        """O_CREAT|O_EXCL fallback. Returns True (and stores the fd) on
        success. Breaks a lock older than STALE_SECONDS -- see the module
        docstring; this is the only backend that needs to."""
        try:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            fd = os.open(str(self.path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            self._break_if_stale()
            return False
        except OSError as exc:
            raise LockUnavailable(f"cannot create lock file {self.path}: {exc}") from exc
        try:
            os.write(fd, f"{os.getpid()} {time.time():.3f}\n".encode("utf-8"))
        except OSError:
            pass  # informational only; the lock is the file's existence
        self._fd = fd
        return True

    def _break_if_stale(self) -> None:
        try:
            age = time.time() - os.stat(str(self.path)).st_mtime
        except OSError:
            return  # vanished between open and stat -- next attempt wins it
        if age <= STALE_SECONDS:
            return
        try:
            os.unlink(str(self.path))
        except OSError:
            pass  # someone else broke it first; either way, retry

    def acquire(self) -> "StoreLock":
        deadline = time.monotonic() + self.timeout
        started = time.monotonic()
        if self.backend == "exclusive":
            while True:
                if self._try_exclusive():
                    self.waited = time.monotonic() - started
                    return self
                if time.monotonic() >= deadline:
                    break
                time.sleep(_POLL_SECONDS)
            self.waited = time.monotonic() - started
            raise LockTimeout(
                f"timed out after {self.timeout:g}s waiting for {self.path} "
                f"(backend={self.backend})"
            )

        fd = self._open_lock_fd()
        try:
            while True:
                got = self._try_flock(fd) if self.backend == "flock" else self._try_msvcrt(fd)
                if got:
                    self._fd = fd
                    self.waited = time.monotonic() - started
                    return self
                if time.monotonic() >= deadline:
                    break
                time.sleep(_POLL_SECONDS)
        except BaseException:
            os.close(fd)
            raise
        os.close(fd)
        self.waited = time.monotonic() - started
        raise LockTimeout(
            f"timed out after {self.timeout:g}s waiting for {self.path} "
            f"(backend={self.backend})"
        )

    # -- release ---------------------------------------------------------

    def release(self) -> None:
        fd, self._fd = self._fd, None
        if fd is None:
            return
        try:
            if self.backend == "flock":
                import fcntl
                try:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                except OSError:
                    pass  # closing the fd releases it regardless
            elif self.backend == "msvcrt":
                import msvcrt
                try:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass  # closing the fd releases it regardless
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
            if self.backend == "exclusive":
                # This backend's lock IS the file's existence, so it must be
                # removed on release. The kernel-backed backends deliberately
                # leave their (0-byte) file in place -- see STALE LOCKS.
                try:
                    os.unlink(str(self.path))
                except OSError:
                    pass

    def __enter__(self) -> "StoreLock":
        return self.acquire()

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.release()
        return False


def _log_lock_timeout(message: str, env: "dict | None" = None) -> None:
    """Append a lock timeout to persist-failures.log, which doctor.sh
    surfaces. Shared by the CLI here and persist-proposal.py's own handler
    so a bash caller's timeout is exactly as visible as a Python one --
    curator-run.sh in particular runs from cron with nobody watching stderr.
    Never raises."""
    env = os.environ if env is None else env
    try:
        log_dir = env.get("SL_LOG_DIR")
        if not log_dir:
            import paths
            log_dir = str(paths.resolve_all(env)["logs"])
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        import isotime
        with open(Path(log_dir) / "persist-failures.log", "a",
                  encoding="utf-8", newline="\n") as handle:
            handle.write(f"{isotime.now_iso()} {message}\n")
    except (OSError, ImportError):
        pass


def _main(argv: "list[str]") -> int:
    """Tiny CLI so bash callers (curator-run.sh, via lib/store-lock.sh) and
    doctor.sh can use and report this lock without reimplementing any of it.

      store_lock.py backend            -- print the selected backend
      store_lock.py probe              -- backend + crash behaviour + timeout
      store_lock.py run [--state-dir D] [--timeout S] -- CMD [ARGS...]
                                       -- run CMD holding the lock

    `run` is the bash entry point: the lock is held for exactly the child's
    lifetime and released when this wrapper exits, including if the child is
    killed. There is no acquire/release pair for bash to get wrong, and no
    way for a bash `set -e` early exit to leak a held lock.
    """
    if argv and argv[0] == "backend":
        print(BACKEND)
        return 0
    if argv and argv[0] == "probe":
        print(f"backend={BACKEND}")
        print(f"releases_on_crash={'yes' if BACKEND_RELEASES_ON_CRASH else 'no'}")
        print(f"timeout={_timeout_from_env():g}")
        return 0
    if argv and argv[0] == "run":
        rest = argv[1:]
        state_dir = None
        timeout = None
        while rest and rest[0].startswith("--"):
            if rest[0] == "--":
                rest = rest[1:]
                break
            if rest[0] == "--state-dir" and len(rest) > 1:
                state_dir, rest = rest[1], rest[2:]
            elif rest[0] == "--timeout" and len(rest) > 1:
                timeout, rest = float(rest[1]), rest[2:]
            else:
                print(f"store_lock.py run: unknown option {rest[0]!r}", file=sys.stderr)
                return 2
        if not rest:
            print("store_lock.py run: no command given", file=sys.stderr)
            return 2
        target = Path(state_dir) if state_dir else default_lock_dir()
        try:
            lock = StoreLock(target, timeout=timeout)
            lock.acquire()
        except LockTimeout as exc:
            _log_lock_timeout(f"store-lock: timed out running {rest[0]!r}: {exc}")
            print(f"store_lock.py: {exc}", file=sys.stderr)
            return 75  # EX_TEMPFAIL: contended, retryable -- not a bug in CMD
        except LockUnavailable as exc:
            _log_lock_timeout(f"store-lock: unavailable running {rest[0]!r}: {exc}")
            print(f"store_lock.py: {exc}", file=sys.stderr)
            return 74  # EX_IOERR
        try:
            import subprocess
            return subprocess.call(rest)
        finally:
            lock.release()
    print("usage: store_lock.py {backend|probe|run [--state-dir D] [--timeout S] -- CMD...}")
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
