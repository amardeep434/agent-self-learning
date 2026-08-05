#!/usr/bin/env python3
"""List session transcript (*.jsonl) files under a directory, newest mtime
first, optionally floored by a minimum mtime -- the cross-platform
replacement for index-session.sh's previous
`find ... | while read _f; do stat -c/-f ...; done | sort -rn | cut -f2- | head -N`
pipeline.

Why this exists (fix-p6, macOS CI failure on
tests/test-index-session-first-run.sh): that pipeline combined THREE
platform-varying pieces in one shell one-liner -- GNU vs. BSD `stat`'s `-c`
vs. `-f` flag and output text, GNU vs. BSD `find -newer`'s own filesystem
timestamp comparison, and `sort -n`'s numeric-prefix parsing of `stat`'s
text output -- any one of which drifting from its GNU counterpart on a BSD
userland (macOS, real BSD) silently changes which files are selected, with
no error. `os.path.getmtime()` hits the same stat(2)/lstat syscall on every
platform Python supports and returns a float Python compares directly, with
no intermediate CLI text format and no second `find`-builtin comparator to
disagree with it -- collapsing three independently-driftable comparisons
into one syscall plus one Python `>` operator. This does not depend on which
of the three CLI-level differences (if any) was CI's actual macOS cause: it
removes the entire class task.

Deliberately dependency-free (stdlib only, 3.9-compatible) and side-effect
free (pure listing -- makes no directory/database changes), so it is safe to
call from index-session.sh on every invocation, including a fresh empty
SESSIONS_DIR (prints nothing, exit 0) and a missing one (same).
"""
from __future__ import annotations

import argparse
import os
import sys


def iter_jsonl_paths(root: str):
    """Yield every '*.jsonl' file path under root, recursively.

    os.walk (not glob/Path.rglob) to sidestep any platform difference in
    how those handle the case-insensitive-filesystem probe already
    documented elsewhere on this branch (APFS default) -- os.walk simply
    lists directory entries and does a plain Python string suffix check.
    """
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".jsonl"):
                yield os.path.join(dirpath, name)


def list_transcripts(root: str, since_mtime: float | None, limit: int) -> list[str]:
    """Return up to `limit` transcript paths under root, newest mtime first.

    since_mtime=None: no filtering (the first-run case -- there is no
    meaningful "newer than" comparison when the index DB was just created,
    so every pre-existing transcript is a candidate, capped only by limit).

    since_mtime=<float>: only paths with mtime STRICTLY greater than this
    value are included (mirrors `find -newer`'s strict-greater-than
    semantics, not >=, so a transcript with exactly the DB's own mtime --
    a real possibility at whole-second filesystem timestamp resolution --
    is intentionally excluded on a re-run once it has already been
    indexed once, matching find -newer's existing behaviour rather than
    silently re-indexing every unchanged session every run).

    A path whose mtime cannot be read (e.g. removed between listing and
    stat, a real TOCTOU window) is skipped rather than raising -- matches
    the previous shell pipeline's `2>/dev/null` treatment of the same race
    silently dropping that one entry, not aborting the whole listing.
    """
    if not os.path.isdir(root):
        return []

    entries: list[tuple[float, str]] = []
    for path in iter_jsonl_paths(root):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if since_mtime is not None and not (mtime > since_mtime):
            continue
        entries.append((mtime, path))

    entries.sort(key=lambda t: t[0], reverse=True)
    return [path for _mtime, path in entries[:limit]]


def _main(argv: list[str]) -> int:
    # LF-only stdout (fix round E, see lib/paths.py's _main for the full
    # rationale). Native Windows Python emits "\r\n" for every print, bash
    # strips only the record-terminating "\n" from `$(...)`, and this module's
    # output IS read into bash variables -- index-session.sh uses each line as
    # a file path. A trailing "\r" there is
    # invisible and corrupts every downstream use of the value.
    try:
        sys.stdout.reconfigure(newline="\n")
    except (AttributeError, ValueError):
        pass

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", help="directory to search recursively for *.jsonl files")
    parser.add_argument(
        "--since-mtime", type=float, default=None,
        help="only list files with mtime strictly greater than this Unix epoch value",
    )
    parser.add_argument(
        "--limit", type=int, default=20,
        help="maximum number of paths to print (default: 20)",
    )
    args = parser.parse_args(argv)

    for path in list_transcripts(args.root, args.since_mtime, args.limit):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
