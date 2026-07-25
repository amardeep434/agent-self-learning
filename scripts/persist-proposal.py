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
from isotime import now_iso as _now_iso  # noqa: E402  (fix round D: shared with skill-lifecycle.py, index-session.py, coach-signals.py)
from proposal_schema import ValidationError, extract_proposal, validate_proposal  # noqa: E402

# Bounds the *accumulated* size of a memory file across repeated append-mode
# proposals. proposal_schema caps a single proposal's content, but says
# nothing about the file it lands in after many proposals have appended to
# it over time -- without this, an adversary who cannot get past the
# per-proposal cap in one shot can still grow MEMORY.md without bound across
# many small, individually-valid proposals. 1 MiB is generous for a curated
# memory/skill file while still bounding unattended growth.
MAX_MEMORY_FILE_BYTES = 1 * 1024 * 1024

# The on-disk skill layout every *consumer* requires (inject-agents-md.py,
# curator-run.sh, skill-lifecycle.py): a directory per skill containing
# SKILL.md, plus one shared metadata file at the top of the skills store.
# This file used to write a flat `<name>.md` instead -- syntactically valid,
# semantically invisible, since nothing downstream ever looked for it.
SKILL_CONTENT_FILENAME = "SKILL.md"
USAGE_FILENAME = ".usage.json"


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

    Called once per directory level in `_write_all`'s `dirs` chain (e.g.
    (skills_dir, skill_dir) for a per-skill directory), so `root` is always
    `target`'s *immediate* parent in that chain, not necessarily the
    top-level store directory.
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


