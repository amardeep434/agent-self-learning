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

TOCTOU: on platforms where the `os` module reports dir_fd support for
open/mkdir/stat/replace/unlink (checked via `os.supports_dir_fd`, never by
platform name -- see DIR_FD_SUPPORTED below), every directory below the
trusted store root (memory_dir/skills_dir themselves, resolved by paths.py
and never proposal-derived) is opened relative to its parent's already-open
file descriptor with O_NOFOLLOW, and every subsequent stat/read/write/rename
against it is anchored to that same fd. There is then no point where a path
component is re-resolved from a string after being validated, which is what
closes the race a prior version of this module measured at up to ~18% escape
under active contention (tests/test-adversarial-sweep.py's TestTOCTOU; see
.superpowers/sdd/2026-07-25-harness-neutral-persistence/fix-p3-toctou-report.md).
Windows has no dir_fd support in the stdlib `os` module at all (`os.mkdir`
etc. raise NotImplementedError there), so on Windows this module uses the
path-based implementation (_write_all_path). There, every directory in the
chain is *pinned* where the platform allows it: held open root-to-leaf via
CreateFileW (ctypes, stdlib) with FILE_FLAG_BACKUP_SEMANTICS |
FILE_FLAG_OPEN_REPARSE_POINT and a share mode omitting FILE_SHARE_DELETE (but
GRANTING FILE_SHARE_WRITE -- creating a file in a directory is a write to the
directory object, so denying it denies our own staging), which makes the
kernel refuse any rename or delete of that directory for the duration of the
write. In-place conversion to a junction is NOT covered; see win_dir_pin.
Pinning is gated on a functional probe that measures BOTH halves of that
contract -- an attacker's rename is refused AND our own staged replace inside
the pinned directory still succeeds -- with a control experiment so an
unwritable volume cannot look like protection. Where either half fails,
pinning is off and this module's TOCTOU window on that platform is exactly as
previously disclosed. See lib/win_dir_pin.py for the MSDN citations and the
two corrections of record from CI runs 30184253819 and 30184755246.

CONCURRENCY: the plan+write transaction (everything from reading an existing
MEMORY.md or `.usage.json` through renaming the staged files into place) is
serialised across processes by lib/store_lock.py's whole-store lock. Without
it, two hooks firing near-simultaneously -- which both harnesses do, and which
the detached-by-design review pipeline makes likely rather than exotic -- each
read the same file, each append their own entry, and each rename their own
copy over the other's: one of the two appends is destroyed and BOTH processes
exit 0 printing a success JSON. Measured before the fix, with a
barrier-synchronised harness: 30-38 of 40 concurrent appends lost, and 38 of
40 `.usage.json` skill-telemetry records lost (so this was never an
append-only defect -- "replace"-mode skill writes read-modify-write
`.usage.json` too). See tests/test-persist-concurrency.py and
.superpowers/sdd/2026-07-25-harness-neutral-persistence/fix-p7-append-race-report.md.
Acquisition is bounded; on timeout this exits non-zero AND writes to
${SL_LOG_DIR}/persist-failures.log, which doctor.sh surfaces -- a silent
give-up would be the very failure mode this project exists to eliminate.

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
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import paths  # noqa: E402
import win_dir_pin  # noqa: E402
from isotime import now_iso as _now_iso  # noqa: E402  (fix round D: shared with skill-lifecycle.py, index-session.py, coach-signals.py)
from proposal_schema import ValidationError, extract_proposal, validate_proposal  # noqa: E402
from store_lock import LockTimeout, LockUnavailable, StoreLock, default_lock_dir  # noqa: E402

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
# The values themselves now live in lib/skill_layout.py -- the single
# definition every consumer (Python via import, bash via its CLI) reads from;
# see that module's docstring. Aliased here under this module's existing
# names so the rest of this file, and its tests, need no further changes.
import skill_layout  # noqa: E402

SKILL_CONTENT_FILENAME = skill_layout.SKILL_MD_FILENAME
USAGE_FILENAME = skill_layout.USAGE_FILENAME

