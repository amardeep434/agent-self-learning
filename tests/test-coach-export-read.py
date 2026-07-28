#!/usr/bin/env python3
"""tests/test-coach-export-read.py -- scripts/coach-export-read.py (Route B)
against a REAL Coach export payload.

Why this file exists at all, given tests/test-coach-signals.py already touches
the reader twice: those two cases exercise the reader only incidentally, on an
invented two-pattern dict with a single top-level key (`antiPatterns`). A real
`Export Summary` from the ai-engineer-coach fork carries eight top-level keys
and ten patterns. Until 2026-07-28 that shape had never existed on any machine
-- the fork's .vsix had not been installed anywhere -- so every assertion this
project had about Route B was an assertion about a shape we made up.
`tests/fixtures/coach-export-v1.json` is now derived from an export that
actually ran (see its `_fixture` key for what was normalized and why), and this
suite pins the reader's contract against it: the CLI contract (argv, stdout,
exit code), the extraction, and -- the point of the whole exercise -- which
malformed inputs are allowed to be quiet and which are not.

The counts asserted below are the fixture's, not the real export's; the real
values were scaled when the fixture was vendored.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
READER = REPO / "scripts" / "coach-export-read.py"
FIXTURE = REPO / "tests" / "fixtures" / "coach-export-v1.json"

# Every top-level key a real schemaVersion-1 export emits. Asserted as a
# subset, not an equality: upstream adding a key must not fail this suite --
# that is the whole reason the reader tolerates unknown keys.
REAL_TOP_LEVEL_KEYS = {
    "activity", "antiPatterns", "filter", "flow",
    "generatedAt", "production", "schemaVersion", "totals",
}

# Spot-checked rows from the fixture: highest count, a `high` severity, and
# the lowest count. Enough that a reader which dropped, reordered, or
# zero-filled rows cannot still pass.
EXPECTED = {
    "no-slash-commands": ("low", 507),
    "low-context-provision-claude": ("high", 470),
    "late-night-coding": ("low", 74),
}


def run_reader(arg):
    return subprocess.run([sys.executable, str(READER), str(arg)],
                          capture_output=True, text=True)


def write_tmp(obj):
    """Write `obj` as JSON to a fresh temp file and return its path. Accepts a
    str to write malformed (non-JSON) bytes."""
    path = Path(tempfile.mkdtemp()) / "summary-latest.json"
    path.write_text(obj if isinstance(obj, str) else json.dumps(obj),
                    encoding="utf-8")
    return path


def load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class FixtureIntegrityTest(unittest.TestCase):
    """Guards the fixture itself. A fixture that quietly loses the realism it
    was vendored for would leave every test below passing against a shape as
    invented as the one this suite replaced."""

    def test_fixture_carries_the_full_real_top_level_shape(self):
        report = load_fixture()
        self.assertTrue(REAL_TOP_LEVEL_KEYS.issubset(set(report)),
                        "fixture lost top-level keys: {}".format(
                            sorted(REAL_TOP_LEVEL_KEYS - set(report))))
        self.assertEqual(report["schemaVersion"], 1)
        self.assertIsInstance(report["generatedAt"], str)
        self.assertEqual(len(report["antiPatterns"]["topPatterns"]), 10)

    def test_fixture_carries_no_identifying_content(self):
        """Re-run of the pre-vendoring privacy scan, as a standing check: this
        file is derived from one person's real usage and must stay pure
        aggregate counts, rule ids and upstream suggestion text."""
        raw = FIXTURE.read_text(encoding="utf-8")
        for label, needle in [("absolute path", "/home/"), ("absolute path", "/Users/"),
                              ("windows path", ":\\"), ("email", "@"),
                              ("url", "http")]:
            self.assertNotIn(needle, raw, "fixture contains a {}".format(label))


class ReaderContractTest(unittest.TestCase):
    def test_extracts_every_pattern_from_a_real_payload(self):
        proc = run_reader(FIXTURE)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        signals = json.loads(proc.stdout)
        self.assertEqual(len(signals), 10)
        self.assertEqual([s["source"] for s in signals], ["export"] * 10)

    def test_ids_severities_and_counts_match_the_payload(self):
        signals = {s["id"]: s for s in json.loads(run_reader(FIXTURE).stdout)}
        for pattern_id, (severity, count) in EXPECTED.items():
            self.assertIn(pattern_id, signals)
            self.assertEqual(signals[pattern_id]["severity"], severity, pattern_id)
            self.assertEqual(signals[pattern_id]["count"], count, pattern_id)

    def test_every_count_matches_its_source_occurrences(self):
        """`occurrences` is upstream's field name, `count` is ours. Renaming
        across that boundary is exactly where a per-pattern number goes missing
        without anything failing, so pin all ten, not a sample."""
        report = load_fixture()
        expected = {p["id"]: p["occurrences"]
                    for p in report["antiPatterns"]["topPatterns"]}
        actual = {s["id"]: s["count"] for s in json.loads(run_reader(FIXTURE).stdout)}
        self.assertEqual(actual, expected)
        self.assertNotIn(0, set(actual.values()),
                         "a zero count means occurrences was not read")

    def test_preserves_payload_order(self):
        report = load_fixture()
        self.assertEqual([s["id"] for s in json.loads(run_reader(FIXTURE).stdout)],
                         [p["id"] for p in report["antiPatterns"]["topPatterns"]])

    def test_unknown_top_level_keys_are_tolerated(self):
        """Upstream will add fields. A new sibling of `antiPatterns` must not
        cost us Route B."""
        report = load_fixture()
        report["someFutureSection"] = {"nested": [1, 2, 3]}
        report["schemaVersion"] = 99
        proc = run_reader(write_tmp(report))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(proc.stdout)), 10)

    def test_unknown_per_pattern_keys_are_tolerated(self):
        report = load_fixture()
        report["antiPatterns"]["topPatterns"][0]["someFutureField"] = "x"
        proc = run_reader(write_tmp(report))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(json.loads(proc.stdout)), 10)


class DenominatorTest(unittest.TestCase):
    """`count` on its own is not interpretable, so the reader also carries the
    export's own `totals.requests` as `denominator`. These pin the two things
    that matter: it must be the export's real total, and every way of NOT
    having one must land on 0 -- the value the renderer treats as "show no
    prevalence". A guessed denominator would produce a confident wrong rate,
    which is worse than the bare count this replaces."""

    def test_denominator_is_the_exports_own_request_total(self):
        report = load_fixture()
        signals = json.loads(run_reader(FIXTURE).stdout)
        self.assertEqual({s["denominator"] for s in signals},
                         {report["totals"]["requests"]})

    def test_rates_reproduce_the_percentages_coach_states_itself(self):
        """The fixture's own description strings quote percentages Coach
        computed upstream ("83% of requests have no file references", "135
        requests (27%)"). Recomputing count/denominator and landing on the
        same numbers is independent evidence that totals.requests really is
        the denominator occurrences were counted against -- not merely the
        only total in the payload."""
        signals = {s["id"]: s for s in json.loads(run_reader(FIXTURE).stdout)}
        for pattern_id, coach_says in [("no-file-context", 83), ("weekend-overwork", 27)]:
            s = signals[pattern_id]
            self.assertEqual(round(s["count"] * 100 / s["denominator"]), coach_says,
                             pattern_id)

    def test_export_without_totals_yields_no_denominator(self):
        report = load_fixture()
        del report["totals"]
        signals = json.loads(run_reader(write_tmp(report)).stdout)
        self.assertEqual({s["denominator"] for s in signals}, {0})
        self.assertEqual(len(signals), 10, "losing totals must not lose signals")

    def test_unusable_totals_yield_no_denominator(self):
        """Each of these would otherwise reach the renderer's arithmetic."""
        for label, totals in [("non-numeric", {"requests": "many"}),
                              ("null", {"requests": None}),
                              ("negative", {"requests": -5}),
                              ("wrong type", ["requests", 507]),
                              ("no requests key", {"sessions": 55})]:
            report = load_fixture()
            report["totals"] = totals
            proc = run_reader(write_tmp(report))
            self.assertEqual(proc.returncode, 0, "{}: {}".format(label, proc.stderr))
            self.assertEqual({s["denominator"] for s in json.loads(proc.stdout)}, {0},
                             label)


class LoudFailureTest(unittest.TestCase):
    """The reader must not report a broken export as a quiet zero. A missing
    file is the one absence that is genuinely normal (Coach not installed);
    everything else means something wrote an export we cannot read."""

    def test_missing_file_is_quiet_and_successful(self):
        proc = run_reader(Path(tempfile.mkdtemp()) / "absent.json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), [])

    def test_payload_missing_antipatterns_fails_loudly(self):
        report = load_fixture()
        del report["antiPatterns"]
        proc = run_reader(write_tmp(report))
        self.assertNotEqual(proc.returncode, 0,
                            "a present export with no antiPatterns exited 0")
        self.assertEqual(json.loads(proc.stdout), [])
        self.assertIn("unreadable export", proc.stderr)

    def test_payload_missing_toppatterns_fails_loudly(self):
        report = load_fixture()
        del report["antiPatterns"]["topPatterns"]
        proc = run_reader(write_tmp(report))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unreadable export", proc.stderr)

    def test_non_list_toppatterns_fails_loudly(self):
        """A dict here iterates as its keys and every element is skipped, so
        the silent-zero looks identical to 'no anti-patterns found'."""
        report = load_fixture()
        report["antiPatterns"]["topPatterns"] = {"no-slash-commands": 507}
        proc = run_reader(write_tmp(report))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not a list", proc.stderr)

    def test_truncated_json_fails_loudly(self):
        truncated = FIXTURE.read_text(encoding="utf-8")[:2000]
        proc = run_reader(write_tmp(truncated))
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(json.loads(proc.stdout), [])

    def test_wrong_argument_count_is_rejected(self):
        proc = subprocess.run([sys.executable, str(READER)],
                              capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Usage:", proc.stderr)


if __name__ == "__main__":
    unittest.main()