def _load_usage_dict(skills_dir: Path) -> dict:
    """Read the shared `.usage.json`, symlink/hardlink/UTF-8 safe, "{}" if absent.

    Uses `_read_existing` -- the same defence-in-depth read path already used
    for append-mode memory files -- so a planted symlink or hardlink at
    `.usage.json` is refused exactly like one at MEMORY.md would be, rather
    than silently read-through.
    """
    usage_path = skills_dir / USAGE_FILENAME
    text = _read_existing(usage_path)
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        # Refuse rather than silently starting fresh: silently discarding a
        # corrupt-but-real .usage.json would be a quiet destructive action
        # of exactly the kind this file's threat model exists to prevent.
        raise PersistError(f"{usage_path} exists but is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise PersistError(f"{usage_path} does not contain a JSON object")
    return data


def _merge_usage(usage: dict, skill_names: list[str]) -> dict:
    """Create-or-refresh one `.usage.json` record per skill in this proposal.

    Matches the field semantics skill-lifecycle.py actually reads (see
    compute_activity_anchor and the created_by/pinned/state/use_count checks
    in run_lifecycle there) -- this does not invent new fields.

    - created_by/created_at/state/pinned/use_count are seeded only if the
      record doesn't already have them, so re-persisting an existing skill
      never clobbers a human's pin, its lifecycle state, or its telemetry.
    - last_patched_at is always bumped to now: it is the activity field
      compute_activity_anchor() reads that specifically means "content was
      patched," which is exactly what this write is doing.
    """
    now = _now_iso()
    merged = dict(usage)
    for name in skill_names:
        record = dict(merged.get(name, {}))
        record.setdefault("created_by", "agent")
        record.setdefault("created_at", now)
        record.setdefault("state", "active")
        record.setdefault("pinned", False)
        record.setdefault("use_count", 0)
        record["last_patched_at"] = now
        merged[name] = record
    return merged


def _plan(proposal: dict, memory_dir: Path, skills_dir: Path) -> list[tuple[tuple[Path, ...], Path, str, str]]:
    """Build the write plan.

    Each entry is `(dirs, target, mode, content)`: `dirs` is the ordered
    chain of directories from the top-level store directory down to
    `target`'s immediate parent, every one of which `_write_all` creates and
    confinement/symlink-checks in order before anything is staged. Memory
    entries are a one-level chain (`(memory_dir,)`); skills are two-level
    (`(skills_dir, skill_dir)`) since each skill now gets its own directory.
    """
    planned: list[tuple[tuple[Path, ...], Path, str, str]] = []

    # "Also in scope" fix (fix round D): _write_all() symlink-checks every
    # directory in a write's chain (memory_dir / skills_dir included) before
    # touching anything -- but with a symlinked skills_dir, _load_usage_dict
    # below reads `<target>/.usage.json` *before* _write_all ever runs, since
    # planning (this function) happens first. That let a symlinked skills_dir
    # leak a boolean "is .usage.json valid JSON?" signal (via PersistError's
    # message vs. success) from outside the store, before the write path's
    # own confinement checks got a chance to refuse it. No content disclosure
    # was achievable this way and nothing was ever written, but the read
    # itself should never happen at all -- hoisting the same symlink check
    # _write_all already performs to the top of planning closes that read
    # window without weakening any other check (root-relative confinement,
    # O_NOFOLLOW, hardlink rejection, etc. are all untouched and still run at
    # write time exactly as before).
    if proposal["memory"]:
        _reject_if_symlink(memory_dir, "store directory")
    for entry in proposal["memory"]:
        planned.append(((memory_dir,), memory_dir / entry["file"], entry["mode"], entry["content"]))

    skill_names = [entry["name"] for entry in proposal["skills"]]
    if skill_names:
        _reject_if_symlink(skills_dir, "store directory")
    for entry in proposal["skills"]:
        skill_dir = skills_dir / entry["name"]
        planned.append(((skills_dir, skill_dir), skill_dir / SKILL_CONTENT_FILENAME,
                        "replace", entry["content"]))

    if skill_names:
        # Folded into the very same staged-then-renamed transaction as the
        # skill content below: a crash between the two renames is the one
        # residual this module can't close (documented in _write_all), but
        # nothing here introduces a *new* window beyond that pre-existing one.
        usage = _load_usage_dict(skills_dir)
        merged = _merge_usage(usage, skill_names)
        usage_content = json.dumps(merged, indent=2, sort_keys=True) + "\n"
        planned.append(((skills_dir,), skills_dir / USAGE_FILENAME, "replace", usage_content))

    return planned


def _write_all(planned: list[tuple[tuple[Path, ...], Path, str, str]]) -> tuple[list[str], int]:
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

    Each entry's `dirs` chain (see `_plan`) is walked and mkdir'd/checked one
    level at a time: every directory is created (a no-op if it already
    exists as a real directory), confinement-checked against its immediate
    parent via `_assert_inside`, and *explicitly* symlink-checked itself.
    That explicit check is deliberately redundant with two things that
    already happen to cover it at the current chain depths (max 2: e.g.
    skills_dir -> skill_dir): the *next* iteration's `_assert_inside(parent,
    directory)` call also symlink-checks `parent` (catching a symlinked
    non-final directory), and the post-loop `_assert_inside(stage_dir,
    target)` call symlink-checks `stage_dir` (catching a symlinked final
    directory). A mutation test that deleted the explicit per-directory
    check accordingly did not reproduce a live vulnerability -- both
    surrounding checks still closed it. It is kept anyway: it is what makes
    every directory in the chain check itself directly rather than relying
    on being some *other* directory's `root` argument on a different
    iteration, which is what a future third chain level (none exist today)
    would need to stay safe.
    """
    staged: list[tuple[str, Path]] = []
    total = 0
    try:
        for dirs, target, mode, content in planned:
            parent: Path | None = None
            for directory in dirs:
                directory.mkdir(parents=True, exist_ok=True)
                if parent is not None:
                    _assert_inside(parent, directory)
                _reject_if_symlink(directory, "store directory")
                parent = directory
            stage_dir = dirs[-1]

            _assert_inside(stage_dir, target)
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
            tmp_name = _stage(stage_dir, data)
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

    try:
        # _plan (not just _write_all) can now raise: computing the skill
        # write plan reads and merges the existing `.usage.json`, which is
        # itself subject to the same symlink/hardlink/corrupt-content
        # refusals as any other read in this file. Both must map to the
        # same exit code -- a caller should not be able to tell "planning
        # failed" from "writing failed" from the exit status alone.
        planned = _plan(proposal, memory_dir, skills_dir)

        if args.dry_run:
            print(json.dumps({"written": [], "skipped": [str(p) for _, p, _, _ in planned],
                              "bytes": sum(len(c.encode("utf-8")) for _, _, _, c in planned)}))
            return 0

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
