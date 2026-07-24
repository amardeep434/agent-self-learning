#!/usr/bin/env python3
# tests/test-coach-rules-eval.py
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "coach-rules-eval.py"

RULE_MEGA = """---
id: mega-sessions
name: Mega Sessions
group: session-hygiene
severity: high
scope: sessions
version: 1
thresholds:
  maxMessages: 50
---

# Description
Detects sessions with an excessive number of messages.

# How to Improve
Start new sessions periodically. Break large tasks into focused conversations.

# Detection Logic
```detect
scan: sessions
match: requestCount >= thresholds.maxMessages
aggregate: count
check: count > 0
```
"""

RULE_UNSUPPORTED = """---
id: exotic-rule
name: Exotic
severity: low
scope: requests
thresholds:
  x: 1
---

# How to Improve
Do the exotic thing.

# Detection Logic
```detect
scan: requests
match: something unsupported
aggregate: sum
check: sum > 3
```
"""


def make_db(path, message_counts):
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, project_path TEXT,"
        " title TEXT, started_at TEXT, last_active TEXT, message_count INTEGER,"
        " source TEXT, parent_id TEXT, indexed_at TEXT)"
    )
    for i, mc in enumerate(message_counts):
        conn.execute(
            "INSERT INTO sessions (session_id, message_count) VALUES (?, ?)",
            ("s{}".format(i), mc),
        )
    conn.commit()
    conn.close()


class CoachRulesEvalTest(unittest.TestCase):
    def run_eval(self, rules, message_counts):
        tmp = tempfile.mkdtemp()
        rules_dir = Path(tmp) / "rules"
        rules_dir.mkdir()
        for name, content in rules.items():
            (rules_dir / name).write_text(content)
        db = Path(tmp) / "search.db"
        make_db(str(db), message_counts)
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(rules_dir), str(db)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout), proc.stderr

    def test_triggers_on_threshold_breach(self):
        signals, _ = self.run_eval({"mega-sessions.md": RULE_MEGA}, [10, 60, 55])
        self.assertEqual(len(signals), 1)
        self.assertEqual(signals[0]["id"], "mega-sessions")
        self.assertEqual(signals[0]["severity"], "high")
        self.assertEqual(signals[0]["count"], 2)
        self.assertEqual(signals[0]["source"], "rules")
        self.assertIn("Start new sessions", signals[0]["suggestion"])

    def test_no_trigger_below_threshold(self):
        signals, _ = self.run_eval({"mega-sessions.md": RULE_MEGA}, [10, 20])
        self.assertEqual(signals, [])

    def test_unsupported_rule_skipped_not_fatal(self):
        signals, stderr = self.run_eval(
            {"mega-sessions.md": RULE_MEGA, "exotic.md": RULE_UNSUPPORTED}, [60]
        )
        self.assertEqual(len(signals), 1)
        self.assertIn("exotic-rule", stderr)

    def test_missing_db_yields_empty(self):
        tmp = tempfile.mkdtemp()
        rules_dir = Path(tmp) / "rules"
        rules_dir.mkdir()
        (rules_dir / "mega-sessions.md").write_text(RULE_MEGA)
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(rules_dir), str(Path(tmp) / "absent.db")],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(json.loads(proc.stdout), [])


if __name__ == "__main__":
    unittest.main()
