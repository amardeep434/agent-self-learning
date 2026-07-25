# Task 8 Report: Test runner and 3-OS CI

## Status: DONE

## What was implemented

### 1. `tests/run-all.sh` (new)
Discovers suites via `tests/test-*.sh` and `tests/test-*.py` globs (with `nullglob`
so a no-match glob yields an empty array rather than a literal pattern string).
Design choices beyond the brief's starter snippet, all in the "cannot lie"
direction:
- Reports a discovered-suite count and enforces a sanity floor
  (`RUN_ALL_MIN_SUITES`, default 15; currently discovers 17 — 12 shell + 5
  python). Zero suites is an automatic failure; below-floor is also a
  failure, distinct message.
- Every suite is checked for existence/readability immediately before
  invocation and recorded as a named failure if either check fails, rather
  than letting `bash`/`python3` produce an ambiguous "command not found".
- All suites always run to completion — the loop never short-circuits on a
  failure — and failures are collected into an array, named individually,
  and printed as a block before the final `exit`.
- Exit code is `1` if suite count is implausible OR any suite failed; `0`
  only if both conditions are clean.
- `chmod +x` applied.

### 2. `.github/workflows/ci.yml` (new)
3 OS × 2 Python matrix (`ubuntu-latest`, `macos-latest`, `windows-latest` ×
`3.9`, `3.13`), `fail-fast: false`, `shell: bash` default (Git Bash on
Windows), `actions/checkout@v4`, `actions/setup-python@v5` (both pinned to
major version, no floating refs). Added `permissions: contents: read` as a
defense-in-depth hardening not in the brief's template (strengthens, does
not weaken).

Deviations from the brief's literal YAML, each because local investigation
found it would fail on first push otherwise:

- **`"on":` quoted.** Validating with PyYAML showed bare `on:` parses as the
  boolean key `True` under YAML 1.1 (the classic GitHub-Actions gotcha).
  GitHub's own parser special-cases `on:` and is unaffected, but quoting it
  removes the ambiguity for any other YAML-1.1-strict tool and costs
  nothing.
- **Added a `python3` shim step for Windows.** Verified via web research:
  `actions/setup-python` on Windows only ever exposes `python.exe`, never a
  `python3` on PATH — this is a known upstream gap, not fixed by pinning a
  version. Every script in this repo (`config.sh`, `install.sh`,
  `curator-run.sh`, `session-review.sh`, etc.) hardcodes `python3` by
  project-wide convention, including `install.sh`'s own prerequisite check
  (`for cmd in jq sqlite3 python3`). Without a shim, every Windows matrix
  cell would fail before a single test ran, with a confusing
  "python3: command not found" deep in a subshell rather than a clear
  signal. Fixed by copying `python.exe` to `python3.exe` in the same
  directory, in a Windows-only step, rather than touching the `python3`
  convention across scripts/ (out of this task's scope and would spread the
  same fix across many load-bearing files).
