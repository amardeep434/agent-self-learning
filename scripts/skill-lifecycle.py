#!/usr/bin/env python3
"""
skill-lifecycle.py
Lifecycle state machine for learned skills.

Walks $SL_SKILLS_DIR/.usage.json and applies deterministic
state transitions based on activity timestamps:

    active  --(30 days inactive)--> stale
    stale   --(90 days inactive)--> archived  (directory moved to .archive/)
    stale   --(any activity)------> active    (reactivated)

Respects:
    - pinned skills (no state transitions)
    - user-created skills (only agent-created skills are managed)

Usage:
    python3 skill-lifecycle.py              # Apply transitions
    python3 skill-lifecycle.py --dry-run    # Preview only
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from isotime import parse_iso  # noqa: E402  (fix round D blocker (a): shared parser, see lib/isotime.py)
import skill_layout  # noqa: E402  (single definition of the skill-directory layout; see lib/skill_layout.py)
from store_lock import (  # noqa: E402  (fix-p8: same lock persist-proposal.py takes)
    LockTimeout, LockUnavailable, StoreLock, default_lock_dir,
)

# ---------------------------------------------------------------------------
# Configuration (overridable via environment variables)
# ---------------------------------------------------------------------------


def _default_skills_dir() -> Path:
    """Resolve the skills directory.

    C2 fix: this used to hardcode ~/.claude/learned-skills and read only the
    Claude-branded CLAUDE_LEARNED_SKILLS_DIR, never the vendor-neutral
    SL_SKILLS_DIR that curator-run.sh exports (via lib/config.sh) before
    invoking this script with no arguments. Two failure modes resulted:
    on a correct vendor-neutral install (no ~/.claude at all), this fell
    back to the hardcoded literal, found nothing, printed "Nothing to do."
    and exited 0 -- lifecycle transitions silently never ran. On an
    *upgraded* machine where a legacy ~/.claude/learned-skills still exists
    from before this project went vendor-neutral, it would run destructive
    shutil.move/shutil.rmtree calls against that stale legacy directory
    while curator-run.sh's own report describes the new one -- silently
    wrong-location and destructive at the same time.

    Resolution order, matching every other consumer in this project:
      1. SL_SKILLS_DIR        -- vendor-neutral, set by lib/config.sh
      2. CLAUDE_LEARNED_SKILLS_DIR -- deprecated alias, honored for one
         release so a caller that sets only the legacy name keeps working
      3. scripts/lib/paths.py's "skills" key -- the single resolver, so a
         caller (e.g. this script invoked standalone with no environment at
         all) never falls back to a hardcoded ~/.claude literal.
    """
    if os.environ.get("SL_SKILLS_DIR"):
        return Path(os.environ["SL_SKILLS_DIR"])
    if os.environ.get("CLAUDE_LEARNED_SKILLS_DIR"):
        print(
            "skill-lifecycle.py: CLAUDE_LEARNED_SKILLS_DIR is deprecated; "
            "use SL_SKILLS_DIR",
            file=sys.stderr,
        )
        return Path(os.environ["CLAUDE_LEARNED_SKILLS_DIR"])
    sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
    import paths  # noqa: E402  (import deferred to keep this a stdlib-only default path)

    return paths.resolve_all()["skills"]


SKILLS_DIR = _default_skills_dir()
# Values come from lib/skill_layout.py -- the single definition of the
# skill-directory layout every consumer shares. See that module's docstring.
USAGE_FILE = skill_layout.usage_file_path(SKILLS_DIR)
ARCHIVE_DIR = skill_layout.archive_dir_path(SKILLS_DIR)
STALE_DAYS = int(os.environ.get("CLAUDE_SKILL_STALE_DAYS", "30"))
ARCHIVE_DAYS = int(os.environ.get("CLAUDE_SKILL_ARCHIVE_DAYS", "90"))


class UsageCorruptError(Exception):
    """`.usage.json` exists but is not valid JSON (or not a JSON object).

    "Also in scope" fix (fix round D): this used to be indistinguishable
    from "no .usage.json at all" -- load_usage() silently returned {} for
    both, and run_lifecycle() then printed "No .usage.json found. Nothing
    to do." and exited 0 for a file that DOES exist, just corrupt. That is
    the exit-0-while-doing-nothing shape this project exists to eliminate,
    and it directly contradicted persist-proposal.py's policy for the exact
    same file: persist-proposal.py refuses (exit 2) rather than silently
    treating a corrupt .usage.json as empty, because silently discarding it
    would itself be a quiet destructive action. This makes the two agree:
    skill-lifecycle.py now refuses too, instead of proceeding as if nothing
    were there.
    """


def load_usage() -> dict:
    """Load .usage.json. Empty dict if missing; raises if present but corrupt."""
    if not USAGE_FILE.exists():
        return {}
    try:
        with open(USAGE_FILE, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        raise UsageCorruptError(f"{USAGE_FILE} exists but is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise UsageCorruptError(f"{USAGE_FILE} does not contain a JSON object")
    return data


def save_usage(data: dict) -> None:
    """Atomic write of .usage.json (temp file + rename)."""
    tmp = USAGE_FILE.with_suffix(".json.tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    tmp.rename(USAGE_FILE)


def compute_activity_anchor(record: dict) -> int | None:
    """Find the most recent activity timestamp across all activity fields."""
    anchor: int | None = None
    for field in ("last_used_at", "last_viewed_at", "last_patched_at"):
        val = record.get(field)
        if val:
            epoch = parse_iso(val)
            if epoch is not None and (anchor is None or epoch > anchor):
                anchor = epoch

    if anchor is None:
        # Fall back to created_at
        created = record.get("created_at")
        if created:
            anchor = parse_iso(created)

    return anchor


def run_lifecycle(dry_run: bool = False) -> str:
    """Apply lifecycle transitions. Returns a summary log."""
    usage = load_usage()
    if not usage:
        return "No .usage.json found. Nothing to do."

    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)

    now_epoch = int(datetime.now(timezone.utc).timestamp())
    now_iso = datetime.now(timezone.utc).isoformat()
    stale_cutoff = now_epoch - (STALE_DAYS * 86400)
    archive_cutoff = now_epoch - (ARCHIVE_DAYS * 86400)

    checked = 0
    marked_stale = 0
    archived = 0
    reactivated = 0
    lines: list[str] = []

    for skill_name, record in list(usage.items()):
        checked += 1

        created_by = record.get("created_by", "unknown")
        state = record.get("state", "active")
        pinned = record.get("pinned", False)
        use_count = record.get("use_count", 0)

        # Only manage agent-created skills
        if created_by != "agent":
            continue

        # Skip pinned skills
        if pinned:
            continue

        anchor = compute_activity_anchor(record)
        if anchor is None:
            anchor = now_epoch  # No timestamps at all -- treat as current

        # Never-used grace period: if use_count == 0 and still within
        # stale window, it is too young to mark stale
        if use_count == 0 and anchor > stale_cutoff:
            if state == "stale":
                lines.append(
                    f"[REACTIVATE] {skill_name} "
                    f"(never-used, too young for stale)"
                )
                if not dry_run:
                    record["state"] = "active"
                reactivated += 1
            continue

        # Archive transition (inactive 90+ days)
        if anchor <= archive_cutoff and state != "archived":
            lines.append(
                f"[ARCHIVE] {skill_name} "
                f"(inactive {ARCHIVE_DAYS}+ days)"
            )
            if not dry_run:
                skill_dir = SKILLS_DIR / skill_name
                archive_dest = ARCHIVE_DIR / skill_name
                if skill_dir.is_dir():
                    if archive_dest.exists():
                        shutil.rmtree(archive_dest)
                    shutil.move(str(skill_dir), str(archive_dest))
                record["state"] = "archived"
                record["archived_at"] = now_iso
            archived += 1

        # Stale transition (inactive 30+ days, currently active)
        elif anchor <= stale_cutoff and state == "active":
            lines.append(
                f"[STALE] {skill_name} "
                f"(inactive {STALE_DAYS}+ days)"
            )
            if not dry_run:
                record["state"] = "stale"
            marked_stale += 1

        # Reactivation (activity within stale window, currently stale)
        elif anchor > stale_cutoff and state == "stale":
            lines.append(f"[REACTIVATE] {skill_name} (active again)")
            if not dry_run:
                record["state"] = "active"
            reactivated += 1

    # Persist changes
    if not dry_run and (marked_stale > 0 or archived > 0 or reactivated > 0):
        save_usage(usage)

    # Build summary
    summary = (
        f"\nLifecycle summary: checked={checked} "
        f"stale={marked_stale} archived={archived} "
        f"reactivated={reactivated}"
    )
    lines.append(summary)

    if dry_run:
        lines.insert(0, "[DRY RUN] No changes applied.\n")

    return "\n".join(lines)


def _log_lock_failure(message: str) -> None:
    """Append to ${SL_LOG_DIR}/persist-failures.log. Never raises -- an
    unwritable log directory must not replace one failure report with a
    different one. Same line shape and same log as persist-proposal.py, so
    doctor.sh needs no new parsing."""
    try:
        log_dir = os.environ.get("SL_LOG_DIR")
        if not log_dir:
            import paths
            log_dir = str(paths.resolve_all()["logs"])
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        from isotime import now_iso
        with open(Path(log_dir) / "persist-failures.log", "a",
                  encoding="utf-8", newline="\n") as handle:
            handle.write(f"{now_iso()} {message}\n")
    except (OSError, ImportError):
        pass


def main() -> int:
    """CLI entry point."""
    dry_run = "--dry-run" in sys.argv

    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__.strip())
        return 0

    try:
        if dry_run:
            # No writes, no directory moves -- nothing to serialise, and
            # taking the lock would make an explicitly no-side-effects mode
            # create a state directory and a lock file. Same rule as
            # persist-proposal.py --dry-run.
            output = run_lifecycle(dry_run=True)
        else:
            # fix-p8. run_lifecycle() is one read-modify-write span over the
            # SAME .usage.json persist-proposal.py writes: load_usage() ->
            # decide transitions -> shutil.move() skill directories ->
            # save_usage(). A review persisting a skill anywhere inside that
            # span was lost exactly as in fix-p7 (measured: 24 of 24 records
            # destroyed), and the directory moves make it worse than a lost
            # update -- a skill directory can be moved out from under a write
            # that is mid-flight. The whole span is held, not just
            # save_usage(): locking only the final write is the half-fix
            # fix-p7's mutation B already proved inadequate for this exact
            # file.
            with StoreLock(default_lock_dir()):
                output = run_lifecycle(dry_run=False)
    except LockTimeout as exc:
        # Loud, never silent: curator-run.sh invokes this from a 7-day cron
        # with nobody watching stderr, so the failure has to reach
        # persist-failures.log, which doctor.sh surfaces. Exit 3, distinct
        # from the corrupt-usage exit 2, so a caller can tell "contended,
        # try again later" from "the store is damaged".
        _log_lock_failure(f"skill-lifecycle: lock timeout: {exc}")
        print(f"skill-lifecycle: refusing to proceed: {exc}", file=sys.stderr)
        return 3
    except LockUnavailable as exc:
        _log_lock_failure(f"skill-lifecycle: lock unavailable: {exc}")
        print(f"skill-lifecycle: refusing to proceed: {exc}", file=sys.stderr)
        return 3
    except UsageCorruptError as exc:
        # Matches persist-proposal.py's policy for the same file: refuse
        # rather than silently treat corrupt-but-present as absent-and-empty.
        print(f"skill-lifecycle: refusing to proceed: {exc}", file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
