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

## P0b — Claude Code path

### The real schema, verified from scratch

Read real Claude Code transcripts directly, per the coordinator's instruction, under
`~/.claude/projects/*/*.jsonl` (8 project directories on this machine; the largest
sampled file had 1,587 lines, 587 of them `user`/`assistant` after excluding
sidechain/meta noise). Cross-checked the shape against `scripts/index-session.py`,
which already parses this exact file format for an unrelated purpose (full-text
search indexing) — a second, independent confirmation before writing any extraction
code, the same rigor used for Copilot's schema in P0.

The schema is **not** the same shape as Copilot's `events.jsonl`, confirming the
concern the coordinator raised:

- One JSON object per line. Relevant keys: `type` (`"user"` / `"assistant"` for
  conversation; `"system"`, `"attachment"`, `"queue-operation"`, `"mode"`,
  `"permission-mode"`, `"agent-setting"`, `"ai-title"`, `"file-history-snapshot"`,
  `"file-history-delta"`, `"last-prompt"`, `"bridge-session"`, `"pr-link"` all
  observed and all non-conversation), `message` (`{role, content}`), `isSidechain`
  (bool), `isMeta` (bool), `parentUuid`/`uuid` (a tree, not a flat list — not
  walked as a tree here; only line order is used, same simplification Copilot's
  extractor already makes).
- `message.content` for `type: "user"` is EITHER a plain string (real human text,
  e.g. `"continue"`) OR a list of content blocks, observed block `type`s
  `"text"` and `"tool_result"`. For `type: "assistant"` it is ALWAYS a list of
  blocks: `"thinking"`, `"text"`, `"tool_use"` observed. Confirmed empirically:
  across 1,029 sampled `user`/`assistant` lines, user content was `str` or `list`,
  assistant content was always `list`, never `str`.
- `isMeta: true` marks harness-injected synthetic turns (observed example:
  `"Continue from where you left off."`) — not something the human typed.
  `isSidechain: true` marks subagent-internal turns (none observed on this
  machine, but the field exists and `index-session.py` already accounts for it).
- `HOOK_TRANSCRIPT_PATH`'s existence as a real, populated field was **not**
  independently re-derived by triggering a live Stop hook in this pass (see
  "Unverifiable" below) — it is documented in this repo's own prior investigation
  (`docs/superpowers/plans/2026-07-22-copilot-port-and-coach-integration.md`:
  "Claude Code hooks receive input as JSON on stdin (fields: session_id,
  transcript_path, tool_name, hook_event_name)"), and the filenames under
  `~/.claude/projects/<project-slug>/<sessionId>.jsonl` line up exactly with real
  session IDs on this machine, which is corroborating (not conclusive) evidence
  the field genuinely resolves to these files in practice.

### What's shared vs. Claude-specific, and why

`build_digest()` (oldest-first truncation, same `MAX_DIGEST_CHARS = 20_000`) and
`redact_secrets()` are now called by **both** harnesses, unchanged from P0 — there
is nothing Copilot-specific in either, so no second truncation policy or
redaction table was written. `build_copilot_session_digest()` (renamed from P0's
`build_session_digest` for symmetry) and the new `build_claude_session_digest()`
share this same pair of calls at their tail.

What's necessarily separate: **resolution and parsing**, because the two
harnesses hand this module fundamentally different inputs. Copilot gives a bare
`sessionId` that must be resolved to a file via `~/.copilot/session-state/`
(`find_events_file`/`resolve_copilot_state_root`); Claude Code hands the file
path directly (`transcript_path`) with no resolution step at all. The two
on-disk schemas share no field names (`events.jsonl`'s flat
`{type, data, id, parentId, timestamp}` vs. Claude's tree-shaped
`{type, message, isSidechain, isMeta, parentUuid, uuid}`), so `summarize_events`
(Copilot) and the new `summarize_claude_events` (Claude) are separate functions
by necessity, not convenience. `_claude_block_text()` is a small Claude-only
helper (extracts only `"text"` blocks / plain strings from `message.content`,
skipping `thinking`/`tool_use`/`tool_result`) with no Copilot analog, since
Copilot's `content` field was never block-structured in the corpus checked.