def _probe_dir_fd_support() -> bool:
    """Real functional probe, not a platform-name check and not a bare
    `os.supports_dir_fd` set-membership lookup either.

    This codebase has been bitten repeatedly by assuming what a platform
    *name* implies (see tests/test-path-compare-lib.sh, tests/test-doctor.sh,
    and the CAN_SYMLINK/CAN_HARDLINK probes in tests/test-persist-proposal.py)
    -- but `os.supports_dir_fd` itself turned out to be an unreliable proxy
    for what we actually need here: on this project's own Linux dev/CI
    environment, `os.replace in os.supports_dir_fd` is False (only
    `os.rename` is listed, even though both wrap the same syscall), while
    `os.replace(src, dst, src_dir_fd=..., dst_dir_fd=...)` demonstrably
    works when called for real. Trusting the set literally for os.replace
    would have wrongly reported dir_fd as unsupported everywhere this
    module actually runs, silently falling back to the documented-weaker
    path-based writer on every POSIX platform -- exactly the kind of
    "measured wrong, believed for years" mistake this fix exists to correct
    (see the module docstring's TOCTOU section). A real, disposable
    open/mkdir/stat/replace/unlink sequence in a throwaway temp directory is
    the only thing that can't lie the way an introspection table can.
    """
    if not (hasattr(os, "O_DIRECTORY") and hasattr(os, "O_NOFOLLOW")):
        return False
    try:
        with tempfile.TemporaryDirectory() as d:
            root_fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.mkdir("probe-dir", dir_fd=root_fd)
                sub_fd = os.open("probe-dir", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                  dir_fd=root_fd)
                try:
                    fd = os.open("a", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=sub_fd)
                    os.close(fd)
                    os.stat("a", dir_fd=sub_fd, follow_symlinks=False)
                    os.replace("a", "b", src_dir_fd=sub_fd, dst_dir_fd=sub_fd)
                    os.unlink("b", dir_fd=sub_fd)
                finally:
                    os.close(sub_fd)
            finally:
                os.close(root_fd)
        return True
    except (OSError, NotImplementedError):
        return False


DIR_FD_SUPPORTED = _probe_dir_fd_support()

# Retries for picking a temp-file name that doesn't collide inside a
# dir_fd-anchored directory (no path-based tempfile.mkstemp equivalent
# exists for dir_fd -- see _stage_fd). Collisions are pathologically
# unlikely (16 hex chars of os.urandom per attempt); this bounds a
# pathological run rather than looping forever.
_TMP_NAME_ATTEMPTS = 8


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
    O_NOFOLLOW (os.O_NOFOLLOW is absent there), so on Windows this falls back
    to the is_symlink()/st_reparse_tag pre-check alone. The narrow race that
    leaves on the *directory* components is closed separately by
    lib/win_dir_pin.py's held directory handles (see _write_all_path); the
    residual here is the target *file* itself, where os.replace() does not
    follow a symlink at the destination in any case (see
    _reject_if_symlink). Note that directory junctions never require the
    elevation symlink creation does, and are invisible to
    Path.is_symlink() -- which is why st_reparse_tag is checked too.
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


def _append_join(existing: str, content: str) -> str:
    """Join `content` onto `existing` so it starts on a line of its own.

    `existing + content` -- what both write paths did until now -- assumes the
    file already ends with a newline. Nothing enforces that: append content
    comes from a model, and a proposal whose content lacks a trailing newline
    leaves the file ending mid-line, so the NEXT proposal's first entry is
    concatenated onto it. Measured on the real store: MEMORY.md line 19 held
    four separate entries run together as
    `...invented shape.- [Probe...].- Route B path: ...`, which is not
    line-separated memory any more, it is one 516-character line that no
    reader (human or model) can treat as four facts.

    Normalising, not merely inserting a separator, so the result is
    idempotent: repeated appends can never accumulate blank lines at the end
    of the file, and an existing file that already ends in several newlines
    collapses to exactly one. Trailing blank lines carry no meaning in a
    file whose entries are one-per-line by contract, so collapsing them is
    lossless; the content's INTERNAL newlines are untouched.

    Empty (or newline-only) content is a no-op rather than a bare "\\n": an
    append of nothing must not silently grow the file by a blank line.
    """
    body = content.strip("\n")
    if not body:
        return existing
    prefix = existing.rstrip("\n")
    if prefix:
        prefix += "\n"
    return prefix + body + "\n"


