#!/usr/bin/env python3
"""Persist a reviewer proposal. The ONLY component that writes memory/skills.

Reads reviewer stdout on stdin, extracts and validates the proposal, then
writes every file itself. The reviewer agent needs no write tool at all —
which is what makes this work identically on Claude Code, Copilot CLI, and
VS Code Copilot Chat, none of whose path allow-lists we can control.

Nothing is written unless the whole proposal validates: a partially applied
proposal is a corrupted store. Validation is already all-or-nothing
(proposal_schema.validate_proposal either raises or returns a fully validated
object). The write phase mirrors that guarantee at the filesystem level: every
entry is staged to a temp file in its final directory first; only once every
stage has succeeded do we rename the temp files into place. A failure at any
point during staging (bad permissions, disk full, a planted symlink) leaves
every real file exactly as it was before this run. The one residual risk is a
failure *during* the rename phase itself (see README below on atomicity), which
the code documents rather than silently ignoring, per the exit-code contract.

THREAT MODEL: the proposal originates from a background LLM agent whose
context may have been influenced by prompt injection. Assume the content is
adversarial: it wants to write outside the store, clobber an arbitrary file,
follow a symlink to somewhere sensitive, or leave the store half-written.
proposal_schema.py is the syntactic boundary (allow-listed filenames, a
slash-free skill-name regex, size and count caps). Everything in this file is
a second, filesystem-level boundary — defence in depth, not duplicated trust.
"""
from __future__ import annotations

import argparse
import errno
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import paths  # noqa: E402
from proposal_schema import ValidationError, extract_proposal, validate_proposal  # noqa: E402

# Bounds the *accumulated* size of a memory file across repeated append-mode
# proposals. proposal_schema caps a single proposal's content, but says
# nothing about the file it lands in after many proposals have appended to
# it over time -- without this, an adversary who cannot get past the
# per-proposal cap in one shot can still grow MEMORY.md without bound across
# many small, individually-valid proposals. 1 MiB is generous for a curated
# memory/skill file while still bounding unattended growth.
MAX_MEMORY_FILE_BYTES = 1 * 1024 * 1024


class PersistError(Exception):
    """A filesystem-level confinement or write failure. Maps to exit code 2."""


def _reject_if_symlink(path: Path, what: str) -> None:
    """Refuse outright rather than silently writing/reading through a link.

    os.replace() (used below for the actual write) never follows a symlink
    at the destination -- it swaps the directory entry atomically -- so a
    symlink planted at `target` cannot redirect our write elsewhere even if
    this check races it. We still refuse explicitly and loudly: a planted
    symlink means something is wrong (attack or corrupted store), and
    silently overwriting-in-place would hide that.

    Also refuses Windows reparse points (directory junctions in particular):
    `Path.is_symlink()` does not detect them, but `os.lstat().st_reparse_tag`
    does (present on Windows since Python 3.8; simply absent, and therefore a
    harmless no-op, on POSIX). Junction creation on Windows does not require
    the elevated privilege that symlink creation does, so this is not an
    edge case -- it is the practical way this exact escape would be staged
    on that platform.
    """
    if path.is_symlink():
        raise PersistError(f"refusing to use symlinked {what}: {path}")
    try:
        reparse_tag = getattr(path.lstat(), "st_reparse_tag", 0)
    except OSError:
        reparse_tag = 0  # doesn't exist yet -- nothing to reject
    if reparse_tag:
        raise PersistError(f"refusing to use reparse-point {what}: {path}")


def _assert_inside(root: Path, target: Path) -> None:
    """Filesystem-level confinement check, defence in depth over the schema.

    The schema already forbids traversal syntactically (exact allow-listed
    memory filenames; skill names matching a slash-free regex), so `target`
    can never legitimately gain extra path components -- this is a backstop,
    not the primary defence. It also guards against `root` itself (the
    memory/ or learned-skills/ directory) having been replaced by a symlink:
    naively comparing target.parent.resolve() to root.resolve() would pass
    even in that case, since both would resolve to the same symlinked
    destination. Checking root for symlink-ness directly is what actually
    catches that.
    """
    if root.exists():
        _reject_if_symlink(root, "store directory")
    root_r = root.resolve()
    parent_r = target.parent.resolve()
    if root_r != parent_r and root_r not in parent_r.parents:
        raise PersistError(f"refusing write outside store: {target}")
    if target.name in ("", ".", "..") or "/" in target.name or "\\" in target.name:
        raise PersistError(f"refusing suspicious filename: {target.name!r}")


