#!/usr/bin/env python3
"""Single source of truth for ISO-8601 timestamp parsing/formatting in Python.

Fix round D, blocker (a): scripts/skill-lifecycle.py carried its own copy of
this parser (`iso_to_epoch`), missing both fixes `sl_iso_to_epoch` in
lib/config.sh already had:

  1. No "Z" swap. Python 3.9's `datetime.fromisoformat` REJECTS a trailing
     "Z" (it only accepts "+00:00"-style offsets until 3.11). Every shell
     producer in this project (session-review.sh, curator-run.sh,
     turn-counter.sh, sync-coach-rules.sh) writes `date -u
     +%Y-%m-%dT%H:%M:%SZ`, i.e. always with a "Z". Under 3.9 the unswapped
     parser silently returned None for every one of those timestamps, which
     upstream (skill-lifecycle.py's compute_activity_anchor) is
     indistinguishable from "no activity recorded at all" -- CI run
     30149706340 failed on exactly this, both 3.9 cells.
  2. No naive-datetime guard. A timestamp with no "Z" and no explicit offset
     parses to a tz-naive datetime; `.timestamp()` on a naive datetime is
     interpreted in the INTERPRETER'S LOCAL TIME, silently shifting the
     result by up to +/-14 hours depending on the host's timezone. Live on
     every Python version, not just 3.9.

This is the ONLY place either fix may live. skill-lifecycle.py,
persist-proposal.py, index-session.py, and coach-signals.py all import this
module rather than keeping their own copy -- a second copy is exactly how
this defect (the eighth instance of "a component that exits 0 while doing
nothing, or operating on the wrong location") happened in the first place.
lib/config.sh's bash-side python3 fallback shells out to this file's `parse`
subcommand instead of embedding its own inline `python3 -c '...'` copy, for
the same reason.

Mixed timestamp formats are expected and must both work: shell producers
write `...Z`; Python producers (`now_iso()` below, used by persist-proposal.py,
index-session.py, coach-signals.py) write `.isoformat()`, i.e. `...+00:00`.
Both can land in the same `.usage.json` (or session-search DB), so `parse_iso`
must treat them identically.
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone


def parse_iso(iso_str: str | None) -> int | None:
    """Parse an ISO-8601 timestamp to Unix epoch seconds (int).

    Accepts a trailing "Z" (swapped to "+00:00" first, since Python 3.9's
    fromisoformat rejects "Z" outright), any explicit "+HH:MM"/"-HH:MM"
    offset (sign preserved -- fromisoformat parses it itself, so there is no
    hand-rolled sign-flipping step to get wrong), and optional fractional
    seconds. A timestamp with no offset at all (naive) is treated as UTC,
    never as the interpreter's local time -- silently doing otherwise is
    exactly the kind of directional, hard-to-notice bug this module exists
    to eliminate (see module docstring, defect 2).

    Returns None for an empty, missing, or unparsable input -- callers
    decide what "no timestamp" means for them (skill-lifecycle.py falls back
    to another field or treats it as "now"; this module makes no policy
    choice about that).
    """
    if not iso_str:
        return None
    ts = iso_str
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(ts)
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def now_iso() -> str:
    """Return the current UTC time as an ISO-8601 string (with +00:00 offset).

    Matches every Python producer in this project (persist-proposal.py's
    prior _now_iso, index-session.py, coach-signals.py) so all of them stay
    byte-for-byte identical rather than independently re-deriving the same
    one-liner.
    """
    return datetime.now(timezone.utc).isoformat()


def _main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "parse":
        epoch = parse_iso(argv[1])
        print(epoch if epoch is not None else 0)
        return 0
    if argv and argv[0] == "now":
        print(now_iso())
        return 0
    print("usage: isotime.py parse <iso-timestamp> | isotime.py now", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