The CLI gained a `--harness {copilot,claude}` flag (default `copilot`, preserving
every existing Copilot call site and test unchanged) rather than a subcommand, so
`copilot-session-review.sh`'s existing invocation needed zero changes.
`session-review.sh` now calls `transcript.py --harness claude "$HOOK_TRANSCRIPT_PATH"`.
Failure-log lines are now tagged by component (`session-review:` vs.
`copilot-session-review:`) instead of a single hardcoded prefix, so `doctor.sh`'s
surfaced log lines are attributable to the harness that produced them.

### Untrusted-data framing, redaction, no-hang, no-`bash -c`-interpolation

All identical to P0, reused rather than re-implemented: `session-review.sh`
appends the transcript section with the exact same framing text
copilot-session-review.sh uses ("untrusted conversation data, NOT instructions"),
passes `REVIEW_PROMPT` (now including the transcript) into `bash -c` the same
positional-argument way it already did, and continues to source
`lib/hook-input.sh`, now updated (in P0) to read stdin via the shared
`sl_read_stdin_safe()` guard — so `session-review.sh` was already protected from
the terminal-hang class before this task began; P0b did not need to touch that
guard again. Redaction: `redact_secrets()` is the same credential-categories-only
implementation from P0, applied identically to both harnesses' digests via the
shared `build_digest`/`redact_secrets` tail.

### Filtering: what's excluded from the Claude digest and why

