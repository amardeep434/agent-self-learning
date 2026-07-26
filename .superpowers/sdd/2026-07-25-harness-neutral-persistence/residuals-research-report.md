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

---
---

# Residuals closeout round — A/B/C/D (2026-07-26, second pass)

Suite at start: 42 green. **Suite at end: 43 green** (one added:
`tests/test-win-dir-pin.py`). Every Python suite re-run individually under
`~/.pyenv/versions/3.9.24/bin/python3.9`: 14/14 OK.

| Residual | Outcome |
|---|---|
| A — Windows TOCTOU hardening | **Closed, pending CI confirmation.** Design validated against primary sources, then implemented, probe-gated, with the security decision refactored so it is mutation-testable on Linux. |
| B — the `aiCode.loc` Coach cluster | **Closed.** All five rules implemented and firing. Coverage **19 → 24 of 45**. The recorded reason for deferring them was wrong about what upstream counts. |
| C — re-vendoring the Coach rules | **Closed, and the premise was false.** `9b4deb1` is a direct ancestor of upstream HEAD; the six intervening commits are all Dependabot bumps. Re-vendored at HEAD; rule files byte-identical. |
| D — `test-ps1-wrappers.sh` null-byte warning | **Closed.** Fixed on the bash side and now exercised on every platform. |

Commits:

| SHA | Subject |
|---|---|
| `5f6ccac` | `feat(persist): close the Windows write-path TOCTOU with held directory handles` |
| `23f54a9` | `fix(test): stop the "ignored null byte" warning in the Windows CI log` |
| `8111bb8` | `chore(coach): re-vendor rules at upstream HEAD 766d0f2 (byte-identical)` |
| `0878dd6` | `feat(coach): implement the aiCode.loc cluster — 19 of 45 rules to 24` |

---

## Residual A — Windows TOCTOU hardening

### Validating the prior round's design before building on it

The design was *reasoned*, not tested. Three claims were load-bearing and all
three were re-derived from primary sources.

**1. The share-mode quotes are exact.** Fetched
<https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew>
and matched the table rows verbatim:

> **FILE_SHARE_DELETE** (0x00000004) — "Enables subsequent open operations on
> a file or device to request delete access. Otherwise, no process can open
> the file or device if it requests delete access. … **Note** Delete access
> allows both delete and rename operations."

> **FILE_SHARE_WRITE** (0x00000002) — "… Otherwise, no process can open the
> file or device if it requests write access."

> **FILE_FLAG_BACKUP_SEMANTICS** (0x02000000) — "You must set this flag to
> obtain a handle to a directory."

> **FILE_FLAG_OPEN_REPARSE_POINT** (0x00200000) — "Normal reparse point
> processing will not occur; **CreateFile** will attempt to open the reparse
> point. … If the file is not a reparse point, then this flag is ignored."

Also, from the same page's Remarks: "To open a directory using **CreateFile**,
specify the **FILE_FLAG_BACKUP_SEMANTICS** flag as part of
*dwFlagsAndAttributes*."

**2. The make-or-break question the prior round never asked.** Holding a
directory handle with a share mode that denies delete and write is only
useful if it does not *also* block our own staging and renaming inside that
directory. Nothing in the design addressed this, and if the answer had been
"it blocks us too", the whole approach was dead.

It does not, and Windows itself is the dispositive precedent: the OS holds an
open handle to every process's current directory for the life of the process.
Raymond Chen, *The curse of the current directory*:

> "The primary consequence of this curse is that you can't delete a directory
> if it is the current directory of a running process."

<https://devblogs.microsoft.com/oldnewthing/20101109-00/?p=12323>

Every process on the machine creates files in its own working directory while
that handle is held. Sharing is enforced per *file object*; creating or
renaming a child opens the child, not the parent.

**3. A simpler verification API than the design proposed.** The design
specified `GetFileInformationByHandleEx` + `FileIdInfo`. `GetFileInformationByHandle`
+ `BY_HANDLE_FILE_INFORMATION` is sufficient and available since Windows XP:
its `dwFileAttributes` carries both `FILE_ATTRIBUTE_REPARSE_POINT` and
`FILE_ATTRIBUTE_DIRECTORY`, and the doc states "The identifier (low and high
parts) and the volume serial number uniquely identify a file on a single
computer."
<https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information>

