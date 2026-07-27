# Fix round C report — the verification gate itself

Branch: `harness-neutral-persistence`. Builds on round A (`6316e4f`) and round B (`4432883`).
This is the last of three rounds fixing findings from the whole-branch final review
(NO-GO for merge). Every finding in scope was, in one way or another, a diagnostic or
document that told the user things were fine when they were not — the exact
exit-0-while-wrong pattern this project exists to eliminate, one layer up: the gate
that is supposed to catch it.

## What changed and why

### C3 (Critical) — `self-learning-health.sh` reported HEALTHY with the writer deleted

`REQUIRED_SCRIPTS` (scripts/self-learning-health.sh) omitted `persist-proposal.py`,
`lib/proposal_schema.py`, `copilot-session-review.sh`, and `doctor.sh`. Reproduced the
review's exact scenario: copy a full install, `rm persist-proposal.py
lib/proposal_schema.py`, run health — confirmed `Status: HEALTHY`, exit 0, before the fix.

Fix: added the four entries, **and** added a new "Persistence Writer Self-Check" section
that actually *runs* `persist-proposal.py --dry-run` (an existing, already-safe flag —
validates and plans a write but performs none) against a canned schema-valid proposal,
with `AGENT_LEARNING_HOME` overridden to a throwaway `mktemp -d` for that one subprocess
call, removed immediately after. A file-existence check cannot catch `proposal_schema.py`
being present-but-corrupt; this does, because the broken import surfaces as a non-zero
exit from the actual writer.

**Mutation results** (`tests/test-health-writer-self-check.sh`):
- Broke: deleted `persist-proposal.py` + `lib/proposal_schema.py` (the review's exact
  repro). Before fix: `Status: HEALTHY`, exit 0. After fix: exit 1, both files individually
  reported `missing`.
- Broke: left both files present but overwrote `lib/proposal_schema.py` with
  `this is not valid python at all !!! %%%%` (syntactically invalid — proves the self-check
  actually imports the module, not just stats the file). Before fix (REQUIRED_SCRIPTS alone,
  no self-check): would have reported HEALTHY, since existence checks pass on a corrupt
  file. After fix: exit 1, `writer self-check failed (persist-proposal.py exited 1)`.
- Verified the self-check never touches the real store: after a full healthy run,
  `${STORE}/memory/MEMORY.md` does not exist.
- One implementation bug caught by this same TDD pass, not by review: the first version of
  the self-check captured `python3 ... --dry-run`'s exit status via
  `SELF_CHECK_OUT="$(...)"; SELF_CHECK_RC=$?`, which is wrong under this script's
  `set -e` — a failing command substitution assigned to a variable is itself a failing
  simple command, so `set -e` aborted the whole health check silently at that line,
  before `fail()` ever ran, on the corrupt-schema mutation. Fixed to
  `SELF_CHECK_OUT="$(...)" || SELF_CHECK_RC=$?`.

Related — **deferred minor 11**: `self-learning-health.sh` checked only Claude Code's hook
registration; only `doctor.sh` (a secondary, opt-in tool) checked Copilot's. Added a
"Hook Registration (Copilot CLI)" section mirroring the Claude Code one exactly (same
`sl_check_hook_fresh()` shared helper, same fresh/stale/missing verdicts, absence is a WARN
never a FAIL). `tests/test-health-copilot-hooks.sh` covers: no `~/.copilot` (WARN, not FAIL),
fresh hook (PASS), stale hook (FAIL, flips exit code).

### I9 (Important) — the original defect's exact signature was invisible

Confirmed by execution: a reviewer that emits prose with no extractable JSON produces exit
0, a `persist.log` line of exactly `{"written": [], "skipped": ["no-proposal"], "bytes": 0}`,
and *nothing* in `persist-failures.log`. `doctor.sh` only ever read `persist-failures.log`,
so a run of this — byte-identical to "genuinely nothing to learn this cycle" — was
invisible.

Fix: `doctor.sh` now also reads the last 10 lines of `persist.log`, reverses them (POSIX
`sed '1!G;h;$!d'`, not `tac` — GNU-only, absent on stock macOS), and counts a *trailing*
streak of consecutive no-proposal results (a streak broken by any other outcome stops the
count — a genuine write three cycles ago followed by three empty ones is still flagged;
three empty ones followed by a genuine write is not). Threshold: **3**. Justification:
`SL_MEMORY_REVIEW_INTERVAL`/`SL_SKILL_REVIEW_INTERVAL` both default to 10 turns, so three
consecutive empty results mean the last three 10+-turn stretches of active work produced not
one memory or skill entry — for an actively-used install, that pattern is far more
consistent with broken extraction than with genuinely nothing worth learning three cycles
running. A streak this size flips doctor's exit code to 1 (not just prints text) and names
the failure mode explicitly ("byte-identical to the reviewer's output being wrapped in a way
persist-proposal.py cannot extract a proposal from").

**Mutation results** (`tests/test-doctor-persist-log.sh`): absent log → ABSENT, no fail; one
trailing no-proposal line → not flagged, exit 0; three consecutive trailing no-proposal
lines → SUSPICIOUS, exit 1; three no-proposal lines *not* at the tail (a real write more
recent) → not flagged, exit 0 (proves the streak is measured from the end, not "3+
occurrences anywhere in the window").

### Round A finding — `doctor.sh` misreported when `python3` is missing

Round A fixed this shape in `self-learning-health.sh` only; `doctor.sh`'s
`_sl_report_hooks()` was untouched and had the identical bug: with `python3` absent,
`SL_SCRIPTS_DIR` silently resolves to `""`, and `sl_check_hook_fresh()` treats an empty
`scripts_dir` as "never fresh" — so a genuinely fresh hook was reported STALE, with no
mention of `python3` anywhere.

Reproduced first (`tests/test-doctor-no-python.sh`, RED): a real fresh `turn-counter.sh`
hook, run with a `python3`-free PATH, printed `turn-counter.sh: STALE -- ... does not point
at /turn-counter.sh` (the empty-`scripts_dir` tell). Fixed by guarding both the Claude Code
and Copilot hook-reporting blocks in `doctor.sh` on a `_SL_PYTHON3_AVAILABLE` flag set once
near the top, printing the same "cannot verify hook freshness -- python3 not found on PATH"
message `self-learning-health.sh` already used, and setting `STATUS=1`. Test now green;
confirms the fresh hook is never misreported and the real cause is named.

### I11 (Important) — the `~/.claude` source guard covered only three files, and only shell

`tests/test-script-paths.sh` previously pinned exact `~/.claude` reference counts for
`curator-run.sh`, `index-session.sh`, `self-learning-health.sh` only — no Python scripts
were ever in scope, which is exactly how C2 (`skill-lifecycle.py`) and the
`inject-agents-md.py` fallback survived to the final review.

First, an actual remaining hit was found and fixed: `scripts/coach-signals.py`'s `main()`
defaulted `SL_COACH_SIGNALS_FILE`, `SL_COACH_RULES_DIR`, and `SL_SEARCH_DB` to
`os.path.join(home, ".claude", ...)` when their env vars were unset. In real operation this
default is never exercised (`lib/config.sh` always exports all three before either reviewer
script calls this file), but it is still `~/.claude`-referencing code reachable from the
Copilot path, latent exactly the way this round's constraint forbids. Replaced with
`_paths_defaults()`, a small helper that imports `scripts/lib/paths.py` (the single
resolver) and returns `resolve_all()`, computed at most once and only if actually needed.
Verified: `env -i HOME=$TMP AGENT_LEARNING_HOME=$TMP/store SL_COACH_RULES_ENABLED=true
python3 scripts/coach-signals.py` (no other SL_* vars set) now writes
`$TMP/store/state/coach-signals.json`, never anything under `$TMP/.claude`.

Then extended the guard repo-wide over `scripts/**/*.sh` and `scripts/**/*.py` (excluding
`__pycache__`), two precise per-language patterns chosen to avoid false-triggering on the
large amount of legitimate prose in this codebase that *discusses* `~/.claude` (the whole
point of most of these files' comments is documenting why code must not go there):
- bash: `${HOME}/.claude` — actual variable-expansion path syntax; comments use the tilde
  form (`~/.claude`), which this does not match.
- python: `".claude"` — a quoted path-segment string literal, as real path-construction code
  would use.

Every hit is named individually in `BASH_CLAUDE_EXEMPTIONS`/`PY_CLAUDE_EXEMPTIONS` (plain
indexed `"path|reason"` arrays, no associative arrays or namerefs — bash 3.2 on stock macOS
has neither), matching `test-install-paths.sh`'s `INSTALL_EXEMPTIONS` style. Final,
re-verified exemption list (three bash, one python):
- `index-session.sh` — `SESSIONS_DIR`, Claude Code's own transcript source, read-only.
- `self-learning-health.sh` — `SETTINGS_FILE`, Claude Code's own hook config, read-only.
- `doctor.sh` — `CLAUDE_SETTINGS`, same as above, gated behind `command -v claude`. **This
  one was not previously in the narrow list at all** — the old test never covered
  `doctor.sh`.
- `scripts/lib/paths.py` — `legacy_home()`, detect-only, never read from or written to.

Also removed one docstring false-positive: `coach-signals.py`'s new helper originally quoted
`".claude"` in prose describing the old bug, which the new grep pattern would (correctly, if
uselessly) flag; reworded to describe it without the literal quoted form.

**Mutation results**:
- Appended a `def _mutated_bad_default(): return ".claude"` to `coach-rules-eval.py` (a
  script with zero real exemption need) → guard FAILed, named the exact file, gave the
  exact instruction to add it to `PY_CLAUDE_EXEMPTIONS` or fix it. Reverted.
- Appended a `BAD="${HOME}/.claude/whatever"` comment line to `turn-counter.sh` → guard
  FAILed identically on the bash side. Reverted.
- Full suite re-run clean after both reverts.

### Round B finding — `curator-run.sh`'s `TRANSITION_LOG` empty-check branch

Determined by execution, not inspection, per the instruction: ran
`skill-lifecycle.py` both against a real `.usage.json` and against `{}`/absent — in every
case `run_lifecycle()` returns a non-empty string (either the `"Lifecycle summary:
checked=... "` line, always appended, or `"No .usage.json found. Nothing to do."` when no
usage file exists at all). `curator-run.sh`'s own `else` branch (`skill-lifecycle.py`
missing) sets a non-empty `"[WARN] No skill-lifecycle script found"` too. There is no
reachable path on which `TRANSITION_LOG` is the empty string. **Dead code** — removed the
`if [[ -z "$TRANSITION_LOG" ]]; then echo "_No transitions this cycle._"` branch, with a
comment recording the execution-based determination for future readers, rather than leaving
an unreachable "fix".

