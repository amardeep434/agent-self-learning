# Task 7b report: Harness-neutral install paths

## Status
DONE

## Summary

Removed the last `~/.claude` dependency from the installer/uninstaller pair.
`install.sh` no longer requires `~/.claude` to exist, no longer writes any
directory under it, and resolves every install location through
`scripts/lib/paths.py` (called once, results cached in shell variables).
`config/copilot-hooks.json` is now a template carrying the `__SL_SCRIPTS_DIR__`
placeholder, substituted at install time with the resolved absolute scripts
path via `sed`. `uninstall.sh` now cleans both the legacy `~/.claude` location
and the resolved vendor-neutral location, per design decision 5.

## Files changed

- `scripts/lib/paths.py` — added `"scripts": ("scripts",)` to `_SUBPATHS` (the
  one sanctioned change to this file).
- `tests/test-paths.py` — extended `test_all_keys_present` for the new key;
  added 4 new cases covering `scripts` across the full override chain
  (explicit, XDG, Windows LOCALAPPDATA, Linux default).
- `config/copilot-hooks.json` — `bash`/`powershell` commands now use
  `__SL_SCRIPTS_DIR__` in place of `~/.claude/scripts/self-learning`.
- `install.sh` — full rewrite of path handling:
  - dropped the `~/.claude` existence precondition (Copilot-only installs
    must not require Claude Code to be present first);
  - resolves `paths.py all` once into `SL_HOME`, `SL_STATE`, `SL_SKILLS`,
    `SL_MEMORY`, `SL_LOGS`, `SL_SESSIONS_DB`, `SL_CONFIG_FILE`, `SL_SCRIPTS`
    via a single `while IFS='=' read` loop (no associative arrays, so it
    stays bash-3.2-compatible for macOS's system `/bin/bash`);
  - `DIRS`, `DEST_DIR`, `CONFIG_DST`, `DB_PATH`, `USAGE_FILE` all now derive
    from those variables instead of `${HOME}/.claude/...`;
  - Step 4b renders the Copilot hook template via
    `sed "s|__SL_SCRIPTS_DIR__|${SL_SCRIPTS}|g" ... > ...` instead of a plain
    `cp`;
  - also copies `scripts/lib/paths.py` into the installed `lib/` dir (see
    Deviation 1 below);
  - prints a legacy-install migration note (preserve-and-notify, design
    decision 4) by shelling out to `paths.legacy_home()` — read-only, never
    writes to or moves `~/.claude`;
  - the echoed Claude Code `settings.json` snippet and the cron-job / verify
    hints at the end now use the resolved `${SL_SCRIPTS}` / `${SL_LOGS}`
    paths instead of literal `~/.claude/...`. The instruction to edit
    `~/.claude/settings.json` itself is unchanged — that file legitimately
    stays in Claude Code's own config directory per design decision 2.
- `uninstall.sh` — resolves the same `paths.py all` output (best-effort: if
  `python3` is missing, only the legacy cleanup runs, never a hard failure);
  removes both the legacy `~/.claude/scripts/self-learning` /
  `~/.claude/self-learning.conf` / etc. **and** the resolved `SL_SCRIPTS`,
  `SL_CONFIG_FILE`, `SL_STATE`, `SL_LOGS/{reviews,curator}`,
  `SL_HOME/backups/curator` locations; the `--keep-data`/full-uninstall data
  section now also clears `SL_HOME/{memory,learned-skills,sessions/search.db}`
  alongside the legacy `~/.claude` equivalents.
- `install.ps1`, `uninstall.ps1` — inspected, no hardcoded paths found
  (both are pure bash delegators); left unchanged as the brief anticipated.
- `tests/test-copilot-hooks-json.sh` — added assertions that the template
  carries `__SL_SCRIPTS_DIR__` in both `bash` and `powershell` fields and
  contains no `.claude`.
- `tests/test-claude-absent.sh` — added an assertion that the shipped
  `config/copilot-hooks.json` template contains no `~/.claude`, closing the
  vacuity documented in that file's own comments.
- `tests/test-uninstall.sh` — added scenario 3: legacy `~/.claude` files and
  resolved-store (`AGENT_LEARNING_HOME`) files installed simultaneously,
  asserting a single `uninstall.sh --yes` run removes both.
- `tests/test-install-paths.sh` (new) — the task's central test. Runs
  `install.sh` for real under `env -i` with a temp `HOME`, explicit
  `AGENT_LEARNING_HOME`, and a fake `~/.copilot`. Asserts: exit 0; no
  `${HOME}/.claude` created; every installed script present under the
  resolved `scripts` dir; data dirs under the resolved home; the rendered
  Copilot hook config contains the resolved absolute scripts path, no
  `.claude`, no unsubstituted `__SL_SCRIPTS_DIR__`, no `CLAUDE`; the path
  named in the hook config points at a file that actually exists and equals
  the installed `copilot-session-review.sh`; and idempotence on a second run.

## TDD sequence

1. Wrote all five test files/additions first, all correctly red against the
   unmodified `install.sh`/`copilot-hooks.json` (confirmed by running before
   any implementation changes — `test-install-paths.sh` failed on the
   `~/.claude` precondition check with `install.sh`'s own hardcoded
   dependency error, not an environment artifact; `test-copilot-hooks-json.sh`
   and `test-claude-absent.sh` failed on `grep -q '__SL_SCRIPTS_DIR__'` /
   `.claude` finding the literal old strings).
2. Implemented `paths.py`, `install.sh`, `uninstall.sh`,
   `config/copilot-hooks.json` per above.
3. Iterated to green — see "issues found and fixed" below for the one bug
   caught mid-implementation.
4. Ran the full suite: all pass (see below).
5. Mutation-tested the four required mutations against
   `tests/test-install-paths.sh` — all four killed the test, all four
   restored cleanly (`git status --porcelain` unaffected each time, `diff`
   confirmed byte-identical restoration for mutation 4).
6. Committed.

## Issue found and fixed while writing the tests (not a deviation, a bug fix)

`grep -c '\.claude' file | grep -qx 0` is unsafe under `set -o pipefail`
(used throughout this test suite): `grep -c` exits 1 when the count is zero
(no match), and pipefail propagates that failure through the pipe even
though the downstream `grep -qx 0` succeeds — so the intended "PASS when
count is 0" check inverted to FAIL. Rewrote as
`count=$(grep -c '\.claude' file || true); check ... "0" "$count"` in
`tests/test-claude-absent.sh`. `tests/test-copilot-hooks-json.sh` already
used the safe command-substitution form, so it needed no fix. Flagging this
because it is exactly the shape of "vacuous/inverted test" the brief warned
about — worth checking any other `grep -c | grep` pipelines in this test
suite if more are added later.

## Deviations from the brief

1. **Copy `scripts/lib/paths.py` into the installed `lib/` directory.**
   The brief's `Step 2b` glob (`scripts/lib/*.sh`) never copied `paths.py`,
   even before this task — `config.sh` (which *is* copied) resolves
   `_sl_paths_py` relative to its own installed location and silently falls
   back to hardcoded defaults if `paths.py` is absent. That fallback already
   avoided `~/.claude`, so this wasn't strictly required to pass the new
   test, but leaving `paths.py` uncopied would mean an installed system
   never actually picks up `AGENT_LEARNING_HOME`/`XDG_DATA_HOME` overrides
   after installation (only at install time). Copying it closes that gap.
   This is a strengthening (explicitly authorized), not a redesign — same
   file, same install target, one more `do_copy` call.
2. **Dropped the `~/.claude` existence precondition entirely** (was: `if
   [[ ! -d "${HOME}/.claude" ]]; then error; fi`). This is required by the
   brief's own intent (a Copilot-only user must be able to install without
   Claude Code present) but is worth calling out explicitly since it's a
   behavior change for existing Claude-only users too — they no longer get
   an error if `~/.claude` doesn't exist yet; the installer just proceeds
   and writes to the resolved store. This matches design decision 2's
   framing that `~/.claude` is Claude Code's own directory, never a
   precondition of this project.
