# Residuals research round — `harness-neutral-persistence`

Date: 2026-07-26
Branch: `harness-neutral-persistence` (nothing pushed; commits are local)
Suite at start: 41 suites, all green. Suite at end: **42 suites, all green.**
Python: all Python suites run under `~/.pyenv/versions/3.9.24/bin/python3.9`.

Four documented residuals were re-investigated with the instruction *"deep
research, ground everything in evidence, make no assumptions"* — including
the assumption that the residual descriptions themselves were correct. Two
of the four turned out to rest on claims that were simply false, and the
falsifying evidence was already on this machine or in this repo's own CI log.

| # | Residual | Outcome |
|---|---|---|
| 1 | Windows has no `O_NOFOLLOW`, so `dir_fd` TOCTOU hardening does not cover it | **Partially closed** — premise confirmed, but "unfixable" disproven; a documented Win32 fix exists and is now specified in code. Implementation deliberately deferred (cannot be executed from a POSIX host). |
| 2 | WSL-vs-Git-Bash ambiguity, "untestable without a PowerShell CI job" | **Closed** — the claim was wrong twice over; the resolver was already running on Windows CI. Windows-specific assertions added. |
| 3 | 34 of 45 Coach rules "need per-request telemetry this project never captures" | **Largely closed** — the framing was wrong. 8 rules now evaluate from telemetry that was already on disk; 11 of the rest are IDE-only *by upstream's own flag*; 15 are reachable-but-unimplemented with a named cost. 11/45 → **19/45**. |
| 4 | No genuine interactive `sessionEnd` with real conversation history | **Closed to the stated limit** — real historical sessions from both harnesses now demonstrably reach the prompt, at zero cost. One narrow gap remains, stated precisely below. |

Commits (in order):

| SHA | Subject |
|---|---|
| `e4cb1f9` | `feat(coach): plumb harness-native telemetry — 11 of 45 rules to 19` |
| `967d0ef` | `test(ps1): assert the WSL-vs-Git-Bash distinction on Windows; correct README` |
| *(this file + persist-proposal.py docstring)* | `docs: residuals research round` |

---

## Residual 1 — Windows TOCTOU

### The premises, checked

**`os.O_NOFOLLOW` is genuinely absent on Windows, not merely undocumented.**
CPython's `os` docs list `O_NOFOLLOW` under *"The above constants are
extensions and not present if they are not defined by the C library"* with
**Availability: Linux, macOS, Unix**; the Windows-only constant list
(`O_BINARY`, `O_NOINHERIT`, `O_SHORT_LIVED`, `O_TEMPORARY`, `O_RANDOM`,
`O_SEQUENTIAL`, `O_TEXT`) does not include it, and `O_NOFOLLOW_ANY` was added
for macOS only in 3.10.
<https://docs.python.org/3/library/os.html#os.O_NOFOLLOW>

`dir_fd` is likewise a *"some Unix platforms"* feature; the docs state that
where unsupported it *"will raise a `NotImplementedError`"*, and give no
Windows availability.

This repo's own CI corroborates both, on windows-latest, run `30177841369`:

```
[capability probe] O_NOFOLLOW: UNAVAILABLE (POSIX-only primitive)
[capability probe] dir_fd (functional): UNAVAILABLE (e.g. native Windows)
```

**The threat model does apply on Windows** — more than the residual's
parenthetical suggested. The same CI run prints:

```
[capability probe] symlink creation: AVAILABLE
[capability probe] hardlink creation: AVAILABLE
```

so the "symlinks require Developer Mode or elevation" mitigation is not in
force on the runner. Independently, **directory junctions** (`mklink /J`)
have never required elevation and are a documented privilege-redirection
vector; they are reparse points that redirect exactly like a symlink and are
invisible to `Path.is_symlink()`. `_reject_if_symlink()` already checks
`st_reparse_tag` for this reason, which is correct but is a *check*, and
therefore still racy.

### The finding: "unfixable with the stdlib alone" was wrong

