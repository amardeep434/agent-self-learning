# Task 7 Report: Claude-absent regression guard

## What was implemented

Created `tests/test-claude-absent.sh`, an executable regression guard that runs
`scripts/copilot-session-review.sh` on a machine with no `claude` binary and no
`~/.claude` directory, asserting:

1. `claude` is genuinely unreachable on the PATH used for the test (a setup
   self-check, not a behavior assertion).
2. `python3` and `jq` are genuinely reachable on that same PATH (a setup
   self-check — the brief's `MINIMAL_PATH` assumption must hold on the machine
   actually running the test).
3. After running the Copilot review pipeline end-to-end with a fake `copilot`
   binary emitting a valid proposal, `MEMORY.md` is persisted with the correct
   content — proving persistence works without Claude Code present at all.
4. No `~/.claude` directory was created as a side effect.
5. The script's own source never invokes `claude -p`.

## Deviations from the brief, with reasoning

1. **Polling instead of a fixed check-then-fail.** The brief's own Step-1 test
   snippet checks `[[ -f ... ]]` immediately after the script returns, which
   races the detached `nohup ... & disown` pipeline that Task 6 introduced.
   I replaced that immediate check with the same bounded-polling idiom already
   used in `tests/test-session-review.sh` and
   `tests/test-copilot-session-review.sh` (up to 50 iterations Ã 0.2s = 10s).
   This was flagged explicitly as required in your task instructions, and I
   verified by running the un-polled version manually — it is a race, not a
   theoretical concern (on this machine the file was not always present
   immediately). This is a strengthening, not a weakening: the assertion is
   now waiting for what actually happens instead of what the script's exit
   timing happens to allow.

2. **PATH tool resolution is verified, not assumed.** The brief's
   `MINIMAL_PATH="${FAKE_BIN}:/usr/bin:/bin"` was written on the assumption
   that `/usr/bin` has `python3` and `jq`. On this machine `python3` actually
   resolves through a pyenv shim first in the normal PATH, but `/usr/bin/python3`
   and `/usr/bin/jq` both do exist, so the brief's literal PATH works here.
   I still added defensive resolution logic (extend `MINIMAL_PATH` with the
   directory of whichever system `python3`/`jq` resolves to, only if that
   directory does *not* also expose `claude`, and hard-fail the test with a
   clear message otherwise) per your explicit instruction to verify rather
   than guess. This makes the test portable to machines where those tools live
   elsewhere (e.g. Homebrew's `/opt/homebrew/bin`) without silently leaving a
   tool unreachable, which would produce a false "nothing persisted" failure
   that looks like a real coupling bug but is actually a test-environment
   artifact.

No other deviations. I did not add an assertion on `config/copilot-hooks.json`
or the installed `~/.claude/scripts/self-learning/...` path per the explicit
scope boundary in your instructions — that remains task 7b's responsibility.
This means the guard is intentionally **partially vacuous**: it proves the
*script's own logic* is harness-neutral when invoked directly from the repo,
but not that the *installed, hook-triggered* path is (since the shipped hook
config still invokes `bash ~/.claude/scripts/self-learning/copilot-session-review.sh`).
I'm flagging this per your instructions, not fixing it here.

## Mutation test results (3/3 killed)

All mutations applied to a copy, verified to break the test, then reverted
(confirmed via `diff` against the pre-mutation backup):

1. **Neuter the spawn** (`if command -v copilot &>/dev/null; then` →
   `if false && command -v copilot &>/dev/null; then`):
   **KILLED** — `FAIL: nothing persisted with claude absent`, exit 1.

2. **Claude-namespaced persistence path** (patched
   `scripts/persist-proposal.py` to write memory under
   `$HOME/.claude/memory` instead of the resolved store path):
   **KILLED** — both `FAIL: nothing persisted with claude absent` and
   `FAIL: Copilot path created .../.claude` fired, exit 1.

3. **Something creates `~/.claude` during the run** (inserted
   `mkdir -p "${HOME}/.claude"` near the top of
   `scripts/copilot-session-review.sh`):
   **KILLED** — `FAIL: Copilot path created .../.claude`, exit 1.

killed: 3, survived: 0.

`git status --porcelain` after restoring all three mutations showed only the
new test file (`?? tests/test-claude-absent.sh`), confirming every mutation
was fully reverted.

## Full-suite result

Baseline at HEAD `7ad0fb1`: 9 shell suites + 5 Python suites, all passing —
confirmed before writing the new test.

After adding `tests/test-claude-absent.sh` (commit `0910a37`): 10 shell
suites + 5 Python suites, all passing. No regressions.

```
OK: tests/test-claude-absent.sh
OK: tests/test-config.sh
OK: tests/test-copilot-hooks-json.sh
OK: tests/test-copilot-session-review.sh
OK: tests/test-hook-input.sh
OK: tests/test-inject-agents-md.sh
OK: tests/test-session-review.sh
OK: tests/test-skillopt-run.sh
OK: tests/test-turn-counter.sh
OK: tests/test-uninstall.sh
OK: tests/test-coach-rules-eval.py
OK: tests/test-coach-signals.py
OK: tests/test-paths.py
OK: tests/test-persist-proposal.py
OK: tests/test-proposal-schema.py
OVERALL FAIL=0
```

## Concerns

- The guard is deliberately scoped to the repo-invoked script, not the
  installed/hook-triggered path (`config/copilot-hooks.json` still points at
  `~/.claude/scripts/self-learning/...`). This is a known, tracked gap per
  your scope boundary — task 7b's responsibility. Until 7b lands, a real
  install still exercises a Claude-namespaced invocation path, and this test
  cannot catch that.
- No other concerns. The test is deterministic (bounded 10s poll, no bare
  sleeps), self-verifying about its own PATH assumptions, and all three
  required mutations were load-bearing.