def _reject_duplicate_lines(existing: str, content: str, target: Path) -> None:
    """Refuse an append that repeats a line already present in `target`.

    Memory is a single bounded file with no eviction (see
    MAX_MEMORY_FILE_BYTES -- a hard wall, not a trim), so every duplicated
    line permanently costs space that a real fact could have used, and
    nothing ever evicts it.

    Refused loudly (PersistError -> exit 2 -> one attributed line in
    persist-failures.log, which doctor.sh reports) rather than silently
    deduplicated on write. A silent drop would hide the actual fault -- a
    reviewer that did not read MEMORY.md before proposing, which the OUTPUT
    CONTRACT now explicitly requires -- and would leave the operator with a
    "written" result that did not match what was proposed. This is the same
    trade proposal_schema already makes for two entries naming one file:
    wholesale refusal with a diagnostic the reviewer can act on.

    Exact whole-line matches only. The near-duplicates in the real store
    (the same lesson twice, with different wording after the em-dash) are
    NOT caught here and cannot be, without the writer judging meaning; the
    defence for those is the contract rule telling the reviewer to read the
    file first, not this check.
    """
    # Blank lines are filtered on the CONTENT side only. Filtering them out of
    # `have` as well was written first and proved inert under mutation -- with
    # no blank line ever reaching the `in have` test, what `have` contains
    # cannot matter -- so it was removed rather than kept as decoration.
    have = set(existing.split("\n"))
    repeated = [line for line in content.split("\n")
                if line.strip() and line in have]
    if repeated:
        raise PersistError(
            f"refusing to append a line already present in {target}: "
            f"{repeated[0]!r} (read the file before proposing; "
            f"{len(repeated)} duplicate line(s) in this entry)"
        )


def _append_data(existing: str, content: str, target: Path) -> str:
    """The whole append policy, shared by both write paths.

    Both _write_all_path and _write_all_fd used to inline `existing + content`
    separately; a policy that lives in two places is exactly the drift this
    project has already been bitten by four times (see lib/review-common.sh's
    header), so it lives here once.
    """
    _reject_duplicate_lines(existing, content, target)
    return _append_join(existing, content)


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


def _folds_onto_other_entry(name: str, entry_exists: bool, actual_entries: "list[str]") -> bool:
    """Would writing skill `name` land on an EXISTING, differently-cased entry?

    Pure and side-effect-free so it can be exercised directly on a
    case-sensitive filesystem, where the condition it detects cannot be
    reproduced (see tests/test-persist-proposal.py).

    `entry_exists` is `(skills_dir / name).exists()`; `actual_entries` is
    `os.listdir(skills_dir)` -- the names the directory REALLY holds.

    This is an observation, not a platform-name branch and not a probe file
    dropped in the user's store:

    - Case-sensitive FS, `alpha/` present, name "ALPHA": the path does not
      exist -> False. Two genuinely distinct skills stay legal, which they
      are on that filesystem.
    - Case-insensitive FS, `alpha/` present, name "ALPHA": the path DOES
      exist (it folds onto `alpha/`) yet "ALPHA" is not in the real
      directory listing -> True. Writing would overwrite `alpha`'s SKILL.md
      while `.usage.json` gained a second, independent "ALPHA" record --
      the exact content-destroying collision this detects.
    - Either FS, re-writing `alpha` as "alpha": exists, and "alpha" IS in
      the listing -> False. A legitimate update of the same skill is never
      blocked; that is the loop's normal, most common operation.
    - Either FS, brand-new name: does not exist -> False.
    """
    return entry_exists and name not in actual_entries


def _assert_no_case_fold_collision(skills_dir: Path, skill_names: list[str]) -> None:
    """Refuse a write that a case-folding filesystem would land on another skill.

    The in-proposal case is caught earlier and cheaply, by
    proposal_schema.validate_proposal. This is the ACROSS-review case: an
    earlier review created `alpha`, a later one proposes `ALPHA`. Same
    destruction, one review cycle apart, and invisible to any check that
    only looks at the proposal in hand.

    Refuse rather than merge or silently rename. Merging would join two
    skills the reviewer meant to keep apart; renaming to the on-disk casing
    would silently rewrite the user's store, which this module's threat
    model forbids outright. Refusing writes nothing at all, and raising
    PersistError puts a named reason in front of a human: exit 2, which the
    detached pipeline in both review scripts records in
    persist-failures.log, which doctor.sh surfaces. Loud, never a drop.
    """
    try:
        actual_entries = os.listdir(skills_dir)
    except FileNotFoundError:
        return  # nothing on disk yet; nothing to collide with
    for name in skill_names:
        if _folds_onto_other_entry(name, (skills_dir / name).exists(), actual_entries):
            existing = [e for e in actual_entries if e.casefold() == name.casefold()]
            raise PersistError(
                f"skill {name!r} case-folds onto existing skill(s) {sorted(existing)!r} "
                f"on this filesystem: writing it would overwrite their content while "
                f"recording a separate {USAGE_FILENAME} entry. Refusing the whole "
                f"proposal; rename the skill or update the existing one under its "
                f"exact name."
            )


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
        # Before anything is staged, and inside the store lock (main() holds
        # it around _plan for exactly this read-modify-write reason), so a
        # concurrent writer cannot create the colliding entry between the
        # check and the write.
        _assert_no_case_fold_collision(skills_dir, skill_names)
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
    """Dispatch to the dir_fd-anchored writer where the platform supports
    it, else the path-based writer below. See DIR_FD_SUPPORTED and
    _write_all_fd's docstring for what "supports it" means and why this is
    a capability check, never a platform-name branch.
    """
    if DIR_FD_SUPPORTED:
        return _write_all_fd(planned)
    return _write_all_path(planned)