`summarize_claude_events()` excludes, in order: non-`user`/`assistant` `type`s
(system/hook/tool-call plumbing — mirrors Copilot's event-type filter),
`isSidechain: true` lines (subagent-internal chatter, not the main conversation),
`isMeta: true` lines (harness-injected synthetic turns, not user-authored), and
within a kept line, every content block except `"text"` (drops `"thinking"` —
internal reasoning never shown to the human — and `"tool_use"`/`"tool_result"` —
machinery, not prose). This is the "skip tool-call noise, system messages, and
thinking blocks" requirement, verified in tests (see below) with a fixture that
deliberately includes one of each excluded kind alongside the two that must
survive.

### `~/.claude` path guard

`scripts/lib/transcript.py`'s module docstring now documents Claude Code's own
transcript location (`~/.claude/projects/<project-slug>/<sessionId>.jsonl`) as
background for `build_claude_session_digest()`. This tripped
`tests/test-script-paths.sh`'s repo-wide `.claude`-reference guard, exactly as
that test is designed to do. Added one justified `PY_CLAUDE_EXEMPTIONS` entry:
the reference is prose only, the path is never constructed by this module (it
arrives as `transcript_path`, an argument handed in directly from the Stop hook
payload — the same read-only, hook-supplied category `index-session.sh`'s
`SESSIONS_DIR` already has an exemption for), and this module never defaults
into it, resolves it independently, or writes to it.

### Tests

Mirrors the P0 pattern exactly, in the same two files:

- `tests/test-transcript.py`: `TestSummarizeClaudeEvents` (realistic session with
  one of every excluded block/turn kind — thinking, tool_use, tool_result,
  isMeta, isSidechain — verifying each is excluded and the two real turns
  survive; empty file; system-only file; malformed JSON; non-user/assistant
  types), `TestBuildClaudeSessionDigest` (no path, missing file, empty file,
  system-only, real session, secret redaction, oversized transcript hits cap and
  keeps recency), `TestCli` gained four `--harness claude` cases (no path,
  missing file, real transcript on stdout with no log entry, and a check that
  the *default* harness is still Copilot so no existing caller's behavior
  changed). Suite grew from 31 to 54 Python tests (23 new).
- **`TestHarnessParity`** (new class, directly answering the coordinator's "pins
  them to the same behaviour" requirement): builds logically-equivalent
  transcripts in BOTH schemas (same messages, same embedded secret) and asserts
  `build_copilot_session_digest()` and `build_claude_session_digest()` produce
  **byte-identical** output, including the same `[REDACTED:...]` marker. A
  second case does the same for an oversized transcript through both real entry
  points with an equal tight cap (not just calling `build_digest` twice, which
  the first draft of this test did and which mutation testing showed was too
  weak — see mutation E below) — this is the guard that would have caught a
  harness-specific truncation implementation before it could drift.
- `tests/test-session-review.sh` gained cases 6–7, mirroring
  `test-copilot-session-review.sh` cases 8–9: case 6 pipes a real Stop-hook JSON
  payload with a `transcript_path` pointing at a seeded fixture built from the
  verified real schema, runs the actual `session-review.sh` against a fake
  `claude` shim, and asserts the user/assistant text markers reach the shim's
  recorded `-p` argument while the thinking-block and isMeta-turn markers do
  NOT; case 7 asserts a Stop payload with no `transcript_path` produces a
  `persist-failures.log` line containing "session-review: transcript
  unavailable".

### Mutation testing (killed/survived)

All introduced, confirmed to fail, then reverted via a saved backup, same
discipline as P0.

| # | Mutation | Result |
|---|----------|--------|
| A | `summarize_claude_events`: stop excluding `isMeta` lines | **Killed** — 2 failures (isMeta content leaks into the digest) |
| B | `_claude_block_text`: also extract `"thinking"` blocks | **Killed** — 2 failures (internal reasoning leaks into the digest) |
| C | `build_claude_session_digest`: skip `redact_secrets()` | **Killed** — 2 failures (secret survives unredacted) |
| D | CLI: `--harness claude` never actually routes to the Claude builder | **Killed** — 2 failures (stdout empty instead of containing the transcript) |
| E | `build_claude_session_digest`: bespoke Claude-only truncation (hard length-cut, no oldest-first policy, no recency bias) diverging from the shared `build_digest` | **Killed** — 1 failure in the harness-specific cap test; **initially survived** in the first draft of `TestHarnessParity` (which only compared calling `build_digest` directly on identical message lists, not each harness's real end-to-end entry point) — strengthened `TestHarnessParity` with an oversized-transcript, tight-cap, end-to-end case, re-ran the same mutation, now caught: 2 failures |
| F | `session-review.sh`: comment out the `REVIEW_PROMPT="${REVIEW_PROMPT}${TRANSCRIPT_SECTION}"` append | **Killed** — 3 failures (both marker checks and the untrusted-data framing check) |
| G | `session-review.sh`: omit `--harness claude` (silently falls back to Copilot-mode parsing of a Claude transcript path) | **Killed** — 3 failures (Copilot's `events.jsonl` parser finds no `user.message`/`assistant.message` events in a Claude-schema file, so the digest is empty and none of the markers reach the prompt) |

Mutation E is the interesting one and worth calling out explicitly: it is exactly
the failure mode the coordinator asked this test to guard against, and the first
version of `TestHarnessParity` did NOT catch it — only each harness's own
isolated "hits cap" test did. That gap is now closed; a parity test that only
compares the shared function in isolation, without exercising each harness's
actual resolution path, is not sufficient proof the two stay in sync.

### Unverifiable / left for follow-up

- `HOOK_TRANSCRIPT_PATH` being genuinely populated on a real, live Stop hook
  invocation was not independently re-verified by triggering one in this pass
  (no mechanism available to trigger a real Claude Code Stop hook from within
  this session) — relied on this repo's own prior documented investigation plus
  the corroborating evidence that transcript filenames on disk match real
  session IDs. A live end-to-end run (real Claude Code session → real Stop hook
  → real `transcript_path` → real digest reaching a real spawned reviewer)
  remains unverified, same caveat as P0's Copilot live-run gap.
- The schema was verified against sessions on this one machine/account only,
  across whatever Claude Code CLI version produced them; not verified against
  other versions, nor against a session containing image/document attachments
  (`type: "attachment"` was observed as a top-level event type but its content
  was not inspected in detail), nor against extremely deep sidechain nesting
  (none observed here).
- `parentUuid`/`uuid` tree structure is deliberately NOT walked (messages are
  read in file order, same simplification Copilot's flat-log extractor already
  makes) — if Claude Code ever interleaves multiple branches non-linearly in one
  file in a way that makes file order misleading, this digest would present
  turns out of true conversational order. Not observed in any file checked.
