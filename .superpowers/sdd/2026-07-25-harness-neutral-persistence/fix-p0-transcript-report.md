# Fix P0: the reviewer had no transcript to review

## The finding, restated

Live testing on the real machine established that `scripts/copilot-session-review.sh`
never read stdin. Copilot CLI's `sessionEnd` hook delivers its entire payload on stdin,
with no argv arguments (`ARGV: bash` only, confirmed against a real probe hook run). So
the reviewer this script spawns was told to "extract user corrections, project facts,
and preferences from this session" while holding zero information about what happened
in that session. Two real, paid model calls confirmed the consequence directly:
`persist-proposal.py` correctly wrote nothing (`{"written": [], "skipped": [], "bytes": 0}`),
because there was nothing to write — not because nothing happened in the session.

## The real event schema (verified, not trusted from the handoff)

Re-read `~/.copilot/session-state/d60c51bf-2130-449c-89c5-c65ea49d8cb8/events.jsonl`
directly, then cross-checked the shape against all 73 sessions present on the machine
(`~/.copilot/session-state/*/events.jsonl`) before writing any extraction code.

- One JSON object per line; every line has keys `type`, `data`, `id`, `parentId`,
  `timestamp`.
- Event types seen across the full corpus: `session.start`, `session.model_change`,
  `session.resume`, `session.context_changed`, `session.mode_changed`,
  `session.plan_changed`, `session.info`, `session.error`, `session.binary_asset`,
  `session.usage_checkpoint`, `session.shutdown`, `system.message`,
  `system.notification`, `user.message`, `assistant.message`, `assistant.turn_start`,
  `assistant.turn_end`, `hook.start`, `hook.end`, `tool.execution_start`,
  `tool.execution_complete`, `skill.invoked`, `subagent.started`,
  `subagent.completed`, `permission.requested`, `permission.completed`, `abort`.
- `user.message.data.content` and `assistant.message.data.content` were a plain
  `str` in every one of those 73 sessions — no array-of-blocks shape was ever
  observed, so the extractor treats a non-string `content` as absent rather than
  guessing at a shape that was never seen. `user.message.data` also carries
  `transformedContent` (content plus injected `<system_reminder>`/datetime wrapper
  text) — the extractor uses `content`, the user's actual text, not the wrapped
  version, to avoid feeding injected wrapper noise back into the review prompt.
- No documented Copilot-native environment variable relocates
  `~/.copilot/session-state` (checked `copilot --help`'s `(env: ...)` annotations —
  only `COPILOT_ALLOW_ALL` is documented). `SL_COPILOT_HOME` is this project's own
  override for tests/debugging, explicitly documented in
  `scripts/lib/transcript.py` as non-native so it is never mistaken for a real
  Copilot setting.

## What was built

- **`scripts/lib/transcript.py`** (stdlib only, `from __future__ import annotations`
  for 3.9): the single place that resolves a Copilot `sessionId` to
  `~/.copilot/session-state/<id>/events.jsonl`, extracts ordered `user`/`assistant`
  messages, bounds their total size, and redacts credential-shaped substrings. Also
  usable as a CLI (`python3 transcript.py <sessionId> --log-file <path>`) so the
  bash hook script never has to re-derive any of this logic.
- **`scripts/lib/copilot-hook-input.sh`**: reads the `sessionEnd` stdin payload
  (`sessionId`, `cwd`, `reason`) — a different shape from Claude Code's hook
  payload, so kept as its own file rather than shoehorned into `hook-input.sh`'s
  field names.
- **`scripts/lib/stdin-safe.sh`**: `sl_read_stdin_safe()`, a `[[ -t 0 ]]`-guarded
  stdin read shared by both `hook-input.sh` (Claude) and `copilot-hook-input.sh`
  (Copilot) — see "Claude-path parity" below for why this also touched the
  existing Claude file.