def _write_all_path(planned: list[tuple[tuple[Path, ...], Path, str, str]]) -> tuple[list[str], int]:
    """Stage every entry, then rename every staged file into place.

    Path-based fallback used only when DIR_FD_SUPPORTED is false (i.e. on
    Windows, which has no dir_fd support in the stdlib `os` module at all --
    see DIR_FD_SUPPORTED). Everywhere DIR_FD_SUPPORTED is true, _write_all_fd
    runs instead and closes the race described below.

    Raises PersistError/OSError on any failure. On a staging failure, no real
    target has been touched. On a (much less likely) rename failure partway
    through, entries already renamed are committed and later ones are not --
    the exception propagates so the caller reports a hard failure (exit 2)
    rather than a false success; a fully cross-file atomic commit would need
    a journal or a directory-swap trick this stdlib-only, cross-platform
    script does not attempt.

    THE RACE THIS USED TO CARRY UNCONDITIONALLY, AND WHAT NOW CLOSES IT
    -------------------------------------------------------------------
    A race lives between `_assert_inside(root, ...)` and
    `tempfile.mkstemp(dir=root)` inside `_stage`: `root` could in principle be
    swapped for a symlink or junction in that gap. Measured
    (tests/test-adversarial-sweep.py's TestTOCTOU, prior to the dir_fd fix) at
    up to ~18% escape under active contention on POSIX. Closing it the POSIX
    way needs dir_fd-relative operations throughout, which Windows's `os`
    module does not provide (`os.mkdir(..., dir_fd=...)` etc. raise
    NotImplementedError; `os.supports_dir_fd` is empty), and `os.O_NOFOLLOW`
    does not exist there either. Both are confirmed UNAVAILABLE by this repo's
    own capability probe on windows-latest.

    The threat is not theoretical on Windows: the same CI probe prints
    "symlink creation: AVAILABLE" on the runner, and directory JUNCTIONS have
    never required elevation at all -- which is why `_reject_if_symlink()`
    above checks `st_reparse_tag`. That check is correct but is a *check*, and
    therefore still racy.

    lib/win_dir_pin.py attempts to close that window on Windows with
    documented Win32 rather than ntdll: every directory in the chain is opened
    root-to-leaf with CreateFileW using FILE_FLAG_BACKUP_SEMANTICS |
    FILE_FLAG_OPEN_REPARSE_POINT and a share mode of FILE_SHARE_READ *only*.
    Omitting FILE_SHARE_DELETE means no other process can obtain delete
    access, and MSDN states delete access "allows both delete and rename
    operations". FILE_SHARE_WRITE is deliberately GRANTED: creating a file in
    a directory is a write to the directory object (FILE_ADD_FILE and
    FILE_WRITE_DATA are both 0x0002), so denying it denies our own staging.
    In-place conversion via FSCTL_SET_REPARSE_POINT is therefore NOT blocked,
    and is not claimed.

    "ATTEMPTS TO" IS DELIBERATE WORDING. The design is documented-correct and
    was nevertheless wrong twice in practice -- once blocking nothing, once
    blocking us. Both are recorded in win_dir_pin's module docstring.

    So `win_dir_pin.available()` does not mean "CreateFileW worked". It means
    BOTH halves of the contract were measured on this machine: an attacker's
    rename is refused AND our own staged replace inside the pinned directory
    still succeeds (win_dir_pin.verify_pin_contract, with a control experiment
    so an unwritable volume cannot masquerade as protection). If either half
    fails, pinning is disabled and this function keeps exactly the race
    documented above: disclosed, not silently papered over.

    Fail-safe posture: unavailable or unopenable -> today's unpinned
    behaviour; a handle that reports a reparse point -> hard refusal; and a
    STAGING failure while pins are held -> release everything and re-run the
    transaction unpinned (see `_write_all_path`), so pinning cannot break
    persistence even if the probe is somehow wrong again.
    `_PIN_SET_FACTORY` below is the single injection point tests use to
    exercise the sequencing on a host where the Win32 backend can never run.

    See .superpowers/sdd/2026-07-25-harness-neutral-persistence/fix-p3-toctou-report.md
    and residuals-research-report.md (Residual 1 / Residual A).

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
    pins = _PIN_SET_FACTORY()
    try:
        try:
            return _write_all_path_once(planned, pins)
        except _StagingFailed as failure:
            if not pins.pinned_paths():
                # Nothing was pinned, so pinning cannot be the cause. This is
                # an ordinary staging failure (permissions, disk full) and
                # must surface exactly as it always has.
                raise failure.cause
    finally:
        # Released BEFORE the retry, which is the entire point: whatever the
        # pins were refusing, they are not holding it any more.
        pins.close_all()

    # Reached only when staging failed while directories were pinned. Staging
    # touches no real target -- the docstring's "on a staging failure, no real
    # target has been touched" invariant is what makes this retry safe, and it
    # is why commit-phase failures are deliberately NOT retried (some entries
    # would already be committed, and re-running an append would double-apply
    # it).
    #
    # This exists so that "the pin broke persistence" is impossible BY
    # CONSTRUCTION, not merely improbable by measurement. win_dir_pin's probe
    # verifies that our own staged replace works while pinned, but it can only
    # verify it in a temp directory; the store may live on another volume with
    # different behaviour. A hardening that silently costs the user every
    # write is worse than the race it closes -- that is not a hypothesis, it
    # is what CI run 30184755246 measured across 10 of 43 suites.
    try:
        return _write_all_path_once(planned, win_dir_pin.PinSet(enabled=False))
    except _StagingFailed as failure:
        raise failure.cause


class _StagingFailed(Exception):
    """Internal marker: an OSError raised during the STAGING phase.

    Never escapes this module -- `_write_all_path` either retries or re-raises
    the original `cause`. It exists only to distinguish "nothing has been
    committed yet, the whole transaction can safely be re-run" from a
    commit-phase failure, where it cannot.

    Deliberately does NOT wrap PersistError: confinement refusals and
    reparse-point rejections are attack signals, and retrying one without its
    pins would be the single worst thing this module could do. PersistError is
    not an OSError subclass, so it bypasses the wrapping entirely rather than
    relying on clause ordering.
    """

    def __init__(self, cause: OSError) -> None:
        super().__init__(str(cause))
        self.cause = cause


def _write_all_path_once(planned: list[tuple[tuple[Path, ...], Path, str, str]],
                         pins) -> tuple[list[str], int]:
    """One attempt at the staged-write transaction. See `_write_all_path`."""
    staged: list[tuple[str, Path]] = []
    total = 0
    try:
        for dirs, target, mode, content in planned:
            parent: Path | None = None
            for directory in dirs:
                # Confinement is checked *before* mkdir, not after: an
                # attacker-controlled name that yields an absolute Path
                # (e.g. a raw "/tmp/evilpwn" reaching _plan/_write_all
                # directly, bypassing proposal_schema's slash-free regex --
                # see the confinement-backstop sweep in
                # tests/test-adversarial-sweep.py) makes pathlib's `/`
                # operator discard the left operand entirely, so `directory`
                # can be a path outside the store on the very first mkdir
                # call. Checking first means that mkdir is never reached for
                # such a path, so no stray directory is left behind on disk
                # even though the write is correctly refused either way.
                if parent is not None:
                    _assert_inside(parent, directory)
                directory.mkdir(parents=True, exist_ok=True)
                _reject_if_symlink(directory, "store directory")
                # Pin *after* mkdir (nothing exists to open before it) and
                # after the path-based check, so the handle-derived verdict
                # is the authoritative one: from here until close_all() the
                # kernel refuses any rename or delete of this directory (NOT
                # in-place reparse conversion -- see win_dir_pin's
                # PIN_SHARE_MODE for why write sharing must be granted).
                # Root-to-leaf order matters -- once level N-1 is pinned,
                # resolving the name of level N through it is safe.
                try:
                    pins.pin(directory)
                except win_dir_pin.ReparsePointError as exc:
                    raise PersistError(str(exc)) from exc
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

            data = (_append_data(_read_existing(target), content, target)
                    if mode == "append" else content)
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

    except OSError as exc:
        # Staging phase only -- the commit loop below is outside this handler
        # on purpose, because a failure there may leave earlier entries
        # committed and is therefore not retryable.
        for tmp_name, _target in staged:
            _cleanup_tmp(tmp_name)
        raise _StagingFailed(exc) from exc
    except BaseException:
        for tmp_name, _target in staged:
            _cleanup_tmp(tmp_name)
        raise

    try:
        written: list[str] = []
        for tmp_name, target in staged:
            os.replace(tmp_name, target)
            written.append(str(target))
        return written, total
    except BaseException:
        for tmp_name, _target in staged:
            _cleanup_tmp(tmp_name)
        raise


# The one seam tests use to drive the Windows pinning sequence from a POSIX
# host, where win_dir_pin's CreateFileW backend can never run. Production code
# never rebinds it; win_dir_pin.PinSet() self-gates on its functional probe.
_PIN_SET_FACTORY = win_dir_pin.PinSet


# ===========================================================================
# dir_fd-anchored write path (used when DIR_FD_SUPPORTED). Every directory
# below the trusted store root is opened relative to its parent's already-
# open file descriptor, with O_NOFOLLOW; every subsequent stat/read/write/
# rename against it is anchored to that fd rather than a path string. A
# planted symlink can therefore never be "raced in" between a check and the
# operation that check was guarding: the kernel resolves each `name` against
# the fd atomically inside a single syscall, and O_NOFOLLOW makes that
# syscall fail outright (ELOOP) rather than follow a symlink swapped in
# mid-flight. This is what closes the race _write_all_path documents as
# unfixed.
# ===========================================================================

def _close_quietly(fd: int) -> None:
    try:
        os.close(fd)
    except OSError:
        pass


def _cleanup_tmp_fd(stage_fd: int, tmp_name: str) -> None:
    try:
        os.unlink(tmp_name, dir_fd=stage_fd)
    except OSError:
        pass  # already renamed, or never created -- nothing to do


def _reject_suspicious_component(name: str) -> None:
    """Same suspicious-name backstop as _assert_inside's target-name check,
    applied to a single path component instead of a resolved Path. Needed
    because the dir_fd walk below deliberately never resolves/stringifies a
    full path (that re-resolution is exactly the TOCTOU surface being
    closed) -- so it can't reuse _assert_inside's parent.resolve() logic and
    needs its own component-level check instead.
    """
    if name in ("", ".", "..") or "/" in name or "\\" in name:
        raise PersistError(f"refusing suspicious path component: {name!r}")


def _raise_dir_open_error(name: str, exc: OSError) -> None:
    if exc.errno == errno.ELOOP:
        raise PersistError(f"refusing to use symlinked directory: {name!r}") from exc
    if exc.errno == errno.ENOTDIR:
        raise PersistError(f"expected a directory but found something else: {name!r}") from exc
    raise exc


def _mkdir_and_open_dir_fd(name: str, dir_fd: int) -> int:
    """Open `name` (relative to `dir_fd`) as a directory fd, O_NOFOLLOW,
    creating it first if it doesn't exist yet.

    The critical property: the *final* open() call that actually hands back
    a usable fd always carries O_NOFOLLOW and is always the last thing that
    happens, after any create-if-missing attempt. So even if something swaps
    `name` for a symlink in the gap between our first failed open and our
    mkdir (the FileExistsError branch below), the re-opening open() call
    still refuses it -- there is no window where a symlink resolved by this
    function goes unchecked.
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        return os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        pass
    except OSError as exc:
        _raise_dir_open_error(name, exc)

    try:
        os.mkdir(name, dir_fd=dir_fd)
    except FileExistsError:
        pass  # raced with something creating it -- the verifying open below decides

    try:
        return os.open(name, flags, dir_fd=dir_fd)
    except OSError as exc:
        _raise_dir_open_error(name, exc)
        raise AssertionError("unreachable")  # _raise_dir_open_error always raises