3. **`uninstall.sh`'s resolved-location cleanup is best-effort on missing
   `python3`**, not a hard failure. The brief doesn't specify this failure
   mode; I chose best-effort because uninstall must never abort partway
   (the file already documents this principle for the `jq`-dependent
   `settings.json` edit) — a machine with `python3` removed but a legacy
   `~/.claude` install still present should still get the legacy files
   cleaned up.

## Mutation testing results

All four required mutations against `tests/test-install-paths.sh`:

| # | Mutation | Result |
|---|----------|--------|
| 1 | `SL_STATE` dir reverted to `${HOME}/.claude/state/self-learning` | **KILLED** — `install.sh created .../.claude`, `state dir under store` failed |
| 2 | Copilot hook rendering replaced with plain `cp` (no substitution) | **KILLED** — `hook config contains resolved scripts path`, `unsubstituted placeholder`, `script path exists on disk`, idempotence checks all failed |
| 3 | Substitution target changed to `${SL_SCRIPTS}/nonexistent-dir` | **KILLED** — `script path exists on disk` and the exact-path-equality check both failed |
| 4 | `DEST_DIR` reverted to `${HOME}/.claude/scripts/self-learning` | **KILLED** — install.sh itself failed (`cp` into a directory the DIRS array never creates anymore), every installed-script and hook-config assertion failed |

