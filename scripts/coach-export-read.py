#!/usr/bin/env python3
"""coach-export-read.py — Route B: read a Coach SummaryExportReport JSON and
emit normalized signals.

Usage: python3 coach-export-read.py <export_json_path>
Output: JSON array
        [{"id", "severity", "suggestion", "count", "denominator", "source": "export"}]

`count` alone is not interpretable. Every `topPatterns` row in a real export
counts REQUESTS ("N requests took over 30 seconds", "83% of requests have no
file references"), and the export states its own request total in
`totals.requests` -- so that total is the denominator that turns a count into
a prevalence. Without it a reader cannot tell 507 occurrences over 507
requests (a standing configuration gap, true of every request) from 507 over
50000 (a habit worth changing). It is emitted per signal rather than once,
because coach-signals.py merges the two routes into a flat id-keyed map and a
top-level field would not survive that -- the same reason `source` is
per-signal.

Two absences that look identical on stdout are deliberately NOT identical on
the exit code:

  no file at all      -> [] on stdout, note on stderr, exit 0. Coach is simply
                         not installed, or has never been asked to export.
                         Route B has nothing to say and that is normal.
  file present, but
  not a readable
  SummaryExportReport -> [] on stdout, diagnostic on stderr, exit 1. Something
                         DID write an export and we cannot read it -- truncated
                         write, or upstream renamed/moved `antiPatterns`. Both
                         are defects, and reporting them as "no signals today"
                         is precisely the silent-success failure this project
                         exists to eliminate.

The caller (coach-signals.py) treats a non-zero route as contributing no
signals, so this stays non-fatal to a review; it just stops being invisible.
"""

import json
import sys
from pathlib import Path

# The one export schema version this reader's `count`/`denominator` semantics
# are known to match. Upstream declares it at src/core/summary-export.ts:39
# (`schemaVersion: 1;`) as an exported contract. Bump ONLY after re-reading
# upstream's topPatterns and totals fields -- a version bump is upstream
# telling us the meaning may have moved.
#
# Related, and worth stating because our own docs invited the wrong reading:
# upstream caps topPatterns at TOP_ANTI_PATTERN_LIMIT = 10
# (summary-export.ts:82, applied :146). The "10 signals" figure in
# docs/coach-integration.md is therefore UPSTREAM'S CAP, not a reduction this
# reader performs -- and Route B can never surface an 11th anti-pattern
# however prevalent it is.
SUPPORTED_SCHEMA_VERSION = 1


def main():
    if len(sys.argv) != 2:
        print("Usage: coach-export-read.py <export_json_path>", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    if not path.is_file():
        print("coach-export-read: no export at {}".format(path), file=sys.stderr)
        print("[]")
        return 0

    try:
        report = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        # Upstream stamps `schemaVersion: 1` (src/core/summary-export.ts:39) as
        # an explicitly exported contract, distinct from the internal analyzer
        # types it is built from, precisely so a consumer can refuse a payload
        # it does not understand. Reaching straight for antiPatterns.topPatterns
        # ignored that: a v2 that re-semanticised `occurrences` from requests to
        # sessions would be consumed happily against the v1 denominator and
        # produce a plausible wrong prevalence -- the silent-wrong-value class
        # this project exists to eliminate. A KeyError here is deliberate: an
        # export with no schemaVersion at all is not a v1 export.
        version = report["schemaVersion"]
        if version != SUPPORTED_SCHEMA_VERSION:
            raise ValueError(
                "export schemaVersion is {!r}, but this reader understands only "
                "{}. `occurrences` and `totals.requests` semantics are not "
                "guaranteed across versions, so the denominator cannot be "
                "trusted -- refusing rather than reporting a wrong prevalence."
                .format(version, SUPPORTED_SCHEMA_VERSION))
        patterns = report["antiPatterns"]["topPatterns"]
        # A non-list here would iterate as something else entirely (a dict
        # yields its keys, a string its characters), every element would fail
        # the isinstance filter below, and the run would look like a clean
        # "no anti-patterns found". Same silent-zero as a missing key, so it
        # takes the same loud path.
        if not isinstance(patterns, list):
            raise TypeError("antiPatterns.topPatterns is {}, not a list".format(
                type(patterns).__name__))
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print("coach-export-read: unreadable export at {} ({}: {})".format(
            path, type(exc).__name__, exc), file=sys.stderr)
        print("[]")
        return 1

    # A missing, zero, negative or non-numeric total is NOT an error -- older
    # or filtered exports may omit `totals` -- but it must degrade to 0, never
    # to a guess. The renderer shows no prevalence at all for a 0 denominator,
    # which is honest; a fabricated denominator would not be. `report` is
    # already known to be subscriptable here (a non-dict would have raised
    # TypeError on the `antiPatterns` lookup above).
    totals = report.get("totals")
    try:
        denominator = int(totals["requests"]) if isinstance(totals, dict) else 0
    except (KeyError, TypeError, ValueError):
        denominator = 0
    if denominator < 0:
        denominator = 0

    signals = []
    for p in patterns:
        if not isinstance(p, dict) or "id" not in p:
            continue
        signals.append({
            "id": str(p["id"]),
            "severity": str(p.get("severity", "unknown")),
            "suggestion": str(p.get("suggestion", "")),
            "count": int(p.get("occurrences", 0) or 0),
            "denominator": denominator,
            "source": "export",
        })

    print(json.dumps(signals, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