def _stat_relative(stage_fd: int, name: str):
    """os.stat anchored to `stage_fd`, not following symlinks. None if absent."""
    try:
        return os.stat(name, dir_fd=stage_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _read_existing_fd(stage_fd: int, name: str) -> str:
    """dir_fd-anchored counterpart to _read_existing: same symlink/hardlink/
    UTF-8 refusals, anchored to `stage_fd` instead of re-resolving a path.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=stage_fd)
    except FileNotFoundError:
        return ""
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise PersistError(f"refusing to use symlinked target: {name!r}") from exc
        raise
    fd_owned_by_handle = False
    try:
        st = os.fstat(fd)
        if st.st_nlink > 1:
            raise PersistError(f"refusing to read multiply-linked file: {name!r}")
        handle = os.fdopen(fd, "r", encoding="utf-8", newline="")
        fd_owned_by_handle = True
        try:
            with handle:
                return handle.read()
        except UnicodeDecodeError as exc:
            raise PersistError(f"existing file is not valid UTF-8: {name!r}") from exc
    finally:
        if not fd_owned_by_handle:
            os.close(fd)


def _stage_fd(stage_fd: int, data: str) -> str:
    """dir_fd-anchored counterpart to _stage: write `data` to a fresh,
    uniquely-named temp file inside the directory `stage_fd` refers to, and
    return its (relative) name. tempfile.mkstemp has no dir_fd parameter, so
    uniqueness is reimplemented here with O_CREAT|O_EXCL and a random name,
    the same approach mkstemp itself uses internally, retried up to
    _TMP_NAME_ATTEMPTS times on collision.

    Same 0600 rationale as `_stage`: learned content is sensitive, and this
    removes any window where a partially-written file is readable by anyone
    but the owner.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = None
    tmp_name = None
    for _ in range(_TMP_NAME_ATTEMPTS):
        candidate = f".persist-tmp-{os.urandom(8).hex()}"
        try:
            fd = os.open(candidate, flags, 0o600, dir_fd=stage_fd)
        except FileExistsError:
            continue
        tmp_name = candidate
        break
    if fd is None:
        raise PersistError("could not create a unique temp file after repeated attempts")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        _cleanup_tmp_fd(stage_fd, tmp_name)
        raise
    return tmp_name


def _write_all_fd(planned: list[tuple[tuple[Path, ...], Path, str, str]]) -> tuple[list[str], int]:
    """dir_fd-anchored implementation of the write phase. See the module
    docstring's TOCTOU section and this section's banner comment above for
    the design; see _write_all_path's docstring for the race this replaces.

    Every fd this function opens is closed in a `finally`, on every path
    including exceptions -- a leaked fd in a script that runs once per
    review is a slow, hard-to-diagnose resource leak in a long-lived
    session, not just an untidy detail.
    """
    staged: list[tuple[int, str, Path]] = []  # (stage_fd, tmp_name, target)
    all_fds: list[int] = []
    total = 0
    try:
        for dirs, target, mode, content in planned:
            opened_this_entry: list[int] = []
            try:
                parent_fd: int | None = None
                for i, directory in enumerate(dirs):
                    if i == 0:
                        # The top-level root (memory_dir/skills_dir) is
                        # trusted -- resolved by paths.py, never derived
                        # from proposal content -- so creating/opening it is
                        # still done by path. Its own symlink-ness is
                        # explicitly rejected, and the O_NOFOLLOW open right
                        # after is atomic against anything that swaps it in
                        # the gap: a symlink there fails the open, it is
                        # never followed.
                        directory.mkdir(parents=True, exist_ok=True)
                        _reject_if_symlink(directory, "store directory")
                        fd = os.open(str(directory), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                    else:
                        # Everything below the root may be proposal-derived
                        # (a skill name). Structural checks first -- pure
                        # string comparisons on the Path objects `_plan`
                        # built, not filesystem calls, so they cannot be
                        # raced -- catch the cases pathlib's `/` operator
                        # can produce from an adversarial raw name (see
                        # tests/test-adversarial-sweep.py's
                        # TestConfinementBackstop): an absolute raw name
                        # discards `dirs[i-1]` entirely (parent mismatch,
                        # caught below), and a raw ".."/"."/"" collapses to
                        # `directory == dirs[i-1]` itself (also a parent
                        # mismatch, since dirs[i-1]'s own parent can never
                        # equal dirs[i-1]) or is caught directly by the
                        # component check. Only once both checks pass does
                        # this touch the filesystem at all.
                        prior = dirs[i - 1]
                        if directory.parent != prior:
                            raise PersistError(f"refusing directory outside its chain: {directory}")
                        _reject_suspicious_component(directory.name)
                        fd = _mkdir_and_open_dir_fd(directory.name, parent_fd)
                    opened_this_entry.append(fd)
                    parent_fd = fd
            except BaseException:
                for fd in opened_this_entry:
                    _close_quietly(fd)
                raise

            # Every fd but the last (stage_fd, the target's immediate
            # parent) is no longer needed once its child has been opened.
            for fd in opened_this_entry[:-1]:
                _close_quietly(fd)
            stage_fd = opened_this_entry[-1]
            all_fds.append(stage_fd)

            if target.parent != dirs[-1]:
                raise PersistError(f"refusing target outside its directory: {target}")
            _reject_suspicious_component(target.name)

            st = _stat_relative(stage_fd, target.name)
            if st is not None:
                if stat.S_ISLNK(st.st_mode):
                    raise PersistError(f"refusing to use symlinked target: {target}")
                if stat.S_ISDIR(st.st_mode):
                    # Caught here (staging phase, before any rename) rather
                    # than left to surface as an IsADirectoryError from
                    # os.replace() during the commit phase below -- see
                    # _write_all_path's matching comment for why that
                    # ordering matters for the all-or-nothing guarantee.
                    raise PersistError(f"refusing to write over existing directory: {target}")

            data = (_append_data(_read_existing_fd(stage_fd, target.name), content, target)
                    if mode == "append" else content)
            if len(data.encode("utf-8")) > MAX_MEMORY_FILE_BYTES:
                raise PersistError(
                    f"{target} would exceed {MAX_MEMORY_FILE_BYTES} bytes after this write"
                )
            tmp_name = _stage_fd(stage_fd, data)
            staged.append((stage_fd, tmp_name, target))
            total += len(content.encode("utf-8"))

        written: list[str] = []
        for stage_fd, tmp_name, target in staged:
            os.replace(tmp_name, target.name, src_dir_fd=stage_fd, dst_dir_fd=stage_fd)
            written.append(str(target))
        return written, total
    except BaseException:
        for stage_fd, tmp_name, _target in staged:
            _cleanup_tmp_fd(stage_fd, tmp_name)
        raise
    finally:
        for fd in all_fds:
            _close_quietly(fd)


def _log_persist_failure(resolved: dict, message: str) -> None:
    """Append one line to ${SL_LOG_DIR}/persist-failures.log.

    This module normally reports failure through its exit code, and the
    shell wrappers (session-review.sh, copilot-session-review.sh) turn a
    non-zero status into a line in this same log. A lock timeout is logged
    here as well, directly: it is the one failure that is *expected* to be
    transient and contended, so the operator needs to see how often it
    happens and against which lock file, not just that "the pipeline failed
    (status 2)". The line shape matches what the wrappers already write
    (`<ISO-8601 Z> <component>: <message>`), because doctor.sh tails this
    file verbatim.

    Never raises: a store whose logs/ directory is unwritable must still get
    the non-zero exit code, not a traceback that replaces one failure report
    with a different one.
    """
    try:
        log_dir = Path(os.environ.get("SL_LOG_DIR") or resolved["logs"])
        log_dir.mkdir(parents=True, exist_ok=True)
        with open(log_dir / "persist-failures.log", "a", encoding="utf-8", newline="\n") as handle:
            handle.write(f"{_now_iso()} persist-proposal: {message}\n")
    except OSError:
        pass


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
        if args.dry_run:
            # No lock: a dry run writes nothing, so there is no
            # read-modify-write span to serialise, and taking the lock would
            # mean creating the state directory and a lock file as a side
            # effect of an explicitly no-side-effects mode.
            planned = _plan(proposal, memory_dir, skills_dir)
            print(json.dumps({"written": [], "skipped": [str(p) for _, p, _, _ in planned],
                              "bytes": sum(len(c.encode("utf-8")) for _, _, _, c in planned)}))
            return 0

        # _plan is inside the lock, not just _write_all: planning reads and
        # merges the existing `.usage.json`, which is itself a
        # read-modify-write whose result is written at the end of _write_all.
        # Locking only the write half would leave exactly the span that
        # destroyed 38 of 40 skill-telemetry records in the pre-fix
        # measurement.
        # default_lock_dir(), not resolved["state"] directly: the lock only
        # serialises processes that pick the SAME path, and skill-lifecycle.py
        # and curator-run.sh (via lib/store-lock.sh) must pick it too. One
        # shared definition -- see store_lock.default_lock_dir.
        with StoreLock(default_lock_dir()):
            planned = _plan(proposal, memory_dir, skills_dir)
            written, total = _write_all(planned)
    except LockTimeout as exc:
        _log_persist_failure(resolved, f"lock timeout: {exc}")
        print(f"persist-proposal: write failed: {exc}", file=sys.stderr)
        return 2
    except (OSError, PersistError, LockUnavailable, ValueError) as exc:
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