- **Added a `sqlite3` install step for Windows.** `sqlite3` (the CLI, not
  Python's bundled module) ships on ubuntu-latest and macos-latest but not
  windows-latest. Several suites and `scripts/self-learning-health.sh` /
  `scripts/index-session.sh` shell out to the `sqlite3` binary directly.
  Installed via `choco install sqlite -y --no-progress`.
- **Added a "Verify required tools are on PATH" step** that fails loudly
  (`::error::`) if `python3`, `jq`, `sqlite3`, or `bash` are not resolvable
  after the above steps, rather than letting a downstream suite fail with an
  ambiguous message that could be mistaken for a real test bug. This is the
  CI-workflow analogue of the "runner cannot lie" principle: if a
  prerequisite is missing, the job dies with an unambiguous reason before
  any test suite even starts.
- Kept the brief's macOS `brew install jq` step even though web research
  says jq is preinstalled on GH-hosted Windows/Linux runners and likely
  macOS too — `brew install` when already-installed exits 0 with a warning,
  so this is a safe no-op if redundant, and removes the assumption entirely
  if the manifest ever changes.

## Fixes required before CI could be trusted (the "find and fix" half of the task)

### Python 3.9 import-time failures (PEP 604 union syntax)

Full sweep of `scripts/*.py` and `scripts/lib/*.py` for `from __future__ import
annotations`:

| File | Had future import? | Uses `X \| None` etc.? | Action |
|---|---|---|---|
| `scripts/index-session.py` | No | Yes (`-> str \| None`, line 115) | **Added** |
| `scripts/skill-lifecycle.py` | No | Yes (`-> int \| None` ×2, lines 62/73) | **Added** |
| `scripts/coach-export-read.py` | No | No | Left as-is |
| `scripts/coach-rules-eval.py` | No | No | Left as-is |
| `scripts/coach-signals.py` | No | No | Left as-is |
| `scripts/inject-agents-md.py` | No | No | Left as-is |
| `scripts/scan-threats.py` | No | No (only `\|` inside regex string literals) | Left as-is |
| `scripts/persist-proposal.py` | Yes (pre-existing) | Yes | No change |
| `scripts/lib/paths.py` | Yes (pre-existing) | Yes | No change |
| `scripts/lib/proposal_schema.py` | Yes (pre-existing) | Yes | No change |

Verification method, in order of rigor:
1. Static grep for `->`/`:` followed by `|` — caught the two real cases plus
   false positives in `scan-threats.py`'s regex strings.
2. `ast.parse()` under Python 3.13 — insufficient, since `X | None` parses
   fine as a `BinOp`; the failure is only at *runtime evaluation* of
   annotations, not at parse time.
3. **Built a real Python 3.9.24 interpreter via `pyenv install 3.9.24`**
   (network was available; build completed in under a minute) and
   `exec()`'d every `scripts/*.py` and `scripts/lib/*.py` file as a module
   (not run as `__main__`, so CLI side effects didn't fire). Before the fix,
   `index-session.py` and `skill-lifecycle.py` failed with
   `TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'`;
   every other file imported clean. After adding the future import to those
   two, all ten files import clean under real 3.9.24.
4. **Ran all 5 `tests/test-*.py` suites under the real 3.9.24 interpreter**
   (not just import — full test execution): all 5 pass, same test counts as
   under 3.13 (4, 7, 14, 16, 53 tests respectively). This is the highest-
   confidence verification available short of actual CI, and it's real, not
   simulated.

Followed the brief's instruction to fix via `from __future__ import
annotations` (matching `paths.py`/`proposal_schema.py`) rather than
rewriting to `Optional[...]` — placed directly after each file's module
docstring, before other imports, matching existing style.

### macOS/BSD portability sweep

Swept `scripts/` and `tests/` for the flag classes named in the brief
(`stat -c`, `readlink -f`, `sed -i` without suffix, `grep -P`, `date -d`,
`timeout`, `mktemp` without template, GNU-only `find` predicates) plus
`echo -e`, `getopt`, `xargs -I`, `find -newermt`/`-printf`, non-portable
shebangs. Findings and fixes:

- **`scripts/self-learning-health.sh:171`** — `stat -c %Y` (GNU-only). Fixed
  to try `stat -c %Y` then fall back to `stat -f %m` (BSD/macOS), matching
  the brief's exact guidance.
- **`date -d "$ts" +%s`** (GNU-only, not in the brief's named list but
  explicitly called out as a class to sweep for) — found in
  `scripts/curator-run.sh` (×2) and `scripts/turn-counter.sh` (×1), all
  parsing timestamps written by this project's own `date -Iseconds` calls.
  Fixed by adding `sl_iso_to_epoch()` to `scripts/lib/config.sh` (the shared
  bash lib already sourced by all three call sites) — tries GNU `date -d`,
  then BSD `date -j -f`, then a `python3` fallback (stdlib only, already a
  hard project dependency), returning `0` on total failure to preserve the
  previous `|| echo 0` behavior. Chose a shared function over three
  independent inline fixes for DRY, since a fourth or fifth caller is
  plausible and per-callsite branching would drift.
- **`date -Iseconds`** — not named in the brief, but the *same GNU-only
  class* (`-I`/`--iso-8601` is a GNU date extension absent from BSD/macOS
  date entirely, would error outright on macOS). Found and fixed in
  `scripts/session-review.sh`, `scripts/curator-run.sh` (×4),
  `scripts/turn-counter.sh` (×2), `scripts/sync-coach-rules.sh` (×1) — all
  replaced with `date -u +%Y-%m-%dT%H:%M:%SZ`, which is plain strftime
  formatting supported identically by GNU and BSD date. This is the
  producer side of the `date -d` consumer fix above: both had to change
  together since `sl_iso_to_epoch` only needs to parse one known format,
  and that format must actually be portable to produce.
- **No occurrences found** of: `readlink -f`, `sed -i` without a suffix,
  `grep -P`, `timeout` (as a shell command — one docstring mention and one
  Python `subprocess.run(timeout=...)` kwarg, both fine), `mktemp` without
  a template (all uses are `mktemp -d`, portable on GNU and BSD), GNU-only
  `find` predicates, `echo -e`, `getopt`, non-`#!/usr/bin/env bash`
  shebangs.

All fixes used `sed -i.bak ... && rm -f *.bak` (suffix provided, then
deleted) for the bulk `date -Iseconds` replacements — never bare `sed -i`.

## Runner-cannot-lie proofs (all four required by the brief)

Ran against the real `tests/run-all.sh`, from `/home/amardeep/claude-self-learning/.claude/worktrees/hnp`.

**1. Empty directory / glob matches nothing.** Copied `run-all.sh` into an
isolated `tests/` dir with no test files:
```
Discovered 0 suite(s): 0 shell, 0 python. Ran 0.
FAIL: discovered zero test suites under tests/test-*.sh or tests/test-*.py. ...
EXIT=1
```
Confirmed: FAILS, does not report success.

**2. Deliberately failing suite, then removed.** Added
`tests/test-zz-deliberate-fail.sh` (`echo ...; exit 1`) to the real repo,
ran the real runner, then deleted the file:
```
Discovered 18 suite(s): 13 shell, 5 python. Ran 18.
FAILED (1/18):
  - tests/test-zz-deliberate-fail.sh [exit 1]
EXIT=1
```
All other 17 suites still ran (loop did not stop early). File removed
afterward; `git status --porcelain` confirmed no leftovers.

**3. Suite exits non-zero with zero output.** Added
`tests/test-zz-silent-fail.sh` (`exit 1`, no echo at all), ran, removed:
```
FAILED (1/18):
  - tests/test-zz-silent-fail.sh [exit 1]
EXIT=1
```
Confirmed: caught purely via exit code, independent of stdout/stderr
content.

**4. Python suite whose import dies before any test runs.** Added
`tests/test-zz-broken-import.py` (`import
this_module_does_not_exist_anywhere` at module level, before any
`unittest` class or `if __name__` guard), ran, removed:
```
=== tests/test-zz-broken-import.py ===
Traceback (most recent call last):
  ...
ModuleNotFoundError: No module named 'this_module_does_not_exist_anywhere'
FAIL: tests/test-zz-broken-import.py (exit 1)
EXIT=1
```
Confirmed: counted as a failure, not a skip — no test inside the file ever
ran, and the runner correctly attributes this as a suite failure.

All four temp files (`test-zz-*`) were deleted after their proof; final
`git status --porcelain` shows none present.

## What was verified locally vs. what only CI can verify

**Verified locally (high confidence):**
- All 17 real suites (12 shell + 5 python) pass under the current
  interpreter (3.13.12) on Linux.
- All 5 Python suites pass under a **real Python 3.9.24** interpreter
  (built via `pyenv install 3.9.24`, not simulated) — this is the strongest
  evidence available that the 3.9 compatibility claim holds, not just for
  the two files with the known bug but for the whole `scripts/` tree
  (verified by import-executing every `.py` file under 3.9.24 directly).
- `tests/test-install-paths.sh` and `tests/test-uninstall.sh` (which run
  real `install.sh`/`uninstall.sh`) pass under `env -i` + temp
  `HOME`/`AGENT_LEARNING_HOME` isolation, as they did before this task —
  confirmed no regression from the portability edits.
- `.github/workflows/ci.yml` parses as valid YAML (via PyYAML, used only
  for validation, not a project runtime dependency) and the top-level
  structure (`on`/`jobs`/`matrix`/`steps`) matches intent after fixing the
  `on:` boolean-key gotcha.
- The bash portability fixes (`sl_iso_to_epoch`, `date -u +%Y-%m-%dT...Z`,
  `stat -c || stat -f`) were reasoned from GNU/BSD man-page differences and
  confirmed not to break existing Linux test assertions, but **were not
  executed against a real BSD/macOS `date`/`stat`** — no macOS environment
  was available in this sandbox.
- The Windows `python3` shim and `choco install sqlite` steps were derived
  from web research (GitHub issues, chocolatey package docs) confirming the
  underlying gaps, but **the workflow has not been run on an actual
  windows-latest runner** — that requires an actual push, which is outside
  this task's authority.

**Could NOT verify locally — matrix cells to watch on first push:**
- **`windows-latest` × 3.9 and windows-latest × 3.13`** — the `python3`
  shim step, `choco install sqlite`, and Git-Bash behavior of every script
  are reasoned-about, not executed. This is the least-tested cell.
- **`macos-latest` × 3.9 and macos-latest × 3.13`** — the `stat -f %m`
  fallback and `date -u +%Y-%m-%dT%H:%M:%SZ` portability were not run
  against real BSD `date`/`stat`; they're standard POSIX-ish invocations
  documented to work on both, but unexecuted here.
- Whether Python's *bundled* `sqlite3` module (used by
  `scripts/index-session.py`, separate from the `sqlite3` CLI) has FTS5
  compiled in on the `setup-python`-provided interpreters for all
  OS/version combinations — existing tests exercise this only on this
  machine's interpreter. If FTS5 is missing on some runner's Python build,
  `tests/test-script-paths.sh`'s index-session assertions would fail; this
  is a pre-existing risk from earlier tasks, not something task 8
  introduced, but CI is the first thing that would expose it.
- `ubuntu-latest` × 3.9/3.13 is the closest to this dev environment and is
  the highest-confidence cell, but was not run in an actual GitHub Actions
  container (only locally, same OS family).

## Concerns

- The Windows `python3` shim (copying `python.exe` to `python3.exe`) is a
  workaround for an upstream `actions/setup-python` limitation, scoped to
  the CI job only — it does not touch how end users install this project on
  real Windows machines (that's `install.ps1`, out of this task's scope,
  and presumably has its own handling since it already exists in the repo).
  Worth confirming `install.ps1` doesn't have the same latent `python3`
  assumption, but that's a pre-existing file this task did not touch.
- `choco install sqlite` pulls from the Chocolatey community repository at
  CI time — a external-network dependency for the Windows jobs specifically
  (Ubuntu/macOS jobs have no such step). If Chocolatey's CDN has an outage,
  those two matrix cells would fail for reasons unrelated to this project's
  code. No safer alternative was available without vendoring a Windows
  sqlite3 binary into the repo, which seemed disproportionate.
- `sl_iso_to_epoch`'s python3 fallback adds a second, slower path if native
  `date -d`/`date -j -f` both fail for some unanticipated reason (e.g. a
  locale quirk) — acceptable since these call sites are rate-gated
  operations (curator idle checks, review-retrigger cooldowns), not hot
  paths.

## Commit

Files changed: `tests/run-all.sh` (new), `.github/workflows/ci.yml` (new),
`scripts/index-session.py`, `scripts/skill-lifecycle.py`,
`scripts/lib/config.sh`, `scripts/self-learning-health.sh`,
`scripts/session-review.sh`, `scripts/curator-run.sh`,
`scripts/turn-counter.sh`, `scripts/sync-coach-rules.sh`.

`bash tests/run-all.sh` → `All 17 suites passed.` / exit 0.
`git status --porcelain` → only the files above (plus this report).

---

## Fix round 1

Review verdict was Spec ✅ / Approved with two Important findings and one
Minor, all closed here.

### Important 1 — `sl_iso_to_epoch` had zero test coverage

**New tests added:**

- `tests/test-config.sh` — 10 new direct unit assertions for
  `sl_iso_to_epoch`: `Z`-suffix, explicit `+00:00` offset, non-UTC `+05:30`
  offset, fractional seconds, `TZ=America/New_York` non-interference,
  `TZ=Asia/Kolkata` non-interference, empty-input sentinel, garbage-input
  sentinel, a real epoch-adjacent timestamp distinguishable from the
  sentinel (`1970-01-01T00:00:01Z` → `1`, not `0`), and a round-trip against
  the repo's own writer format (`date -u +%Y-%m-%dT%H:%M:%SZ`, captured
  live and asserted to land within the actual before/after wall-clock
  window rather than a hardcoded value, since "now" isn't fixed). Expected
  epochs for the fixed-timestamp cases (`1718454896` for
  `2024-06-15T12:34:56Z` and its equivalents) were computed independently
  via `date -u -d ... +%s` and cross-checked with Python's
  `datetime.timestamp()` — hardcoded as literals, not derived from the
  function under test.
- `tests/test-turn-counter.sh` — 2 new end-to-end assertions exercising the
  turn-counter cooldown gate (the actual caller of `sl_iso_to_epoch` at
  `scripts/turn-counter.sh:146`) with a real, non-empty `last_review_at`:
  case 5 seeds a `last_review_at` a few seconds in the past and asserts the
  review signal is suppressed (cooldown holds); case 6 seeds one from 2020
  and asserts the signal fires (cooldown has expired). Case 5 is the one
  that specifically catches the "everything looks infinitely stale"
  failure mode described in the review — case 6 exists so a
  gate that is simply broken in the *other* direction (always suppresses)
  can't hide behind case 5 alone.

**Mutation test A — reviewer's exact mutation (stub the function to
`echo 0; return 0`):** applied to `scripts/lib/config.sh`, then ran both
suites:
- `tests/test-config.sh`: 8 of the 10 new assertions FAILED (the two
  sentinel-return assertions for empty/garbage input still passed, correctly,
  since `0` is their expected value — that's the sentinel-vs-real-zero
  assertion doing its job, distinguishing "correctly returns 0" from
  "always returns 0").