def _open_nofollow_fd(path: Path, flags: int, mode: int = 0o644) -> int:
    """Open `path` with O_NOFOLLOW where the platform supports it.

    On POSIX this closes the TOCTOU window between an earlier is_symlink()
    check and this call: if something swapped in a symlink in between, the
    kernel refuses with ELOOP instead of following it. Windows has no
    O_NOFOLLOW (os.O_NOFOLLOW is absent there), so on Windows we fall back to
    the is_symlink() pre-check alone, which leaves a narrow race the stdlib
    gives no primitive to close. Unprivileged symlink creation is restricted
    by default on Windows, which bounds -- but does not eliminate -- that
    risk (directory junctions do not require the same privilege and are not
    detected by Path.is_symlink()).
    """
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        return os.open(path, flags | nofollow, mode)
    except OSError as exc:
        if nofollow and exc.errno == errno.ELOOP:
            raise PersistError(f"refusing write through symlink: {path}") from exc
        raise


def _read_existing(target: Path) -> str:
    """Read the current content of `target` for append mode, or "" if absent.

    Raises PersistError (never a raw traceback) for anything that makes the
    existing file untrustworthy to read: a symlink/reparse-point target
    (checked above), a hardlink to content outside the store (checked via
    st_nlink below -- is_symlink() and O_NOFOLLOW are both blind to
    hardlinks, since a hardlink IS a regular file from the filesystem's
    point of view, just one with more than one directory entry pointing at
    the same inode), or content that isn't valid UTF-8 (a write failure, not
    a proposal-validation failure -- surfaced as PersistError/exit 2, not
    left to raise UnicodeDecodeError past this function and collapse into
    whatever the nearest bare `except` happens to catch).
    """
    _reject_if_symlink(target, "target file")
    if not target.exists():
        return ""
    fd = _open_nofollow_fd(target, os.O_RDONLY)
    fd_owned_by_handle = False
    try:
        st = os.fstat(fd)
        if st.st_nlink > 1:
            raise PersistError(f"refusing to read multiply-linked file: {target}")
        handle = os.fdopen(fd, "r", encoding="utf-8", newline="")
        fd_owned_by_handle = True
        try:
            with handle:
                return handle.read()
        except UnicodeDecodeError as exc:
            raise PersistError(f"existing file is not valid UTF-8: {target}") from exc
    finally:
        if not fd_owned_by_handle:
            os.close(fd)


