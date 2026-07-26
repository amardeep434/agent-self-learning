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
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The telemetry fixture builders live with the telemetry suite; importing
# them here keeps ONE definition of "what a real Copilot event looks like"
# instead of a second copy that could drift from the real store.
import importlib.util as _ilu
_TFIX_SPEC = _ilu.spec_from_file_location(
    "test_telemetry_fixtures", str(Path(__file__).resolve().parent / "test-telemetry.py"))
TFIX = _ilu.module_from_spec(_TFIX_SPEC)
_TFIX_SPEC.loader.exec_module(TFIX)

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "coach-rules-eval.py"
SCHEMA = REPO / "schema" / "session-search-schema.sql"
VENDOR_RULES = REPO / "vendor" / "coach-rules"

# The suite drives the evaluator as a SUBPROCESS almost everywhere, which is
# the right default -- it exercises the real CLI contract. This in-process
# handle exists only for assertions the subprocess boundary destroys: main()
# emits a signal only when `count is not None and count > 0`, so a return of
# None and a return of 0 are indistinguishable from outside. See
# NoLanguageExplorationUnitTest.
_EVAL_SPEC = _ilu.spec_from_file_location("coach_rules_eval_inproc", str(SCRIPT))
CRE = _ilu.module_from_spec(_EVAL_SPEC)
sys.path.insert(0, str(REPO / "scripts" / "lib"))
_EVAL_SPEC.loader.exec_module(CRE)
parse_rule = CRE.parse_rule
eval_no_language_exploration = CRE.eval_no_language_exploration

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
    def run_eval(self, rules_dir, db_path, telemetry_home=None):
        """Always runs with the harness telemetry stores pointed somewhere
        explicit -- never at the developer's real ~/.copilot and ~/.claude.

        Without this, every assertion below would depend on whose machine
        the suite runs on: the same command would evaluate 19 rules on a
        workstation with both harnesses installed and 11 in CI, and a
        "coverage dropped" failure would be indistinguishable from "this
        laptop has no Copilot sessions". `telemetry_home=None` means an
        empty, nonexistent store, which is the CI shape.
        """
        env = dict(os.environ)
        if telemetry_home is None:
            env["SL_COPILOT_HOME"] = "/nonexistent-telemetry-store"
            env["CLAUDE_CONFIG_DIR"] = "/nonexistent-telemetry-store"
        else:
            env["SL_COPILOT_HOME"] = str(telemetry_home)
            env["CLAUDE_CONFIG_DIR"] = str(telemetry_home)
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(rules_dir), str(db_path)],
            capture_output=True, text=True, env=env,
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


