# Fix round P4 — structural risk (skill-layout single-sourcing) + `doctor --strict` + deferred minors

Branch: `harness-neutral-persistence`. Starting point: `c24c977` (31 suites green,
six CI cells green, dir_fd-hardened write path). This round adds three commits:

1. `39de89e` — Item 1: single-source the skill-directory layout
2. `1732afc` — Item 2: `doctor.sh --strict`
3. `0798ef0` — Item 3: deferred minors

This session was interrupted once by an API session limit partway through
Item 1 (right after `import skill_layout` was added to `skill-lifecycle.py`,
before the rest of the migration). The coordinator confirmed the partial
state was intact and uncommitted; work resumed from exactly that point. Each
item below was committed as soon as its own tests were green, per the
coordinator's instruction to commit incrementally rather than hold everything
for one final commit.

## Item 1 — single-source the skill-directory layout

### Design

`scripts/lib/skill_layout.py` is now the one definition of:

- `SKILL_MD_FILENAME = "SKILL.md"`
- `USAGE_FILENAME = ".usage.json"`
- `ARCHIVE_DIRNAME = ".archive"`

plus four helper functions (`skill_dir`, `skill_md_path`, `usage_file_path`,
`archive_dir_path`) that compose those constants with a `skills_dir` Path, so
callers build paths instead of string-concatenating the constants themselves.

**Python consumers** (`persist-proposal.py`, `skill-lifecycle.py`,
`inject-agents-md.py`) import the module directly:

- `persist-proposal.py` keeps its existing module-level names
  (`SKILL_CONTENT_FILENAME`, `USAGE_FILENAME`) but assigns them from
  `skill_layout.SKILL_MD_FILENAME` / `skill_layout.USAGE_FILENAME` — an
  alias, not a re-typed literal, verified by object-identity in the pin test.
- `skill-lifecycle.py`'s `USAGE_FILE`/`ARCHIVE_DIR` are now built via
  `skill_layout.usage_file_path(SKILLS_DIR)` / `skill_layout.archive_dir_path(SKILLS_DIR)`.
- `inject-agents-md.py`'s `list_skills()` now calls
  `skill_layout.skill_md_path(skills_dir, child.name)` instead of
  `child / "SKILL.md"`.

**Bash consumers** (`curator-run.sh`, `self-learning-health.sh`) source a new
`scripts/lib/skill-layout.sh`, which shells out to
`python3 skill_layout.py all` exactly once and sets
`SL_SKILL_MD_FILENAME` / `SL_USAGE_FILENAME` / `SL_ARCHIVE_DIRNAME` — the
same CLI-wrapper pattern `lib/config.sh` already uses for `lib/paths.py`
(`get <key>` / `all`, KEY=VALUE lines, `\r`-stripped for Windows safety).
It has a hardcoded-literal fallback if `python3` is unavailable, matching
`config.sh`'s own degraded-mode contract (never silently empty).

### Hot-path confirmation