- `tests/test-turn-counter.sh`: case 5 (recent-timestamp-suppresses) FAILED
  as expected; case 6 (stale-timestamp-fires) still passed by coincidence
  (2020 read as epoch 0 is still "stale", so the gate still fires) — this
  is why case 5, not case 6, is the mutation-sensitive half of the pair.
- File restored via `diff` against a pre-mutation copy; confirmed byte-identical, then confirmed both suites pass again.

**Mutation test B — sign/offset mishandling:** inserted
`ts="${ts%[+-][0-9][0-9]:[0-9][0-9]}"` at the top of `sl_iso_to_epoch` (a
plausible real bug: someone "normalizing" the input by stripping what looks
like a trailing offset, without realizing it changes the represented
instant for any *non-zero* offset). Result: exactly one assertion failed —
`sl_iso_to_epoch: non-UTC +05:30 offset` (expected `1718454896`, got
`1718474696`, a 5.5-hour/19800-second drift matching the stripped offset
exactly). The `Z`-suffix, `+00:00`, and fractional-seconds assertions all
still passed, because none of those inputs contain a non-zero offset for
the mutation to corrupt — confirming the non-UTC-offset assertion is doing
real, distinct work, not just duplicating the `Z`-suffix case. File
restored and re-verified clean afterward.