class TelemetryAdapterTest(CoachRulesEvalBase):
    """Fire/no-fire pairs for every rule backed by scripts/lib/telemetry.py.

    The fixtures are built with tests/test-telemetry.py's own builders, whose
    event shapes were copied from the real harness stores -- so "this rule
    can fire" is demonstrated against the shape the harness actually writes,
    not against a shape invented to make the rule fire.

    The standing rule this class exists to enforce: a rule that evaluates
    but can never fire is worse than a loud skip. Every rule below therefore
    gets BOTH a firing case and a silent case, and the class after this one
    proves each of them skips loudly when the telemetry store is absent.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = Path(self.tmp) / "search.db"
        conn = make_db(str(self.db))
        insert_session(conn, "s0", 1)
        conn.commit()
        conn.close()
        self.store = Path(self.tmp) / "store"
        (self.store / "session-state").mkdir(parents=True)

    def copilot(self, session_id, events):
        return TFIX.copilot_session(str(self.store), session_id, events)

    def usage_rows(self, rows):
        conn = sqlite3.connect(str(self.store / "session-store.db"))
        conn.executescript(TFIX.CopilotStoreDbTest.DDL)
        conn.execute("INSERT INTO sessions (id) VALUES ('s1')")
        conn.executemany(
            "INSERT INTO assistant_usage_events (session_id, model, input_tokens,"
            " output_tokens, cache_read_tokens, duration_ms, reasoning_effort,"
            " created_at) VALUES ('s1',?,?,?,?,?,?,'2026-07-25')", rows)
        conn.commit()
        conn.close()

    def fired(self, rule_id):
        signals, stderr = self.run_eval(VENDOR_RULES, self.db, telemetry_home=self.store)
        self.assertNotIn(
            "skipping {} ".format(rule_id), stderr,
            "{} skipped when it should have evaluated:\n{}".format(rule_id, stderr))
        return [s for s in signals if s["id"] == rule_id]

    # -- model-overreliance ------------------------------------------------
    def test_model_overreliance_fires_on_a_single_dominant_model(self):
        self.usage_rows([("claude-opus-4.6", 100, 10, 0, 500, None)] * 20
                        + [("gpt-5.4", 100, 10, 0, 500, None)])
        self.assertTrue(self.fired("model-overreliance"))

    def test_model_overreliance_silent_when_models_are_varied(self):
        self.usage_rows([("m{}".format(i % 5), 100, 10, 0, 500, None) for i in range(30)])
        self.assertEqual(self.fired("model-overreliance"), [])

    # -- reasoning-effort-overuse ------------------------------------------
    def test_reasoning_effort_overuse_fires_on_mostly_high(self):
        self.usage_rows([("m", 100, 10, 0, 500, "high")] * 25)
        self.assertTrue(self.fired("reasoning-effort-overuse"))

    def test_reasoning_effort_overuse_silent_on_mostly_low(self):
        self.usage_rows([("m", 100, 10, 0, 500, "low")] * 25)
        self.assertEqual(self.fired("reasoning-effort-overuse"), [])

    def test_reasoning_effort_unknown_rows_stay_out_of_the_denominator(self):
        """21 high + 100 NULL must still read as 100% high effort, because
        upstream's own field is `totalKnown`. Counting NULLs as not-high
        would silently suppress the signal on any harness that does not
        record the setting."""
        self.usage_rows([("m", 100, 10, 0, 500, "high")] * 21
                        + [("m", 100, 10, 0, 500, None)] * 100)
        self.assertTrue(self.fired("reasoning-effort-overuse"))

    # -- cache-hit-starvation ----------------------------------------------
    def test_cache_hit_starvation_fires_on_large_uncached_prompts(self):
        self.usage_rows([("m", 50000, 10, 0, 500, None)] * 25)
        self.assertTrue(self.fired("cache-hit-starvation"))

    def test_cache_hit_starvation_silent_when_prompts_are_cached(self):
        self.usage_rows([("m", 50000, 10, 49000, 500, None)] * 25)
        self.assertEqual(self.fired("cache-hit-starvation"), [])

    # -- slow-responses ----------------------------------------------------
    def test_slow_responses_fires_on_long_turns(self):
        for i in range(8):
            self.copilot("s{}".format(i), TFIX.simple_turn(
                "0", user="x", start=0, end=45))
        self.assertTrue(self.fired("slow-responses"))

    def test_slow_responses_silent_on_quick_turns(self):
        for i in range(8):
            self.copilot("s{}".format(i), TFIX.simple_turn(
                "0", user="x", start=0, end=2))
        self.assertEqual(self.fired("slow-responses"), [])

    # -- verbose-output ----------------------------------------------------
    def test_verbose_output_fires_on_long_answers_to_short_prompts(self):
        for i in range(12):
            self.copilot("s{}".format(i), TFIX.simple_turn(
                "0", user="fix it", out_tokens=9000))
        self.assertTrue(self.fired("verbose-output"))

    def test_verbose_output_silent_when_answers_are_short(self):
        for i in range(12):
            self.copilot("s{}".format(i), TFIX.simple_turn(
                "0", user="fix it", out_tokens=200))
        self.assertEqual(self.fired("verbose-output"), [])

    # -- high-cancellation -------------------------------------------------
    def test_high_cancellation_fires_when_most_turns_are_aborted(self):
        for i in range(6):
            events = TFIX.simple_turn("0", user="x")
            events.insert(-1, TFIX.ev("abort", {"reason": "user_initiated"},
                                      "2026-07-25T22:40:03.000Z"))
            self.copilot("s{}".format(i), events)
        self.assertTrue(self.fired("high-cancellation"))

    def test_high_cancellation_silent_when_turns_complete(self):
        for i in range(6):
            self.copilot("s{}".format(i), TFIX.simple_turn("0", user="x"))
        self.assertEqual(self.fired("high-cancellation"), [])

    # -- runaway-agent-loops -----------------------------------------------
    def test_runaway_agent_loops_fires_on_many_tools_under_a_subagent(self):
        for i in range(4):
            events = TFIX.simple_turn("0", user="x", tools=[
                ("bash", {"command": "ls"})] * 20)
            events.insert(-1, TFIX.ev("subagent.started", {"agentName": "explore"},
                                      "2026-07-25T22:40:01.000Z"))
            self.copilot("s{}".format(i), events)
        self.assertTrue(self.fired("runaway-agent-loops"))

    def test_runaway_agent_loops_silent_when_agent_turns_use_few_tools(self):
        for i in range(4):
            events = TFIX.simple_turn("0", user="x", tools=[
                ("bash", {"command": "ls"})] * 5)
            events.insert(-1, TFIX.ev("subagent.started", {"agentName": "explore"},
                                      "2026-07-25T22:40:01.000Z"))
            self.copilot("s{}".format(i), events)
        self.assertEqual(self.fired("runaway-agent-loops"), [])

    def test_runaway_agent_loops_skips_when_no_turn_is_agent_attributed(self):
        """Not the same as "silent". With no subagent anywhere, there is no
        population for a rule about agent loops to be measured over, so the
        honest output is a skip -- reporting "0 runaway loops" from a corpus
        that contains no agent turns at all would be a clean bill of health
        derived from absent data."""
        for i in range(4):
            self.copilot("s{}".format(i), TFIX.simple_turn(
                "0", user="x", tools=[("bash", {"command": "ls"})] * 20))
        signals, stderr = self.run_eval(VENDOR_RULES, self.db, telemetry_home=self.store)
        self.assertIn("skipping runaway-agent-loops ", stderr)
        self.assertEqual([s for s in signals if s["id"] == "runaway-agent-loops"], [])

    # -- excessive-file-context --------------------------------------------
    def test_excessive_file_context_fires_on_wide_file_fanout(self):
        for i in range(12):
            self.copilot("s{}".format(i), TFIX.simple_turn("0", user="x", tools=[
                ("view", {"path": "/repo/f{}.py".format(n)}) for n in range(35)]))
        self.assertTrue(self.fired("excessive-file-context"))

    def test_excessive_file_context_silent_on_narrow_fanout(self):
        for i in range(12):
            self.copilot("s{}".format(i), TFIX.simple_turn("0", user="x", tools=[
                ("view", {"path": "/repo/f{}.py".format(n)}) for n in range(3)]))
        self.assertEqual(self.fired("excessive-file-context"), [])


class TelemetryDetectPinTest(CoachRulesEvalBase):
    """Each telemetry adapter hardcodes one rule's predicate, so it must
    refuse to run if that rule's `detect` block ever changes shape.

    Found by mutation testing: disabling `_pin()` entirely left the whole
    suite green, because every fixture used the rules exactly as vendored.
    Without this test, a `sync-coach-rules.sh` re-sync that tightened a
    threshold expression or added an OR-branch would keep emitting the OLD
    predicate's answer under the NEW rule's name -- silently wrong, which is
    the one outcome worse than a skip.
    """

    def test_changed_detect_block_skips_instead_of_evaluating_the_old_predicate(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 1)
        conn.commit()
        conn.close()

        rules_dir = Path(tmp) / "rules"
        rules_dir.mkdir()
        for rule_file in VENDOR_RULES.glob("*.md"):
            text = rule_file.read_text(encoding="utf-8")
            if rule_file.stem == "high-cancellation":
                text = text.replace("match: isCanceled == true",
                                    "match: isCanceled == true AND agentMode == \"ask\"")
            (rules_dir / rule_file.name).write_text(text, encoding="utf-8")

        store = Path(tmp) / "store"
        (store / "session-state").mkdir(parents=True)
        for i in range(6):
            events = TFIX.simple_turn("0", user="x")
            events.insert(-1, TFIX.ev("abort", {"reason": "user_initiated"},
                                      "2026-07-25T22:40:03.000Z"))
            TFIX.copilot_session(str(store), "s{}".format(i), events)

        signals, stderr = self.run_eval(rules_dir, db, telemetry_home=store)
        self.assertIn("skipping high-cancellation ", stderr)
        self.assertIn("detect block changed", stderr)
        self.assertEqual([s for s in signals if s["id"] == "high-cancellation"], [])


class AiCodeAdapterTest(CoachRulesEvalBase):
    """Fire/no-fire pairs for the five rules that need aiCode.loc.

    Fixtures are built with the same builders test-telemetry.py uses, whose
    event shapes were copied from the real stores, and the code bodies are
    put where the harness really puts them (`edit`'s new_str / `create`'s
    file_text, plus prose fences in assistant.message content). A rule that
    only fires against a hand-shaped record would prove nothing.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = Path(self.tmp) / "search.db"
        conn = make_db(str(self.db))
        insert_session(conn, "s0", 1)
        conn.commit()
        conn.close()
        self.store = Path(self.tmp) / "store"
        (self.store / "session-state").mkdir(parents=True)

    def fired(self, rule_id):
        signals, stderr = self.run_eval(VENDOR_RULES, self.db, telemetry_home=self.store)
        self.assertNotIn(
            "skipping {} ".format(rule_id), stderr,
            "{} skipped when it should have evaluated:\n{}".format(rule_id, stderr))
        return [s for s in signals if s["id"] == rule_id]

    @staticmethod
    def _edit(path, lines):
        return ("edit", {"path": path, "old_str": "x",
                         "new_str": "\n".join("line{}".format(i) for i in range(lines))})

    def _session(self, session_id, turns):
        events = []
        for turn in turns:
            events.extend(turn)
        TFIX.copilot_session(str(self.store), session_id, events)

    def _turn(self, turn_id, user, edits=(), start=0, end=5):
        return TFIX.simple_turn(turn_id, user=user, tools=edits, start=start, end=end)

    @staticmethod
    def _restamp(events, start_s, end_s):
        """Rewrite a turn's timestamps to VALID ISO at arbitrary offsets.

        TFIX._ts() only formats a seconds field, so any offset above 59
        produces "22:40:200" -- which parses to None, which makes every
        timestamp-dependent predicate silently unreachable. Found by mutation
        testing: deleting speed-accept's gap check AND its LoC floor both
        left the suite green, because no fixture had a parseable timestamp
        pair in the first place.
        """
        def stamp(offset):
            return "2026-07-25T{:02d}:{:02d}:{:02d}.000Z".format(
                22 + offset // 3600, (offset // 60) % 60, offset % 60)
        for event in events:
            etype = event["type"]
            if etype in ("assistant.turn_end",):
                event["timestamp"] = stamp(end_s)
            else:
                event["timestamp"] = stamp(start_s)
        return events

    def _timed_turn(self, turn_id, user, edits=(), start=0, end=5):
        return self._restamp(
            TFIX.simple_turn(turn_id, user=user, tools=edits), start, end)

    # -- vibe-coding -------------------------------------------------------
    def test_vibe_coding_fires_on_big_output_from_a_bare_prompt(self):
        for index in range(3):
            self._session("s{}".format(index), [
                self._turn("0", "make it work", [self._edit("/r/a.py", 150)]),
            ])
        self.assertTrue(self.fired("vibe-coding"))

    def test_vibe_coding_silent_when_the_first_prompt_is_spec_shaped(self):
        """The NOT(...) branch is the whole point of the rule -- a session
        that opened with a spec is not vibe coding however much code came
        out. Without this case the rule would look like a pure LoC alarm."""
        for index in range(3):
            self._session("s{}".format(index), [
                self._turn("0", "Requirements:\n- parse the file",
                           [self._edit("/r/a.py", 150)]),
            ])
        self.assertEqual(self.fired("vibe-coding"), [])

    def test_vibe_coding_silent_below_the_loc_threshold(self):
        for index in range(3):
            self._session("s{}".format(index), [
                self._turn("0", "make it work", [self._edit("/r/a.py", 5)]),
            ])
        self.assertEqual(self.fired("vibe-coding"), [])

    # -- copy-paste-blindness ---------------------------------------------
    def test_copy_paste_blindness_fires_without_follow_up_refinement(self):
        for index in range(3):
            self._session("s{}".format(index), [
                self._turn("0", "write the parser", [self._edit("/r/a.py", 80)]),
                self._turn("1", "thanks", start=6, end=8),
            ])
        self.assertTrue(self.fired("copy-paste-blindness"))

    def test_copy_paste_blindness_silent_when_a_later_prompt_asks_for_changes(self):
        for index in range(3):
            self._session("s{}".format(index), [
                self._turn("0", "write the parser", [self._edit("/r/a.py", 80)]),
                self._turn("1", "actually fix the edge case", start=6, end=8),
            ])
        self.assertEqual(self.fired("copy-paste-blindness"), [])

    def test_copy_paste_blindness_silent_when_a_later_request_edits_a_file(self):
        for index in range(3):
            self._session("s{}".format(index), [
                self._turn("0", "write the parser", [self._edit("/r/a.py", 80)]),
                self._turn("1", "ok", [self._edit("/r/a.py", 2)], start=6, end=8),
            ])
        self.assertEqual(self.fired("copy-paste-blindness"), [])

    # -- speed-accept ------------------------------------------------------
    def _speed_session(self, spacing, lines):
        turns = []
        for index in range(7):
            start = index * spacing
            turns.append(self._timed_turn(str(index), "go",
                                          [self._edit("/r/a.py", lines)],
                                          start=start, end=start + 5))
        self._session("s0", turns)

    def test_speed_accept_fires_on_instant_follow_ups_after_big_output(self):
        self._speed_session(spacing=6, lines=40)   # 1s gap, 40 LoC
        self.assertTrue(self.fired("speed-accept"))

    def test_speed_accept_silent_when_the_reader_takes_time(self):
        """Same LoC, same request count -- only the gap changes. Pins that
        the timing half of the predicate is live rather than decorative."""
        self._speed_session(spacing=300, lines=40)  # 295s gap
        self.assertEqual(self.fired("speed-accept"), [])

    def test_speed_accept_silent_on_out_of_order_timestamps(self):
        """Upstream requires `gap >= 0`. A negative gap means overlapping or
        reordered events -- bad data, not a fast human -- and treating it as
        a hit would invent speed-accept occurrences out of clock skew."""
        turns = []
        for index in range(7):
            start = 300 - index * 40
            turns.append(self._timed_turn(str(index), "go",
                                          [self._edit("/r/a.py", 40)],
                                          start=start, end=start + 5))
        self._session("s0", turns)
        self.assertEqual(self.fired("speed-accept"), [])

    def test_speed_accept_silent_below_the_loc_floor(self):
        """Same instant gaps -- only the LoC changes. Pins the other half."""
        self._speed_session(spacing=6, lines=3)     # 1s gap, 3 LoC
        self.assertEqual(self.fired("speed-accept"), [])

    # -- low-markdown-ratio ------------------------------------------------
    def test_low_markdown_ratio_fires_on_code_with_no_docs(self):
        events = [TFIX.ev("session.start",
                          {"sessionId": "s0", "context": {"gitRoot": "/repo"}},
                          "2026-07-25T22:40:00.000Z")]
        events.extend(self._turn("0", "build", [self._edit("/repo/a.py", 300)]))
        TFIX.copilot_session(str(self.store), "s0", events)
        self.assertTrue(self.fired("low-markdown-ratio"))

    def test_low_markdown_ratio_silent_when_docs_accompany_the_code(self):
        events = [TFIX.ev("session.start",
                          {"sessionId": "s0", "context": {"gitRoot": "/repo"}},
                          "2026-07-25T22:40:00.000Z")]
        events.extend(self._turn("0", "build", [
            self._edit("/repo/a.py", 100), self._edit("/repo/README.md", 100)]))
        TFIX.copilot_session(str(self.store), "s0", events)
        self.assertEqual(self.fired("low-markdown-ratio"), [])

    def test_low_markdown_ratio_silent_below_the_total_loc_floor(self):
        events = [TFIX.ev("session.start",
                          {"sessionId": "s0", "context": {"gitRoot": "/repo"}},
                          "2026-07-25T22:40:00.000Z")]
        events.extend(self._turn("0", "build", [self._edit("/repo/a.py", 10)]))
        TFIX.copilot_session(str(self.store), "s0", events)
        self.assertEqual(self.fired("low-markdown-ratio"), [])

    # -- no-language-exploration -------------------------------------------
    def _week_session(self, session_id, day, language_path):
        """One turn stamped in a chosen week-of-month bucket."""
        stamp = "2026-07-{:02d}T12:00:00.000Z".format(day)
        events = TFIX.simple_turn("0", user="go", tools=[self._edit(language_path, 5)])
        for event in events:
            event["timestamp"] = stamp
        TFIX.copilot_session(str(self.store), session_id, events)

    def test_no_language_exploration_fires_when_no_new_language_appears(self):
        for index, day in enumerate((1, 8, 15, 22, 28)):
            self._week_session("s{}".format(index), day, "/repo/a.py")
        self.assertTrue(self.fired("no-language-exploration"))

    def test_no_language_exploration_silent_when_a_new_language_appears_late(self):
        for index, day in enumerate((1, 8, 15, 22)):
            self._week_session("s{}".format(index), day, "/repo/a.py")
        self._week_session("s9", 28, "/repo/a.rs")
        self.assertEqual(self.fired("no-language-exploration"), [])

    def test_no_language_exploration_ignores_markup_and_data_formats(self):
        """Upstream's IGNORE set: a week of nothing but JSON and markdown is
        not language exploration. Without it the rule would go silent for
        anyone who writes config files."""
        for index, day in enumerate((1, 8, 15, 22)):
            self._week_session("s{}".format(index), day, "/repo/a.py")
        self._week_session("s9", 28, "/repo/data.json")
        self.assertTrue(self.fired("no-language-exploration"))


class NoLanguageExplorationUnitTest(unittest.TestCase):
    """Calls the adapter directly, because the end-to-end path cannot
    distinguish "returned None" from "returned 0".

    main() emits a signal only when `count is not None and count > 0`. The
    firing return value here is `weeksSinceNew`, which is 0 in exactly the
    case where the rule must NOT fire -- so a mutation deleting the
    `recentNew == 0` condition still produced no signal and survived the
    end-to-end tests. Asserting the return value itself is what kills it.
    """

    class _Tel:
        def __init__(self, turns):
            self.turns = turns
            self.api_calls = []

    @staticmethod
    def _req(day, language):
        return {"source": "copilot", "session_id": "s{}".format(day),
                "timestamp": "2026-07-{:02d}T12:00:00.000Z".format(day),
                "aiCode": [{"language": language, "loc": 5}]}

    def _rule(self):
        return parse_rule(VENDOR_RULES / "no-language-exploration.md")

    def _eval(self, requests):
        return eval_no_language_exploration(self._rule(), self._Tel(requests))

    def test_returns_weeks_since_new_when_nothing_new_appeared(self):
        result = self._eval([self._req(day, "python") for day in (1, 8, 15, 22, 28)])
        self.assertEqual(result, 4)

    def test_returns_none_when_a_new_language_appeared_in_the_latest_week(self):
        requests = [self._req(day, "python") for day in (1, 8, 15, 22)]
        requests.append(self._req(28, "rust"))
        self.assertIsNone(self._eval(requests))

    def test_new_language_one_week_ago_still_fires_with_a_nonzero_count(self):
        requests = [self._req(day, "python") for day in (1, 8, 15)]
        requests.append(self._req(22, "rust"))
        requests.append(self._req(28, "python"))
        self.assertEqual(self._eval(requests), 1)

    def test_returns_none_below_the_minimum_week_count(self):
        self.assertIsNone(self._eval([self._req(day, "python") for day in (1, 8)]))

    def test_ignored_languages_never_count_as_exploration(self):
        requests = [self._req(day, "python") for day in (1, 8, 15, 22)]
        requests.append(self._req(28, "json"))
        self.assertEqual(self._eval(requests), 4)

    def test_empty_selection_raises_rather_than_scoring_zero(self):
        with self.assertRaises(ValueError):
            self._eval([])


class TelemetryAbsentSkipsLoudlyTest(CoachRulesEvalBase):
    """With no harness store, every telemetry-backed rule must SKIP, naming
    the missing source -- never evaluate to a clean bill of health.

    This is the regression guard for the failure mode that motivated the
    whole design: a rule scored against zero records reports "no problem"
    in exactly the situation where the honest answer is "no data".
    """

    TELEMETRY_RULE_IDS = [
        "model-overreliance", "reasoning-effort-overuse", "cache-hit-starvation",
        "slow-responses", "verbose-output", "high-cancellation",
        "runaway-agent-loops", "excessive-file-context",
        "vibe-coding", "copy-paste-blindness", "speed-accept",
        "low-markdown-ratio", "no-language-exploration",
    ]

    def test_all_telemetry_rules_skip_with_a_source_naming_reason(self):
        tmp = tempfile.mkdtemp()
        db = Path(tmp) / "search.db"
        conn = make_db(str(db))
        insert_session(conn, "s0", 1)
        conn.commit()
        conn.close()

        signals, stderr = self.run_eval(VENDOR_RULES, db)  # no telemetry_home
        emitted = {s["id"] for s in signals}
        for rule_id in self.TELEMETRY_RULE_IDS:
            self.assertIn("skipping {} ".format(rule_id), stderr,
                          "{} did not skip loudly with no telemetry store".format(rule_id))
            self.assertNotIn(rule_id, emitted)
        self.assertIn("events.jsonl", stderr)
        self.assertIn("projects/*.jsonl", stderr)


class SkipPathTest(CoachRulesEvalBase):
    """Every rule this evaluator does not evaluate must skip LOUDLY with a
    specific reason, never silently evaluate to a no-op.

    "Specific" was not enough. On 2026-07-26 an adversarial re-analysis
    found twelve of the then-21 skip reasons were specific AND FALSE -- each
    naming a concrete upstream behaviour or local measurement that does not
    exist, and each pointing away from doing work. So the bar is now
    EVIDENCE-CITING, not merely specific: a skip reason must carry either
    "[upstream <file>:<line>]", "[vendored <rule>.md ...]" or
    "[measured ...]". A reason that cannot name how it could be checked is
    not admissible.

    See coach-rules-eval.py's UNSUPPORTED_REASONS header for the standing
    rules, including the two banned arguments (requiresIdeContext as proof
    of unreachability; "a constant conjunct makes the rule a constant")."""

    # `requiresIdeContext` is upstream's dashboard-attribution flag, not a
    # reachability proof -- see the UNSUPPORTED_REASONS header, rule 2. It
    # must not reappear as a load-bearing justification.
    BANNED_REASON_SUBSTRINGS = ("IDE-ONLY", "Reachable via Route B only")

    def test_every_skip_reason_cites_upstream_source_or_a_measurement(self):
        _, stderr = self.run_eval(VENDOR_RULES, self._empty_db())
        import importlib.util as ilu
        for rule_id, reason in CRE.UNSUPPORTED_REASONS.items():
            self.assertTrue(
                any(tag in reason for tag in
                    ("[upstream ", "[vendored ", "[measured ")),
                "skip reason for {} cites no checkable evidence -- it must "
                "carry [upstream <file>:<line>], [vendored <rule>.md ...] "
                "or [measured ...]:\n{}".format(
                    rule_id, reason),
            )
            for banned in self.BANNED_REASON_SUBSTRINGS:
                self.assertNotIn(
                    banned, reason,
                    "skip reason for {} resurrects a banned justification "
                    "({!r}) -- see UNSUPPORTED_REASONS header".format(
                        rule_id, banned),
                )

    def test_skip_reasons_only_name_rules_that_exist(self):
        """A stale entry for a deleted/renamed rule would be dead text that
        never prints, so no reader could catch that it went wrong."""
        vendored = {
            f.stem for f in VENDOR_RULES.glob("*.md") if f.name != "UPSTREAM.md"
        }
        self.assertEqual(set(CRE.UNSUPPORTED_REASONS) - vendored, set())

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

    # 11 from the project's own index (generic engine + REQUEST_ADAPTERS +
    # the two bespoke session adapters). The 13 TELEMETRY_ADAPTERS are NOT
    # counted here: this test runs with no harness store, where they must
    # skip. TelemetryAdapterTest covers them with a store present, and
    # TelemetryAbsentSkipsLoudlyTest pins that they skip without one.
    EXPECTED_EVALUATED = 11
    EXPECTED_TELEMETRY_ADAPTERS = 13
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