### I10 (Important) — doc claims that no longer matched the tree

**`CLAUDE.md:3-13`** — replaced the "WORK IN PROGRESS, Task 7, `BASE = a934cb3`" resume
banner (stale: all 10 tasks are complete and three fix rounds have landed since) with an
accurate short status pointing at the handoff doc (now explicitly labeled historical) and
the `.superpowers/sdd/.../` ledger + fix-round reports, plus the two things that are
genuinely still open (no green Windows/macOS CI run observed; Copilot live end-to-end
pending). Checked for other files referencing the banner or the handoff doc by name before
editing (`grep -rln` across `*.md`) — only `CLAUDE.md` itself did, so nothing else needed
reconciling.

**`CLAUDE.md:45`** (commit count) — `git rev-list --count befd131..HEAD` → **32**, not 63.
Rather than hardcode 32 (which drifts on this round's own commits, immediately making itself
wrong), replaced the claim with the command to run, per the "a number that drifts every
commit is a liability" instruction. Same treatment for the "18 suites (13 shell, 5 Python)"
line at `CLAUDE.md:25` — now 21 shell + 5 python = 26 after this round's four new test
files, and would already have been wrong the moment this round landed; replaced with
"discovered by glob, run `bash tests/run-all.sh` for the current total."

**`CLAUDE.md:53` / `README.md`'s Roadmap and Agent-compatibility tables** — verified via
`gh run list --branch harness-neutral-persistence` + `gh run view <id>`: CI *has* run once
on this branch (run `30147396824`, triggered ~06:22:54Z, i.e. **before** round A's commit at
~06:52:15Z / 12:22:15 IST — so it reflects pre-round-A code). Result: `ubuntu-latest` green
on both Python versions; `windows-latest` and `macos-latest` red on both Python versions.
Updated every place that claimed "no CI run has ever executed" (false) or implied Windows
support was verified/"done including Windows support" (false — implemented and
reasoned-about, not observed passing) to state exactly this: one run happened, it was red on
Windows/macOS, round A addressed the causes identified from it, and **no subsequent run has
been observed** — so Windows/macOS remain unverified, not proven fixed. Per instruction, I
did not claim anything passes on Windows/macOS; that is for the next CI run to confirm.

