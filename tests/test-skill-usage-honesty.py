#!/usr/bin/env python3
"""tests/test-skill-usage-honesty.py

Keeps the `use_count` documentation honest about what the code actually does.

On 2026-07-30 `prompts/curator-review.md` stated that a skill goes stale only
when `use_count > 0` and that "any use_count or view_count increment
reactivates", while `prompts/authoring-standards.md` said `use_count` is
"incremented when the skill is invoked via Skill tool". None of that was true:
no incrementer existed anywhere, all 50 tracked skills read 0, and `view_count`
was absent from every record rather than merely zero. So the curator archived on
wall-clock staleness alone while its own prompt described a usage-driven policy
to the reviewing model.

This is a two-way lock, and the direction that matters is the SECOND one:

  1. While no incrementer exists, the docs must say so.
  2. The moment an incrementer IS added, this test fails -- forcing the docs to
     be corrected back. Without that direction, wiring a real usage signal later
     would silently leave behind documentation describing it as dead.

It deliberately does not assert anything about the live store: a developer with
a populated store and one with an empty one must both get the same answer, and
this repo has been burned by tests that measured the machine instead of the tree.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
CURATOR_PROMPT = REPO / "prompts" / "curator-review.md"
AUTHORING = REPO / "prompts" / "authoring-standards.md"

# An assignment that raises use_count: `+= 1`, `= use_count + 1`, or an explicit
# increment helper. Narrow on purpose -- `setdefault("use_count", 0)` and plain
# reads must NOT count, or this test would pass on the very state it exists to
# catch.
INCREMENT_RE = re.compile(
    r"use_count[^\n]{0,40}(\+=\s*1|=\s*[^\n]*use_count[^\n]*\+\s*1)"
    r"|increment_use_count",
)


def incrementer_sites() -> list[str]:
    """Every place in scripts/ that raises use_count."""
    hits = []
    for path in sorted(SCRIPTS.rglob("*")):
        if not path.is_file() or path.suffix not in (".py", ".sh"):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if INCREMENT_RE.search(text):
            hits.append(str(path.relative_to(REPO)))
    return hits


class UseCountHonestyTest(unittest.TestCase):
    def test_docs_match_whether_an_incrementer_exists(self):
        sites = incrementer_sites()
        curator = CURATOR_PROMPT.read_text(encoding="utf-8")
        authoring = AUTHORING.read_text(encoding="utf-8")

        if sites:
            # Direction 2: a signal now exists, so the "dead" wording must go.
            self.assertNotIn(
                "Archival is wall-clock only", curator,
                "use_count is now incremented at {} -- curator-review.md still "
                "tells the reviewing model that archival ignores usage. Update "
                "it.".format(", ".join(sites)))
            self.assertNotIn(
                "reserved, always 0 today", authoring,
                "use_count is now incremented at {} -- authoring-standards.md "
                "still calls it reserved and always 0. Update it.".format(
                    ", ".join(sites)))
        else:
            # Direction 1: nothing increments it, so both files must say so.
            self.assertIn(
                "Archival is wall-clock only", curator,
                "Nothing in scripts/ increments use_count, so curator-review.md "
                "must not describe a usage-driven archival policy to the model.")
            self.assertIn(
                "reserved, always 0 today", authoring,
                "Nothing in scripts/ increments use_count, so "
                "authoring-standards.md must not claim the Skill tool raises it.")

    def test_view_count_is_not_claimed_to_be_written(self):
        """`view_count` is absent from every live record, not merely zero, so no
        prompt may describe it as a live signal."""
        if incrementer_sites():
            self.skipTest("a usage signal now exists; the claim is being revised")
        authoring = AUTHORING.read_text(encoding="utf-8")
        self.assertIn("never written at all", authoring)

    def test_the_detector_would_actually_catch_an_incrementer(self):
        """Guards the guard.

        A regex that matches nothing would make the whole test vacuously pass in
        the "no incrementer" direction forever -- exactly the shape of a test
        that guards nothing, which this repo has shipped before.
        """
        self.assertRegex("record['use_count'] += 1", INCREMENT_RE)
        self.assertRegex("usage[name]['use_count'] = use_count + 1", INCREMENT_RE)
        self.assertRegex("increment_use_count(name)", INCREMENT_RE)
        # And must NOT fire on initialisation or a plain read.
        self.assertNotRegex('record.setdefault("use_count", 0)', INCREMENT_RE)
        self.assertNotRegex('use_count = record.get("use_count", 0)', INCREMENT_RE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