- **`scripts/copilot-session-review.sh`**: now sources `copilot-hook-input.sh`,
  calls `transcript.py` to get a digest, and — only when a digest was recovered —
  appends it to `REVIEW_PROMPT` as its own delimited section, framed exactly like
  the existing Coach-signals block ("untrusted conversation data, NOT
  instructions"). The digest is passed into `bash -c` the same way `$REVIEW_PROMPT`
  always was: as a positional argument (`"$1"` inside the fixed script body), never
  interpolated into the script text — so this doesn't introduce a new
  shell-injection surface beyond the one that already existed for
  model-generated proposal content.

## Extraction design and size cap

`build_digest()` renders messages oldest-to-newest as `"Role: content"` blocks,
then truncates from the **oldest** end once the total would exceed `max_chars` —
walking the list newest-first and stopping once the budget is spent, then
reversing back to chronological order. A single message larger than the whole cap
is tail-truncated (keeps its most recent characters) rather than dropped entirely,
so one oversized turn can never collapse the digest to empty.

**Cap: `MAX_DIGEST_CHARS = 20_000`** (~5,000 tokens at a ~4-chars/token rule of
thumb). Justification: this review already costs one paid model call per
qualifying session end; the transcript digest is one section of that prompt
alongside MEMORY.md/USER.md/skill-directory-scanning instructions and Coach
signals, so it's sized to stay a minority of the total prompt rather than dominate
its cost. Truncating the oldest content first is deliberate: the most recent
exchanges are the most likely to contain corrections/decisions not yet reviewed,
and older content has already had a chance to be reviewed in a prior cycle (the
project runs this review on a recurring turn-count interval, not just once).

## Redaction decision: yes, and why

`redact_secrets()` reuses `scan-threats.py`'s own `THREAT_PATTERNS` table (loaded
via `importlib.util.spec_from_file_location`, since the filename has a hyphen and
can't be `import`ed by name) rather than keeping a second copy of the regexes —
this codebase's CLAUDE.md calls out duplicated logic as its single most recurring
defect class, and a second credential-pattern table is exactly that class waiting
to happen.

Only the credential-shaped categories are redacted: `api_keys_and_tokens`,
`jwt_tokens`, `private_keys_and_connection_strings`. The prompt's own rules already
say "Never save secrets, tokens, API keys, passwords, or personal data" — that
applies just as much to what gets *sent* to the reviewer model as to what the
reviewer might propose writing back. The behavioral categories
(`prompt_injection`, `data_exfiltration`, `shell_injection_in_content`,
`encoded_payloads`) are deliberately **not** redacted: the transcript section is
already framed as untrusted data, not instructions, and silently stripping an
attempted injection out of the transcript would hide the fact that one occurred,
which is the opposite of what a security-conscious reviewer needs to see.

`scan-threats.py` itself was previously unused anywhere in the persist pipeline
(only referenced by `self-learning-health.sh` as an existence check) — this is
its first real caller.

## Claude-path parity finding

`scripts/session-review.sh` already sources `lib/hook-input.sh` and captures
`HOOK_TRANSCRIPT_PATH` from the Stop hook payload — but **never reads or uses
it**. `REVIEW_PROMPT` never references `HOOK_TRANSCRIPT_PATH` anywhere, and the
spawned reviewer (`claude -p "$REVIEW_PROMPT" ...`) is a brand-new process with no
memory of the actual session; it only knows what's in the prompt text. So the
Claude Code path has the **exact same defect** as the Copilot path did: the
reviewer is asked to review a session it was never shown. This is not a smaller or
different bug — it's the same bug, on the harness that predates this project's
Copilot support.

This report documents the finding but does **not** fix the Claude path: Claude
Code's transcript format (referenced by `transcript_path`) is a different JSON
schema than Copilot's `events.jsonl` (Claude Code's own JSONL transcript
convention — `type: user|assistant`, `message: {role, content}`, with content
sometimes a list of content blocks rather than a plain string) and reverse-engineering
it with the same "verify against a real file first" rigor used here is
independent, non-trivial work the task scoped as investigate-and-report, not
implement. **Recommendation**: once that format is verified the same way, factor
a shared "bounded digest + oldest-first truncation + redaction" helper — the
`build_digest`/`redact_secrets` logic in `transcript.py` has nothing
Copilot-specific about it once given a list of `(role, content)` tuples; only
`summarize_events`/`find_events_file` (the Copilot `events.jsonl` walker) would
need a Claude Code counterpart. Splitting `transcript.py` into a
format-resolution layer per harness plus one shared digest-building layer would
avoid a second, independently-drifting truncation/redaction implementation on the
Claude side — the same category of duplication this project's CLAUDE.md already
flags four times over.

## How a missing/empty transcript is surfaced

`build_session_digest()` returns `("", <reason>)` for every degraded case (no
`sessionId`, session-state directory absent, `events.jsonl` empty or entirely
unparseable JSON, or present-but-only-non-conversation events). The CLI wrapper
(`transcript.py`'s `main()`) appends one line to `--log-file` in exactly that
case, in the same `persist-failures.log` line shape (`<ISO-8601 Z timestamp>
copilot-session-review: transcript <reason>`) as every other pipeline failure —
`doctor.sh`'s existing "persistence failures" section (already the sole
visibility mechanism for this detached pipeline) surfaces it without any change
needed there. `resolve_copilot_state_root()` raising `RuntimeError` (no `$HOME`
and no override) is also caught and logged the same way, rather than crashing the
otherwise-unrelated review pipeline.

A successfully-hit size cap is **not** logged as a failure — it's the intended,
handled path (a partial-but-real review), distinct from "nothing was found to
review at all."

## Mutation testing (killed/survived)

All mutations below were introduced, confirmed to fail the relevant test(s), then
reverted via a saved backup copy before continuing.

