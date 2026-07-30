#!/usr/bin/env python3
"""mirror-skills.py — publish learned skills where each harness already looks.

Route A of the delivery plan. The store keeps learned skills at
`<store>/learned-skills/<name>/SKILL.md`, which no harness discovers, so 46
well-formed skills were invisible to every agent. Every upstream this project
cites solves delivery the same way -- by writing into the directory the harness
already scans, needing no hook at all:

    SkillOpt-Sleep   ~/.claude/skills/skillopt-sleep-learned/SKILL.md
                     (skillopt_sleep/config.py:139-149)
    GEPA / gskill    .claude/skills/<repo>/SKILL.md
                     ("with YAML frontmatter so Claude Code discovers and loads
                      it automatically" -- claude_code_skills.py:95-97)
    Coach            ~/.agents/skills/<slug>/SKILL.md
                     (panel-request-service.ts:626-643)

TARGETS are probed, never assumed from a platform name: a directory is written
only if its PARENT already exists, i.e. only if that harness is actually
installed. Mirroring into ~/.copilot on a machine with no Copilot would create
the very wrong-location state paths.py exists to prevent.

SAFETY -- the whole reason this is not a `cp -r`. A mirrored skill directory
carries a marker file, and this script will NEVER write into or delete a
directory that lacks one. `~/.claude/skills/` is the user's own namespace and
already held 21 hand-written skills when this was built; a name collision must
cost us the mirror, never the user's work. The marker is also what makes
uninstall removable-by-construction: it deletes exactly the directories it can
prove it created.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import paths  # noqa: E402
import skill_layout  # noqa: E402

# Presence of this file marks a skill directory as ours. Content is a warning
# plus the source path, so a user who finds it knows what wrote it and where the
# real copy lives.
MARKER_NAME = ".self-learning-managed"

def resolve_home() -> Path | None:
    """The user's home directory, or None if it cannot be determined.

    `Path.home()` RAISES rather than returning None when it cannot resolve, and
    on Windows it consults USERPROFILE before HOME. Both facts bit this file:
    the roots below were once module-level constants built from `Path.home()`,
    so importing the module under `env -i HOME=<tmp>` -- which every test here
    uses, and which sets no USERPROFILE -- died at import time on both
    windows-latest CI cells:

        File "scripts/mirror-skills.py", line 56, in <module>
        File ".../pathlib/_local.py", line 808, in expanduser
        RuntimeError: Could not determine home directory.

    HOME is checked FIRST and explicitly, because it is what the sandboxing in
    tests/ and in CLAUDE.md's hard rule 1 actually sets; falling through to
    USERPROFILE would have a sandboxed run mirror into the developer's REAL
    profile on Windows.
    """
    for var in ("HOME", "USERPROFILE"):
        value = os.environ.get(var)
        if value:
            return Path(value)
    try:
        return Path.home()
    except RuntimeError:
        return None


# Candidate mirror roots. The PARENT of each must already exist for that root to
# be used -- see the module docstring. VS Code Copilot Chat is deliberately not
# a separate entry: it reads ~/.claude (its shipped default hook locations
# include ~/.claude/settings.json), so the Claude Code target covers it. That
# is an inference from the hook-location default, NOT a measured fact about
# skill discovery -- no real VS Code session has ever been observed loading a
# skill from here.
def mirror_roots() -> tuple[tuple[str, Path], ...]:
    """Candidate roots, resolved lazily.

    A function, not a constant: computing these at import time cannot see a HOME
    set after import, and it makes an unresolvable home a crash instead of a
    reportable condition.
    """
    home = resolve_home()
    if home is None:
        return ()
    return (
        ("claude", home / ".claude" / "skills"),
        ("copilot", home / ".copilot" / "skills"),
    )


def marker_text(source: Path) -> str:
    return (
        "Managed by agent-self-learning (scripts/mirror-skills.py).\n"
        "Do NOT edit this directory: it is overwritten from the store copy at\n"
        f"{source}\n"
        "Edit the store copy instead, or delete this whole directory to drop the\n"
        "mirror. `uninstall.sh` removes exactly the directories carrying this file.\n"
    )


def is_ours(directory: Path) -> bool:
    """True only for a directory we created. The gate on every write and delete."""
    return (directory / MARKER_NAME).is_file()


def active_roots(roots: "tuple[tuple[str, Path], ...] | None" = None) -> list[tuple[str, Path]]:
    """Roots whose parent exists -- i.e. harnesses actually installed here."""
    if roots is None:
        roots = mirror_roots()
    return [(name, root) for name, root in roots if root.parent.is_dir()]


def _write_exact(path: Path, text: str) -> None:
    """Write text with NO newline translation.

    `Path.write_text()` / `open(..., "w")` translate "\n" to os.linesep on
    Windows, so a store file with LF endings was mirrored with CRLF and the copy
    was NOT byte-identical to its source. Caught by CI on both windows-latest
    cells 2026-07-30 (`cmp` failed in tests/test-mirror-skills.sh case A).

    That matters beyond tidiness: mirror_one() decides whether to rewrite by
    comparing the target's text to the source's, so a translated copy differs on
    every run -- the mirror would never report "unchanged", would rewrite all 46
    files at every session start, and the idempotence this relies on would be
    silently false. `newline=""` is the same fix paths.py already applies to its
    stdout for the same reason.
    """
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def _read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def mirror_one(source_md: Path, target_dir: Path) -> str:
    """Mirror one skill. Returns the action taken, for the caller to report.

    "skipped-not-ours" is the important one: it means a directory of that name
    exists and we did not create it, so it is the user's.
    """
    if target_dir.exists() and not is_ours(target_dir):
        return "skipped-not-ours"

    desired = _read(source_md)
    if desired is None:
        return "skipped-unreadable-source"

    target_md = target_dir / skill_layout.SKILL_MD_FILENAME
    if target_dir.is_dir() and _read(target_md) == desired:
        # Idempotent: touching nothing keeps mtimes stable, which matters
        # because this runs on every session start.
        return "unchanged"

    try:
        target_dir.mkdir(parents=True, exist_ok=True)
        # Marker first. If writing SKILL.md fails afterwards, the directory is
        # still identifiably ours and so still cleanable -- the reverse order
        # could strand an unmarked directory we would then refuse to touch.
        _write_exact(target_dir / MARKER_NAME, marker_text(source_md))
        _write_exact(target_md, desired)
    except OSError:
        return "failed"
    return "written"


def prune(skills_dir: Path, target_root: Path) -> list[str]:
    """Delete mirrored skills that no longer exist in the store.

    Needed because curator-run.sh archives and deletes skills. Without this the
    mirror would keep advertising an archived skill forever -- the stale-index
    failure Hermes invalidates its snapshot from six separate call sites to
    avoid. Only marked directories are ever removed.
    """
    removed = []
    if not target_root.is_dir():
        return removed
    for child in sorted(target_root.iterdir()):
        if not child.is_dir() or not is_ours(child):
            continue
        if not skill_layout.skill_md_path(skills_dir, child.name).is_file():
            try:
                shutil.rmtree(child)
                removed.append(child.name)
            except OSError:
                continue
    return removed


def main() -> int:
    quiet = "--quiet" in sys.argv
    try:
        skills_dir = Path(os.environ.get("SL_SKILLS_DIR") or paths.resolve_all()["skills"])
    except (KeyError, OSError, RuntimeError) as exc:
        # RuntimeError is paths.py's own: "cannot resolve a home directory ...
        # Refusing to fall back to a path relative to the current working
        # directory." That must be a reported failure, not an uncaught traceback
        # -- this runs detached from a session-start hook where a traceback goes
        # nowhere a human will read it.
        print(f"mirror-skills: cannot resolve the skills directory: {exc}", file=sys.stderr)
        return 1

    roots = active_roots()
    if not roots:
        if not quiet:
            print("mirror-skills: no harness skill directory present, nothing to mirror")
        return 0

    if not skills_dir.is_dir():
        if not quiet:
            print(f"mirror-skills: no learned skills at {skills_dir}")
        return 0

    names = [
        child.name
        for child in sorted(skills_dir.iterdir())
        if child.is_dir()
        and not child.name.startswith(".")
        and skill_layout.skill_md_path(skills_dir, child.name).is_file()
    ]

    exit_code = 0
    for label, root in roots:
        tally: dict[str, int] = {}
        for name in names:
            action = mirror_one(skill_layout.skill_md_path(skills_dir, name), root / name)
            tally[action] = tally.get(action, 0) + 1
            if action == "failed":
                exit_code = 1
        removed = prune(skills_dir, root)
        if not quiet:
            summary = ", ".join(f"{k}={v}" for k, v in sorted(tally.items())) or "nothing"
            print(f"mirror-skills[{label}] {root}: {summary}, pruned={len(removed)}")
            # Named individually: a collision means the user has a skill of that
            # name, and "skipped=3" alone would not tell them which.
            if tally.get("skipped-not-ours"):
                print(
                    f"  NOTE: {tally['skipped-not-ours']} name(s) already exist in "
                    f"{root} and were not created by us -- left untouched."
                )
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