**README.md's compatibility table**:
- Windows row: was "reasoned-about, not observed" for both harnesses (defensible but stale
  now that a real run exists) — replaced with the actual CI result (which jobs failed, that
  round A addressed the identified causes, that no re-run has been observed).
- Coach signals (Routes A/B) row: verified rather than assumed. Read
  `scripts/session-review.sh` and `scripts/copilot-session-review.sh`: both call
  `coach-signals.py`, then (if the signals file exists and is <7 days old) append a "Coach
  signals" section built from it directly into `REVIEW_PROMPT` before spawning the reviewer
  — genuinely wired end-to-end, not just evaluated and discarded. Confirmed
  `tests/test-session-review.sh` has a live assertion for this ("coach signal id reaches
  prompt", checking the fake `claude` binary's captured invocation actually contains the
  signal id) and that it currently passes. The ✅/✅ claim is accurate as of this round;
  strengthened the Notes column to say *why* (the prompt-injection mechanism) and cite
  `test-session-review.sh` alongside the two existing citations, rather than leave the
  row's earlier I5-era doubt unresolved in the text.

### M14 (Minor) — `install.sh` treated a missing script as a warning

`install.sh:211` printed `[WARN] Script not found` for any `SCRIPTS[]` entry missing from
the source tree and continued, exiting 0 — a broken install (the writer or anything it
imports, silently absent) reported success. Reproduced first: copied the whole install
source tree to a temp dir, deleted `scripts/persist-proposal.py`, ran `install.sh` for
real — confirmed exit 0 despite the omission (`tests/test-install-paths.sh`, RED). Fixed:
now prints `[FAIL]` plus a two-line fatal error naming the exact missing path and `exit 1`
immediately. Verified fixed (exit 1, error names `persist-proposal.py`); existing
install-paths assertions (idempotent second run, no `~/.claude`, hook config) still pass —
the fatal path is only reached when a script genuinely does not exist.