The residual (and `_write_all_path`'s docstring) said the window was
*"Unfixable on this platform with the stdlib alone"*. That is false.

The obvious approach — emulating `dir_fd` — really is expensive: it needs
`NtCreateFile` with an `OBJECT_ATTRIBUTES.RootDirectory` handle, an ntdll
native API rather than documented Win32, with `UNICODE_STRING` marshalling
and `NTSTATUS` decoding. Judged honestly: too much.

But that is not what is required. Win32 offers a cheaper primitive that
closes the *same* window, reachable from `ctypes` (stdlib):

Open each store directory once with `CreateFileW` and **hold the handle**
across the whole check → stage → rename sequence, using:

- `FILE_FLAG_BACKUP_SEMANTICS` (0x02000000) — *"You must set this flag to
  obtain a handle to a directory."*
- `FILE_FLAG_OPEN_REPARSE_POINT` (0x00200000) — *"Normal reparse point
  processing will not occur; CreateFile will attempt to open the reparse
  point... If the file is not a reparse point, then this flag is ignored."*
  So the handle is the directory itself, never a junction's target, and the
  reparse check becomes a property of the opened object rather than of a
  re-resolved path string.
- `dwShareMode = FILE_SHARE_READ` — omitting `FILE_SHARE_DELETE` and
  `FILE_SHARE_WRITE`.

The share mode is the load-bearing part. MSDN, `dwShareMode`:

> **FILE_SHARE_DELETE** — Enables subsequent open operations on a file or
> device to request delete access. Otherwise, no process can open the file or
> device if it requests delete access. … **Note** Delete access allows both
> delete and rename operations.

> **FILE_SHARE_WRITE** — … Otherwise, no process can open the file or device
> if it requests write access.

<https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew>

Swapping a directory for a junction requires deleting or renaming it first
(blocked without `FILE_SHARE_DELETE`), or converting it in place via
`FSCTL_SET_REPARSE_POINT`, which needs a write handle (blocked without
`FILE_SHARE_WRITE`). So while the handle is held the swap is **prevented by
the kernel**, not detected afterwards. Identity verification, if wanted on
top, is `GetFileInformationByHandleEx` with `FileIdInfo` → `FILE_ID_INFO`
(`VolumeSerialNumber` + 128-bit `FileId`), documented as uniquely identifying
a file on a single computer.
<https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info>

### What was done, and what was not

**Not implemented, and the reason is not technical.** The design is
fail-safe: it would be probe-gated exactly like `DIR_FD_SUPPORTED`, so a
wrong implementation degrades to today's path-based writer rather than
breaking anything, and POSIX never reaches it at all. What blocks it is
verification. This is syscall-level code on the write path that guards ~120
codified attacks (96 executed this round in `test-adversarial-sweep.py`, 32
in `test-persist-proposal.py`), it cannot be executed on a POSIX development
host, and this working session cannot push to obtain a Windows CI run. This
branch's recurring damage pattern is confident claims nobody re-derived;
landing unrunnable `ctypes` on the write path would be another instance.

**What was done:** `_write_all_path`'s docstring now carries the corrected
finding in full — the confirmed premises with their CI-probe evidence, the
junction threat, the rejected `NtCreateFile` approach, the accepted
share-mode design with its MSDN quotations, and an explicit statement that
the blocker is verification rather than feasibility. The false "unfixable"
sentence is gone.

**Mutation results:** none applicable — no behavioural change. Regression
check: `test-persist-proposal.py` 32/32, `test-adversarial-sweep.py` 96
attacks executed (floor 55), 1 loud skip (case-collision refusal, needs a
case-insensitive filesystem).

**Still open:** the Windows TOCTOU window itself. Now with a specified,
costed, citation-backed design instead of a "can't be done".

---

## Residual 2 — WSL vs Git Bash, and the "untestable" claim

### The claim was wrong twice

**First**, GitHub's own workflow-syntax documentation states that **`pwsh` is
the default shell on Windows runners**:

> **pwsh** — "This is the default shell used on Windows. The PowerShell Core.
> GitHub appends the extension .ps1 to your script name."

<https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax>

So a PowerShell job on `windows-latest` was never blocked on anything.

**Second, and decisively: the resolver was already being tested on Windows.**
`.github/workflows/ci.yml`'s windows cells run `bash tests/run-all.sh`, which
runs `tests/test-ps1-wrappers.sh`, which probes for `pwsh` and — when present
— runs both `ps-parse-check.ps1` and the behavioural `ps-wrapper-tests.ps1`.
CI run `30177841369`, cell `test (windows-latest, 3.13)`:

```
=== tests/test-ps1-wrappers.sh ===
[capability probe] pwsh: AVAILABLE (7.6.3)
All ps1-wrapper tests passed.
```

`find-bash.ps1`'s resolver has therefore been executing on Windows on every
push. **A dedicated `shell: pwsh` job was considered and deliberately not
added**: it would be a seventh CI cell duplicating coverage that already runs.

### The gap that was real

What the tests *asserted* on Windows: nothing platform-specific. The suite's
own header even said the Windows half "cannot" be covered. Both branches of
the resolver were exercised on Ubuntu, where every `bash` is Linux bash and
sees every path — i.e. the exact ambiguity the resolver exists for was never
present in the environment testing it.

### Discriminator research

| Candidate | Verdict |
|---|---|
| `uname -s` | **Reliable.** Git Bash (MSYS2) reports `MINGW64_NT-*` / `MSYS_NT-*`; WSL reports `Linux` because it *is* Linux. This is the standard `msys*\|cygwin*\|mingw*` detection idiom. |
| Location under `System32` | **Unreliable both ways.** Misses WSL shims installed elsewhere; would wrongly reject an unusual-but-working bash. `find-bash.ps1` already refuses to branch on it, and a test pins that refusal. |
| `$WSL_DISTRO_NAME` | **Wrong question.** It is set inside a WSL shell; it says nothing about a `bash.exe` one is merely invoking from PowerShell. |
| presence of `wslpath` | Weak — a Git Bash environment with WSL installed can see WSL binaries. Not used. |
| Functional `test -f <windows path>` | **What the resolver already does**, and the strongest signal: it asks the interpreter the only question that matters. Confirmed by Microsoft's own WSL filesystem documentation that `C:\repo` is reached as `/mnt/c/repo` inside WSL, so a Windows-style path genuinely does not resolve there. <https://learn.microsoft.com/en-us/windows/wsl/filesystems> |

### What was implemented

`tests/lib/ps-wrapper-tests.ps1` gained a Windows-only block (`$IsWindows`)
that:

1. enumerates every `bash` on PATH via `Get-Command bash -All`;
2. classifies each **functionally** by `uname -s` → `git-bash` / `wsl` /
   `unknown`, printing the table;
3. reports whether `System32\bash.exe` exists;
4. **asserts** the resolver did not return a WSL bash for a Windows-style
   repo path — the silent-wrong-location failure the guard exists to prevent;
5. **asserts** the resolver found a usable bash at all (Git for Windows ships
   on every runner, so a refusal means the probe is broken on Windows).

On non-Windows the block prints an explicit SKIP naming where it does run.
`find-bash.ps1`'s own logic was **not** changed — it is already a functional
probe, and changing resolver behaviour that cannot be executed here would
repeat the mistake this round is correcting.

The stale prose in `tests/test-ps1-wrappers.sh` and `ps-wrapper-tests.ps1`
("no PowerShell CI job", "cannot without Windows") was corrected in place
with the CI-log evidence.

**Mutation results:** not applicable to PowerShell here (no `pwsh` on this
host — see caveat).

**⚠️ Caveat, stated plainly:** this development host has no `pwsh`, so the
new PowerShell block **could not be executed locally**. Balanced-delimiter
checks were run (code-only parens 44/44, braces 22/22, brackets 12/12, no odd
single-quote lines) and only constructs already proven in that file plus
standard PS-Core ones (`$IsWindows`, `Get-Command -All`, `Select-Object
-First 1`) were used. `ps-parse-check.ps1` covers the file in CI. **Treat the
new Windows assertions as CI-pending until a run is observed.**

---

## Residual 3 — the Coach rules. The framing was wrong.

This was the highest-value item and the residual's own conclusion was the
most wrong thing in the brief.

### On-disk evidence (read, not assumed)

**`~/.copilot/session-state/<id>/events.jsonl`** — 41 sessions present.
Census of the largest real session (6,536 events), with each event type's
`data` keys:

| event | n | keys that matter |
|---|---|---|
| `tool.execution_start` | 1787 | `toolName`, `mcpServerName`, `mcpToolName`, `arguments`, `turnId` |
| `tool.execution_complete` | 1787 | `success`, `error`, `toolTelemetry` |
| `assistant.message` | 1343 | `model`, **`outputTokens`**, `toolRequests`, `turnId` |
| `assistant.turn_start` / `turn_end` | 637 / 634 | `turnId`, `model` (→ wall-clock elapsed) |
| `permission.requested` | 57 | `permissionRequest{kind, commands, possiblePaths}` |
| `permission.completed` | 57 | `result{kind}` |
| `user.message` | 41 | `content`, `source`, `delivery`, `attachments` |
| `subagent.started` / `completed` | 32 / 32 | **`agentName`**, `model`, `totalToolCalls`, `durationMs` |
| `skill.invoked` | 5 | **`name`**, `path`, `source` |
| `session.model_change` | 2 | **`newModel`**, **`reasoningEffort`**, `contextTier` |
| `abort` | 3 | `reason` (`user_initiated`) → **`isCanceled`** |
| `session.shutdown` | 1 | `tokenDetails{input,output,cache_read,cache_write}`, **`codeChanges{linesAdded, linesRemoved, filesModified[]}`** |

**`~/.copilot/session-store.db`** — the prior investigation's note was
**correct and current**. Verified against a temp copy (never the live file):

```sql
CREATE TABLE assistant_usage_events (
  session_id TEXT, turn_index INTEGER, agent_id TEXT, model TEXT NOT NULL,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
  cache_write_tokens INTEGER, reasoning_tokens INTEGER, duration_ms INTEGER,
  time_to_first_token_ms INTEGER, initiator TEXT, reasoning_effort TEXT,
  finish_reason TEXT, ...);
```

**2,302 real rows.** Models: `claude-opus-4.6` ×2039, `claude-sonnet-4.5`
×123, `gpt-5.4` ×123, `gpt-5.4-mini` ×11, `gpt-5.6-terra` ×6. `initiator`:
`agent` 1087 / `sub-agent` 1110 / `user` 99. `reasoning_effort`: `high` 2168 /
`low` 11. Also `session_files(file_path, tool_name, turn_index)` and
`sessions(cwd, repository, branch, summary)`.

**`~/.claude/projects/*/*.jsonl`** — 8 project dirs. `assistant` lines carry
`message.model`, `message.usage{input_tokens, output_tokens,
cache_read_input_tokens, cache_creation_input_tokens}`, `requestId`, and
`tool_use` content blocks. `user` lines carry `interruptedMessageId` (14 real
instances = cancellations), `promptSource`, `permissionMode`.

**A trap found by reading rather than assuming:** Claude Code writes **one
JSONL line per content block** of a single API response (thinking / text /
tool_use are separate lines) and repeats the *identical* `usage` object on
each. Summing per line triple-counts tokens on a typical tool-using response.
The parser de-duplicates by `requestId`; a mutation removing that is killed
by a test.

### Upstream evidence — this reframed everything

Cloned `microsoft/AI-Engineering-Coach` at HEAD `766d0f2` (2026-07-24). The
vendored commit `9b4deb1` is no longer reachable in the public history.

1. **Upstream is not a VS Code-internals consumer.** Its README is *"any
   harness, one dashboard"* and *"reads your local AI session logs"*.
   `src/core/parser-harnesses.ts` registers collectors for **Claude Code**,
   **Codex CLI** and **OpenCode**; `src/core/parser-vscode-cli.ts` parses
   Copilot CLI's own `events.jsonl` — *the same file this project reads*.
   `src/core/types/session-types.ts` documents the CLI origins field by
   field: *"Copilot CLI: `session.start.data.reasoningEffort` and
   `session.model_change.data.reasoningEffort`"*, *"Copilot CLI emits these
   in `session.shutdown.modelMetrics`"*.
   **So the fields were never unobtainable. They were unplumbed.**

2. **Upstream itself declares eleven rules IDE-only.** Exactly eleven rule
   files carry `requiresIdeContext: true`, and `src/core/detector-registry.ts`
   drops them for non-IDE harnesses:

   ```ts
   export function getActiveDetectors(skipIdeDetectors: boolean) {
     return registry.filter(d => !skipIdeDetectors || !d.requiresIdeContext);
   }
   ```
   with `skipIdeDetectors = !!(f?.harness && !f.harness.startsWith('Local Agent')
   && f.harness !== 'Xcode')` (`analyzer-patterns.ts`).

   **For a CLI harness, those eleven are a correct permanent skip — upstream
   would skip them too.** They are not a coverage gap in this project.

3. **`toolConfirmations` is populated by `parser-vscode-request.ts` and by no
   other parser** — not the CLI parser, not the Claude parser. Confirmed by
   grep across all five parsers.

4. **The DSL.** Upstream ships a real expression language under
   `src/core/dsl/` — lexer, parser, interpreter, ~4,300 lines, with function
   calls, pipes and format filters. This project's evaluator hand-parses two
   regex-shaped clause forms. That is a **deliberately scoped subset, well
   behind the real dialect**, and it is now stated as such in the module
   docstring. Each adapter pins the exact predicate it implements and refuses
   to run if a re-vendor changes it (a test proves this).

### Reachability table (three buckets, as instructed)

**Bucket A — reachable today from CLI logs. Implemented (8).**

| Rule | Field(s) | Source | Fires on real data? |
|---|---|---|---|
| `reasoning-effort-overuse` | `reasoningEffort` | `assistant_usage_events` | **Yes** — 2141/2152 high, ratio 0.995 > 0.5 |
| `slow-responses` | `totalElapsed` | turn_start→turn_end | **Yes** — 32 turns > 30s (min 5) |
| `runaway-agent-loops` | `toolsUsed`, `agentName` | `tool.execution_start`, `subagent.started` | **Yes** — 18 turns (min 3) |
| `model-overreliance` | `modelId` | usage rows / assistant msgs | Input live (8 models, topShare 0.72); healthy, so silent |
| `cache-hit-starvation` | `promptTokens`, `cacheReadTokens` | usage rows | Input live (2273 matched, cacheRate 0.96); healthy |
| `verbose-output` | `completionTokens`, `messageLength` | `outputTokens` + `user.message` | Input live (13/314); below threshold |
| `high-cancellation` | `isCanceled` | `abort` / `interruptedMessageId` | Input live (2/314); healthy |
| `excessive-file-context` | `referencedFiles` | tool `arguments.path` | Input live (max 38 files/turn); below threshold |

Every one has a fire **and** a no-fire test against fixtures whose event
shapes were copied from the real stores.

**Bucket B — Route B only (11). Not a defect in this project.**

`agent-mode-for-asks`, `agentic-no-tools`, `auto-approve-terminal`,
`instruction-bloat`, `no-custom-instructions`, `no-devcontainer`,
`no-file-context`, `no-plan-mode`, `no-skills`, `no-slash-commands`,
`yolo-mode` — upstream's own `requiresIdeContext: true` set. They key off VS
Code surfaces with no CLI analogue. Two deserve specific note:

- **`agentMode` is a constant for CLI.** Upstream's own CLI and Claude
  parsers hardcode `agentMode: 'agent'`. Any rule branching on ask-mode is
  structurally dead here — which is why `no-spec-structure` is skipped
  *deliberately* rather than emitted as a permanent always-true signal.
- **`yolo-mode` / `auto-approve-terminal` are unmeasurable from CLI logs on
  their own merits, independent of the IDE flag.** Both need an auto-approval
  *rate*. Measured across the whole corpus — 242 real confirmations, latency
  = `permission.completed` minus `permission.requested`:

  | `result.kind` | n | min | median |
  |---|---|---|---|
  | `approved` | 165 | 0.638s | 6.7s |
  | `approved-for-location` | 7 | 3.125s | 5.9s |
  | `denied-interactively-by-user` | 9 | 7.525s | 40.6s |
  | `denied-no-approval-rule-and-could-not-request-from-user` | 61 | 0.000s | 0.004s |

  Every approval took human-scale time; only non-interactive *denials* are
  instantaneous. That is the signature of auto-approved calls emitting **no
  permission event at all**. A rate computed over what *is* recorded would
  have a permanently zero numerator — a rule that evaluates and can never
  fire. `approved-for-location` was the tempting mapping and **it is wrong**:
  its 3.1s minimum shows it is a human picking "approve for this location".
  An earlier draft of the parser had exactly this bug; measuring killed it.

**Bucket C — reachable but not implemented, with a named cost (15).**

| Cost | Rules |
|---|---|
| `aiCode.loc` — upstream reconstructs generated code from tool arguments (`file_text`/`new_str`/`content`); doing so here means holding whole file bodies in memory per indexed session | `copy-paste-blindness`, `low-markdown-ratio`, `speed-accept`, `vibe-coding`, `no-language-exploration` |
| A maintained upstream table this project would have to snapshot and let rot | `premium-waste`, `premium-for-lookup-questions`, `auto-avoidance` (model-tier list), `profanity` (wordlist, `src/core/profanity.ts`), `session-drift` (work-type taxonomy) |
| An upstream analyzer the vendored rule file does not carry | `broken-flow-state` (`flowScoreStats`, `src/core/analyzer-flow.ts`) |
| Blocked on one IDE-only field despite the rest being captured | `context-engineering-gaps` (needs `customInstructions`) |
| Would change the rule's meaning if partially evaluated | `no-spec-driven-development` (2 of 3 OR-branches dead) |
| Structurally constant for CLI | `no-spec-structure` |
| Pattern set not carried in the vendored file | `verbose-prompt-no-compression` |

**The honest residual is 15, not 34** — and none of those 15 is a
"missing data" claim any more.

### What was implemented

- **`scripts/lib/telemetry.py`** (new). Two streams, deliberately separate:
  `build_turn_requests()` (one record per user request) and
  `build_api_calls()` (one per model API call). One user request is many API
  calls in an agentic harness — 2,302 usage rows across 133 turns in this
  corpus — so flattening them would inflate every per-request count and
  deflate every per-API-call rate. `requests_with(records, *fields)` is the
  only supported selector and returns records where each field is genuinely
  present; **`None` means "not available here", never `0`/`""`/`[]`**.
  SQLite is opened through an `immutable=1` URI so a live Copilot process is
  never blocked and no `-wal`/`-shm` is created (a test asserts the file's
  mtime is unchanged). File-path extraction mirrors upstream's own tool lists
  (`FILE_REF_TOOLS`/`FILE_EDIT_TOOLS`/`META_TOOLS`, `CLAUDE_WRITE_TOOLS`/
  `CLAUDE_READ_FILE_TOOLS`/`CLAUDE_READ_PATH_TOOLS`) rather than guessed ones,
  so `referencedFiles`/`editedFiles` mean what the consuming rules mean.
- **`scripts/coach-rules-eval.py`** — 8 `TELEMETRY_ADAPTERS`, each pinning its
  rule's `detect` block; `_require_records()` turns an empty selection into a
  loud skip. `UNSUPPORTED_REASONS` rewritten entirely against upstream source.
- **Tests** — `tests/test-telemetry.py` (new, 23 tests) with fixtures copied
  from real event shapes, plus `LiveStoreProbe`, which reads whatever real
  stores exist and **fails if a present store parses to zero records** (the
  one thing a fixture suite structurally cannot catch). On this machine:
  claude 518 records, copilot events 211, copilot db 2275.
  `tests/test-coach-rules-eval.py` gained fire/no-fire pairs for all 8 rules,
  `TelemetryAbsentSkipsLoudlyTest`, and `TelemetryDetectPinTest`.
- **Hermeticity fix (latent bug found in passing):** `run_eval` previously
  ran the evaluator with the inherited environment, so it read the
  developer's real `~/.copilot` and `~/.claude`. The pinned coverage count
  would have differed between a workstation and CI, and a "coverage dropped"
  failure would have been indistinguishable from "this laptop has no Copilot
  sessions". It now always points the telemetry roots somewhere explicit.

### Mutation results (Residual 3)

9 mutants, **9 killed** — 7 on the first pass, 2 after adding tests:

| Mutation | Result |
|---|---|
| `requests_with` treats `None` as present | killed |
| Claude per-`requestId` de-duplication removed | killed |
| `tool_result` user lines start a new turn | killed |
| `META_TOOLS` no longer excluded | killed |
| `referencedFiles`/`editedFiles` not de-duplicated | killed |
| `_require_records` returns `[]` instead of raising | killed |
| reasoning-effort denominator includes unknown rows | killed |
| `_elapsed_ms` unparseable-timestamp branch returns `0` not `None` | **survived** → test added → killed |
| `_pin()` detect-block check disabled | **survived** → test added → killed |

The second survivor was the more interesting one: with `_pin()` disabled the
whole suite stayed green, because every fixture used the rules exactly as
vendored. A `sync-coach-rules.sh` re-sync that tightened a predicate would
have kept emitting the *old* predicate's answer under the *new* rule's name.
`TelemetryDetectPinTest` now covers it.

---

## Residual 4 — real conversation history through the digest path

Closed without spending anything, exactly as the brief anticipated.
`scripts/lib/transcript.py` was run under Python 3.9 against **real
historical sessions on this machine**:

| Harness | Session | Messages parsed | Digest |
|---|---|---|---|
| Copilot | `ede008b3…` (6,536 events) | 766 (725 assistant / 41 user) | 19,981 chars, no failure reason |
| Copilot | `d7200451…` | 445+ | 19,566 chars |
| Claude | `33462410….jsonl` (13,669 lines) | 743 (675 / 68) | 20,035 chars |
| Claude | `2acf8311….jsonl` | — | 17,481 chars |
| Claude | `db33e8a0….jsonl` | — | 17,087 chars |

Real conversational content reaches the prompt in every case — the tails
contain genuine end-of-session summaries and hand-offs, which is precisely
the material the reviewer is meant to learn from. Oldest-first truncation
works (`[... 696 earlier message(s) truncated ...]`) and the 20,000-char cap
is respected. Both harnesses' real formats parse correctly.

One observation worth recording: the digests are assistant-heavy (7 user
turns of 70 blocks in the Copilot sample; 4 of 124 in the Claude sample).
That is a faithful reflection of agentic sessions, and real user turns *do*
survive into the window, but if review quality ever disappoints, biasing
truncation to preserve user turns is the first thing to try.

**What remains genuinely unproven:** that the hook fires end-to-end on a
*live interactive* session and this digest reaches the model in that path.
Everything either side of that seam is now demonstrated — hook firing was
shown separately in an earlier round, and digest construction from real files
is shown here — but the two have not been observed in one continuous live
run. **No paid call was spent, and none is recommended**: the only thing such
a call could add is the seam itself, and both sides of it already have
coverage.

---

## Premises in the brief that turned out to be wrong

Stated plainly, as requested:

1. **"Untestable without a PowerShell CI job" (Residual 2) — wrong.** `pwsh`
   is the *default* shell on Windows runners, and the resolver's behavioural
   test has been running on `windows-latest` on every push. Adding a job
   would have duplicated existing coverage.
2. **"34 rules need telemetry this project never captures" (Residual 3) —
   wrong, and the coordinator's reframing was right.** Microsoft's own
   extension parses the *same CLI log files*; 8 rules were reachable
   immediately, 11 are IDE-only by upstream's own declaration, and 15 are
   reachable-but-costly. "Never captures" was true only of this project's own
   index, not of the machine.
3. **"Unfixable on this platform with the stdlib alone" (Residual 1, in the
   code) — wrong.** A documented Win32 share-mode design closes the window
   without touching ntdll. The blocker is verification, not feasibility.
4. **A guess this round nearly shipped, caught by measuring:**
   `approved-for-location` is *not* auto-approval. Mapping it that way would
   have created exactly the "evaluates but can never fire" rule the standing
   rule forbids.

## Needs a decision

1. **Residual 1 implementation.** Do you want the Windows `CreateFileW`
   share-mode hardening built in a round that can push and watch Windows CI?
   The design is specified and fail-closed; it is ~150 lines of `ctypes`.
2. **Bucket C, `aiCode.loc` cluster (5 rules).** Capturing generated-code LOC
   from tool arguments would unlock `vibe-coding`, `copy-paste-blindness`,
   `low-markdown-ratio`, `speed-accept`, `no-language-exploration` — the
   largest remaining group. The cost is holding file bodies in memory during
   extraction; a line-count-only streaming pass could avoid most of it.
3. **Re-vendor the rules?** The vendored commit `9b4deb1` is gone from
   upstream's public history; HEAD is `766d0f2`. Re-syncing would tell us
   whether any pinned `detect` block has drifted — and the new pin test would
   surface it loudly rather than silently.