Each mutation was restored and reverified green (mutation 4's restore was
byte-diffed identical to the pre-mutation file). `git status --porcelain`
after all mutation work shows only the intended file set.

## Full suite result

```
OK tests/test-claude-absent.sh
OK tests/test-config.sh
OK tests/test-copilot-hooks-json.sh
OK tests/test-copilot-session-review.sh
OK tests/test-hook-input.sh
OK tests/test-inject-agents-md.sh
OK tests/test-install-paths.sh     (new)
OK tests/test-session-review.sh
OK tests/test-skillopt-run.sh
OK tests/test-turn-counter.sh
OK tests/test-uninstall.sh
OK tests/test-coach-rules-eval.py
OK tests/test-coach-signals.py
OK tests/test-paths.py
OK tests/test-persist-proposal.py
OK tests/test-proposal-schema.py
```

11 shell suites (baseline 10 + the new one) + 5 Python suites, all passing.
No regressions against the baseline at `44209dc`.

`install.sh`/`uninstall.sh` were never run against the real `$HOME` — every
invocation in testing and mutation work used `env -i HOME=<tempdir> ...` or
`export HOME="$TMP"` inside a `mktemp -d` sandbox.

## Concerns

- **Pre-existing, out-of-scope bug noticed while reading `install.sh`:**
  `persist-proposal.py` (the sole write path per the plan's global
  constraints) is referenced by both `session-review.sh` and
  `copilot-session-review.sh` at `"${SCRIPT_DIR}/persist-proposal.py"`
  (relative to wherever those scripts are installed), but `persist-proposal.py`
  is **not** in `install.sh`'s `SCRIPTS` array and was never copied even
  before this task (confirmed via `git show HEAD:install.sh`). A fresh
  install would ship a review pipeline that cannot find its own persistence
  script. This predates Task 7b and is outside its file list, so I left it
  unfixed — flagging it here since it's a real installer bug adjacent to
  this one and easy to miss.
