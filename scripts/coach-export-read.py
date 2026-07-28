#!/usr/bin/env python3
"""coach-export-read.py — Route B: read a Coach SummaryExportReport JSON and
emit normalized signals.

Usage: python3 coach-export-read.py <export_json_path>
Output: JSON array [{"id", "severity", "suggestion", "count", "source": "export"}]

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
        patterns = report["antiPatterns"]["topPatterns"]
        # A non-list here would iterate as something else entirely (a dict
        # yields its keys, a string its characters), every element would fail
        # the isinstance filter below, and the run would look like a clean
        # "no anti-patterns found". Same silent-zero as a missing key, so it
        # takes the same loud path.
        if not isinstance(patterns, list):
            raise TypeError("antiPatterns.topPatterns is {}, not a list".format(
                type(patterns).__name__))
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        print("coach-export-read: unreadable export at {} ({}: {})".format(
            path, type(exc).__name__, exc), file=sys.stderr)
        print("[]")
        return 1

    signals = []
    for p in patterns:
        if not isinstance(p, dict) or "id" not in p:
            continue
        signals.append({
            "id": str(p["id"]),
            "severity": str(p.get("severity", "unknown")),
            "suggestion": str(p.get("suggestion", "")),
            "count": int(p.get("occurrences", 0) or 0),
            "source": "export",
        })

    print(json.dumps(signals, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
