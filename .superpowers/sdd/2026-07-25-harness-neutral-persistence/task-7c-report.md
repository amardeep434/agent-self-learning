# Task 7c report

Status: DONE
Commit: c283fad — "fix(scripts): resolve store paths via config.sh in health, curator, index-session"

## What was implemented

Followed the brief's TDD order exactly:

1. Wrote `tests/test-script-paths.sh` against the *unmodified* scripts.
2. Ran it — 27 of 31 assertions failed, all naming the hardcoded `${HOME}/.claude` store
   path (e.g. `[FAIL] /tmp/.../.claude/state/self-learning missing`, curator writing its
   backup under `.claude/backups/curator`, index-session failing to find its schema file
   under `.claude/scripts/self-learning`). No failure was a missing-dependency artifact of
   `env -i` — confirmed the red was for the right reason.
3. Implemented the fix in all three scripts.
4. Re-ran: all 31 assertions pass.
5. Ran the full suite: 12/12 shell suites, 5/5 Python suites pass (baseline was
   11 shell + 5 Python; +1 for the new test file).
6. Mutation-tested the test (see below), then committed.

### `scripts/self-learning-health.sh`
- Added `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and
  `source "${SCRIPT_DIR}/lib/config.sh"`, matching the `turn-counter.sh` /
  `session-review.sh` pattern.
- `REQUIRED_DIRS` now uses `$SL_STATE_DIR`, `$SL_SKILLS_DIR`,
  `$(dirname "$SL_SEARCH_DB")`, `${SL_LOG_DIR}/reviews`, `${SL_LOG_DIR}/curator`, and
  `$SCRIPT_DIR` itself (replacing the old hardcoded `.../scripts/self-learning` self-check).
- `REQUIRED_SCRIPTS` presence/executable check now looks in `$SCRIPT_DIR` (own directory)
  instead of a hardcoded install path.
- `COUNTER_FILE`, `LOCK_DIR` → under `$SL_STATE_DIR`.
- `DB_PATH` → `$SL_SEARCH_DB`.
- `USAGE_FILE` → under `$SL_SKILLS_DIR`.
- `SETTINGS_FILE="${HOME}/.claude/settings.json"` **left unchanged** (legitimate,
  Claude-Code-owned). The section is now titled `Hook Registration (Claude Code)` and,
  per the brief's explicit instruction, a missing `settings.json` is now `warn()` instead
  of `fail()`, with the message explaining this is normal on a Copilot-only install and
  pointing at where Copilot hooks actually live. This does not weaken the check when
  Claude Code *is* installed — verified in the test that with settings.json present and
  populated, the turn-counter/session-review/index-session hook-registration PASS checks
  still fire correctly.

### `scripts/curator-run.sh`
- Same `SCRIPT_DIR` + `source lib/config.sh` pattern.
- `SKILLS_DIR` → `$SL_SKILLS_DIR`; `ARCHIVE_DIR` derived from it (unchanged shape).
- `BACKUP_DIR` → `"${SL_HOME}/backups/curator"` — there is no `backups` key in
  `paths.py` (correctly out of scope per the brief), so this derives it under `SL_HOME`
  exactly the way `install.sh` already creates it (`install.sh:168`,
  `"${SL_HOME}/backups/curator"`), so the installer and this consumer cannot disagree.
- `LOG_DIR` → `${SL_LOG_DIR}/curator`; `STATE_DIR` → `$SL_STATE_DIR`.

### `scripts/index-session.sh`
- Same `SCRIPT_DIR` + `source lib/config.sh` pattern.
- `DB_PATH` → `$SL_SEARCH_DB`.
- `SESSIONS_DIR="${HOME}/.claude/projects"` **left unchanged and commented** as
  Claude Code's own transcript source — not the framework's store, must not be
  neutralized.

## Deviations from the brief, with reasoning

1. **Strengthened, not weakened**: the brief only asked that the settings.json check be
   "clearly labelled" — I additionally changed its failure severity from FAIL to WARN
   (explicitly authorized by the brief's own text: "on a Copilot-only machine its absence
   is normal, not a failure — make sure a Copilot-only user does not see a spurious
   FAIL"). This is a behavior change beyond a label, but it's exactly what the brief's
   prose demands, so I'm calling it out rather than silently doing it.
2. Everything else is a direct, literal implementation of the brief and the established
   `turn-counter.sh`/`session-review.sh` pattern — no other deviations.

## Mutation test results (required, all four)

Ran each mutation, confirmed `tests/test-script-paths.sh` fails, noted which assertions
fired, restored, verified restoration via `diff`.

1. **Revert health.sh's `REQUIRED_DIRS` to `${HOME}/.claude/...`.**
   KILLED. Fired: "health reports resolved state dir present", "...skills dir present",
   "health exits 0 (HEALTHY)...", "health prints overall HEALTHY status", "health output
   never cites state dir under ~/.claude", and more (5+ assertions).

2. **Revert curator-run.sh's `SKILLS_DIR` to `${HOME}/.claude/learned-skills`.**
   KILLED. Fired: "curator report cites the resolved (store) skills dir", "curator report
   never cites a skills dir under ~/.claude", "curator-run.sh has zero ~/.claude
   references" (the narrow source assertion also caught it, since curator-run.sh has no
   legitimate exception at all).

3. **Revert index-session.sh's `DB_PATH` to `${HOME}/.claude/sessions/search.db`.**
   KILLED. Fired: "index-session created the DB under the resolved store", "index-session
   did NOT create a DB under ~/.claude", "index-session indexed the session found via
   ~/.claude/projects" (indexing failed because the schema-init path diverged), and the
   narrow source-count assertion (2 occurrences instead of the expected 1).

4. **My own: change `index-session.sh`'s `SESSIONS_DIR` away from `~/.claude/projects`
   (to `${SL_HOME}/claude-projects-copy`).**
   KILLED — and I decided it *should* be killed. Reasoning: if `SESSIONS_DIR` silently
   stops pointing at Claude Code's real transcript directory, session indexing silently
   breaks — the exact same failure shape (a component that appears to run fine while
   reading/writing the wrong location) that this whole task exists to eliminate, just on
   the source side instead of the store side. So the test asserts real end-to-end
   behavior: it writes a session transcript to the real `~/.claude/projects/...` and
   confirms it gets indexed. When `SESSIONS_DIR` is redirected, that transcript is no
   longer found (0 sessions indexed instead of 1), and the narrow source-count assertion
   also drops from 1 to 0. Both fired. I explicitly do **not** consider this "punishing
   the legitimate reference" — the legitimate reference is the *literal, unmodified*
   `SESSIONS_DIR="${HOME}/.claude/projects"` line; any edit to it (even a well-intentioned
   refactor) should require a deliberate test update, not pass silently. This is
   documented in the test file's own comments above the assertion.

## Full suite result

12/12 shell test suites pass, 5/5 Python test suites pass (baseline was 11 shell + 5
Python at HEAD `612816e`; +1 for the new `tests/test-script-paths.sh`).

```
OK tests/test-claude-absent.sh
OK tests/test-config.sh
OK tests/test-copilot-hooks-json.sh
OK tests/test-copilot-session-review.sh
OK tests/test-hook-input.sh
OK tests/test-inject-agents-md.sh
OK tests/test-install-paths.sh
OK tests/test-script-paths.sh
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

`git status --porcelain` after commit is clean (all changes committed); before commit it
showed exactly the four intended files (three modified scripts + one new test), nothing
else.

## Concerns (not fixed — out of scope per the brief)

- **index-session.sh's `-newer "$DB_PATH"` first-run gap** (pre-existing, unrelated to
  path resolution): on a brand-new store, the very first run creates the DB file and then
  immediately checks for `*.jsonl -newer "$DB_PATH"`. Any session transcript that already
  existed *before* that first run (older than the freshly-created empty DB) will never be
  picked up by that run — it only catches transcripts written after the DB's creation
  mtime. This is orthogonal to Task 7c (it's a staleness/logic issue, not a path-resolution
  issue, and predates this task per the brief's own note that these three scripts are
  "unmodified since the initial skeleton commit"). Flagging per the brief's instruction to
  report rather than expand scope.
- `self-learning-health.sh` and `scripts/doctor.sh` (Task 9, not yet created) will overlap
  once doctor.sh exists — per the brief I did not build doctor functionality here and did
  not delete or restructure the health script beyond the path-resolution and
  severity/label fix required by this task.