- The `LEGACY_HOME` detection in `install.sh` shells out to a small inline
  `python3 -c` snippet importing `paths.legacy_home()` rather than adding a
  new CLI verb to `paths.py`, to honor "the one sanctioned change to this
  file" (adding the `scripts` key). If a future task wants this exposed as
  `paths.py legacy` for reuse (e.g. by Task 9's `doctor`), that's a small,
  low-risk follow-up.

## Fix round 1

Coordinator review flagged one Critical item (my own concern #1, escalated)
and adjudicated my concern #2 (dropping the `~/.claude` precondition) as
correct with no work required.

### CRITICAL: the writer was not installed — fixed

`install.sh`'s `SCRIPTS` array omitted `persist-proposal.py` (the sole write
path per the plan's global constraints), and Step 2b copied only
`scripts/lib/*.sh` plus a hand-listed `paths.py` — never
`scripts/lib/proposal_schema.py`, which `persist-proposal.py` imports from
its own installed directory. On a real install this meant the review
pipeline would run to completion, burn a paid model call, and persist
nothing, failing silently below the hook layer — the exact defect this
project exists to eliminate, relocated into the installer.

**Changes to `install.sh`:**
- Added `"persist-proposal.py"` to the `SCRIPTS` array (copied and chmod'd
  identically to the other `.py` entries already there).
- Replaced the hand-listed `paths.py`-only block in Step 2b with a loop over
  `scripts/lib/*.py` mirroring the existing `*.sh` loop, so any future
  Python library is copied automatically instead of needing to be
  separately remembered. Still routed through `do_copy`/`do_mkdir`
  (`do_chmod` not needed for a `python3 <path>`-invoked file) — `--dry-run`
  behavior unchanged.

**New tests in `tests/test-install-paths.sh`:**
- A hardcoded `EXPECTED_FILES` list — `persist-proposal.py`, `lib/paths.py`,
  `lib/proposal_schema.py`, `lib/config.sh`, `session-review.sh`,
  `copilot-session-review.sh` — each asserted present under the resolved
  scripts directory.
- An end-to-end assertion: pipes a minimal valid proposal
  (`{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace",
  "content": "<unique marker>"}]}`) into `python3
  <resolved-scripts-dir>/persist-proposal.py` under the same sandboxed
  `env -i` / `AGENT_LEARNING_HOME` environment as the install, and confirms
  the memory file appears under the resolved memory directory with the
  exact marker content. This runs the *installed* copy standalone (not the
  repo copy), so it is the only assertion that exercises whether the
  installed tree's internal imports actually resolve.

**Mutation results:**

| # | Mutation | Result |
|---|----------|--------|
| A | Removed `"persist-proposal.py"` from the `SCRIPTS` array | **KILLED** — `expected installed file present: persist-proposal.py` failed, and the e2e run then failed too (exit 2, `ModuleNotFoundError`-equivalent absence) since the writer itself was never installed |
| B | Excluded `proposal_schema.py` specifically from the `*.py` copy loop (kept `paths.py`) | **KILLED** — e2e assertions failed (`exits 0 standalone` got exit 1, no memory file written, no expected content) exactly as predicted. One deviation from the literal expected contrast: because the brief's own required `EXPECTED_FILES` list includes `lib/proposal_schema.py` by name, that single list entry *also* failed under this mutation — every other file-existence check (including all other `EXPECTED_FILES` entries and the pre-existing script checks) still passed. The e2e assertion is not the *only* thing that caught it, but it is what proves the deeper property (installed-tree self-sufficiency) rather than mere presence — the redundancy is a strengthening, not a weakening, of the intended contrast. |

Both mutations restored; `diff` confirmed byte-identical restoration of
`install.sh` in both cases.

### Adjudicated in my favour

No changes made — the `~/.claude` existence precondition stays removed, per
the coordinator's ruling that this is the intended behavior change the plan
requires, not a regression.

### Full suite after fix round 1

```
OK tests/test-claude-absent.sh
OK tests/test-config.sh
OK tests/test-copilot-hooks-json.sh
OK tests/test-copilot-session-review.sh
OK tests/test-hook-input.sh
OK tests/test-inject-agents-md.sh
OK tests/test-install-paths.sh
OK tests/test-session-review.sh
OK tests/test-skillopt-run.sh
OK tests/test-turn-counter.sh
OK tests/test-uninstall.sh
OK tests/test-coach-rules-eval.py
OK tests/test-coach-signals.py
OK tests/test-paths.py
OK tests/test-persist-proposal.py
OK tests/test-proposal-schema.py
```

11 shell suites + 5 Python suites, all green. `git status --porcelain` after
these changes showed only `install.sh` and `tests/test-install-paths.sh`
modified — no unintended changes.
