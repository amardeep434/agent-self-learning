# Task 9 report: scripts/doctor.sh

## Status

DONE. Commit `92f3c47`.

## What was implemented

`scripts/doctor.sh` (executable, sources `scripts/lib/config.sh`, never
reimplements path resolution) prints, in order:

1. **Resolved paths** — every key config.sh exposes (`home`, `memory`,
   `skills`, `state`, `logs`, `sessions_db`, `config_file`) plus `scripts`
   (obtained via `python3 scripts/lib/paths.py get scripts`, since
   config.sh does not export `SL_SCRIPTS` — see Deviations). Each is
   prefixed with **which override won** (`AGENT_LEARNING_HOME` /
   `XDG_DATA_HOME` / `LOCALAPPDATA` / default), determined by mirroring
   `paths.py`'s `resolve_home()` precedence check in bash — display only,
   the actual resolution is still 100% done by `paths.py`.
2. **Writability** — for `home`, `memory`, `skills`, `state`, `logs`:
   `mkdir -p` then create-and-remove a real temp file
   (`mktemp "$dir/.doctor-write-test.XXXXXX"`), never inferred from
   permission bits. A failure here sets exit status 1.
3. **Detected harnesses** — `claude`, `copilot`, and `code`/`~/.vscode`
   presence. When `claude` or `copilot` is present and its hook config
   file exists (`~/.claude/settings.json`,
   `~/.copilot/hooks/self-learning.json`), the file is checked for whether
   it actually references the currently-resolved scripts directory,
   flagging it `STALE` if not — the Task 7b/7c bug class. VS Code is
   reported present/absent only; its adapter isn't shipped yet (out of
   scope per the plan), so there's no hook to check.
4. **Legacy `~/.claude` store** — detected via
   `python3 -c "...; import paths; paths.legacy_home()"` (imported, not
   reimplemented, not modified). Only ever printed and given a manual
   `cp` migration hint; no code path writes, moves, or deletes anything
   under it.
5. **`${SL_LOG_DIR}/persist-failures.log`** — the load-bearing section.
   Three states, reported distinctly: **absent** (pipeline never ran, or
   ran and never failed — both stated explicitly so absence is never
   read as proof of health), **present but empty** (ran, zero failures),
   and **populated** (count + a `!!!`-bracketed unmissable banner +
   bounded tail of the last 5 entries + the most recent entry's ISO
   timestamp and age in seconds, computed via `sl_iso_to_epoch` from
   `config.sh` — no new date-parsing code). A populated log sets exit
   status 1.

Exit code: 0 unless a required dir is not writable or the failure log is
non-empty (both conditions set `STATUS=1`, combined at the end).

## Ruling on the `self-learning-health.sh` overlap

**Kept separate, not merged, not deleted, not silently duplicated.**
Both source `scripts/lib/config.sh`, which guarantees they can never
disagree on a resolved path or a knob value — that was the actual risk,
not code duplication of *echo* statements.

- `self-learning-health.sh` answers "is the install structurally
  complete" — required scripts present and executable, hook registration
  present by string match, turn-counter/`.usage.json`/search-db JSON
  validity, dependency binaries on PATH. It is the install-verification
  tool.
