#!/usr/bin/env python3
"""Single source of truth for the on-disk learned-skill layout.

    <skills_dir>/<name>/SKILL.md   -- one directory per skill, containing its
                                       content (never a flat "<name>.md")
    <skills_dir>/.usage.json       -- one shared usage/lifecycle metadata file
                                       for every skill in the store
    <skills_dir>/.archive/         -- archived skill directories are moved
                                       here by lifecycle transitions

This structure used to be re-stated independently in persist-proposal.py,
skill-lifecycle.py, inject-agents-md.py, curator-run.sh, and
self-learning-health.sh -- a five-way liability. It already cost this branch
a Critical once: the writer produced a flat `<name>.md` while every reader
required `<name>/SKILL.md`, so the pipeline burned a paid model call, wrote a
file, and nothing downstream could ever see it (fix round B). A later round
aligned the *values* across those five sites but left the *structure*
independently re-typed in each one, so a sixth divergence was one edit away.

This module is now the one place the layout is defined. Python consumers
import it directly. Bash consumers (curator-run.sh, self-learning-health.sh)
shell out to its CLI exactly once per script invocation -- the same pattern
`lib/paths.py` already established for filesystem locations, and `lib/config.sh`
for sourcing it. Neither bash consumer is on the per-tool-call hot path
(that's turn-counter.sh alone, which never touches the skill layout), so
adding one more subprocess spawn to either of them does not touch the <100ms
hook budget documented in CLAUDE.md.

tests/test-skill-layout-pinning.sh is the mutation-tested guard: it asserts
every consumer's literal for these three values traces back to this module
(or its CLI output), not a locally re-typed string.
"""
from __future__ import annotations

import sys
from pathlib import Path

SKILL_MD_FILENAME = "SKILL.md"
USAGE_FILENAME = ".usage.json"
ARCHIVE_DIRNAME = ".archive"

# Order matters only for `all` output readability; `get` looks up by key.
_VALUES = {
    "skill_md_filename": SKILL_MD_FILENAME,
    "usage_filename": USAGE_FILENAME,
    "archive_dirname": ARCHIVE_DIRNAME,
}


def skill_dir(skills_dir: Path, name: str) -> Path:
    """Path to one skill's directory: <skills_dir>/<name>/."""
    return Path(skills_dir) / name


def skill_md_path(skills_dir: Path, name: str) -> Path:
    """Path to one skill's content file: <skills_dir>/<name>/SKILL.md."""
    return skill_dir(skills_dir, name) / SKILL_MD_FILENAME


def usage_file_path(skills_dir: Path) -> Path:
    """Path to the shared usage/lifecycle metadata file."""
    return Path(skills_dir) / USAGE_FILENAME


def archive_dir_path(skills_dir: Path) -> Path:
    """Path to the directory archived skills are moved into."""
    return Path(skills_dir) / ARCHIVE_DIRNAME


def _main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "get":
        key = argv[1]
        if key not in _VALUES:
            print(f"unknown skill-layout key: {key}", file=sys.stderr)
            return 2
        print(_VALUES[key])
        return 0
    if argv and argv[0] == "all":
        for key, value in _VALUES.items():
            print(f"{key}={value}")
        return 0
    print("usage: skill_layout.py get <key> | skill_layout.py all", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