def _stage(root: Path, data: str) -> str:
    """Write `data` to a fresh temp file inside `root`; return its path.

    Writing here never touches the real target -- that only happens in the
    rename phase, once every entry in the proposal has staged successfully.

    `tempfile.mkstemp` creates the file at mode 0600, and `os.replace` carries
    that mode onto the final target rather than whatever mode a pre-existing
    file had. That's deliberate, not an oversight: learned content is
    sensitive by the same threat model that governs everything else here, and
    0600 removes any window where a partially-written file is readable by
    anyone but the owner. A previously-0644 MEMORY.md coming back as 0600
    after a proposal is applied is this policy working as intended.
    """
    fd, tmp_name = tempfile.mkstemp(dir=root, prefix=".persist-tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        _cleanup_tmp(tmp_name)
        raise
    return tmp_name


def _cleanup_tmp(tmp_name: str) -> None:
    try:
        os.unlink(tmp_name)
    except OSError:
        pass  # already renamed, or never created -- either way, nothing to do


def _plan(proposal: dict, memory_dir: Path, skills_dir: Path) -> list[tuple[Path, Path, str, str]]:
    planned: list[tuple[Path, Path, str, str]] = []
    for entry in proposal["memory"]:
        planned.append((memory_dir, memory_dir / entry["file"], entry["mode"], entry["content"]))
    for entry in proposal["skills"]:
        planned.append((skills_dir, skills_dir / f"{entry['name']}.md", "replace", entry["content"]))
    return planned


def _write_all(planned: list[tuple[Path, Path, str, str]]) -> tuple[list[str], int]:
    """Stage every entry, then rename every staged file into place.

    Raises PersistError/OSError on any failure. On a staging failure, no real
    target has been touched. On a (much less likely) rename failure partway
    through, entries already renamed are committed and later ones are not --
    the exception propagates so the caller reports a hard failure (exit 2)
    rather than a false success; a fully cross-file atomic commit would need
    a journal or a directory-swap trick this stdlib-only, cross-platform
    script does not attempt.

    A narrower, un-closed residual also lives between `_assert_inside(root,
    ...)` above and `tempfile.mkstemp(dir=root)` inside `_stage`: `root`
    could in principle be swapped for a symlink in that gap. Closing it
    would need `dir_fd`-relative operations throughout, and `mkstemp` has no
    `dir_fd` parameter to hang that off of. Documented, not fixed.
    """
    staged: list[tuple[str, Path]] = []
    total = 0
    try:
        for root, target, mode, content in planned:
            root.mkdir(parents=True, exist_ok=True)
            _assert_inside(root, target)
            _reject_if_symlink(target, "target file")
            if target.is_dir():
                # Caught here (staging phase, before any rename) rather than
                # left to surface as an IsADirectoryError from os.replace()
                # during the commit phase below -- failing early here means
                # an entry earlier in the same proposal that already renamed
                # successfully is not left committed while this one fails.
                raise PersistError(f"refusing to write over existing directory: {target}")

            data = _read_existing(target) + content if mode == "append" else content
            if len(data.encode("utf-8")) > MAX_MEMORY_FILE_BYTES:
                # proposal_schema bounds a single proposal's content; it has
                # no notion of what's already on disk. Without this, many
                # individually-valid append proposals could grow a memory
                # file without bound over time.
                raise PersistError(
                    f"{target} would exceed {MAX_MEMORY_FILE_BYTES} bytes after this write"
                )
            tmp_name = _stage(root, data)
            staged.append((tmp_name, target))
            total += len(content.encode("utf-8"))

        written: list[str] = []
        for tmp_name, target in staged:
            os.replace(tmp_name, target)
            written.append(str(target))
        return written, total
    except BaseException:
        for tmp_name, _target in staged:
            _cleanup_tmp(tmp_name)
        raise


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Persist a reviewer proposal.")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate and report without writing")
    args = parser.parse_args(argv)

    raw = sys.stdin.read()
    obj = extract_proposal(raw)
    if obj is None:
        print(json.dumps({"written": [], "skipped": ["no-proposal"], "bytes": 0}))
        return 0

    try:
        proposal = validate_proposal(obj)
    except ValidationError as exc:
        print(f"persist-proposal: invalid proposal: {exc}", file=sys.stderr)
        return 1

    resolved = paths.resolve_all()
    memory_dir, skills_dir = resolved["memory"], resolved["skills"]
    planned = _plan(proposal, memory_dir, skills_dir)

    if args.dry_run:
        print(json.dumps({"written": [], "skipped": [str(p) for _, p, _, _ in planned],
                          "bytes": sum(len(c.encode("utf-8")) for _, _, _, c in planned)}))
        return 0

    try:
        written, total = _write_all(planned)
    except (OSError, PersistError, ValueError) as exc:
        # ValueError is deliberately included alongside the two expected
        # failure types: it's the base class for UnicodeDecodeError and
        # covers any future decode/parse-shaped failure in the write path
        # too. A write failure must always exit 2, never fall through
        # uncaught and collapse into a traceback that looks like (or is
        # mistaken for) the validation-failure exit code of 1.
        print(f"persist-proposal: write failed: {exc}", file=sys.stderr)
        return 2

    print(json.dumps({"written": written, "skipped": [], "bytes": total}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
