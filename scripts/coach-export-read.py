#!/usr/bin/env python3
"""coach-export-read.py — Route B: read a Coach SummaryExportReport JSON and
emit normalized signals.

Usage: python3 coach-export-read.py <export_json_path>
Output: JSON array [{"id", "severity", "suggestion", "count", "source": "export"}]
Missing or unparseable file -> [] on stdout (note on stderr), exit 0.
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
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        print("coach-export-read: unparseable export ({})".format(exc), file=sys.stderr)
        print("[]")
        return 0

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