`scripts/lib/skill-layout.sh` is **not** sourced from `config.sh` — it is
sourced directly and only by `curator-run.sh` and `self-learning-health.sh`,
each exactly once near the top of the script, outside any loop. Confirmed by
inspection and by `grep -rl "curator-run.sh\|self-learning-health.sh"` across
the repo: neither is referenced by `turn-counter.sh` or any hook-registration
config — `turn-counter.sh` is the only per-tool-call hook, and it sources only
`config.sh` (which already spends ~22-25ms on its one `paths.py all` spawn,
per CLAUDE.md's documented hook budget). `curator-run.sh` is gated to a 7-day
minimum interval; `self-learning-health.sh` is an on-demand diagnostic
invoked by a human or `doctor.sh`. Neither is hot. The one extra spawn each
incurs happens once per invocation of either script, not per skill in a loop
— the `source` line sits before any `for`/`while` over skills in both files.

### Pin test and mutation

`tests/test-skill-layout-pinning.sh` (added to the suite; count went 31→32):

1. Behavioral: `skill_layout.py`'s `get`/`all` CLI output, and
   `skill-layout.sh`'s bash variables, resolve to the three expected values.
2. `persist-proposal.py`'s aliases are checked by **object identity**
   (`is`, not `==`) against `skill_layout`'s own constants — proves it's a
   real import, not a coincidentally-matching literal.
3. `skill-lifecycle.py`'s `USAGE_FILE`/`ARCHIVE_DIR` are checked by
   **monkeypatching** `skill_layout.USAGE_FILENAME`/`ARCHIVE_DIRNAME` to
   mutated values *before* `skill-lifecycle.py` is imported, then asserting
   the mutation propagated — proves the module tracks the shared definition
   live, not a value frozen at some earlier point.
4. Source-pin: a zero-tolerance grep for a re-typed literal
   (`"SKILL.md"`, `".usage.json"`, `".archive"` in Python;
   `/SKILL.md`, `/.usage.json`, `/.archive` in bash) across all five
   consumers.

**Mutation test performed:** reverted `curator-run.sh`'s `USAGE_FILE=` line
to the literal `"${SKILLS_DIR}/.usage.json"`. Result: the pinning test's
`"scripts/curator-run.sh has no re-typed skill-layout literal"` assertion
flipped from PASS to FAIL (exit 1). Restored the file; re-ran; back to
`All skill-layout pinning tests passed.` — killed and restored, confirmed.

## Item 2 — `doctor --strict`

Added `--strict` as a positional/any-position flag to `doctor.sh`. Default
behavior (no flag) is byte-for-byte unchanged: `_sl_report_hooks()` still
prints `STALE` loudly but the new `STALE_HOOKS_FOUND` tracker it now also
sets is only consulted when `STRICT=1`. Under `--strict`, if any hook was
reported stale, `STATUS` is forced to 1 and a line explaining why is printed
just before the overall verdict. The legacy-`~/.claude`-store section is
untouched by `--strict` — it was never wired to `STATUS` before, and nothing
in this change wires it now, so it stays non-fatal in both modes, per the
prior ruling.

Documented in `README.md`'s Diagnostics section (new paragraph after the
`persist-failures.log` explanation): default vs. `--strict` behavior, the
suggested use (CI or any exit-code-gating wrapper), and the legacy-store
exception restated explicitly.

### Test and mutation

`tests/test-doctor-strict.sh` (new; suite count 32→33): no-harness case (both
modes exit 0), stale-hook case (default stays 0 and reports HEALTHY;
`--strict` exits 1 and reports UNHEALTHY with the staleness line), and a
legacy-store case (detected in `--strict` output, does not fail it).

**Mutation test performed:** deleted the `if [[ "$STRICT" -eq 1 &&
"$STALE_HOOKS_FOUND" -eq 1 ]]; then STATUS=1; ...; fi` block entirely.
Result: three assertions flipped to FAIL (`stale hook under --strict exits
1`, `--strict run's overall status is UNHEALTHY`, `--strict run names hook
staleness as the reason`), two stayed PASS (the no-harness cases, correctly
unaffected), overall exit 1. Restored; re-ran; all 11 assertions PASS again.

## Item 3 — deferred minors

- **`index-session.sh` first-run gap.** `DB_EXISTED` is now captured
  *before* the initialize-if-needed block creates the DB file. On a first
  run (`DB_EXISTED=0`), the script indexes existing transcripts sorted by
  mtime (via the same `stat -c %Y || stat -f %m` GNU/BSD fallback
  `self-learning-health.sh` already uses — deliberately not `date -r`, whose
  argument means "a file's mtime" on GNU date but "a raw Unix epoch integer"
  on BSD/macOS date, which would have silently sorted by garbage on macOS
  rather than failing loudly), capped to 20 for the same "don't let a Stop
  hook run unboundedly long on a big pre-existing history" reason the
  original `head -20` had. Subsequent runs keep the original `-newer`
  filter. New test: `tests/test-index-session-first-run.sh` (suite count
  33→34) seeds a transcript *before* the first `index-session.sh` invocation
  and asserts it gets indexed. **Mutation test:** forced the script into the
  `-newer`-only branch (`if false; then` in place of the `DB_EXISTED`
  check) — the pre-existing-transcript assertion flipped to FAIL
  (`sqlite3` query errored, since `sessions` table check returned `ERROR`
  rather than `1`); restored, re-ran, PASS.