### M13 (Minor) — `sl_check_hook_fresh`'s unanchored match

`grep -qF -- "${scripts_dir}/${script_name}"` in `scripts/lib/config.sh` is a plain
substring match with no end-of-match boundary, so a hook pointing at
`.../turn-counter.sh.bak` read as fresh (the resolved path is a literal prefix of the
`.bak` filename). Reproduced first in `tests/test-config.sh` (RED: expected `stale`, got
`fresh`). Fixed: the literal path is now regex-escaped (`sed` on the standard metachar
class) and matched with `grep -E` requiring the match be followed by `$` (end of line) or a
character that cannot continue a filename (`[^A-Za-z0-9_./-]` — i.e. a quote or
whitespace). Both consumers (`doctor.sh`, `self-learning-health.sh`) share this one
function, so the fix applies to both at once, per the file's own design intent. Verified:
`.bak` case now `stale`; an exact match still `fresh`; a match followed by a flag/space
(`turn-counter.sh --verbose`) still `fresh` (proves the fix only rejects the *continuation*
case, not real hook commands with trailing arguments). Existing `test-doctor.sh` fresh/stale
assertions (which exercise real hook JSON, not synthetic edge cases) still pass unchanged.

### M12 (Minor) — turn-counter.sh's documented <50ms target