### What was implemented

`scripts/lib/win_dir_pin.py` (new). `persist-proposal.py`'s `_write_all_path`
pins every directory in the chain root-to-leaf as it `mkdir`s down it, holds
every handle for the whole check → stage → rename transaction, and releases
them in a `finally`.

Ordering is deliberate and documented at the call site: pin *after* `mkdir`
and *after* the existing path-based check, so the handle-derived verdict is
the authoritative one. Once level N-1 is pinned, resolving level N's name
through it is safe — which is what makes root-to-leaf order load-bearing
rather than incidental.

**Fail-safe posture, asymmetric on purpose:**

| Condition | Behaviour | Why |
|---|---|---|
| `available()` false (any POSIX host) | `PinSet.pin()` is a no-op | POSIX runs `_write_all_fd` anyway; zero change to the stronger path |
| Directory cannot be opened (`OSError`) | degrade to today's unpinned write | turning a working Windows install into a failing one to close a race is a worse regression than the race |
| Handle reports a reparse point | `PersistError`, hard refusal | attack signal; same verdict `_reject_if_symlink` already returns, but derived from the opened object rather than a path string |

Availability is a real functional probe — open a throwaway directory, verify
it, close it. A test tokenizes the module (stripping comments *and* string
literals, since the docstrings discuss `sys.platform` precisely to explain why
it is not used) and asserts no `sys.platform` / `os.name` / `platform.system`
appears in executable code.

### Structuring it to be testable from a POSIX host

`ctypes.WinDLL` does not exist on Linux, so the backend cannot run here at
all. Two seams make the important parts provable anyway:

* **`interpret_info(path, attributes, volume_serial, index_high, index_low)`** —
  the security *verdict*, extracted as a pure function. Before this split,
  deleting the reparse-point refusal was a mutation nothing here could kill.
* **`PinSet(opener=..., enabled=...)`** and `persist-proposal._PIN_SET_FACTORY` —
  the sequencing (pin order, dedupe, refusal propagation, release-on-failure)
  driven by a recording fake through the real writer.

`tests/test-win-dir-pin.py`: 39 tests, 5 skipped on POSIX. `WindowsBackendTest`
holds the four assertions only CI can make and is skipped loudly elsewhere. A
`[capability probe] win32 directory pinning: AVAILABLE|UNAVAILABLE` line is
printed unconditionally.

### Mutation results (Residual A)

12 mutants, **11 killed, 1 equivalent**:

| # | Mutation | Result |
|---|---|---|
| M1 | `FILE_SHARE_DELETE` added back to the share mode | killed |
| M2 | `FILE_FLAG_OPEN_REPARSE_POINT` dropped | killed |
| M3 | `pin()` swallows `ReparsePointError` | killed |
| M4 | `pin()` re-raises `OSError` instead of degrading | killed |
| M5 | `close_all()` does not close | killed |
| M6 | `pins.close_all()` removed from the writer's `finally` | killed |
| M7 | probe skips the backend-presence gate | **equivalent** — with no `WinDLL`, `open_pin` raises `OSError`, which the probe already catches; the gate is a fast path, not a correctness guard |
| M8 | reparse-point refusal removed | survived → `interpret_info` extracted + tested → killed |
| M9 | writer never pins | killed |
| M10 | dedupe removed (double-open leaks a handle) | killed |
| M11 | non-directory refusal removed | killed |
| M12 | identity truncates the high index word | killed |

Regression: `test-persist-proposal.py` 32/32, `test-adversarial-sweep.py` 96
attacks executed (floor 55, 1 loud skip needing a case-insensitive
filesystem), `test-persist-concurrency.py` 0 lost entries.

### What only CI can confirm

1. `CreateFileW` with `FILE_READ_ATTRIBUTES` + `FILE_SHARE_READ` +
   `BACKUP_SEMANTICS|OPEN_REPARSE_POINT` opens a directory handle on
   windows-latest → the probe line prints AVAILABLE.
