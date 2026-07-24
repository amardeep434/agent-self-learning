#!/usr/bin/env python3
"""coach-rules-eval.py — Route A: evaluate vendored AI Engineering Coach
anti-pattern rules against our session index.

Usage: python3 coach-rules-eval.py <rules_dir> <db_path>

Output (stdout): JSON array of triggered signals:
    [{"id", "severity", "suggestion", "count", "source": "rules"}]

Supported `detect` DSL subset (anything else -> rule skipped with stderr note):
    scan: sessions
    match: requestCount <op> thresholds.<key>   (op: >= > <= < ==)
    aggregate: count
    check: count > 0
`requestCount` maps to the sessions.message_count column.
"""

import json
import re
import sqlite3
import sys
from pathlib import Path

OPS = {
    ">=": lambda a, b: a >= b,
    "<=": lambda a, b: a <= b,
    "==": lambda a, b: a == b,
    ">": lambda a, b: a > b,
    "<": lambda a, b: a < b,
}

MATCH_RE = re.compile(
    r"^requestCount\s*(>=|<=|==|>|<)\s*thresholds\.([A-Za-z_][A-Za-z0-9_]*)$"
)


def parse_rule(path):
    """Parse frontmatter (flat keys + one-level `thresholds:` map), the
    `# How to Improve` section, and the ```detect block. Returns dict or None."""
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None

    meta = {}
    thresholds = {}
    in_thresholds = False
    end_idx = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end_idx = i
            break
        if line.startswith("thresholds:"):
            in_thresholds = True
            continue
        if in_thresholds and re.match(r"^\s+[A-Za-z_]", line):
            key, _, val = line.strip().partition(":")
            val = val.strip()
            try:
                thresholds[key] = float(val) if "." in val else int(val)
            except ValueError:
                thresholds[key] = val
            continue
        in_thresholds = False
        key, sep, val = line.partition(":")
        if sep:
            meta[key.strip()] = val.strip()
    if end_idx is None:
        return None

    body = "\n".join(lines[end_idx + 1:])

    improve = ""
    m = re.search(r"^# How to Improve\s*\n(.*?)(?=^# |\Z)", body, re.M | re.S)
    if m:
        improve = " ".join(m.group(1).split())

    detect = {}
    m = re.search(r"```detect\s*\n(.*?)```", body, re.S)
    if m:
        for dline in m.group(1).splitlines():
            key, sep, val = dline.partition(":")
            if sep:
                detect[key.strip()] = val.strip()

    return {
        "id": meta.get("id", path.stem),
        "severity": meta.get("severity", "unknown"),
        "thresholds": thresholds,
        "suggestion": improve,
        "detect": detect,
    }


def load_message_counts(db_path):
    if not Path(db_path).is_file():
        return None
    conn = sqlite3.connect(str(db_path))
    try:
        rows = conn.execute("SELECT message_count FROM sessions").fetchall()
    except sqlite3.Error:
        return None
    finally:
        conn.close()
    return [r[0] for r in rows if r[0] is not None]


def evaluate(rule, message_counts):
    """Return triggered-count for a supported rule, or raise ValueError."""
    d = rule["detect"]
    if d.get("scan") != "sessions":
        raise ValueError("unsupported scan: {}".format(d.get("scan")))
    if d.get("aggregate") != "count":
        raise ValueError("unsupported aggregate: {}".format(d.get("aggregate")))
    if d.get("check") != "count > 0":
        raise ValueError("unsupported check: {}".format(d.get("check")))
    m = MATCH_RE.match(d.get("match", ""))
    if not m:
        raise ValueError("unsupported match: {}".format(d.get("match")))
    op, key = m.group(1), m.group(2)
    if key not in rule["thresholds"]:
        raise ValueError("threshold {} not defined".format(key))
    threshold = rule["thresholds"][key]
    if not isinstance(threshold, (int, float)):
        raise ValueError("threshold {} is not numeric".format(key))
    return sum(1 for mc in message_counts if OPS[op](mc, threshold))


def main():
    if len(sys.argv) != 3:
        print("Usage: coach-rules-eval.py <rules_dir> <db_path>", file=sys.stderr)
        return 1

    rules_dir, db_path = Path(sys.argv[1]), sys.argv[2]
    message_counts = load_message_counts(db_path)
    if message_counts is None:
        print("[]")
        return 0

    signals = []
    for rule_file in sorted(rules_dir.glob("*.md")):
        if rule_file.name == "UPSTREAM.md":
            continue
        rule = parse_rule(rule_file)
        if rule is None:
            print("coach-rules-eval: skipping {} (no frontmatter)".format(rule_file.name),
                  file=sys.stderr)
            continue
        try:
            count = evaluate(rule, message_counts)
        except ValueError as exc:
            print("coach-rules-eval: skipping {} ({})".format(rule["id"], exc),
                  file=sys.stderr)
            continue
        if count > 0:
            signals.append({
                "id": rule["id"],
                "severity": rule["severity"],
                "suggestion": rule["suggestion"],
                "count": count,
                "source": "rules",
            })

    print(json.dumps(signals, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
