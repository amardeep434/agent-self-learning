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
USAGE_FILE = SKILLS_DIR / ".usage.json"
ARCHIVE_DIR = SKILLS_DIR / ".archive"
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


def main() -> int:
    """CLI entry point."""
    dry_run = "--dry-run" in sys.argv

    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__.strip())
        return 0

    try:
        output = run_lifecycle(dry_run=dry_run)
    except UsageCorruptError as exc:
        # Matches persist-proposal.py's policy for the same file: refuse
        # rather than silently treat corrupt-but-present as absent-and-empty.
        print(f"skill-lifecycle: refusing to proceed: {exc}", file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
