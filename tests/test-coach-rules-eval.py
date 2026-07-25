#!/usr/bin/env python3
# tests/test-coach-rules-eval.py
"""Tests for scripts/coach-rules-eval.py.

Covers:
  - the generic scan:sessions requestCount engine (mega-sessions,
    abandon-sessions)
  - the bespoke adapters (tunnel-vision, mcp-tool-bloat, and the 7
    text/timestamp-only "requests" adapters)
  - the skip path: unsupported rules must skip loudly with a specific,
    non-generic reason, never silently evaluate to zero
  - a coverage-assertion test pinned against the REAL vendor/coach-rules
    directory, so a future change that silently drops evaluable rules (or
    silently adds a fake-evaluating one) fails the suite
"""
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "coach-rules-eval.py"
SCHEMA = REPO / "schema" / "session-search-schema.sql"
VENDOR_RULES = REPO / "vendor" / "coach-rules"

NOW = "2026-07-01T12:00:00+00:00"

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

RULE_ABANDON = """---
id: abandon-sessions
name: Abandoned Sessions
group: session-hygiene
severity: low
scope: sessions
version: 1
thresholds:
  maxAbandonRate: 0.4
  minSample: 10
---

# How to Improve
Use follow-up messages to refine responses.

# Detection Logic
```detect
scan: sessions
match: requestCount == 1
aggregate: ratio
check: ratio > thresholds.maxAbandonRate AND count > thresholds.minSample
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


def make_db(path):
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA.read_text())
    return conn


def insert_session(conn, session_id, message_count, project_path="p"):
    conn.execute(
        "INSERT INTO sessions (session_id, project_path, title, started_at,"
        " last_active, message_count, source, indexed_at) VALUES (?,?,?,?,?,?,?,?)",
        (session_id, project_path, "t", NOW, NOW, message_count, "interactive", NOW),
    )


def insert_message(conn, session_id, idx, content, role="user", timestamp=NOW):
    conn.execute(
        "INSERT INTO messages (session_id, msg_index, role, content, timestamp)"
        " VALUES (?,?,?,?,?)",
        (session_id, idx, role, content, timestamp),
    )


class CoachRulesEvalBase(unittest.TestCase):
    def run_eval(self, rules_dir, db_path):
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(rules_dir), str(db_path)],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout), proc.stderr

    def write_rules(self, tmp, rules):
        rules_dir = Path(tmp) / "rules"
        rules_dir.mkdir()
        for name, content in rules.items():
            (rules_dir / name).write_text(content)
        return rules_dir


class GenericSessionEngineTest(CoachRulesEvalBase):
    def test_mega_sessions_triggers_on_threshold_breach(self):
        tmp = tempfile.mkdtemp()
        rules_dir = self.write_rules(tmp, {"mega-sessions.md": RULE_MEGA})
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 10)
        insert_session(conn, "s1", 60)
        insert_session(conn, "s2", 55)
        conn.commit()
        conn.close()

        signals, _ = self.run_eval(rules_dir, db)
        self.assertEqual(len(signals), 1)
        self.assertEqual(signals[0]["id"], "mega-sessions")
        self.assertEqual(signals[0]["count"], 2)
        self.assertEqual(signals[0]["source"], "rules")

    def test_mega_sessions_no_trigger_below_threshold(self):
        tmp = tempfile.mkdtemp()
        rules_dir = self.write_rules(tmp, {"mega-sessions.md": RULE_MEGA})
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 10)
        insert_session(conn, "s1", 20)
        conn.commit()
        conn.close()

        signals, _ = self.run_eval(rules_dir, db)
        self.assertEqual(signals, [])

    def test_abandon_sessions_ratio_and_count_and_check(self):
        tmp = tempfile.mkdtemp()
        rules_dir = self.write_rules(tmp, {"abandon-sessions.md": RULE_ABANDON})
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        for i in range(15):  # 1-message sessions
            insert_session(conn, "ab{}".format(i), 1)
        for i in range(5):  # multi-message sessions
            insert_session(conn, "ok{}".format(i), 4)
        conn.commit()
        conn.close()

        # ratio = 15/20 = 0.75 > 0.4, count = 15 > 10 -> triggers
        signals, _ = self.run_eval(rules_dir, db)
        self.assertEqual(len(signals), 1)
        self.assertEqual(signals[0]["id"], "abandon-sessions")
        self.assertEqual(signals[0]["count"], 15)

    def test_abandon_sessions_below_min_sample_does_not_trigger(self):
        tmp = tempfile.mkdtemp()
        rules_dir = self.write_rules(tmp, {"abandon-sessions.md": RULE_ABANDON})
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        for i in range(3):  # ratio 1.0 but count(3) <= minSample(10)
            insert_session(conn, "ab{}".format(i), 1)
        conn.commit()
        conn.close()

        signals, _ = self.run_eval(rules_dir, db)
        self.assertEqual(signals, [])

    def test_unsupported_rule_skipped_not_fatal(self):
        tmp = tempfile.mkdtemp()
        rules_dir = self.write_rules(
            tmp, {"mega-sessions.md": RULE_MEGA, "exotic.md": RULE_UNSUPPORTED}
        )
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 60)
        conn.commit()
        conn.close()

        signals, stderr = self.run_eval(rules_dir, db)
        self.assertEqual(len(signals), 1)
        self.assertIn("exotic-rule", stderr)

    def test_missing_db_yields_empty(self):
        tmp = tempfile.mkdtemp()
        rules_dir = self.write_rules(tmp, {"mega-sessions.md": RULE_MEGA})
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(rules_dir), str(Path(tmp) / "absent.db")],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(json.loads(proc.stdout), [])


class BespokeAdapterTest(CoachRulesEvalBase):
    """Each test proves the adapter can genuinely FIRE on plausible data,
    not just parse without error."""

    def eval_real_rule(self, rule_id, db):
        # Evaluate against the single real vendored rule file so the test
        # tracks the actual shipped detect block, not a hand-copied one.
        rules_dir = Path(tempfile.mkdtemp())
        (rules_dir / (rule_id + ".md")).write_text(
            (VENDOR_RULES / (rule_id + ".md")).read_text()
        )
        return self.run_eval(rules_dir, db)

    def test_tunnel_vision_fires_on_concentrated_workspace(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "big", 200, project_path="proj-x")
        insert_session(conn, "y", 2, project_path="proj-y")
        insert_session(conn, "z", 2, project_path="proj-z")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("tunnel-vision", db)
        ids = [s["id"] for s in signals]
        self.assertIn("tunnel-vision", ids)

    def test_tunnel_vision_no_fire_when_spread_evenly(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        for p in ["proj-x", "proj-y", "proj-z"]:
            insert_session(conn, "s-" + p, 50, project_path=p)
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("tunnel-vision", db)
        self.assertNotIn("tunnel-vision", [s["id"] for s in signals])

    def test_mcp_tool_bloat_fires_on_many_distinct_tools(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        for i in range(3):
            sid = "bloat{}".format(i)
            insert_session(conn, sid, 45)
            for t in range(45):
                insert_message(conn, sid, t, "[tool: T{}]".format(t), role="assistant")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("mcp-tool-bloat", db)
        self.assertIn("mcp-tool-bloat", [s["id"] for s in signals])

    def test_mcp_tool_bloat_no_fire_under_threshold(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        sid = "small"
        insert_session(conn, sid, 3)
        for t in range(3):
            insert_message(conn, sid, t, "[tool: T{}]".format(t), role="assistant")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("mcp-tool-bloat", db)
        self.assertNotIn("mcp-tool-bloat", [s["id"] for s in signals])

    def test_caps_lock_fires_on_shouted_messages(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        sid = "s0"
        insert_session(conn, sid, 1)
        insert_message(conn, sid, 0, "WHY IS THIS STILL BROKEN AFTER ALL THIS TIME")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("caps-lock", db)
        self.assertIn("caps-lock", [s["id"] for s in signals])

    def test_caps_lock_no_fire_on_normal_message(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        sid = "s0"
        insert_session(conn, sid, 1)
        insert_message(conn, sid, 0, "please refactor the auth module carefully")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("caps-lock", db)
        self.assertNotIn("caps-lock", [s["id"] for s in signals])

    def test_late_night_coding_fires_on_early_hours(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 15)
        for i in range(15):
            insert_message(conn, "s0", i, "fix thing {}".format(i),
                            timestamp="2026-07-0{}T02:00:00+00:00".format((i % 9) + 1))
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("late-night-coding", db)
        self.assertIn("late-night-coding", [s["id"] for s in signals])

    def test_late_night_coding_no_fire_on_daytime_messages(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 15)
        for i in range(15):
            insert_message(conn, "s0", i, "fix thing {}".format(i), timestamp=NOW)
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("late-night-coding", db)
        self.assertNotIn("late-night-coding", [s["id"] for s in signals])

    def test_lazy_prompting_fires_on_many_short_messages(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 20)
        for i in range(15):
            insert_message(conn, "s0", i, "fix bug")  # 7 chars, short
        for i in range(15, 20):
            insert_message(conn, "s0", i,
                            "Refactor the authentication middleware to use JWT "
                            "tokens and add refresh token rotation")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("lazy-prompting", db)
        self.assertIn("lazy-prompting", [s["id"] for s in signals])

    def test_low_constraint_usage_fires_when_no_constraints_used(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        for i in range(35):
            sid = "s{}".format(i)
            insert_session(conn, sid, 1)
            insert_message(conn, sid, 0,
                            "please build a REST endpoint that returns the "
                            "current weather forecast for a given city")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("low-constraint-usage", db)
        self.assertIn("low-constraint-usage", [s["id"] for s in signals])

    def test_low_constraint_usage_no_fire_when_constraints_present(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        for i in range(35):
            sid = "s{}".format(i)
            insert_session(conn, sid, 1)
            insert_message(conn, sid, 0,
                            "please build a REST endpoint but do not use any "
                            "third-party dependencies and only return JSON")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("low-constraint-usage", db)
        self.assertNotIn("low-constraint-usage", [s["id"] for s in signals])

    def test_weekend_overwork_fires_on_weekend_heavy_traffic(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 30)
        # 2026-07-04 and 2026-07-05 are Saturday/Sunday
        for i in range(25):
            insert_message(conn, "s0", i, "weekend work {}".format(i),
                            timestamp="2026-07-04T10:00:00+00:00")
        for i in range(25, 30):
            insert_message(conn, "s0", i, "weekday work {}".format(i),
                            timestamp="2026-07-01T10:00:00+00:00")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("weekend-overwork", db)
        self.assertIn("weekend-overwork", [s["id"] for s in signals])

    def test_repeated_prompts_fires_on_exact_duplicates(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 5)
        for i in range(5):
            insert_message(conn, "s0", i, "why is the build failing again")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("repeated-prompts", db)
        self.assertIn("repeated-prompts", [s["id"] for s in signals])

    def test_repeated_prompts_no_fire_on_distinct_messages(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 5)
        for i in range(5):
            insert_message(conn, "s0", i, "distinct message number {}".format(i))
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("repeated-prompts", db)
        self.assertNotIn("repeated-prompts", [s["id"] for s in signals])

    def test_frustration_signals_fires_on_punctuation_and_caps(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 3)
        insert_message(conn, "s0", 0, "WHY WONT THIS WORK???!!!")
        insert_message(conn, "s0", 1, "THIS IS SO BROKEN FIX IT NOW")
        insert_message(conn, "s0", 2, "please refactor the module")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("frustration-signals", db)
        self.assertIn("frustration-signals", [s["id"] for s in signals])

    def test_frustration_signals_no_fire_on_calm_messages(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 2)
        insert_message(conn, "s0", 0, "Please refactor the auth module")
        insert_message(conn, "s0", 1, "Add error handling to the API endpoint")
        conn.commit()
        conn.close()

        signals, _ = self.eval_real_rule("frustration-signals", db)
        self.assertNotIn("frustration-signals", [s["id"] for s in signals])


class SkipPathTest(CoachRulesEvalBase):
    """The 34 unreachable rules must skip loudly and name the specific
    missing field, never silently evaluate to a no-op."""

    def test_every_real_vendored_rule_either_evaluates_or_names_missing_field(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 5)
        insert_message(conn, "s0", 0, "hello")
        conn.commit()
        conn.close()

        signals, stderr = self.run_eval(VENDOR_RULES, db)
        # Every skip line must say WHY, not just "unsupported".
        for line in stderr.splitlines():
            if "skipping" not in line:
                continue
            if line.startswith("coach-rules-eval: skipping") and "(no frontmatter)" not in line:
                self.assertIn("(", line)
                reason = line.split("(", 1)[1]
                self.assertNotEqual(reason.strip(), ")")
                # generic "unsupported" alone (no further detail) is banned
                self.assertFalse(
                    re.fullmatch(r"unsupported\)?", reason.strip()),
                    "skip reason too generic: {}".format(line),
                )

    def test_profanity_skips_with_wordlist_reason(self):
        signals, stderr = self.run_eval(VENDOR_RULES, self._empty_db())
        self.assertIn("profanity", stderr)
        self.assertIn("wordlist", stderr)

    def _empty_db(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 1)
        conn.commit()
        conn.close()
        return db

    def test_field_specific_reason_for_a_representative_unreachable_rule(self):
        signals, stderr = self.run_eval(VENDOR_RULES, self._empty_db())
        self.assertIn("high-cancellation", stderr)
        self.assertIn("isCanceled", stderr)


class CoverageAssertionTest(CoachRulesEvalBase):
    """Pins the evaluable count against the REAL vendored rules directory.
    If this drops, a future change silently reduced coverage. If it rises
    without a corresponding test above, someone added an evaluator without
    proving it can fire -- update both together, deliberately."""

    EXPECTED_EVALUATED = 11
    EXPECTED_TOTAL_RULES = 45

    def test_coverage_count_pinned(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 1)
        conn.commit()
        conn.close()

        _, stderr = self.run_eval(VENDOR_RULES, db)
        m = re.search(r"(\d+) of (\d+) vendored rules evaluated", stderr)
        self.assertIsNotNone(m, "coverage line missing from stderr:\n{}".format(stderr))
        evaluated, total = int(m.group(1)), int(m.group(2))
        self.assertEqual(total, self.EXPECTED_TOTAL_RULES)
        self.assertEqual(
            evaluated, self.EXPECTED_EVALUATED,
            "evaluable rule count changed ({} != {}) -- if this is an "
            "intentional improvement, add a fire/no-fire test pair for the "
            "new rule above and update EXPECTED_EVALUATED".format(
                evaluated, self.EXPECTED_EVALUATED
            ),
        )

    def test_vendor_rules_directory_has_45_rule_files(self):
        rule_files = [
            f for f in VENDOR_RULES.glob("*.md") if f.name != "UPSTREAM.md"
        ]
        self.assertEqual(len(rule_files), self.EXPECTED_TOTAL_RULES)


if __name__ == "__main__":
    unittest.main()