Measured on this machine, 5-6 runs each, `date +%s%N` wall-clock around the full hook
invocation (stdin JSON piped in, `AGENT_LEARNING_HOME` pointed at an empty temp store):

- With a **native python3 binary** directly on PATH: 50-68ms (mean ~63ms). Matches the
  round's stated 58-62ms baseline.
- With this machine's **pyenv shim** in front of python3 (its normal `PATH` state):
  130-157ms. Isolated the cause: `python3 -c 'pass'` direct-binary vs. pyenv-shim timing
  showed the shim itself costs ~85ms per invocation (22-25ms real interpreter startup vs.
  108-112ms through the shim) — an environmental artifact of this dev machine, not this
  project's code; noted but not used as the basis for the target.
- Isolated the dominant real cost: `python3 scripts/lib/paths.py all` alone (the one
  subprocess `lib/config.sh` spawns per hook invocation) is ~22-25ms with a native
  interpreter.

Decision: **amended the target** from <50ms to <100ms (matching the general hook budget the
same sentence already states), rather than attempt caching. Considered caching the resolved
paths across hook invocations (e.g. a state-file cache keyed by env) to close the ~15-18ms
gap, and rejected it for this round: a stale cache that outlives a change to
`AGENT_LEARNING_HOME`/`XDG_DATA_HOME` is exactly the silent-wrong-location defect class this
project exists to eliminate, and the savings (turn-counter would still be single-digit-ms
away from 50ms even after removing the whole python3 spawn) do not justify introducing that
risk. `CLAUDE.md:38` now documents the actual measured range and the reasoning, instead of a
number the code was already known to miss.

## Full-suite status

`bash tests/run-all.sh`: **26/26 suites pass** (21 shell + 5 python; was 22 at the start of
this round — 4 new files: `test-doctor-no-python.sh`, `test-doctor-persist-log.sh`,
`test-health-writer-self-check.sh`, `test-health-copilot-hooks.sh`). One pre-existing test
(`test-doctor.sh`) needed a scoping fix, not a behavior change: its "empty
persist-failures.log is not reported as ABSENT" assertion grepped the *entire* doctor.sh
output, which now legitimately contains "ABSENT" for the unrelated, correctly-absent
`persist.log` (I9's new section) in that same scenario — narrowed the assertion to the
`persistence failures` section specifically.

## Remaining exit-0-while-wrong pattern instances found

None identified beyond what's fixed above, within this round's scope. Two things
deliberately left alone as out of scope, flagged here rather than silently skipped:
- `curator-run.sh`'s `TRANSITION_LOG` capture still swallows a `skill-lifecycle.py` crash
  via `|| true` on the `$(...)` — if the script traceback'd instead of returning a summary,
  `TRANSITION_LOG` would contain the traceback text (which is non-empty, so it would still
  get written into the report, just as an ugly one) and the curator run continues rather than
  failing loudly. Not the finding assigned this round (which was specifically about the
  now-removed empty-string branch), noting it as a candidate for a future round rather than
  fixing unassigned scope.
- doctor.sh's persist.log section only counts a *streak of the specific string*
  `"skipped": ["no-proposal"]`; a reviewer emitting a validation-error proposal that fails
  `validate_proposal()` (exit 1, nothing to stdout, only appended to `persist-failures.log`)
  is still fully covered by the existing persist-failures.log section — not a gap, just
  worth stating explicitly that the two sections are complementary, not overlapping.

## Commits

1. `fix:` — C3, I9, round-A doctor.sh finding, I11, round-B curator finding, M12-code-adjacent
   pieces, M13, M14 (code + tests together, TDD pairs).
2. `docs:` — I10 (CLAUDE.md, README.md) and M12's CLAUDE.md target amendment.

`git status --porcelain` after both commits shows only the intended file set (verified
before committing); `.superpowers/` remains untracked in this repo's history (round A/B fix
reports live there too, also uncommitted — consistent with existing project convention, not
a gap introduced by this round).
