# Task 2 Report: config.sh delegates to the resolver; env-var cleanup

## Status: DONE

## Commit
`8dcbdeb` — feat(config): resolve paths via paths.py, add SL_REVIEW_ENABLED, drop dead CLAUDE_REVIEW_* entries

## Files modified
- `scripts/lib/config.sh`
- `config/settings-hooks.json`
- `tests/test-config.sh`

## What changed

### `scripts/lib/config.sh`
1. Added `SL_REVIEW_ENABLED` to the `_sl_env_snapshot` variable list so a
   pre-set `SL_REVIEW_ENABLED` survives sourcing the config file (env beats
   file), matching the existing pattern used for every other `SL_*` var.
2. Replaced the six hardcoded `${HOME}/.claude`-based defaults
   (`SL_HOME`, `SL_STATE_DIR`, `SL_SKILLS_DIR`, `SL_MEMORY_DIR`,
   `SL_LOG_DIR`, `SL_SEARCH_DB`) with a block that shells out to
   `scripts/lib/paths.py all` and only fills in values still unset (so any
   value already set by env or the config file continues to win — the
   `${VAR:-value}` pattern is preserved per key). This is the single place
   bash asks Python for paths, per the "paths computed in exactly one place"
   constraint.
3. Added `SL_REVIEW_ENABLED` with legacy fallback: if `SL_REVIEW_ENABLED` is
   unset and `CLAUDE_REVIEW_ENABLED` is set, copy the legacy value across and
   print a deprecation notice to stderr; otherwise default to `true`.
4. Added `SL_REVIEW_ENABLED` to the final `export` list.

Note: the `SL_CONFIG_FILE` default itself (`${HOME}/.claude/self-learning.conf`)
was left untouched — the brief's exact replacement block only covered the six
path variables, not `SL_CONFIG_FILE`. See "Deviation / concern" below.

### `config/settings-hooks.json`
Added the `"env"` object specified by the brief, with the five live/intended
keys (`SL_MEMORY_REVIEW_INTERVAL`, `SL_SKILL_REVIEW_INTERVAL`,
`SL_REVIEW_ENABLED`, `SL_REVIEW_MIN_TURNS`, `SL_REVIEW_MAX_TURNS`) ahead of
`"hooks"`. The file as found on this branch did not actually contain a
pre-existing `"env"` block with nine `CLAUDE_REVIEW_*` entries (contrary to
the "context" note) — it had no `"env"` key at all. I added the block fresh,
producing exactly the end-state the brief specifies. `scripts/session-review.sh`
still reads `CLAUDE_REVIEW_ENABLED` and was intentionally left unmodified per
instructions (Task 5 rewrites it) — it will pick up `SL_REVIEW_ENABLED` via
the legacy fallback in `config.sh` once callers source that, or continue via
its own literal env var name where hooks set that directly; no functional
change to that script in this task.

### `tests/test-config.sh`
- Updated the pre-existing assertion `check "missing file falls back to
  defaults" ...` to expect `$HOME/.local/share/agent-learning` instead of
  `$HOME/.claude` (deliberate behavior change per brief).
- Appended the five new checks from the brief verbatim: vendor-neutral
  `SL_HOME`, `AGENT_LEARNING_HOME` override, `SL_REVIEW_ENABLED` default,
  legacy `CLAUDE_REVIEW_ENABLED` honored, and new-beats-legacy precedence.

## TDD steps followed

