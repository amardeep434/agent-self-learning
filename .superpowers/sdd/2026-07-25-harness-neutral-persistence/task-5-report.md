# Task 5 Report — Invert the Claude Code reviewer

## Status: DONE

## What changed

`scripts/session-review.sh`:
- Added `SCRIPT_DIR` (derived the same way `LIB_DIR` already was) since the new
  spawn block needs an absolute path to `persist-proposal.py`.
- Switched the enable-flag read from `CLAUDE_REVIEW_ENABLED` to
  `SL_REVIEW_ENABLED` (Task 2 already added the deprecated-fallback logic in
  `scripts/lib/config.sh`; this script just needed to read the new name).
- Replaced the "Write to MEMORY.md or USER.md as appropriate" instruction in
  the review prompt with the brief's exact stdout-only OUTPUT CONTRACT
  (fenced JSON, `version`/`memory`/`skills` shape, explicit "do NOT write any
  file" instruction), and tightened the tool-permission bullets to
  Read/Glob/Grep only (dropped Write/Edit and "mkdir").
- Replaced the synchronous `claude -p ... > "$REVIEW_LOG" 2>&1 &` spawn with
  the brief's detached pipeline: `nohup bash -c '... "$1" -p "$2" | python3
  "$4" ...' _ claude "$REVIEW_PROMPT" "$SL_LOG_DIR"
  "${SCRIPT_DIR}/persist-proposal.py"`, backgrounding the entire
  reviewer-into-writer pipeline (not just the reviewer), with arguments
  passed positionally (never interpolated) and pipeline failures appended to
  `${SL_LOG_DIR}/persist-failures.log`.

`tests/test-session-review.sh`:
- Appended a new case (test 5) using the brief's fake-`claude`-emits-JSON
  fixture and the bounded-poll wait, verifying `MEMORY.md` ends up written
  with the reviewer's proposed content by the writer, not the agent.

## Deviation from the brief (and why)

The brief's Step-1 test snippet invokes `session-review.sh` in a bare
`env -i` sandbox with no pre-existing `turn_counter.json`. I ran it verbatim
first and it failed for the wrong reason: `session-review.sh` exits 0 early
at `if [[ ! -f "$COUNTER_FILE" ]]; then exit 0; fi` before ever reaching the
prompt-build/spawn code, so the reviewer is never invoked — the test would
report "MEMORY.md was not written" regardless of whether the fix was applied
(false negative disguised as the expected red state, and it would never turn
green).

Fix: before invoking the script, the test now seeds
`${TMP_HOME}/store/state/turn_counter.json` with
`total_turns_this_session: 9` (above `SL_REVIEW_MIN_TURNS` default of 5),
under the state dir that `AGENT_LEARNING_HOME=${TMP_HOME}/store` actually
resolves to (verified via `scripts/lib/paths.py`). Everything else in the
brief's test snippet (fake `claude`, bounded poll, assertion, cleanup) is
verbatim.

I confirmed the TDD sequence properly:
1. With the seeded counter file and the *original* `session-review.sh`
   (stashed my script changes), the test fails with exactly
   `FAIL: MEMORY.md was not written by the writer` — the reviewer runs, does
   nothing itself, and the file is absent. True red.
2. With the fix applied, the test passes. True green.

No other deviations. Positional-argument passing into `bash -c` and the
`persist-failures.log` visibility mechanism are preserved exactly as
specified.

## Test command and output

```
$ bash tests/test-session-review.sh
PASS: claude was invoked
PASS: guard env set for reviewer
PASS: guarded entry spawns nothing
PASS: coach signal id reaches prompt
PASS: settings-hooks.json nested schema
PASS: no reference to nonexistent rolling-transcript.sh
PASS: reviewer proposal persisted
All session-review tests passed.
```
exit 0

Ran 3x in a row for flakiness — all green (the detached-pipeline poll has
margin: writer completes in well under the 10s bound).

Also ran adjacent suites to confirm no regressions:
`tests/test-config.sh`, `tests/test-hook-input.sh`,
`tests/test-turn-counter.sh`, `tests/test-copilot-session-review.sh` — all
pass, 0 FAIL lines.

## Files modified

- `/home/amardeep/claude-self-learning/.claude/worktrees/hnp/scripts/session-review.sh`
- `/home/amardeep/claude-self-learning/.claude/worktrees/hnp/tests/test-session-review.sh`

## Commit

`050a106` — `fix(review): reviewer proposes on stdout, script persists (Claude Code path)`

## Anything unsure

- The brief's own Step-1/Step-2 test snippet, taken completely literally,
  never exercises the spawn path (see Deviation above). I'm confident in the
  fix (verified true red/green with the counter-file seed added) but flagging
  it in case the brief's author wants the upstream task-5-brief.md itself
  corrected for future reuse.
- I left `LOG_DIR="${SL_LOG_DIR}/reviews"` and its `mkdir -p` in place (still
  used by `coach-signals.err`); the new spawn's stderr/persist/failure logs
  go directly under `${SL_LOG_DIR}` per the brief, so the script now writes
  into two related but distinct locations (`${SL_LOG_DIR}/reviews/…` for
  coach-signals errors, `${SL_LOG_DIR}/…` for the pipeline). This matches the
  brief's spawn block verbatim; did not attempt to unify them since that
  wasn't asked for.

## Fix round 1 (post-review)

**Finding:** the plan's spawn snippet (which I implemented verbatim) dropped
`--max-turns "${SL_REVIEW_MAX_TURNS}"` and `--output-format text` from the
backgrounded `claude -p` invocation. `SL_REVIEW_MAX_TURNS` became an orphaned
knob (defined in `scripts/lib/config.sh`, read nowhere), and — the important
part — the background reviewer ran with no turn cap at all, which is the
opposite of what a cost-efficiency framework should ship.

**Fix:** restored both flags on the `"$1" -p "$2" ...` line inside the
`bash -c` body, with `SL_REVIEW_MAX_TURNS` appended as a new positional
argument (`"$5"` inside the script, passed as the script's 5th argument
after `${SCRIPT_DIR}/persist-proposal.py`). `$REVIEW_PROMPT` is still never
interpolated into the script body — only referenced by positional number.

**On `--output-format text`:** confirmed correct before restoring, not just
restored on faith. `scripts/persist-proposal.py` reads reviewer stdout and
calls `proposal_schema.extract_proposal(raw_text)`, which scans plain text
for a fenced ` ```json ` block (see `tests/test-proposal-schema.py`, e.g.
`extract_proposal(text)` fed raw strings containing prose + a fenced block).
Claude Code's `--output-format text` prints exactly that — the model's plain
final message, unwrapped. The alternative, `--output-format json`, wraps the
response in an envelope (`{"type":"result","result":"...","...": ...}`),
which would nest the reviewer's proposal one level deeper inside a bigger
JSON object; `extract_proposal`'s brace-scanning would find the *outer*
envelope object first (or get confused by nested JSON depth), not the
intended proposal. So `text` is the only format compatible with the current
extraction contract, and restoring it explicitly (rather than relying on it
being the CLI default) documents that as a hard requirement, not an
accident.

**Test:** added to `tests/test-session-review.sh` test case 5. The fake
`claude` shim now records its own argv to `${TMP_HOME}/claude-argv.log`
(via a `FAKE_CLAUDE_ARGV_LOG` env var threaded through the `env -i` call)
before emitting its canned proposal. Two new assertions run after the
existing persistence check:
- `spawn passes turn cap` — greps the argv log for `--max-turns 16` (16 is
  `SL_REVIEW_MAX_TURNS`'s default from `config.sh`; this test's `env -i`
  sandbox sets no override and no config file).
- `spawn passes plain-text output format` — greps the argv log for
  `--output-format text`.

Mutation-tested the fix the same way as round 0: stashed only
`scripts/session-review.sh` (keeping the updated test), reran, got both new
assertions failing with `expected 'yes', got 'no'` while everything else
still passed — confirming they truly depend on the restored flags rather
than trivially passing. Then restored the fix and reran to green.

### Test command and output (post-fix)

```
$ bash tests/test-session-review.sh
PASS: claude was invoked
PASS: guard env set for reviewer
PASS: guarded entry spawns nothing
PASS: coach signal id reaches prompt
PASS: settings-hooks.json nested schema
PASS: no reference to nonexistent rolling-transcript.sh
PASS: spawn passes turn cap
PASS: spawn passes plain-text output format
PASS: reviewer proposal persisted
All session-review tests passed.
```
exit 0

Ran 3x for flakiness — all green. Also re-ran `tests/test-config.sh`,
`tests/test-hook-input.sh`, `tests/test-turn-counter.sh`,
`tests/test-copilot-session-review.sh` — all pass, 0 FAIL lines.

### Files modified (round 1)

- `/home/amardeep/claude-self-learning/.claude/worktrees/hnp/scripts/session-review.sh`
- `/home/amardeep/claude-self-learning/.claude/worktrees/hnp/tests/test-session-review.sh`

### Commit (round 1)

`1085b6a` — `fix(review): restore --max-turns/--output-format on backgrounded reviewer`