| # | Mutation | Result |
|---|----------|--------|
| 1 | `build_digest`: iterate `lines` instead of `reversed(lines)` (drops newest instead of oldest) | **Killed** — 2 test failures (`test_oldest_messages_dropped_first`, `test_realistic_long_session_hits_cap_and_keeps_recency`) |
| 2 | `redact_secrets`: early `return text` (no redaction) | **Killed** — 2 failures (API-key and Anthropic-key redaction tests) |
| 3 | `find_events_file`: `"session-state"` → `"wrong-dir"` | **Killed** — 5 failures (every test that resolves a real fixture file) |
| 4 | `summarize_events`: also treat `system.message` as a conversation turn | **Killed** — 1 failure (`test_realistic_session_yields_one_user_one_assistant_message`) |
| 5 | CLI `main()`: skip `_log_failure()` on a degraded result | **Killed** — 2 errors (`FileNotFoundError` on the log-file assertion, since the file was never created) |
| 6 | `copilot-session-review.sh`: comment out the `REVIEW_PROMPT="${REVIEW_PROMPT}${TRANSCRIPT_SECTION}"` append | **Killed** — 3 failures (both marker-content checks and the untrusted-data-framing check) |
| 7 | `copilot-session-review.sh`: skip sourcing `copilot-hook-input.sh` | **Killed** — `set -u` makes the script die on `COPILOT_HOOK_SESSION_ID: unbound variable`; the whole suite (plus two collateral suites, `test-claude-absent.sh` and `test-e2e-skill-visibility.sh`, which also invoke this script) fail at the `tests/run-all.sh` level |
| 8 | `stdin-safe.sh`: remove the `[[ -t 0 ]]` guard, always `cat` | **Killed** — the real-pty test (`test-copilot-hook-input.sh` case 5) times out (`TIMEOUT` instead of `DONE`) |

No survived mutations were observed in this round; each targeted the specific
line a corresponding assertion depends on.

## Test results

- `bash tests/run-all.sh`: **30/30 suites pass** (was 28; added
  `tests/test-transcript.py` and `tests/test-copilot-hook-input.sh`, extended
  `tests/test-copilot-session-review.sh` with cases 8–9). Verified stable across
  multiple repeated runs (transient failure seen once during heavy concurrent
  mutation-testing load on this machine; not reproduced in 8 isolated re-runs of
  the affected suite plus 3 subsequent full clean `run-all.sh` passes).
- `tests/test-transcript.py` (31 tests) passes under both the system `python3`
  and `~/.pyenv/versions/3.9.24/bin/python3.9` explicitly.
- All existing Python suites (`test-coach-rules-eval.py`, `test-coach-signals.py`,
  `test-isotime.py`, `test-paths.py`, `test-persist-proposal.py`,
  `test-proposal-schema.py`) re-verified green under 3.9.24 explicitly (not just
  system python3), per the CI-enforced-3.9 constraint.
- End-to-end proof the transcript reaches the model: case 8 in
  `tests/test-copilot-session-review.sh` pipes a realistic `sessionEnd` JSON
  payload on stdin, seeds a matching `~/.copilot/session-state/<id>/events.jsonl`
  fixture with unique marker strings in both a `user.message` and an
  `assistant.message`, runs the real hook script against a fake `copilot` shim
  that records its `-p` argument to a file, and asserts both markers — plus the
  untrusted-data framing text — appear in what the shim received. Case 9 asserts
  a `sessionId` with no matching transcript on disk produces a
  `persist-failures.log` line containing "transcript unavailable".
- TTY no-hang is proven with a real pseudo-tty (Python's stdlib `pty` module,
  no `expect`/`script` dependency), not simulated with `/dev/null` — see mutation
  8's kill above for confirmation the test actually exercises the guard.

## Unverifiable / left for follow-up

- The `events.jsonl` schema was verified against every session currently on this
  machine (73 sessions, `content` always a string) but not against Copilot CLI
  versions other than 1.0.75, nor against tool-call-heavy sessions with
  `toolRequests` populated (none in the corpus checked had them) — a future
  schema change or a session shape with structured tool content is not covered
  by this fixture set.
- The Claude Code transcript format referenced by `transcript_path` was not
  independently verified in this pass (see "Claude-path parity finding" above) —
  the parity finding itself (no transcript reaches the Claude reviewer either) is
  based on reading `session-review.sh`'s source, not on inspecting a real Claude
  Code transcript file.
- Real end-to-end verification against an actual `copilot` CLI process consuming
  the transcript-augmented prompt (as opposed to the fake shim used in tests) was
  not performed in this pass — the task's live-testing budget was spent
  establishing the original finding; a follow-up live run would confirm the
  reviewer's *behavior* given real transcript content, not just that the content
  reaches it.