**Step 2 — confirm failing (before implementation):**
```
$ bash tests/test-config.sh
PASS: both coach flags default false
PASS: env override wins
FAIL: missing file falls back to defaults (expected '/home/amardeep/.local/share/agent-learning', got '/home/amardeep/.claude')
FAIL: SL_HOME still points into .claude (/home/amardeep/.claude)
FAIL: AGENT_LEARNING_HOME drives SL_MEMORY_DIR (expected '/tmp/al/memory', got '/home/amardeep/.claude/memory')
FAIL: SL_REVIEW_ENABLED defaults true (expected 'true', got '')
FAIL: legacy CLAUDE_REVIEW_ENABLED honored (expected 'false', got '')
PASS: SL_REVIEW_ENABLED beats legacy
EXIT:1
```
(5 failures, as expected — matches the brief's predicted failure mode.)

**Step 4 — confirm passing (after implementation):**
```
$ bash tests/test-config.sh
PASS: both coach flags default false
PASS: env override wins
PASS: missing file falls back to defaults
PASS: SL_HOME is vendor-neutral
PASS: AGENT_LEARNING_HOME drives SL_MEMORY_DIR
PASS: SL_REVIEW_ENABLED defaults true
agent-self-learning: CLAUDE_REVIEW_ENABLED is deprecated; use SL_REVIEW_ENABLED
PASS: legacy CLAUDE_REVIEW_ENABLED honored
PASS: SL_REVIEW_ENABLED beats legacy
All config tests passed.
CONFIG_EXIT:0

$ python3 tests/test-paths.py
..........
----------------------------------------------------------------------
Ran 10 tests in 0.048s

OK
PATHS_EXIT:0
```

## Additional verification (not strictly required by brief, done for safety)
Ran every other test file that touches `config.sh` / `settings-hooks.json` to
confirm no regressions from the env-var / JSON change:
```
bash tests/test-copilot-hooks-json.sh       -> All copilot-hooks-json tests passed.
bash tests/test-session-review.sh           -> All session-review tests passed.
bash tests/test-copilot-session-review.sh   -> All copilot-session-review tests passed.
bash tests/test-turn-counter.sh             -> All turn-counter tests passed.
```
Also validated `config/settings-hooks.json` parses as valid JSON via
`python3 -c "import json; json.load(open('config/settings-hooks.json'))"`.

## Deviation from the brief (with justification)

The brief's "Context the implementer needs" section states `settings-hooks.json`
currently "sets nine `CLAUDE_REVIEW_*` entries." On this branch/worktree the
file had **no** `"env"` object at all (verified via `Read` and via
`grep -rn CLAUDE_REVIEW`, which found no JSON hits before my edit). I did not
try to reconstruct or "clean up" nine entries that don't exist here; I simply
added the exact five-key `"env"` object the brief specifies as the desired
end state. Net effect matches the brief's intent (neutral `SL_*` keys only,
no `CLAUDE_REVIEW_*` dead weight) — flagging the discrepancy in case it
indicates the brief was written against a slightly different file version,
or another task/commit in the plan was expected to have added those nine
entries first.

## Things I was unsure about
- Whether `SL_CONFIG_FILE`'s own default (`${HOME}/.claude/self-learning.conf`)
  should also move off `~/.claude` in this task. The brief's literal
  replacement block only lists the six path-derived variables
  (`SL_HOME`..`SL_SEARCH_DB`), not `SL_CONFIG_FILE`, and `paths.py` does
  expose a `config_file` key that isn't consumed here. I left `SL_CONFIG_FILE`
  untouched since the brief didn't ask for it and did not use it in any of
  the five new/updated test assertions (all tests set `SL_CONFIG_FILE`
  explicitly, so this was never exercised). This may be intentional scope
  for a later task, or may be a residual `~/.claude` reference worth a
  follow-up — worth confirming.

---

## Fix round 1 (coordinator-requested)

Coordinator confirmed concern #2 above was a real gap and concern #1 was a
brief/context discrepancy, not a work issue (no action needed there).

### Required fix
`SL_CONFIG_FILE` must default to the `config_file` value from
`scripts/lib/paths.py`, not `${HOME}/.claude/self-learning.conf`, while
keeping the ordering constraint that `SL_CONFIG_FILE` is resolved *before*
the config file is sourced (which happens before the point where the old
code called `paths.py` for the other six keys).

### What changed — `scripts/lib/config.sh`
Restructured to a single early `paths.py all` call, per the "single early
call is cleaner" option in the coordinator's instructions:

1. Moved the `paths.py` invocation to the very top of the script (right
   after the env snapshot loop, before `SL_CONFIG_FILE` is set). It now
   populates seven scratch variables (`_sl_pp_home`, `_sl_pp_state`,
   `_sl_pp_skills`, `_sl_pp_memory`, `_sl_pp_logs`, `_sl_pp_sessions_db`,
   `_sl_pp_config_file`) — one per `paths.py` key, including the
   previously-unconsumed `config_file`.