Both mutations were applied to a temporary copy comparison (`cp
scripts/lib/config.sh /tmp/config.sh.orig` beforehand) and the restore was
verified with `diff` before re-running the full suite.

### Important 2 — no per-suite timeout in `tests/run-all.sh`

**Mechanism added** (`tests/run-all.sh`): a `run_with_timeout()` helper
that:
1. Feature-detects `timeout` (GNU/Linux, and Windows Git Bash which bundles
   GNU coreutils), then `gtimeout` (Homebrew coreutils on macOS), and if
   neither exists, runs the suite **unwrapped** with four `WARNING:` lines
   to stderr every single run — not a one-time or silent degrade — stating
   protection is disabled and how to restore it.
2. Runs the suite as a backgrounded job under `set -m` (job control enabled
   explicitly, since it's off by default in non-interactive scripts). This
   gives the job its own process group (pgid == its pid), which is what
   makes the next step able to reach grandchildren the suite spawned and
   left running, not just the direct child.
3. After `wait`, unconditionally sends `TERM` then (after a 0.2s grace
   period) `KILL` to the negative pid (the whole process group) — a
   best-effort no-op in the overwhelming majority of cases where the group
   is already gone, but the actual cleanup mechanism when something is left
   behind.
4. Distinguishes a timeout (`timeout`'s exit 124, or 137 if `--kill-after`
   escalated to `SIGKILL`) from an ordinary non-zero exit via a global
   `TIMED_OUT` flag — deliberately not via bash 4.3+ negative array
   indexing, because stock macOS ships bash 3.2, which lacks it; this
   script needs to stay 3.2-compatible everywhere else in it already.

**Per-suite limit:** `RUN_ALL_SUITE_TIMEOUT`, default **120s**. Measured
headroom: the slowest suite locally is `test-copilot-session-review.sh` at
~3.1s (`tests/test-config.sh` ~2.5s, `tests/test-session-review.sh` ~2.0s,
`tests/test-script-paths.sh` ~1.65s, everything else under 1s); the real
`install.sh` run in `test-install-paths.sh` was 571ms locally. 120s is
~39x the slowest observed suite — generous enough to absorb a much slower
CI runner (Windows/macOS cold starts, disk-bound `install.sh`) without
flaking, while still bounding a hang to a small fraction of the CI job
budget instead of the full timeout.

**Verification — the `sleep 300` experiment:**
1. Added `tests/test-zz-hang.sh` (`echo ...; sleep 300; echo "should never
   print"`).
2. Ran with `RUN_ALL_SUITE_TIMEOUT=5 bash tests/run-all.sh` wrapped in an
   outer `timeout 30` as a safety net for the experiment itself.
3. Result: runner exited after ~5s (not 30s, not 300s), non-zero (`exit
   1`), with `FAIL: tests/test-zz-hang.sh (exit 124 — timed out after 5s
   and was killed)` and the suite named in the final `FAILED` block as
   `tests/test-zz-hang.sh [timeout 5s]`. The run then continued through all
   remaining suites (18 discovered/ran total) rather than stopping.
4. Orphan check: `ps aux | grep "sleep 300"` and `ps aux | grep
   "tests/test-zz-hang"` both matched nothing after the run — no leftover
   process. (The suite's `sleep 300` was a direct foreground child, so this
   mainly exercises the `timeout --kill-after` path; the process-group
   sweep in step 3 of the mechanism is the backstop for the harder case of
   a suite that backgrounds a child and exits, which wasn't independently
   reproduced but is the documented reason `set -m` + group-kill was used
   instead of a single-pid kill.)
5. `tests/test-zz-hang.sh` removed afterward; confirmed absent via `ls
   tests/test-zz*` (no match) and `git status --porcelain`.

Re-ran the full suite after removing the temp file: 17 discovered/ran,
`All 17 suites passed.`, exit 0, ~17.4s wall time (`time bash
tests/run-all.sh`) — confirms the timeout mechanism adds no meaningful
overhead to the non-hung path.

Re-ran all four original "runner cannot lie" proofs (empty glob,
deliberately-failing suite, silently-failing suite, broken Python import)
against the updated runner to confirm none regressed; all four still
produced the same FAIL/exit-1 behavior as in the original Task 8 report,
with the added suite files removed afterward in each case.

### Minor 3 — pipe swallows the exit code

Added a comment block at the top of `tests/run-all.sh` (right below the
file's main doc comment) explaining that CI invokes the script directly, so
its exit code is checked correctly, but piping it (e.g. `| tee log`)
without the caller's shell setting `set -o pipefail` would silently report
success on a failed run.

### Verification before reporting back

- `bash tests/run-all.sh`: `All 17 suites passed.`, exit 0 — same 17 (12
  shell + 5 python) as before this round; no suite count drift.
- All 5 Python suites re-run under the real Python 3.9.24 interpreter
  (built in the original round via `pyenv install 3.9.24`): all 5 still
  pass with identical test counts (4, 7, 14, 16, 53). No new Python code
  was added in this fix round (the new tests are bash, in
  `tests/test-config.sh` and `tests/test-turn-counter.sh`), so this is a
  confirmation re-run rather than a new risk area, but it was run anyway
  per the coordinator's instruction since new test code is exactly where a
  fresh `X | None` could slip in.
- `git status --porcelain` after cleanup: only `tests/run-all.sh`,
  `tests/test-config.sh`, `tests/test-turn-counter.sh` modified (plus this
  report, which lives under a gitignored path). No stray `test-zz-*` files,
  confirmed via `ls tests/test-zz*` (no match) after each experiment.
  `ps aux` grep for leftover `sleep 300` / `test-zz-hang` processes: no
  match.

### Remaining concerns after this round

- The process-group timeout-cleanup path (step 3 of the mechanism) was
  exercised only indirectly — the `sleep 300` reproduction was a direct
  foreground child, which `timeout --kill-after` alone would have handled
  even without the `set -m` process-group sweep. A suite that specifically
  backgrounds a child and exits before the timeout would be a stronger
  reproduction of "child outlives the kill," but wasn't attempted
  separately since the review's own report already established that
  scenario as the motivating case; the mechanism added (group-kill via
  negative PID) is the standard fix for it.
- `set -m` (job control) in a non-interactive script is correct bash
  behavior on Linux and macOS bash (including the 3.2 default on macOS),
  but its interaction with process groups under Windows Git Bash (MSYS2)
  is unverified locally — this is on the same "unverified matrix cells"
  list as the rest of the Windows job from the original round.
- The 120s per-suite default is a judgment call, not a measured CI-runner
  number (no access to actual GitHub-hosted runner timing). If Windows or
  macOS CI turns out to need more (e.g. a slow `choco install` warm-up
  bleeding into test time, which it shouldn't since that happens in a
  separate workflow step before `tests/run-all.sh` runs), `RUN_ALL_SUITE_TIMEOUT`
  is a one-line override.