2. Staging and `os.replace` inside a pinned directory still succeed.
3. `os.rename`/`os.rmdir` of a pinned directory raise, and succeed after
   release.
4. Opening a directory symlink with the reparse flag yields
   `ReparsePointError`.

All four are `WindowsBackendTest`. **If the probe prints UNAVAILABLE on
windows-latest, the pinning silently did not engage** and the write path fell
back to the old race — that line is the thing to read first in the CI log.

---

## Residual B — the `aiCode.loc` cluster

### The recorded reason for deferring was wrong

The prior report's Bucket C said upstream "reconstructs generated code from
tool arguments (`file_text`/`new_str`/`content`); doing so here means holding
whole file bodies in memory per indexed session."

Read from upstream source at `766d0f2`, `src/core/parser-shared.ts`:

```ts
export const CODE_BLOCK_RE = /```(\w+)?\n([\s\S]*?)```/g;
const MAX_CODE_SCAN_CHARS = 128_000;
aiCode: overrides.aiCode ?? extractCodeBlocks(textForCodeScan(rawResp)),
// loc = code.trim() ? code.trim().split('\n').length : 0
```

`aiCode` is **markdown fenced code blocks in the assistant's response text**.
Tool arguments reach it only because both parsers *synthesise a fence* and
push it into that same text:

```ts
// parser-vscode-cli.ts, FILE_EDIT_TOOLS = {edit, create}
const code = args.file_text ?? args.content ?? args.new_str
           ?? args.newString ?? args.code;
turn.responseChunks.push(`\`\`\`${ext}\n${code}\n\`\`\``);