2. `SL_CONFIG_FILE` now defaults to `${_sl_pp_config_file}`:
   `SL_CONFIG_FILE="${SL_CONFIG_FILE:-${_sl_pp_config_file:-${HOME}/.local/share/agent-learning/self-learning.conf}}"`.
   The trailing literal is a degraded fallback only for the case where
   `python3`/`paths.py` could not run at all (e.g. no `python3` on PATH) —
   it is vendor-neutral (`.local/share/agent-learning`), so it can never
   reintroduce a `~/.claude` reference even in that edge case.
3. The later `SL_HOME`/`SL_STATE_DIR`/`SL_SKILLS_DIR`/`SL_MEMORY_DIR`/
   `SL_LOG_DIR`/`SL_SEARCH_DB` defaults (after the config file is sourced
   and the env snapshot is re-applied) now read from the same `_sl_pp_*`
   scratch variables instead of making a second `paths.py` call — so
   `paths.py` runs exactly once per `config.sh` invocation.
4. Precedence is unchanged and verified by test: pre-set env beats config
   file, which beats the `paths.py`/fallback default, for every variable
   including `SL_CONFIG_FILE` itself.

### New tests — `tests/test-config.sh`
- `"default SL_CONFIG_FILE is vendor-neutral"` — sources `config.sh` with no
  `SL_CONFIG_FILE` set at all and asserts the resulting value contains
  `agent-learning` and never `.claude`.
- `"pre-set SL_CONFIG_FILE overrides paths.py default"` — sources `config.sh`
  with `SL_CONFIG_FILE=/nonexistent/x.conf` pre-set and asserts that exact
  value survives (proving env still wins over the new default).

### Commands run and output

```
$ bash tests/test-config.sh
PASS: both coach flags default false
PASS: env override wins
PASS: missing file falls back to defaults
PASS: SL_HOME is vendor-neutral
PASS: AGENT_LEARNING_HOME drives SL_MEMORY_DIR
PASS: SL_REVIEW_ENABLED defaults true
agent-self-learning: CLAUDE_REVIEW_ENABLED is deprecated; use SL_REVIEW_ENABLED
PASS: legacy CLAUDE_REVIEW_ENABLED honored
PASS: SL_REVIEW_ENABLED beats legacy
PASS: default SL_CONFIG_FILE is vendor-neutral
PASS: pre-set SL_CONFIG_FILE overrides paths.py default
All config tests passed.
CONFIG_EXIT:0

$ python3 tests/test-paths.py
..........
----------------------------------------------------------------------
Ran 10 tests in 0.049s

OK
PATHS_EXIT:0

$ bash tests/test-copilot-hooks-json.sh       -> All copilot-hooks-json tests passed.
$ bash tests/test-session-review.sh           -> All session-review tests passed.
$ bash tests/test-copilot-session-review.sh   -> All copilot-session-review tests passed.
$ bash tests/test-turn-counter.sh             -> All turn-counter tests passed.
```

### Commit
`320b60f` — fix(config): resolve SL_CONFIG_FILE default via paths.py, not ~/.claude

---

## Fix round 2 (coordinator-requested, reviewer-verified)

### Finding
Reviewer ran `config.sh` with `python3` removed from `PATH` and found
`SL_HOME` resolved to empty and `SL_COACH_RULES_DIR` (derived from it)
became the root-relative `/scripts/self-learning/coach-rules` — a
regression versus the pre-diff hardcoded fallback. Cause: the six
`_sl_pp_*` scratch variables (`_sl_pp_home`, `_sl_pp_state`, `_sl_pp_skills`,
`_sl_pp_memory`, `_sl_pp_logs`, `_sl_pp_sessions_db`) had no literal fallback
the way `_sl_pp_config_file` did at the `SL_CONFIG_FILE` line.

### Fix — `scripts/lib/config.sh`
Applied the exact same `${_sl_pp_X:-<literal>}` shape already used for
`SL_CONFIG_FILE` to all six path variables:

```
SL_HOME="${SL_HOME:-${_sl_pp_home:-${HOME}/.local/share/agent-learning}}"
SL_STATE_DIR="${SL_STATE_DIR:-${_sl_pp_state:-${HOME}/.local/share/agent-learning/state}}"
SL_SKILLS_DIR="${SL_SKILLS_DIR:-${_sl_pp_skills:-${HOME}/.local/share/agent-learning/learned-skills}}"
SL_MEMORY_DIR="${SL_MEMORY_DIR:-${_sl_pp_memory:-${HOME}/.local/share/agent-learning/memory}}"
SL_LOG_DIR="${SL_LOG_DIR:-${_sl_pp_logs:-${HOME}/.local/share/agent-learning/logs}}"
SL_SEARCH_DB="${SL_SEARCH_DB:-${_sl_pp_sessions_db:-${HOME}/.local/share/agent-learning/sessions/search.db}}"
```

These literals mirror exactly what `paths.py`'s `resolve_home`/`resolve_all`
produce on Linux/macOS with no `AGENT_LEARNING_HOME`/`XDG_DATA_HOME` set, so
bash and Python never disagree in the normal case. Precedence is unchanged:
pre-set env (`SL_HOME` etc., or `AGENT_LEARNING_HOME` via `paths.py`) beats
config file, which beats the `paths.py` value, which beats this literal
fallback — the literal is only reached when `paths.py` itself couldn't run.

### New test — `tests/test-config.sh`
`"all six paths are non-empty and vendor-neutral with no python3"`: builds a
minimal temp `PATH` containing only symlinks to `bash` and `dirname` (the
only external commands `config.sh` itself needs besides `python3`) —
deliberately excluding `python3` — then sources `config.sh` under that `PATH`
via `env -i` and asserts all of `SL_HOME`, `SL_STATE_DIR`, `SL_SKILLS_DIR`,
`SL_MEMORY_DIR`, `SL_LOG_DIR`, `SL_SEARCH_DB` are non-empty and contain no
`.claude` segment. Uses only `mktemp -d`, `ln -s`, and `command -v` — no
GNU-only flags.

### Commands run and output

```
$ bash tests/test-config.sh
PASS: both coach flags default false
PASS: env override wins
PASS: missing file falls back to defaults
PASS: SL_HOME is vendor-neutral
PASS: AGENT_LEARNING_HOME drives SL_MEMORY_DIR
PASS: SL_REVIEW_ENABLED defaults true
agent-self-learning: CLAUDE_REVIEW_ENABLED is deprecated; use SL_REVIEW_ENABLED
PASS: legacy CLAUDE_REVIEW_ENABLED honored
PASS: SL_REVIEW_ENABLED beats legacy
PASS: default SL_CONFIG_FILE is vendor-neutral
PASS: pre-set SL_CONFIG_FILE overrides paths.py default
PASS: all six paths are non-empty and vendor-neutral with no python3 (/home/amardeep/.local/share/agent-learning|/home/amardeep/.local/share/agent-learning/state|/home/amardeep/.local/share/agent-learning/learned-skills|/home/amardeep/.local/share/agent-learning/memory|/home/amardeep/.local/share/agent-learning/logs|/home/amardeep/.local/share/agent-learning/sessions/search.db)
All config tests passed.
CONFIG_EXIT:0

$ python3 tests/test-paths.py
..........
----------------------------------------------------------------------
Ran 10 tests in 0.051s

OK
PATHS_EXIT:0

$ bash tests/test-copilot-hooks-json.sh       -> All copilot-hooks-json tests passed.
$ bash tests/test-session-review.sh           -> All session-review tests passed.
$ bash tests/test-copilot-session-review.sh   -> All copilot-session-review tests passed.
$ bash tests/test-turn-counter.sh             -> All turn-counter tests passed.
```

### Note on reviewer's Minor finding
Reviewer also flagged `config/settings-hooks.json` still containing
`bash ~/.claude/scripts/...` in its `hooks` block. Per coordinator: no action
needed — that file is Claude Code's own hook adapter config, and the
`~/.claude` constraint applies to the Copilot/VS Code code paths, not to
Claude Code's own configuration.

### Commit
`384a319` — fix(config): literal vendor-neutral fallbacks for all path vars when python3 is unavailable
