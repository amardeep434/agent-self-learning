"""tests/test-isotime.py

Pins scripts/lib/isotime.py -- the shared ISO-8601 parser extracted in fix
round D, blocker (a), after skill-lifecycle.py's own copy of this logic
(missing the "Z" swap and the naive-datetime-as-UTC guard) caused CI run
30149706340 to fail on both Python 3.9 cells: "Z"-suffixed timestamps (what
every shell producer in this project writes) silently failed to parse under
3.9's stricter fromisoformat, so skill-lifecycle.py found no activity anchor
for any skill and exited 0, "Nothing to do."

This suite MUST pass under Python 3.9 specifically -- that is the whole
point of the regression it pins. Run it with the absolute path to a 3.9
interpreter, e.g.:
    ~/.pyenv/versions/3.9.24/bin/python3.9 -m unittest tests/test-isotime.py -v
"""
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import isotime  # noqa: E402


# The exact instant every assertion below is anchored to: 2024-06-15T12:34:56 UTC.
EXPECTED_EPOCH = 1718454896


class TestParseIso(unittest.TestCase):
    def test_z_suffix(self):
        self.assertEqual(isotime.parse_iso("2024-06-15T12:34:56Z"), EXPECTED_EPOCH)

    def test_explicit_utc_offset(self):
        self.assertEqual(isotime.parse_iso("2024-06-15T12:34:56+00:00"), EXPECTED_EPOCH)

    def test_z_and_offset_forms_are_equal(self):
        # The specific claim CLAUDE.md's task description pins: producers
        # write mixed formats into the same .usage.json, and both must
        # resolve to the identical epoch, not merely "both parse."
        self.assertEqual(
            isotime.parse_iso("2024-06-15T12:34:56Z"),
            isotime.parse_iso("2024-06-15T12:34:56+00:00"),
        )

    def test_positive_non_utc_offset(self):
        self.assertEqual(isotime.parse_iso("2024-06-15T18:04:56+05:30"), EXPECTED_EPOCH)

    def test_negative_non_utc_offset_not_flipped_positive(self):
        # 07:04:56-05:30 is the same UTC instant as 18:04:56+05:30 above. If
        # the sign were ever dropped or flipped this would silently resolve
        # to the wrong epoch instead of raising -- the exact "silent and
        # directional" failure mode this module exists to prevent.
        self.assertEqual(isotime.parse_iso("2024-06-15T07:04:56-05:30"), EXPECTED_EPOCH)

    def test_fractional_seconds(self):
        self.assertEqual(isotime.parse_iso("2024-06-15T12:34:56.500Z"), EXPECTED_EPOCH)

    def test_naive_timestamp_treated_as_utc_not_local_time(self):
        # Defect 2: a tz-naive datetime's .timestamp() is otherwise
        # interpreter-local-time-dependent. Pin TZ explicitly (not just
        # inherit CI's default) so this fails HERE, deterministically, if
        # that guard is ever dropped -- rather than only in whichever TZ a
        # given CI runner happens to default to.
        old_tz = os.environ.get("TZ")
        try:
            os.environ["TZ"] = "America/New_York"
            if hasattr(__import__("time"), "tzset"):
                __import__("time").tzset()
            self.assertEqual(isotime.parse_iso("2024-06-15T12:34:56"), EXPECTED_EPOCH)
        finally:
            if old_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old_tz
            if hasattr(__import__("time"), "tzset"):
                __import__("time").tzset()

    def test_empty_returns_none(self):
        self.assertIsNone(isotime.parse_iso(""))

    def test_none_returns_none(self):
        self.assertIsNone(isotime.parse_iso(None))

    def test_garbage_returns_none(self):
        self.assertIsNone(isotime.parse_iso("not-a-real-timestamp"))

    def test_epoch_adjacent_timestamp_distinguishable_from_none(self):
        self.assertEqual(isotime.parse_iso("1970-01-01T00:00:01Z"), 1)


class TestNowIso(unittest.TestCase):
    def test_now_iso_round_trips_through_parse_iso(self):
        produced = isotime.now_iso()
        epoch = isotime.parse_iso(produced)
        self.assertIsNotNone(epoch)
        # Sanity: within a wide window of "now" -- not asserting exact
        # equality against a second independently-computed "now" call,
        # which would be flaky.
        import time
        self.assertLess(abs(time.time() - epoch), 5)

    def test_now_iso_has_explicit_utc_offset(self):
        produced = isotime.now_iso()
        self.assertTrue(produced.endswith("+00:00"))


class TestCli(unittest.TestCase):
    def test_parse_subcommand(self):
        import subprocess
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "isotime.py"), "parse", "2024-06-15T12:34:56Z"],
            capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.strip(), str(EXPECTED_EPOCH))

    def test_parse_subcommand_garbage_prints_zero_sentinel(self):
        import subprocess
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "isotime.py"), "parse", "garbage"],
            capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.strip(), "0")

    def test_now_subcommand(self):
        import subprocess
        r = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "lib" / "isotime.py"), "now"],
            capture_output=True, text=True, check=True)
        self.assertIsNotNone(isotime.parse_iso(r.stdout.strip()))


if __name__ == "__main__":
    unittest.main()