// parser-claude.ts, CLAUDE_WRITE_TOOLS = {Write, Edit, MultiEditTool}
const code = input.content ?? input.new_str;
data.assistantTexts.push(`\`\`\`${ext}\n${code}\n\`\`\``);
```

Three consequences the old note missed, each of which changes what the rules
mean:

* **Added lines only.** `old_str` is never read. "AI LoC" is lines produced,
  not diff size. A pure deletion contributes nothing.
* **Prose fences count identically** to written files.
* **Language is the fence info string** — the file *extension* for synthesised
  fences — lowercased and mapped through `LANG_ALIASES`.

### On-disk evidence, gathered before writing any code

Over the six largest real sessions per harness:

| Harness | total aiCode LoC | top languages |
|---|---|---|
| Copilot CLI | **29,819** | py 19,000 · md 6,540 · html 3,434 · json 94 · bash 65 |
| Claude Code | **11,391** | md 6,803 · kt 2,637 · py 1,033 · sh 423 · sql 139 |

Tool census in those Copilot sessions: `edit` ×379 (all with `new_str`),
`create` ×91 (88 with `file_text`), `assistant.message` with non-empty
`content` ×1,204. The input is real and large.

Workspace identity, needed by `low-markdown-ratio`, also exists in both:
Copilot `session.start.data.context.{gitRoot,cwd}`, Claude the `cwd` field on
every transcript line. Five distinct workspaces on this machine.

### The streaming pass — evaluated, and it is the better design

The prior round's suggestion holds. `telemetry._CodeScan` scans each chunk as
it comes off the event stream and retains only `(language, loc)` pairs, so a
22 MB `events.jsonl` is never resident. Upstream's `MAX_CODE_SCAN_CHARS`
budget is reproduced (including charging the join separators against it) so
identical input yields identical answers.

**The one divergence, stated rather than hidden:** a fence opened in one chunk
and closed in a later one is found by upstream's join-then-scan and not by
this. Harness events carry complete messages and complete tool arguments, so
this is not a shape either harness emits; if that changes it under-counts,
which is the safe direction for rules that fire on *too much* AI code.

### The five rules

Upstream's DSL helpers were transcribed with their source locations named:
`computeSpeedAcceptPairs` (interpreter.ts:374), `computeLangExploration`
(:476), `computeMdRatio` (:518).

Two upstream quirks were kept **deliberately**, and are commented as such:

* `computeMdRatio` hardcodes `ratio < 0.05` instead of reading
  `thresholds.markdownRatio`, which holds the same 0.05. Reading the
  threshold would silently diverge the day upstream retunes one and not the
  other.
* `computeLangExploration`'s week key is
  `${year}-W${ceil((dayOfMonth + firstWeekdayOfMonth)/7)}` — a *week-of-month*
  number concatenated with the year, so weeks from different months collide.
  Reimplementing it as a correct ISO week would make this project answer
  differently from upstream for the same input.

One adaptation, reported because it moves the numerator:
`no-language-exploration` unions `aiCode` and `userCode` upstream; this
project has no `userCode` (upstream's own CLI parser never sets it either),
so only `aiCode` languages count. That can only make "no new language" *more*
likely to fire.

Against real telemetry on this machine, all five evaluate; three fire:
`speed-accept` 32, `low-markdown-ratio` 1, `no-language-exploration` 3.
`vibe-coding` and `copy-paste-blindness` evaluate and are correctly silent.

### Coverage

**19 → 24 of 45.** Coverage line verified live:
`coach-rules-eval: 24 of 45 vendored rules evaluated ... 21 skipped`.
`EXPECTED_TELEMETRY_ADAPTERS` raised 8 → 13; `README.md` corrected.

The remaining 21: 11 IDE-only by upstream's own `requiresIdeContext: true`
flag (a correct permanent skip — upstream skips them for CLI harnesses too),
and **10 reachable-but-unimplemented**, down from 15:

| Cost | Rules |
|---|---|
| A maintained upstream table this project would have to snapshot and let rot | `premium-waste`, `premium-for-lookup-questions`, `auto-avoidance` (model-tier list), `profanity` (wordlist), `session-drift` (work-type taxonomy) |
| An upstream analyzer the vendored rule file does not carry | `broken-flow-state` (`flowScoreStats`, analyzer-flow.ts) |
| Blocked on one IDE-only field | `context-engineering-gaps` (needs `customInstructions`) |
| Would change the rule's meaning if partially evaluated | `no-spec-driven-development` (2 of 3 OR-branches dead) |
| Structurally constant for CLI | `no-spec-structure` |
| Pattern set not carried in the vendored file | `verbose-prompt-no-compression` |

### Mutation results (Residual B)

18 mutants, **all killed** — but three survived the first pass, and each
exposed a test that was passing for the wrong reason. That is the more useful
result than the final tally.

| # | Mutation | Result |
|---|---|---|
| B1 | `LANG_ALIASES` normalisation dropped | killed |
| B2 | empty fence body counts as 1 line | killed |
| B3 | `MAX_CODE_SCAN_CHARS` budget removed | killed |
| B4 | join separators not charged to the budget | **survived** → test resized so the fence fits exactly when the separator is free → killed |
| B5 | arg-key precedence becomes alphabetical | killed |
| B6 | `vibe-coding` ignores the spec-shaped-prompt exemption | killed |
| B7 | `copy-paste-blindness` ignores refinement prompts | killed |
| B8 | `copy-paste-blindness` ignores later edits | killed |
| B9 | `slice(requests, 1)` includes the first request | killed |
| B10 | `speed-accept` drops the gap test | **survived** → see below → killed |
| B11 | `speed-accept` drops the LoC floor | **survived** → see below → killed |
| B12 | `low-markdown-ratio` never counts markdown | killed |
| B13 | `low-markdown-ratio` drops the `minTotalLoc` floor | killed |
| B14 | `no-language-exploration` counts markup/data formats | killed |
| B15 | `no-language-exploration` ignores `recentNew` | **survived** → see below → killed |
| B16 | `aiCode` selection no longer skips loudly | killed |
| B17 | `speed-accept` accepts negative gaps | survived initially → out-of-order-timestamp test added → killed |
| B18 | off-by-one in `weeksSinceNew` | killed |

**B10 and B11 shared one root cause, and it is worth recording.** The
`speed-accept` fixtures used the existing `TFIX._ts()` helper, which formats
*only* a seconds field: `"2026-07-25T22:40:{:02d}.000Z"`. Any offset above 59
produced `"22:40:200"`, which `parse_iso` correctly returns `None` for. So
every timestamp-dependent predicate in those fixtures was unreachable, and
both the gap check and the LoC floor could be deleted with the suite still
green. Fixed with a `_restamp()` helper that produces valid ISO across
minutes, plus separate gap-varying and LoC-varying no-fire cases.

**B15 was a subprocess-boundary blind spot.** `main()` emits a signal only
when `count is not None and count > 0`. `no-language-exploration` returns
`weeksSinceNew`, which is **0 in exactly the case where the rule must not
fire** — so deleting the `recentNew == 0` condition produced a return of 0
instead of `None`, and the end-to-end test could not tell them apart. Fixed
by adding `NoLanguageExplorationUnitTest`, which calls the adapter in-process
and asserts the return value itself.

---

## Residual C — re-vendoring: the premise was false

The brief and the prior report both stated that the vendored commit
`9b4deb1` is "gone from upstream's public history". It is not.

```
$ gh api repos/microsoft/AI-Engineering-Coach/compare/9b4deb1...766d0f2
   status: "ahead"   ahead_by: 6   behind_by: 0   files: 9