- **`_MAX_FENCE_CANDIDATES` comment.** Added, stating explicitly that the
  constant is fail-closed: it bounds how many fenced-block candidates are
  *scanned* for a valid proposal, and every candidate still passes through
  the same `validate_proposal()` checks — so no value of this constant can
  turn a rejection into an acceptance, only (in principle) cause a valid
  proposal buried past the Nth fence to be missed.

- **`_read_existing`'s UTF-8 guard.** Added
  `test_read_existing_rejects_invalid_utf8_as_persist_error` to
  `tests/test-persist-proposal.py` (suite count of assertions within that
  file: 25→26 tests), writing raw invalid-UTF-8 bytes (`\xff`, not a valid
  UTF-8 lead or continuation byte in any context) directly to a file and
  asserting `_read_existing` raises `PersistError` with "not valid UTF-8" in
  the message, rather than a raw `UnicodeDecodeError`. **Mutation test:**
  removed the `except UnicodeDecodeError` wrapper, restoring a bare
  `with handle: return handle.read()`. The new test failed with an
  uncaught `UnicodeDecodeError` traceback (not a silent pass, not a
  different-but-still-green failure). Restored; re-ran; PASS.

- **`trap ... EXIT` cleanup.** Added to `tests/test-claude-absent.sh`,
  `tests/test-session-review.sh`, `tests/test-copilot-session-review.sh`.
  Each of the latter two allocates several temp dirs beyond its original
  single `TMP` (already trapped); the trap for each was extended to cover
  every temp-dir variable the file uses (`${VAR:-}` so it's safe to register
  before those variables are assigned — the trap body is expanded when EXIT
  actually fires, not when `trap` is registered), and the now-redundant
  explicit `rm -rf` calls on the success path were removed. Verified all
  three still pass standalone and inside the full suite.

- **`test-paths.py` import nit.** Split `import os, subprocess, sys,
  tempfile, unittest` (line 1) into one `import` per line (PEP 8 / E401).
  Re-ran under 3.9: 30/30 pass, unchanged.

- **Stale Copilot version docs.** `README.md`'s capability table and
  `CLAUDE.md`'s branch-status banner both stated "real `copilot` 1.0.73" as
  if it were a fixed fact; the installed version has since moved to 1.0.75.
  Reworded both to read explicitly as a point-in-time observation from the
  2026-07-25 verification run ("whatever `copilot` was installed that day…
  1.0.75 has since been observed installed… this project targets 'current,
  authenticated `copilot` on PATH,' never a pinned version"), so neither
  claim silently goes stale on the next Copilot CLI auto-update.
  `docs/verification-log.md`'s own entry (already phrased as
  "auto-updated to 1.0.73 during the run") and the `.superpowers/sdd/`
  historical task reports were left untouched — they are point-in-time
  records of what happened during a specific past run, not standing claims
  about the current state of the world.

## Suite / interpreter results

- `bash tests/run-all.sh`: **34 suite(s) discovered (26 shell, 8 python),
  all 34 passed** (started at 31; +1 per item, three items).
- Every Python suite run individually under
  `~/.pyenv/versions/3.9.24/bin/python3.9`: all 8 pass
  (`test-adversarial-sweep.py`, `test-coach-rules-eval.py`,
  `test-coach-signals.py`, `test-isotime.py`, `test-paths.py`,
  `test-persist-proposal.py`, `test-proposal-schema.py`,
  `test-transcript.py`).

## What could not be closed / unverifiable

- Nothing in this round's scope was left un-closed. All three items have
  passing, mutation-tested guards.
- Out of scope, unchanged from before this round (per CLAUDE.md's own
  status banner): no CI run has been observed on this branch since fix round
  A's platform fixes landed on Windows/macOS specifically for *this* round's
  commits (CI has not been triggered from this session — pushing was
  explicitly out of scope: "Work only there... Do NOT... push"). The live
  Copilot CLI end-to-end check remains as previously documented (done once,
  2026-07-25, one residual: no genuine interactive `sessionEnd` payload
  exercised yet).

## Commits

- `39de89e` — `fix: single-source the skill-directory layout (SKILL.md/.usage.json/.archive)`
- `1732afc` — `feat: add doctor.sh --strict to fail on stale hook config`
- `0798ef0` — `fix: deferred minors — first-run indexing, fail-closed comment, UTF-8 test, trap cleanup, docs`
