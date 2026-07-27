#!/usr/bin/env python3
"""B3: every detached-review launch in the shell suites must be paired with a wait.

`scripts/session-review.sh` and `scripts/copilot-session-review.sh` both detach
their entire pipeline (`nohup ... &` + `disown`), so the launching call returns
long before anything is written. Each writes an unconditional completion marker
as its last statement, and `tests/lib/wait-for-review.sh` provides
`sl_clear_review_marker` / `sl_wait_for_review_complete` /
`sl_expect_no_review_spawned` / `sl_rm_rf_retry` to synchronise on it.

The pairing has been enforced by convention only, and convention has lost three
times: `cd04308` introduced the helper after the race broke a macOS suite,
`263a717` swept sites it had missed, and `ae9e8f6` fixed a site added *after*
the helper existed -- which surfaced as ubuntu-3.13 failing with every assertion
passing and a non-zero exit from teardown. That failure mode (green assertions,
red exit) is expensive to diagnose and trivial to prevent at authoring time.

A spawn-and-wait wrapper was considered and rejected: the call sites are
genuinely heterogeneous (some pipe stdin, some run under `env -i` with a
different HOME, some assert the reviewer must *not* spawn, one runs two
sequential scenarios against two stores). Wrapping them would need an option
surface as large as the sites themselves. A lint costs ~30 lines and catches
the next occurrence when it is written.

Rule enforced: between one launch and the next (or end of file), there must be a
`sl_wait_for_review_complete` or an `sl_expect_no_review_spawned`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent

# A launch: `bash <something>/session-review.sh` or `.../copilot-session-review.sh`.
LAUNCH_RE = re.compile(r"\bbash\s+\S*(?:copilot-)?session-review\.sh")

# JSON fixtures name these same scripts as hook `command` strings without ever
# running them (settings.json / self-learning.json fixtures in the uninstall,
# doctor, health and script-path suites). Counting those as launches would make
# the lint demand a wait for a process that never starts. Detected by the JSON
# keys that can only appear in a fixture, never in an invocation.
FIXTURE_MARKERS = ('"command"', '"bash"', '{"hooks"', '"hooks":')

WAIT_RE = re.compile(r"\bsl_(?:wait_for_review_complete|expect_no_review_spawned)\b")


def launches_and_waits(lines: list[str]) -> tuple[list[int], list[int]]:
    launches, waits = [], []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if LAUNCH_RE.search(line) and not any(m in line for m in FIXTURE_MARKERS):
            launches.append(i)
        if WAIT_RE.search(line) and not stripped.startswith("#"):
            waits.append(i)
    return launches, waits


def main() -> int:
    failures = 0
    checked = 0
    for path in sorted(TESTS_DIR.glob("test-*.sh")):
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        launches, waits = launches_and_waits(lines)
        for idx, start in enumerate(launches):
            checked += 1
            # Window: up to the next launch, or end of file. Principled rather
            # than a magic line count -- each launch must be synchronised on
            # before another one starts, which is exactly the invariant that
            # keeps two detached pipelines from racing each other.
            end = launches[idx + 1] if idx + 1 < len(launches) else len(lines)
            if not any(start < w < end for w in waits):
                failures += 1
                print(
                    f"FAIL: {path.name}:{start + 1} launches the detached reviewer "
                    f"with no sl_wait_for_review_complete or "
                    f"sl_expect_no_review_spawned before the next launch "
                    f"(line {end if end < len(lines) else len(lines)})"
                )
                print(f"       {lines[start].strip()[:110]}")

    if checked == 0:
        # Never pass by finding nothing: a regex that silently stops matching
        # would turn this lint into a no-op that still exits 0, which is the
        # exact defect class the whole project exists to eliminate.
        print("FAIL: lint found zero review launches -- the pattern must be broken")
        return 1

    print(f"Checked {checked} detached-review launch site(s) across the shell suites.")
    if failures:
        print(f"FAILED: {failures} unpaired launch site(s).")
        return 1
    print("All review-launch-lint tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