```

`behind_by: 0` with `status: ahead` means `9b4deb1` is a **direct ancestor** of
HEAD. It was reachable all along; the earlier `gh api commits/<sha>` lookup
that prompted the claim must have been misread.

**All six intervening commits are Dependabot bumps:**

| SHA | Subject |
|---|---|
| `2cc96a61` | build(deps-dev): bump linkify-it 5.0.1 → 5.0.2 |
| `c220b1d1` | build(deps): bump chartjs-chart-treemap 3.1.0 → 4.2.0 |
| `8bef627e` | build(deps-dev): bump eslint-plugin-unicorn 71.1.0 → 72.0.0 |
| `5ff611ac` | build(deps): bump preact (production-dependencies group) |
| `b346d8a4` | build(deps): bump softprops/action-gh-release 3.0.1 → 3.0.2 |
| `766d0f29` | build(deps): bump actions/checkout 7.0.0 → 7.0.1 |

The nine changed files are seven workflow YAMLs, `package.json` and
`package-lock.json`. **Nothing under `src/core/rules`, `src/core/dsl`, or any
parser changed.** So: no `detect` DSL evolution, no rule semantics change, no
rules added or removed.

### The tool, and the guard

`scripts/sync-coach-rules.sh` was run live against HEAD. It fetched all 45
rule files and produced **byte-identical** content — `git diff` showed only
`UPSTREAM.md`'s commit and timestamp. So the script works and provenance
updates correctly.

The predicate-pinning guard was verified by mutation rather than by reading
it: replacing `_pin()`'s two comparisons with `pass` makes
`TelemetryDetectPinTest` fail. Its fixture is exactly the scenario asked
about — a rewritten `detect` block under an unchanged rule name
(`high-cancellation`'s `match:` gains an `AND agentMode == "ask"` clause) — and
the evaluator skips loudly with "detect block changed" instead of answering
with the old predicate. Note the guard covers `match`/`check` *text* only;
threshold **values** are read live from the rule file by design, so a retuned
threshold flows through rather than tripping the guard.

### Recommendation, and what was done

**Re-vendored now, at `766d0f2`.** This is the safest possible version of
"re-vendor": the judgement call the brief posed — re-sync versus stay on a
known-good snapshot — dissolves once the diff is known to be empty. There is
no semantic change to call out because there is no semantic change. What the
update buys is honest provenance: `UPSTREAM.md` now records a commit that
matches upstream's current HEAD, so the next person diffing them starts from
zero drift instead of six commits of unexplained distance.

Two source comments carrying the false "no longer reachable" claim were
corrected in place (`scripts/lib/telemetry.py`, `scripts/coach-rules-eval.py`).

---

## Residual D — the null-byte warning

`OUT="$(pwsh ... 2>&1)"` printed
`bash: warning: command substitution: ignored null byte in input` on every
Windows run. PowerShell's console output encoding on Windows is UTF-16LE,
whose ASCII characters carry a 0x00 high byte, and bash strips NULs from
command substitution with exactly that warning.

Fixed on the **bash** side — temp file plus `tr -d '\0'` — rather than by
setting `[Console]::OutputEncoding` in the `.ps1` files. This host has no
`pwsh`, so a PowerShell-side fix could not be executed before landing, and
that is the failure mode this branch keeps repeating.

**The temp file is load-bearing, not incidental.** The obvious one-liner
`OUT="$(pwsh ... | tr -d '\0')"` yields *`tr`'s* exit status, which is always
0 — a PowerShell parse error would have been reported as a pass.

The helper now runs on **every** platform against a stub `pwsh` that emits
UTF-16-shaped bytes and exits 7, so the fix is not verifiable only on Windows.

Mutation: **2/2 killed.**

| Mutation | Result |
|---|---|
| `tr -d '\0'` → `cat` | killed — and it reproduces the exact CI warning text locally: `warning: command substitution: ignored null byte in input` |
| temp file → `pwsh \| tr` pipeline | killed — exit status became 0 instead of 7 |

One assertion detail worth recording: the *text* check alone is not enough. A
bash string cannot hold a NUL, so `$(...)` over UTF-16 output still *yields*
`"PARSE OK"` — it just prints the warning while doing so. The assertion that
actually pins the fix is on **stderr being empty**.

---

## Premises in the brief that were wrong

1. **"`9b4deb1` is gone from upstream's public history" — false.** It is a
   direct ancestor of HEAD (`behind_by: 0`), and the six commits since are all
   Dependabot bumps touching no source.
2. **"upstream reconstructs generated code from tool arguments … holding whole
   file bodies in memory" — half right, and the missing half changed the
   answer.** `aiCode` is fenced code blocks in the assistant's response text;
   tool arguments reach it only as synthesised fences. The memory cost was an
   artefact of upstream's join-then-scan, not of the metric.
3. **"the biggest cluster needs `aiCode.loc`" — correct**, and it was the
   single highest-value item: five rules, no new data source, and the enabling
   extraction is ~60 lines.
4. **Three of this round's own tests passed for the wrong reason** and were
   caught only by mutation, not by review — two on an unparseable-timestamp
   fixture, one on a subprocess boundary that cannot distinguish `None` from
   `0`. Recorded because the pattern (a green test proving nothing) is the one
   this branch keeps being damaged by.

## Needs a decision

1. **Windows CI for Residual A.** Read the
   `[capability probe] win32 directory pinning:` line first. AVAILABLE means
   the hardening engaged; UNAVAILABLE means it silently fell back to the old
   race and `WindowsBackendTest` was skipped rather than run.
2. **The remaining 10 Coach rules.** Five need a snapshot of an upstream table
   (model tiers, profanity wordlist, work-type taxonomy) that would rot
   silently. My recommendation is to leave those alone: a stale table
   answering under an upstream rule's name is the same failure class as a
   drifted predicate, and unlike the predicate there is no pin that would
   catch it.

---

## Residual A, round 2 — CI disagreed with the design, and CI was right

CI run `30184253819` on `d63b619`. Ubuntu ×2 and macOS ×2 green. Both Windows
cells: **38 of 39 passed**, and the failure was the only assertion that
encoded the module's reason to exist.

```
windows: [capability probe] win32 directory pinning: AVAILABLE
FAIL: test_pinned_directory_cannot_be_renamed_or_removed (WindowsBackendTest)
  tests\test-win-dir-pin.py, line 526
    with self.assertRaises(OSError):
  AssertionError: OSError not raised
