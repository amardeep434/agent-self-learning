# Task 6 Report: Invert the Copilot reviewer

## Status: Complete

## Commit
`a934cb3` — "fix(review): Copilot reviewer proposes on stdout; drop --allow-tool write"

## What changed

### `scripts/copilot-session-review.sh`
- Added `SCRIPT_DIR` (was missing; `LIB_DIR` existed but nothing exposed the
  script's own directory for the writer path). `LIB_DIR="${SCRIPT_DIR}/lib"`.
- Replaced the `REVIEW_PROMPT`'s write-oriented rule ("Only read and write
  files under ...") with a read-only rule, and appended the same stdout-only
  OUTPUT CONTRACT block used in `scripts/session-review.sh` (fenced `json`
  block, `version`/`memory`/`skills` schema, MEMORY.md/USER.md + mode +
  skill-name-regex rules).
- Replaced `MODEL_ARGS` with `COPILOT_ARGS=(-s --allow-tool read)`, appending
  `--model "${SL_COPILOT_REVIEW_MODEL}"` under the **unchanged** regex guard
  `^[A-Za-z0-9._-]+$`. `--allow-tool write` is gone entirely.
- Replaced the synchronous `copilot ... > "$REVIEW_LOG" 2>&1 &` spawn with a
  fully backgrounded pipeline: `nohup bash -c '...' &` runs `copilot "$@" -p
  "$prompt" | python3 "$writer"` inside a subshell with `set -o pipefail`, so
  a reviewer crash isn't masked by the writer's own exit code. Arguments
  (`$REVIEW_PROMPT`, `$SL_LOG_DIR`, the writer path, then `COPILOT_ARGS`) are
  passed positionally into `bash -c`, never interpolated into the script
  body — `$REVIEW_PROMPT` is model-influenced text over multiple turns of
  conversation history, so string-interpolating it would be a shell-injection
  hole. `COPILOT_ARGS` is expanded last (after `shift 3`) since it's the only
  variable-length piece and must land in `"$@"` for the `copilot "$@" -p
  "$prompt"` call inside the subshell.
- On non-zero pipeline exit, appends a line to
  `${SL_LOG_DIR}/persist-failures.log` — the only visibility mechanism now
  that the pipeline is detached (matches `session-review.sh` and what
  `doctor.sh` will surface in Task 9).
- `mkdir -p "${SL_LOG_DIR}"` added before the nohup call (the pre-existing
  `LOG_DIR="${SL_LOG_DIR}/reviews"` mkdir at the top is unrelated — it backs
  `coach-signals.err`, unchanged).

### `tests/test-copilot-session-review.sh`
- Appended test 7 (from the brief, used verbatim): a fake `copilot` binary
  that exits 3 with `FAIL_MARKER: write tool was requested` if it ever sees a
  bare `write` argument, and otherwise emits a valid JSON proposal on stdout.
  Runs the script under `env -i` isolation with `AGENT_LEARNING_HOME` pointed
  at a temp store, then **polls** for `${TMP_HOME}/store/memory/MEMORY.md`
  (up to 50 × 0.2s = 10s) rather than asserting immediately or sleeping a
  fixed amount, since the pipeline is detached and its completion time is
  not deterministic. Asserts the persisted file's content is exactly
  `copilot-persisted`.

## Exact test command and full output

```
$ bash tests/test-copilot-session-review.sh
PASS: copilot invoked
PASS: guard env set
PASS: headless flags present
PASS: no model flag when unset
PASS: model flag when set
PASS: guarded entry spawns nothing
PASS: hook template version 1
PASS: sessionEnd command hook
copilot-session-review: ignoring invalid SL_COPILOT_REVIEW_MODEL
PASS: hostile model string dropped
PASS: untrusted-data framing in prompt
PASS: copilot proposal persisted
All copilot-session-review tests passed.
```
(exit 0)

Before the implementation step, the same command failed as expected:
`FAIL: Copilot path did not persist` (exit 1), confirming the TDD RED step.

Also re-ran the full test suite (`tests/*.sh`) after the change; all 9 test
files still pass, including `test-session-review.sh` (Task 5's equivalent,
untouched) and `test-config.sh`.

## `copilot --help` findings on turn/step caps

Ran `copilot --help` and `copilot help limits` against the installed binary
(`/home/amardeep/.local/bin/copilot`, v1.0.73). Findings:

- There is **no** `--max-turns`, `--max-steps`, or any per-turn/per-tool-call
  iteration cap exposed by the CLI. `--max-autopilot-continues <count>`
  exists but is scoped to interactive `--mode autopilot` (autopilot
  continuation messages), not to `-p`/non-interactive headless runs — it
  does not apply to this hook's invocation shape at all.
- The only cost-control knob for non-interactive `-p` runs is
  `--max-ai-credits <credits>` (minimum 30), a **soft, credit-based** cap
  from the `limits` help topic — accounted only after a model response
  returns, so a single response can exceed it before the CLI can react.
  This is a different unit and semantics than `SL_REVIEW_MAX_TURNS` (a turn
  count with default 16): credits and turns don't have a fixed conversion,
  and the documented minimum (30) doesn't obviously map to "16 turns" in any
  principled way.

**Conclusion:** Copilot CLI genuinely has no turn/step cap equivalent to
`--max-turns` for headless `-p` runs. I did **not** wire `SL_REVIEW_MAX_TURNS`
to `--max-ai-credits` — mapping a turn count onto a credit count would be a
fabricated, misleading conversion, not real cost control, and the task
brief's own "Interfaces / Consumes" list for this task deliberately omits
`SL_REVIEW_MAX_TURNS` (unlike the Claude Code path's interfaces), which is
consistent with this being a known, accepted gap rather than an oversight.
This means the Copilot reviewer path currently has **no hard bound** on the
underlying model's tool-call/reasoning loop length within a single `-p`
invocation — flagging this explicitly per the carry-over instruction rather
than silently omitting cost control. If cost control here matters, the
follow-up would be introducing a new var (e.g. `SL_COPILOT_MAX_AI_CREDITS`)
that maps to `--max-ai-credits` on its own terms — not reusing
`SL_REVIEW_MAX_TURNS`, which isn't in this task's interface contract.

## Deviations from the brief

None of substance. Implementation follows the brief's Step 3 code verbatim,
with two additions the brief's snippet omitted but which were necessary for
the file to actually run:
1. Introduced `SCRIPT_DIR` (the brief's snippet references
   `${SCRIPT_DIR}/persist-proposal.py` but the file only had `LIB_DIR`
   before this task).
2. Kept the pre-existing `LOG_DIR="${SL_LOG_DIR}/reviews"` block (backs
   `coach-signals.err`) untouched, alongside the new `mkdir -p
   "${SL_LOG_DIR}"` the brief specifies for the pipeline's own logs — these
   are two different directories used for two different purposes, both
   still needed.

## Anything unsure

- Whether a future task should add a Copilot-specific credit cap
  (`SL_COPILOT_MAX_AI_CREDITS` → `--max-ai-credits`) is a product decision
  outside this task's scope; flagged above rather than decided unilaterally.