- `doctor.sh` answers "is the system healthy *right now*, and would I
  know if it silently broke" — resolved-path provenance, real writability
  testing (health.sh has none), harness hook **staleness** (health.sh
  only checks hooks are *registered*, never that they point at the
  currently-resolved path — that's the actual Task 7c-class bug), legacy
  store detection (health.sh has none), and `persist-failures.log`
  surfacing (health.sh has none at all — this is the capability that
  did not exist anywhere before this task).

Given zero of doctor's five required checks exist in health.sh today,
duplication risk is low; the shared `config.sh` source is what keeps them
from silently drifting apart on facts both could plausibly state.

## Deviations from the brief, with reasoning

1. **`config.sh` does not export `SL_SCRIPTS`**, despite the brief's
   interface note listing it as exported (with the caveat "verify exact
   names by reading it — do not guess"). I verified by reading it — it
   isn't there. Rather than guess or hand-roll the `scripts` path in
   bash, `doctor.sh` shells out to `paths.py get scripts` directly, the
   same pattern `config.sh` itself uses internally for every other key.
   This keeps "paths computed in exactly one place" intact without
   modifying the interface file.
2. **Wrote both files before doing the formal fail-first run**, then
   went back and executed the required TDD step explicitly: moved
   `doctor.sh` aside, ran `tests/test-doctor.sh`, confirmed every check
   failed with `exit 127` (`No such file or directory`) as the brief
   predicted, restored the file, then re-ran to green. Recorded here for
   honesty about sequencing even though the net result satisfies the
   requirement.
3. **Strengthened, never weakened, the brief's draft implementation**:
   added the override-source line, real create/remove writability testing
   (brief's draft only checked `[[ -w "$dir" ]]`, which is exactly the
   permission-bit inference this task's requirements explicitly forbid),
   absent/empty/populated distinction for the failure log (brief's draft
   only checked non-empty), bounded-tail-with-count-and-age reporting
   instead of a bare `tail -n 5`, harness hook staleness detection
   (absent from the brief's draft entirely), and VS Code presence
   detection. All additive; nothing from the brief's stated exit-code
   contract ("exit 1 when a required path is not writable") was removed
   — I extended it to also cover a non-empty failure log, since leaving
   that log's presence out of the exit code would make the "primary
   requirement" purely cosmetic.
4. **Did not fail the exit code on a stale hook config or a detected
   legacy store.** Both are printed with strong, hard-to-miss text
   (`STALE`, `*** legacy ... found ***`), but neither flips `STATUS`.
   Reasoning: the brief's exit-code contract is explicit and narrow
   ("exit 1 when a required path is not writable"); a stale hook or a
   legacy store are both *user-actionable, not urgent* states (a stale
   hook means reviews go to the wrong place, which is bad but not the
   same class of silent-data-loss the failure log represents; a legacy
   store is expected and normal on any upgraded install until the user
   migrates deliberately). Flipping exit 1 on legacy-store-detected in
   particular would make `doctor` non-zero on every single upgraded
   machine forever, which is a worse false-red than the risk of a human
   skimming past `STALE` in the text. This is a judgment call, not a
   correctness fact — flagged explicitly per the brief's instructions.

## Mutation test results (all killed, restored, verified identical)

| # | Mutation | Result |
|---|----------|--------|
| 1 | Skip the `persist-failures.log` section entirely | **Killed** — 7 assertions failed (ABSENT/EMPTY/count/timestamp/marker/bounded-tail/exit-code text all missing) |
| 2 | Report a non-writable dir as writable | **Killed** — `NOT WRITABLE` assertion and exit-code assertion both failed |
| 3 | Skip legacy-store detection (`if false; then ... fi`) | **Killed** — required tightening one assertion first (see below) |
| 4 (own) | Hardcode `${HOME}/.claude` in the resolved-paths loop (Task 7c bug class) | **Killed** — the "resolved home path does not contain /.claude" assertion fired |
| 5 (own) | `exit "$STATUS"` → `exit 0` while still printing failures | **Killed** — two exit-code assertions failed while the text assertions in the same run still passed, confirming the test checks content *and* exit code independently, not exit code alone |

Mutation 3 exposed a real vacuity in my first draft: `contains "legacy
store detected" "$OUT" "legacy"` passed even under the mutation, because
`doctor.sh` always prints the literal string `"legacy store:"` as a
section header regardless of whether anything was found. Fixed by
tightening that assertion to check for `"legacy ~/.claude store found"`
(the found-branch-only text) instead of the bare substring `"legacy"`,
paired with the existing path-content assertion. Re-ran mutation 3 after
the fix — killed correctly.

After all five mutations, `diff /tmp/doctor.sh.orig scripts/doctor.sh`
confirmed byte-identical restoration, and the full suite re-passed.

## Full-suite result

`bash tests/run-all.sh`: **18 suites discovered (13 shell, 5 python),
all 18 passed** — the 17-suite baseline at HEAD `3fa7d1f` plus the new
`tests/test-doctor.sh`.

`git status --porcelain` at commit time showed only the two intended new
files (`scripts/doctor.sh`, `tests/test-doctor.sh`); the untracked
`.superpowers/` directory predates this task's session (SDD tracking
artifacts from prior tasks) and was left untouched.

## Concerns

- The stale-hook-config check for Claude Code and Copilot CLI only runs
  when the respective binary and hook file are both present on the test
  machine; on a machine with neither, that assertion path is skipped
  rather than exercised (it did run and pass on this dev machine, which
  has `claude` installed). Worth a CI-runner check that at least one
  matrix job has `claude` or `copilot` on PATH so this isn't perpetually
  untested in CI.
- `doctor.sh`'s exit code intentionally does *not* cover stale hooks or a
  detected legacy store (see Deviation 4). If a future maintainer wants
  `doctor` usable as a hard CI gate for "hooks are correctly wired," that
  would need a separate flag (e.g. `--strict`) rather than changing the
  default exit contract, to avoid breaking the documented "exit 1 only on
  non-writable path" behavior other tooling may come to rely on.

---

## Fix round 1

Review verdict: Spec met, changes requested on five items. All five
addressed. Commit `e6bf1e3`.

### Critical 1 — `doctor.sh` was never installed

Confirmed by reading `install.sh`'s `SCRIPTS` array (~line 184-199):
`doctor.sh` was absent, so a real install never copied it — the tool
whose entire purpose is surfacing detached-pipeline failures was itself
unreachable on any real machine.

Fixed: added `"doctor.sh"` to `SCRIPTS`, and added a line to the
completion banner alongside the existing `self-learning-health.sh`
mention:
```
Diagnose state at any time (resolved paths, writability, detected
harnesses, legacy store, and any silent persistence failures):
  bash ${SL_SCRIPTS}/doctor.sh
```

### Critical 2 — structural guard against a third silent omission

This is the second time `install.sh`'s `SCRIPTS` array silently omitted
a file (Task 7b: `lib/proposal_schema.py`; Task 9: `doctor.sh` itself),
both caught only by a human reading code.

Extended `tests/test-install-paths.sh` (not a new suite) with a guard
that parses the `SCRIPTS=( ... )` block out of `install.sh` via
`sed -n '/^SCRIPTS=(/,/^)/p'` and asserts every `scripts/*.sh` and
`scripts/*.py` either appears there or in an explicit, reasoned
exemption list in the test:

```bash
INSTALL_EXEMPTIONS=(
    "sync-coach-rules.sh|maintainer-only vendoring tool; requires the gh CLI and writes into the repo checkout's vendor/coach-rules/, run from source, never from an installed store"
)
```

Used a plain `"name|reason"` indexed array with a `case` lookup instead
of `declare -A`, since stock macOS bash 3.2 (a target of this project,
per `tests/run-all.sh`'s own comments about lacking negative array
indexing) has no associative arrays.

**Mutation test**: added `scripts/zz-dummy.sh` (unregistered, unexempted)
→ `bash tests/test-install-paths.sh` failed with
`FAIL: zz-dummy.sh is neither installed by install.sh's SCRIPTS array
nor exempted in this test`. Removed the dummy → suite passed again,
`git status --porcelain` clean.

### Important 3 — `doctor.sh` and `self-learning-health.sh` disagreed on stale hooks

Reproduced the reviewer's finding: with a hook command pointing at a
stale path, `self-learning-health.sh`'s old check
(`grep -q "turn-counter" "$SETTINGS_FILE"`) matched on the script *name*
appearing anywhere in the file and reported `[PASS]`, while `doctor.sh`
(not even installed until Critical 1's fix) correctly reported `STALE`.

Fixed by extracting a single shared helper into `scripts/lib/config.sh`,
next to `sl_iso_to_epoch()`:

```bash
sl_check_hook_fresh() {
    local file="$1" script_name="$2" scripts_dir="$3"
    # prints: absent | missing | stale | fresh
}
```

Both `scripts/doctor.sh` and `scripts/self-learning-health.sh` now call
this exact function for every hook they check (Claude Code:
`turn-counter.sh`, `session-review.sh`, `index-session.sh`; Copilot CLI:
`copilot-session-review.sh` — doctor.sh only, health.sh doesn't check
Copilot hooks at all, unchanged scope). They cannot disagree about the
same file's freshness by construction, since there is only one place the
freshness logic exists.

`self-learning-health.sh`'s Check 3 was rewritten around this helper;
`stale` now produces a genuine `[FAIL]` with a fix hint, not a false
`[PASS]`. This required updating one pre-existing fixture in
`tests/test-script-paths.sh` that used a placeholder path
(`bash .../turn-counter.sh`) — under the old substring-only check that
passed, under the new freshness-aware check it correctly reads as
`STALE`. Updated the fixture to use the real resolved scripts dir
(`${STORE}/scripts/...`), which is what a real install actually
produces; this is the check getting stricter in exactly the way the
review asked for, not a weakened test.

**Regression test** (in `tests/test-doctor.sh`, section 6): runs both
`doctor.sh` and `self-learning-health.sh` against the identical
`~/.claude/settings.json` fixture, twice — once with a stale path, once
with a fresh (resolved) path — and asserts both tools produce the same
verdict each time (both flag `STALE`, neither does when fresh; and
explicitly checks `self-learning-health.sh` does NOT emit
`"turn-counter hook registered and points"` under the stale fixture,
the literal contradiction the reviewer reproduced).

**Mutation test**: made `sl_check_hook_fresh` unconditionally
`echo "fresh"`. Both `doctor: stale hook path is flagged` and
`self-learning-health: stale hook path is flagged` failed, plus the
explicit false-PASS guard fired
(`self-learning-health.sh reported turn-counter hook as fresh/registered
despite a stale path`). Restored; `diff` confirmed byte-identical.

### Important 4 — vacuous bounded-tail assertion, proven by a surviving mutation

Reproduced the reviewer's proof: the old fixture built log lines with
`printf '2020-01-0%dT00:00:00Z ...' "$((i % 9 + 1))"` over `i in 1..7`,
which produces `2020-01-02` through `2020-01-08` and **never**
`2020-01-01` — so `case "$OUT" in *"2020-01-01"*) FAIL ;; esac` was true
regardless of what `doctor.sh` printed. Confirmed independently: mutated
`tail -n 5` → `head -n 5` (prints the *oldest* five entries instead of
the newest) and re-ran the original test — all 24 assertions passed,
including the supposedly-protective one.

Fixed the fixture to emit 8 genuinely distinct dates
(`2020-01-01` .. `2020-01-07`, then "now"), and added assertions in
both directions against the tail boundary a correct `tail -n 5` produces
(`2020-01-04` .. `2020-01-07`, "now"):
- positive: `2020-01-06` (inside the correct window) must be present.
- negative: `2020-01-01` and `2020-01-02` (outside it) must be absent.

**Contrast mutation**: re-ran the `tail -n 5` → `head -n 5` mutation
against the fixed fixture. Now **fails**, as required:
```
FAIL: populated log: bounded tail includes a recent-but-not-newest entry (output did not contain '2020-01-06')
FAIL: doctor printed an entry that should have been outside the bounded tail (tail vs head regression)
FAIL: doctor printed an entry that should have been outside the bounded tail (tail vs head regression)
```
Restored; suite green again.

### Minor 5 — stale-hook detection previously depended on incidental CI state

The check was gated on `command -v claude` / `command -v copilot`
resolving on the test machine, with a silent `SKIP` otherwise — no
CI matrix job is guaranteed to have either binary, so the assertion
likely never ran in CI.

Fixed by stubbing `claude` and `copilot` (`exit 0` no-op scripts,
content irrelevant since both target scripts only ever call
`command -v` on them) into a directory prepended to `PATH` for the
hook-freshness tests in `tests/test-doctor.sh`, so the assertions run
unconditionally rather than depending on the dev machine. This same
stubbed-PATH setup is reused for both the stale and fresh regression
cases in Important 3.

### Full-suite result (after all fixes)

`bash tests/run-all.sh`: **18 suites discovered (13 shell, 5 python),
all 18 passed** (no new suite file was added; existing suites were
extended per the coordinator's instruction, so the count stayed at 18
rather than going to 19).

### All mutation results, round 1 fixes (summary)

| Mutation | Result |
|---|---|
| Skip `persist-failures.log` section | Killed |
| Report non-writable dir as writable | Killed |
| Skip legacy-store detection | Killed |
| Hardcode `${HOME}/.claude` in resolved-paths printer | Killed |
| `exit "$STATUS"` → `exit 0` | Killed |
| `install.sh` SCRIPTS-array completeness guard (dummy script added) | Killed |
| `sl_check_hook_fresh` forced to always return `fresh` | Killed |
| `tail -n 5` → `head -n 5` in bounded-tail display | Killed (was the surviving mutation; now killed) |

`git status --porcelain` at commit time showed only the seven intended
modified files (`install.sh`, `scripts/doctor.sh`, `scripts/lib/config.sh`,
`scripts/self-learning-health.sh`, `tests/test-doctor.sh`,
`tests/test-install-paths.sh`, `tests/test-script-paths.sh`); the
untracked `.superpowers/` directory predates this session and was left
untouched.

### Remaining concerns

- `doctor.sh`'s exit code still intentionally does not cover stale hooks
  or a detected legacy store (unchanged from round 1's Deviation 4;
  adjudicated by the coordinator as no-work-needed, with finding 3's
  shared-verdict fix accepted as sufficient in its place).
- `self-learning-health.sh` still does not check Copilot CLI's hook
  config at all (`~/.copilot/hooks/self-learning.json`) — only
  `doctor.sh` does. This is pre-existing scope, not touched by this fix
  round; flagging in case a future round wants parity there too.