```

Line 526 is the **rename**. The `os.rmdir` assertion two lines below was never
reached, so that run says nothing about deletion — a resolution problem in the
test that is fixed below.

The probe printing AVAILABLE is the damning part: the module was **live** on
both Windows cells, and what it reported as a working capability was a handle
nobody's sharing check consulted.

### Diagnosis against the coordinator's four hypotheses

| Hypothesis | Verdict |
|---|---|
| Handle not actually open/held at rename time | **No.** `test_pin_a_real_directory_and_read_its_identity` and the probe both passed, which requires a valid handle from the same `open_pin` on the same path; `pin.close()` was in a `finally` after the assertion. |
| Share mode not reaching `CreateFileW` as intended | **Partly — but not as stated.** `dwShareMode` was passed correctly (`wintypes.DWORD` argtype, value `FILE_SHARE_READ`, no truncation possible). The defect was one parameter to its left. |
| Rename path bypasses the sharing check | **No** — but the reason it did not engage is adjacent to this. |
| Guarantee applies to the parent's directory entry, not the directory | **Not needed to explain it.** The simpler explanation is sufficient and documented. |

### Root cause

Windows keeps per-file sharing state in a `SHARE_ACCESS` structure
(`OpenCount`, `Readers`, `Writers`, `Deleters`, `SharedRead`, `SharedWrite`,
`SharedDelete`), and **the share-access check is engaged only for opens
requesting read, write or delete access.**

Microsoft documents this by way of the flag that exists to defeat it.
`IoCheckLinkShareAccess`, `IoShareAccessFlags`:

> **IO_CHECK_SHARE_ACCESS_FORCE_CHECK** (0x00000020) indicate to force check
> share access even if the request is not read/write/delete access.

<https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-iochecklinkshareaccess>

A flag whose entire purpose is "force the check even when the request is not
read/write/delete" only makes sense because the **default is to skip it**.

The pin requested `FILE_READ_ATTRIBUTES` (0x0080) — chosen for minimal
privilege, and sufficient for `GetFileInformationByHandle`. It is not
`FILE_READ_DATA` (0x0001), not `FILE_WRITE_DATA`, not `DELETE`. So the open
never entered the directory's share-access accounting. The handle was held,
the share mode was correct and irrelevant, and every subsequent opener's
sharing check simply never consulted it.

**So the design was right and the implementation was wrong — but only just.**
The MSDN share-mode quotes in the previous round are all accurate; they
describe what a share mode does *once the check runs*. Nothing on the
`CreateFileW` page says the check depends on your own desired access. That
gap between two correct documents is exactly the space this bug lived in.

### The fix, and why it is not trusted

`PIN_DESIRED_ACCESS = FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES`.
`FILE_LIST_DIRECTORY` is 0x0001 — the directory spelling of `FILE_READ_DATA` —
so the open becomes a genuine reader, `Readers` is incremented, and a rename's
`DELETE`-access open has an accounting entry it must clear against
`SharedDelete == 0`.

That is a *reasoned* fix to a *measured* failure, and reasoning is what
produced the original bug. It is therefore **not trusted**, and the structural
change matters more than the one-line fix:

**`available()` no longer means "CreateFileW returned a handle". It means "a
pinned directory was measured to be un-renameable on this machine."**

`verify_pin_blocks_rename(directory, moved)` pins a throwaway directory,
attempts a real rename, and returns one of four verdicts:

| Verdict | Meaning | Availability |
|---|---|---|
| `GUARANTEE_HELD` | rename failed while pinned, succeeded after release | **available** |
| `GUARANTEE_NOT_ENFORCED` | rename succeeded while pinned | disabled |
| `GUARANTEE_INCONCLUSIVE` | rename failed while pinned **and** after release | disabled |
| `GUARANTEE_NO_BACKEND` | no `kernel32` | disabled |

The `INCONCLUSIVE` case is the control experiment and it is load-bearing:
without it a read-only volume, a permissions problem or an antivirus lock
fails the rename for reasons unrelated to the pin, and the module would report
AVAILABLE on the strength of a failure that proves nothing. That is precisely
the mistake this round is correcting, one level up.

Any verdict but `HELD` disables pinning, which returns `_write_all_path` to
exactly its previously documented behaviour. **A race described honestly beats
a protection advertised and absent.**

### CI-visible three-state reporting

```
[capability probe] win32 directory pinning: AVAILABLE (verified: a pinned directory could not be renamed)
[capability probe] win32 directory pinning: UNAVAILABLE (kernel32 present, but the kernel did NOT block a rename of a pinned directory -- pinning disabled, the write path keeps its documented race)
[capability probe] win32 directory pinning: UNAVAILABLE (kernel32 present, but the control rename failed too -- cannot tell protection from an unwritable volume, so pinning is disabled)
[capability probe] win32 directory pinning: UNAVAILABLE (no kernel32 -- expected on POSIX)
```

`python3 scripts/lib/win_dir_pin.py` prints the same verdict as a standalone
diagnostic.

### Tests: sharpened, not relaxed

The failing assertion was **not** weakened. The Windows half now has three
layers:

1. **`test_guarantee_holds_on_this_runner`** — the headline property,
   measured directly, unconditional on Windows, never skipped. If the
   guarantee cannot be delivered, this going red is the *correct* outcome and
   the module should be downgraded rather than the assertion softened. Its
   failure message states the two remaining explanations so the next run is
   diagnostic rather than just red.
2. **`test_probe_agrees_with_the_measured_guarantee`** — the guard that makes
   a green run mean something. It fails if `available()` claims **more** than
   the machine delivers (the failure just seen) *and* if it claims **less**
   (silently giving up real protection). This is the assertion that could not
   have been green on run `30184253819`.
3. **`test_module_is_inert_when_the_guarantee_does_not_hold`** — if the
   property is absent, nothing may be pinned.

`test_pinned_directory_cannot_be_renamed_or_removed` was **split**, because
the rename failing first meant CI never reported the rmdir result.
Deletion and rename are enforced by different mechanisms on Windows — an open
handle blocks directory deletion outright, while rename goes through the
share-access check — so one holding tells you nothing about the other.
`test_rename_is_allowed_again_once_the_pin_is_released` adds the control
experiment as a test in its own right.

### Mutation results (Residual A, round 2)

9 mutants, **all killed** — one after a test was added:

| # | Mutation | Result |
|---|---|---|
| W1 | regress `PIN_DESIRED_ACCESS` to attributes-only (the original bug) | killed |
| W2 | unblocked rename reported as `HELD` | killed |
| W3 | control experiment dropped | killed |
| W4 | directory not restored after an unblocked rename | killed |
| W5 | `_probe` returns available regardless of the verdict | **survived** → see below → killed |
| W5b | `INCONCLUSIVE` treated as available | killed |
| W6 | pin never released during verification | killed |
| W7 | no-backend short circuit removed | killed |
| W8 | probe result not cached (probe runs per call) | killed |

**W5 is the instructive one and it is the same shape as the original defect.**
Making `_probe` return `(True, reason)` unconditionally left the suite green,
because on a POSIX host the function returns early at the no-backend branch
and never reaches that line — so the mapping from *measured verdict* to
*advertised availability* was reachable only on Windows. A module claiming
protection it does not have, with no test able to catch it, is exactly what
this round is fixing. `ProbeVerdictMappingTest` now drives `_probe` with an
injected backend and a stubbed verifier, so all four verdicts and the caching
are exercised on every platform.

### Is the guarantee achievable?

**Not yet proven, and deliberately not asserted.** The evidence says the
observed failure has a specific, documented cause that the fix addresses, and
the fix is the standard access mask for a directory handle. But the previous
round also had a documented rationale and was wrong, so the honest position is:
*the module now measures the property instead of assuming it, and disables
itself if the property is absent.*

Two outcomes are possible on the next run, and both are acceptable deliverables:

* **`AVAILABLE (verified: ...)` and the guarantee test green** — the hardening
  works and the branch is done.
* **`UNAVAILABLE (kernel32 present, but the kernel did NOT block a rename ...)`
  with `test_guarantee_holds_on_this_runner` red** — then renaming a directory
  does not take delete access on the directory object, the coordinator's
  fourth hypothesis is correct, the design (not the implementation) is wrong,
  and the module should be reduced to what it can honestly claim: a
  handle-derived reparse-point check, which is a real but much smaller
  improvement over the path-based `lstat`. The report will record that as a
  well-evidenced negative result.

What must NOT happen is a green run with the property absent, and that is now
structurally impossible: the probe would have to report AVAILABLE while the
measurement said otherwise, and `test_probe_agrees_with_the_measured_guarantee`
fails on exactly that.

### What CI must confirm next

1. The capability line's verdict — **read this first**, it is now the answer,
   not a plumbing status.
2. `test_guarantee_holds_on_this_runner` — the property itself.
3. `test_probe_agrees_with_the_measured_guarantee` — that the module is not
   lying in either direction.
4. `test_pinned_directory_cannot_be_removed` — never actually reported before,
   because the old combined test died at the rename first.
