# Claude Self-Learning

A cross-harness self-learning system, adapted from NousResearch's Hermes Agent architecture. It serves Claude Code, GitHub Copilot CLI, and (planned) VS Code Copilot Chat as peers -- Claude Code is one adapter among them, and no shared code path (storage, review pipeline, skill/memory schema) may depend on it. Sessions learn from every interaction, accumulating reusable skills, refined memories, and searchable session history -- without requiring the user to manually curate any of it. The system runs entirely in the background via hooks and subagents, writing to a shared, vendor-neutral disk-backed store (see "Storage locations" below) that persists across sessions and is loaded as a frozen snapshot at session start.

## Architecture

```
SESSION START
    |
    v
+-------------------+     +--------------------+     +------------------+
| Load frozen       |     | MEMORY.md (2200ch) |     | USER.md (1375ch) |
| snapshots from    |<----| learned-skills/    |     | .usage.json      |
| disk into prompt  |     | sessions/search.db |     |                  |
+--------+----------+     +--------------------+     +------------------+
         |
         v
+--------+----------+
| Normal            |     PostToolUse hook
| conversation      |---> turn-counter.sh
| (user <-> Claude) |     (increments counter)
+--------+----------+
         |
         | every N turns (default 10)
         v
+--------+----------+
| Background Review |     Detached headless reviewer (Claude Code subagent
| - Memory review   |---> or Copilot CLI, per harness) proposes a single JSON
| - Skill review    |     object on stdout; scripts/persist-proposal.py
| - Combined review |     validates it and performs every write, confined
+--------+----------+     to the resolved store (max 16 tool uses)
         |
         v
+--------+----------+
| Session End       |     Stop hook
| - Final review    |---> session-review.sh
| - Index session   |---> index-session.sh
+--------+----------+     (SQLite FTS5)
         |
         v (periodic, every 7 days)
+--------+----------+
| Curator           |     Consolidates narrow skills
| - Lifecycle prune |---> into class-level umbrellas
| - Skill merge     |     Archives stale/unused skills
+-------------------+
```

## Requirements

| Dependency | Needed for | Version | Windows notes |
|------------|-----------|---------|---------------|
| bash | all scripts | 4.0+ | via Git for Windows (Git Bash) or WSL |
| jq | hook payload + settings/JSON handling | 1.6+ | `winget install jqlang.jq` |
| python3 | injector, coach signals, session indexing and search (including its bundled `sqlite3` module) | 3.9+ (stdlib only — 3.9 is the CI floor; 3.8 is untested) | `winget install Python.Python.3.12` |
| sqlite3 (CLI, optional) | manual DB inspection; `self-learning-health.sh`'s database check (degrades to a warning, not a failure, if absent) | any | bundled with Git for Windows or `winget install SQLite.SQLite` |
| Claude Code | Claude adapter (optional) | current | — |
| GitHub Copilot CLI | Copilot adapter (optional) | current, authenticated | PowerShell 7+ required for its hooks |
| gh CLI | vendoring Coach rules, fork maintenance | 2.40+ | `winget install GitHub.cli` |
| Node.js + npm | building the Coach fork VSIX (Route B only) | Node 22+ | `winget install OpenJS.NodeJS` |

At least one of Claude Code / Copilot CLI must be installed for the system to do anything.

## Install

**Linux / macOS**
```bash
git clone <this-repo> && cd claude-self-learning
bash install.sh            # add --dry-run to preview
```

**Windows (PowerShell, with Git for Windows installed)**
```powershell
git clone <this-repo>; cd claude-self-learning
.\install.ps1              # delegates to install.sh via Git Bash
```

`install.ps1`/`uninstall.ps1` are parse-checked and behaviourally tested on
every push (GitHub's ubuntu runners ship `pwsh`). They check that the `bash`
they found can actually
see this repository before delegating to it (a `test -f` probe on the exact
script path, never a filename match). If the first `bash` on your PATH is
WSL's launcher — `C:\Windows\System32\bash.exe` — it runs inside the WSL
filesystem, where this directory is `/mnt/c/...` and `$HOME` is the WSL
user's, so an install through it would land somewhere you are not looking.
The wrappers refuse with an explanation instead. To install for WSL, run
`bash install.sh` inside WSL deliberately.

Then register the Claude Code hooks. `config/settings-hooks.json` is a
**template**, not a file to merge as-is: it carries a `__SL_SCRIPTS_DIR__`
placeholder that install.sh substitutes with the resolved store's `scripts`
directory. Merge the rendered copy, which install.sh both prints and writes to
`<store>/settings-hooks.json`, into `~/.claude/settings.json`. Merging the raw
template registers hooks that invoke a literal `__SL_SCRIPTS_DIR__` path and
never fire.

To render it yourself without re-running the installer:

```bash
sed "s|__SL_SCRIPTS_DIR__|$(python3 scripts/lib/paths.py get scripts)|g" \
    config/settings-hooks.json
```

`~/.claude/settings.json` is Claude Code's own config file, so *that* location
is deliberately Claude-specific; the **script paths it invokes** are not, and
must point at the vendor-neutral store. The Copilot CLI hook is installed
automatically to `~/.copilot/hooks/self-learning.json` when `~/.copilot` exists.

## Storage locations

All framework state (memory, learned skills, session index, logs, installed
scripts) lives under one vendor-neutral store, resolved by
`scripts/lib/paths.py` and shared by every bash script via `scripts/lib/config.sh`.
No default points inside `~/.claude` — that was the previous default, and it
is exactly what broke Copilot CLI persistence (Copilot's path allow-list
refuses writes outside its own namespace). Resolution order, first hit wins:

1. `$AGENT_LEARNING_HOME` — explicit override, mainly for testing/debugging
2. `$XDG_DATA_HOME/agent-learning`
3. Windows only: `%LOCALAPPDATA%\agent-learning`
4. `~/.local/share/agent-learning` (Linux and macOS default)

Run `scripts/lib/paths.py all` to print every resolved path, or `paths.py get <key>`
for one. The keys are: `home`, `state`, `skills` (`learned-skills/`), `memory`,
`logs`, `sessions_db` (`sessions/search.db`), `config_file`
(`self-learning.conf`), and `scripts` (installed copies of everything under
`scripts/`).

### Concurrent writes are serialised

Both harnesses can fire a review hook at nearly the same moment, and the
review pipeline is detached by design, so two `persist-proposal.py` processes
racing each other is ordinary operation, not an edge case. Every write
transaction (read existing content → merge → stage → rename) therefore runs
under one whole-store exclusive lock at `<state>/persist.lock`
(`scripts/lib/store_lock.py`). Without it, concurrent appends to `MEMORY.md`
— and concurrent updates to `learned-skills/.usage.json` — silently
overwrote each other while every writer reported success.

Every writer of the store takes this same lock: `persist-proposal.py` for its
whole plan-and-write transaction, `skill-lifecycle.py` for its whole pass
(read `.usage.json` → decide transitions → move skill directories → write),
and `curator-run.sh` for its pre-run backup, so that backup is a
point-in-time snapshot rather than a mix of before and after. The curator
releases the lock before invoking `skill-lifecycle.py`, which takes it in its
own process — short spans, deliberately, because one long hold across a whole
curator sweep would make a session-end review wait behind it.

The lock is `flock` on POSIX and `msvcrt.locking` on Windows, each chosen by a
functional probe rather than a platform name, with an `O_CREAT|O_EXCL`
lockfile as a last resort. Both kernel-backed backends are released by the OS
when the holding process dies, so a crashed review cannot wedge the store;
only the fallback needs (and has) age-based stale-lock breaking. `doctor.sh`
prints which backend is in force. Waiting is bounded — default 20s,
overridable with `SL_PERSIST_LOCK_TIMEOUT` — and a timeout fails loudly: a
non-zero exit plus a `lock timeout` line in `persist-failures.log`.

Both kernel-backed backends are confirmed to *execute* in CI, not merely to
exist: `tests/test-persist-concurrency.py` prints
`[capability probe] store_lock backend=...` on every run, and the matrix logs
show `flock` on the ubuntu and macos cells and `msvcrt` on the windows cells.
Grep any run's log for `store_lock backend=` to see it for yourself.

Harness-owned config files are a deliberate exception and stay where each
harness owns them: Claude Code's `~/.claude/settings.json` and Copilot CLI's
`~/.copilot/hooks/self-learning.json` are not moved into the store — only the
script paths those configs invoke are resolved through the neutral store.

### Migrating from an existing `~/.claude` install

Nothing is moved automatically, on install or otherwise. If you have an older
install that wrote memory/skills under `~/.claude`, run `bash scripts/doctor.sh`:
it detects a populated `~/.claude/memory` or `~/.claude/learned-skills` and
reports it under "legacy store" without touching it. To migrate deliberately,
copy the data yourself into the path doctor reports as the new store's `home`,
e.g.:

```bash
cp -r ~/.claude/memory ~/.claude/learned-skills "$(python3 scripts/lib/paths.py get home)/"
```

### `CLAUDE_REVIEW_ENABLED` is deprecated

Use `SL_REVIEW_ENABLED` instead. The old name is still honored for one
release for upgrade safety — if `SL_REVIEW_ENABLED` is unset and
`CLAUDE_REVIEW_ENABLED` is set, its value is used and a deprecation warning is
printed to stderr — but it will be removed. `SL_REVIEW_ENABLED` defaults to `true`.

## Diagnostics: `scripts/doctor.sh`

Run `bash scripts/doctor.sh` any time to see: every resolved path and which
override in the resolution chain produced it; whether each is actually
writable (a real create+remove temp-file test, not a permission-bit guess);
which harnesses (`claude`, `copilot`, `code`) are detected on this machine and
whether their hook configs point at the current resolved scripts directory
(`fresh`) or a stale one left over from a previous install layout (`stale`);
whether a legacy `~/.claude` store exists (detected, never touched); and,
most importantly, the contents of `${SL_LOG_DIR}/persist-failures.log`.

**That log deserves special attention.** The background review pipeline runs
fully detached (`nohup ... &`) so the calling hook can return immediately;
this means a review that fails — bad model output, a validation rejection in
`persist-proposal.py`, a write outside the store — can **never surface as a
non-zero hook exit code**. `doctor.sh` reading `persist-failures.log` is the
only mechanism that replaces that missing signal. If you want to know whether
background learning is actually persisting anything, run `doctor.sh`; do not
infer health from "the hook didn't error."

By default, `doctor.sh` exits non-zero only for a non-writable resolved path
or a non-empty `persist-failures.log`; a `stale` hook (see above) is printed
loudly but does not affect the exit code, so a plain `doctor.sh` run can
report `overall: HEALTHY` while a hook config still points at an old scripts
directory. Run `bash scripts/doctor.sh --strict` to additionally fail (exit
1) when any hook is `stale` — use this in CI or any wrapper that gates on
doctor's exit code, so broken hook wiring cannot pass silently. `--strict` is
opt-in; default behaviour is unchanged. One exception applies in both modes:
a detected legacy `~/.claude` store is never fatal, even under `--strict` —
every machine upgraded from a pre-vendor-neutral install would otherwise fail
`doctor.sh` forever, training operators to ignore its exit code entirely.

## Known residuals

Stated rather than quietly carried. None of these is a plan to fix; each is a
limit that a reader should know about before trusting the system further than
it goes.

- **The TOCTOU hardening does not cover Windows.** `persist-proposal.py`
  anchors every write on a `dir_fd` with `O_NOFOLLOW`, which closes the
  resolve-then-open race. Both primitives are POSIX-only and the stdlib
  offers no Windows equivalent, so Windows falls back to the documented,
  weaker path-based writer. `doctor.sh` prints which writer is in force.
  Closing it would need a Windows-specific reimplementation outside the
  stdlib-only constraint.
- **The WSL-vs-Git-Bash PATH ambiguity is reasoned about but not CI-tested.**
  `install.ps1`/`uninstall.ps1` refuse to delegate to a `bash` that cannot see
  this repository (a `test -f` probe on the exact script path). That guard is
  parse-checked and behaviourally tested on ubuntu runners, which have `pwsh`
  but no WSL — so the *scenario* it defends against cannot be reproduced
  without a Windows PowerShell CI job, which does not exist. The logic is
  tested; the environment is not.
- **`transcript.py` parses two undocumented, unversioned third-party on-disk
  formats** — Copilot CLI's `session-state/<id>/events.jsonl` and Claude
  Code's `projects/<slug>/<id>.jsonl`. Both were reverse-engineered from real
  files and neither vendor documents or versions them, so an update on either
  side can break session digestion. The mitigation is that it **fails
  loudly**: every degraded outcome — file missing, zero parseable events, or
  events present but none matching the expected message shape (the exact
  signature of a renamed schema) — returns a named reason that is appended to
  `persist-failures.log`, which `doctor.sh` surfaces. It never yields a
  silently empty transcript, which is this project's signature failure mode.
  It cannot be made immune to a format change; it can only refuse to hide one.
- **No genuine interactive Copilot session has yet fired `sessionEnd` with
  real conversation history in the payload.** The path is verified end-to-end
  with a real paid model call (see the compatibility table); the remaining gap
  needs ordinary day-to-day use, not engineering.
- **3 of the 45 vendored Coach rules are not evaluated** by the adapted Route
  A evaluator (42 evaluate). Each skips loudly with a reason that cites
  either an upstream file and line or a measurement over the local stores,
  and `tests/test-coach-rules-eval.py` enforces that: a reason with no
  checkable evidence fails the suite. The three, in full:
  `no-devcontainer` is genuinely unreachable (upstream's own
  `computeDevcontainerStats` filters to VS Code harnesses before reading any
  field); `broken-flow-state` is a deferred ~150-line analyzer port whose
  inputs are all present; `no-file-context` is reachable but deliberately not
  shipped under upstream's rule id, because answering it here would require
  redefining `referencedFiles` for one rule while four shipped adapters
  depend on the current definition.

  This was "34 not evaluated" until 2026-07-26. An adversarial re-analysis
  found that twelve of the then-21 skip reasons asserted something about
  upstream's source or the local data that was false, and that every one of
  the twelve pointed away from doing work. Most of the gap was unplumbed
  input described as absent input. Where a rule's CLI mapping differs from
  upstream's field, the adapter says so and says what differs.

## Uninstall (single command)

```bash
bash uninstall.sh            # removes EVERYTHING incl. learned data (asks first)
bash uninstall.sh --keep-data  # keep memory, skills, and the session index
bash uninstall.sh --yes        # non-interactive
```

Windows: `.\uninstall.ps1` (same flags). This also strips the self-learning
hooks from `~/.claude/settings.json` (a timestamped backup is written first)
and removes `~/.copilot/hooks/self-learning.json`.

## Subsystems

| # | Subsystem | Description |
|---|-----------|-------------|
| 1 | **Background Review** | Post-turn daemon that spawns a review subagent every N turns to extract memories and skills from the conversation. |
| 2 | **Skill Library** | File-backed repository of reusable knowledge with usage telemetry, lifecycle states (active/stale/archived), and authoring standards. |
| 3 | **Memory System** | Bounded MEMORY.md (agent notes) and USER.md (user profile) stores with frozen snapshot loading and threat scanning. |
| 4 | **Curator** | Periodic maintenance daemon that consolidates narrow skills into class-level umbrellas and archives unused skills. |
| 5 | **Session Search** | SQLite-backed cross-session search with four query shapes: discover, scroll, read, browse. Uses FTS5 (ranked, stemmed) when the local SQLite build supports it, probed functionally at index time (`scripts/lib/session_db.py`) -- never assumed from platform name; falls back to a substring `LIKE` query, never a silently empty index, when it doesn't (e.g. macOS's bundled `sqlite3` CLI commonly lacks FTS5, though Python's own bundled SQLite -- what this project actually uses -- usually has it). |

## Agent compatibility

Only rows backed by a suite in `tests/run-all.sh` are marked supported. VS
Code Copilot Chat has no adapter or hooks in this release (tracked as a
follow-up plan) and no row below claims otherwise.

| Capability | Claude Code | GitHub Copilot CLI | Notes |
|------------|-------------|--------------------|-------|
| Learned memory + skills stores | ✅ | ✅ | shared files, agent-agnostic; covered by `test-persist-proposal.py`, `test-proposal-schema.py` |
| AGENTS.md learned-context injection | ✅ | ✅ | Copilot also reads CLAUDE.md; covered by `test-inject-agents-md.sh` |
| Session-end background review | ✅ Stop hook | ✅ sessionEnd hook | both spawn a headless reviewer that is **denied file-write tools** — Claude via `--allowedTools Read,Glob,Grep --disallowedTools Write,Edit,NotebookEdit`, Copilot via `--allow-tool read`. Every write is `persist-proposal.py`'s. Both argv shapes are asserted (`test-session-review.sh`, `test-copilot-session-review.sh`) and checked against the real installed binaries with no model calls (`test-review-cli-flags.sh`). See "Bounding reviewer cost" for the cost knobs. |
| Mid-session turn counting | ✅ PostToolUse hook | ❌ not wired | deliberate: session-end loop is the portable core; covered by `test-turn-counter.sh` |
| Copilot path independent of Claude Code | — | ✅ | `test-claude-absent.sh` runs the full Copilot review path with no `claude` binary or `~/.claude` present |
| Session search indexing | ✅ (Claude JSONL) | ❌ planned | Copilot session-state parser is a follow-up plan; not yet exercised by run-all.sh beyond schema tests |
| Coach signals (Routes A/B) | ✅ Route A (42/45 rules, adapted) + ✅ Route B (full, when the fork is installed) | same | reaches the reviewer prompt: `session-review.sh`/`copilot-session-review.sh` call `coach-signals.py` then append its merged output as a "Coach signals" section of the review prompt when present and <7 days old; covered by `test-coach-signals.py`, `test-coach-rules-eval.py`, and `test-session-review.sh`'s "coach signal id reaches prompt" assertion, which fails if that wiring ever regresses. **Route A is not upstream-equivalent**: `scripts/coach-rules-eval.py` evaluates 42 of the 45 vendored rules - 11 adapted to this project's own `messages`/`sessions` columns, and 31 read from the harnesses' own telemetry stores via `scripts/lib/telemetry.py` (Copilot's `events.jsonl`, `session-store.db` and `workspace.yaml`, Claude Code's `projects/*.jsonl`). Only 3 are skipped, and each skip reason must cite an upstream file:line or a measurement over the local stores - a reason with no checkable evidence fails the suite. See `UNSUPPORTED_REASONS` in `coach-rules-eval.py` and the "AI Engineering Coach integration" section below for all three, and for the twelve false skip reasons that were removed on 2026-07-26. `bash tests/run-all.sh` pins the count so a silent coverage drop fails, and `TelemetryAbsentSkipsLoudlyTest` pins that a missing harness store produces skips rather than a false all-clear. Route B, when the maintained fork is installed, reads Coach's own complete analysis rather than re-deriving it from our narrower data. |
| Windows | ✅ green (Git Bash), with skips — see note | ✅ green (Git Bash), with skips — see note | CI results are per-OS (the whole matrix cell passes or fails), not per-harness, so both columns show the same Windows result. **No run id is frozen here** — earlier versions of this row cited one and went stale within hours, twice. Get the current state with `gh run list --branch main` and `gh run view <id>`; the matrix is `{ubuntu, macos, windows}-latest × Python {3.9, 3.13}`, six cells. As of the last run observed while writing this, all six were green with the full suite. **Green ≠ equally covered.** Re-derive the current figures rather than trusting these — `gh run view --job <windows job id> --log`, then count `SKIP:` lines and `OK (skipped=N)` per `=== tests/… ===` banner; do not count by eye. As measured on run `30284745998`, windows-latest 3.13 against ubuntu-latest 3.13: **4 shell skips** across 3 suites (`test-path-compare-lib.sh` prints two, `test-copilot-hook-input.sh` and `test-doctor.sh` one each) and **21 Python skips** across 5 suites, of which **11 are Windows-only** (`test-persist-proposal.py` 5, `test-adversarial-sweep.py` 3, `test-store-lock-writers.py` 3). `test-win-dir-pin.py` is the inverse suite — 6 skip on Windows, 9 on Linux. **There is no single reason, and "symlinks need elevation" is only half right.** Each skip names its own probed cause: `test-persist-proposal.py`'s 5 are `O_NOFOLLOW: UNAVAILABLE (POSIX-only primitive)` and `dir_fd (functional): UNAVAILABLE` — note that suite also prints `symlink creation: AVAILABLE` and `hardlink creation: AVAILABLE`, so Python *can* build the attack fixtures there; `test-adversarial-sweep.py`'s 3 are `chmod read-only probed and not enforced` (×2) and "POSIX permission bits are not meaningful on Windows/NTFS ACLs"; `test-doctor.sh`'s 1 is the same ACL behaviour, verified by writing a probe file rather than assumed; `test-copilot-hook-input.sh`'s 1 is `pty allocation: UNAVAILABLE (No module named 'termios')`; and `test-path-compare-lib.sh`'s 2 *are* symlink-creation failures — `ln -s` could not create one, verified with `[[ -L … ]]`. So the shell half fails to make symlinks while the Python half succeeds. Every skip is gated on a probe that verifies the limitation instead of inferring it from the platform name. Three things to state plainly rather than let green imply otherwise: `test-store-lock-writers.py`'s 3 skip because **`bash` is not runnable from Python on that runner** (probed), so the bash-driven concurrent-writer scenarios go unexercised on Windows — the lock backend itself does run there (`store_lock backend=msvcrt`); **4 live telemetry/transcript tests skip on every cell on every platform**, because no runner has a Copilot or Claude store, so live extraction is exercised only on a developer machine with both harnesses installed; and conversely Windows covers what POSIX cannot — `win32 directory pinning: AVAILABLE (verified: a pinned directory could not be renamed, and our own staged replace inside it still succeeded)`. |
| macOS | ✅ green | ✅ green | Same per-OS note as the Windows row, including the "no frozen run id" part. No skips on macOS. |
| Copilot CLI live end-to-end (real session, real file on disk) | n/a | ✅ verified 2026-07-25 (one residual) | Run against whatever `copilot` version was installed on 2026-07-25 (1.0.73 at that moment; it has since auto-updated past that, e.g. 1.0.75 — this project targets "current, authenticated `copilot` on PATH," never a pinned version, so treat any specific number here as a point-in-time observation, not a requirement) with a real paid model call. `copilot-session-review.sh` completed end-to-end and the writer accepted a valid empty proposal (correct — headless `-p` has no transcript to mine); the same OUTPUT CONTRACT with a transcript produced a conforming proposal and **real content persisted** to `<store>/memory/MEMORY.md`, append mode, 0600, nothing written outside the store. Residual: no genuine *interactive* session has fired the `sessionEnd` hook with real conversation history in the payload yet — that needs ordinary use. |

## AI Engineering Coach integration (optional)

Two independent, off-by-default integrations with
[microsoft/AI-Engineering-Coach](https://github.com/microsoft/AI-Engineering-Coach).
Enable either or both in the resolved store's `self-learning.conf` (see
"Storage locations" and "Configuration reference" above):

| Flag | Route | What it does | Requires |
|------|-------|--------------|----------|
| `SL_COACH_RULES_ENABLED=true` | A — rules mode | Evaluates Coach's MIT-licensed anti-pattern rules (vendored in `vendor/coach-rules/`) against our own session index; triggered rules steer the background review. Fully automatic. | nothing extra |
| `SL_COACH_EXPORT_ENABLED=true` | B — export mode | Reads the full Coach analysis from `~/.aiec/summary-latest.json`, written automatically by our maintained fork's auto-export patch. Richer signals than Route A. | the fork's `.vsix` installed in VS Code |

When both are enabled, signals are merged and deduplicated by rule id; Route B
(export) data wins because it comes from Coach's complete analyzer.

**Route A evaluates 42 of the 45 vendored rules (measured, pinned by tests -
see the Coach signals row above). They come from two data sources and are
still ADAPTATIONS, not re-implementations of the upstream rules.**

*Corrected twice.* This section said 11 rules until 2026-07-26, then 24, and
now says 42. Both corrections went the same direction, and the reason is worth
recording because it is a failure mode rather than an accident.

The first correction: upstream (`microsoft/AI-Engineering-Coach`) is not a VS
Code-internals consumer - its own README is *"any harness, one dashboard"*,
`src/core/parser-vscode-cli.ts` parses Copilot CLI's
`~/.copilot/session-state/<id>/events.jsonl`, and `src/core/parser-claude.ts`
parses Claude Code's `~/.claude/projects/*.jsonl`. Those are the files this
project already reads for the reviewer's digest. The telemetry was unplumbed
here, not unobtainable.

The second correction came from an adversarial re-analysis of the 21 skips
that survived the first one. **Twelve of the twenty-one skip messages asserted
something about upstream's source or about the local data that is false, and
every one of the twelve pointed away from doing work.** A random error rate
would have created work about half the time. Two arguments did most of the
damage and are now banned in the skip table's header:

- *`requiresIdeContext: true` proves the rule is unreachable.* It does not.
  Upstream computes `skipIdeDetectors` only when a harness FILTER is applied
  to the dashboard (`src/core/analyzer-patterns.ts:262`); in the default view
  all 45 detectors run over a corpus that includes CLI sessions. The flag is
  about attributing a finding in a mixed-harness view, not about the input
  being absent.
- *A conjunct that is constant here makes the rule a constant.* A
  universally-true clause inside a conjunction is a NO-OP; the discriminating
  work is done by the other clauses. Three rules were skipped on this.

The data sources are:

1. **The project's own index** (`SL_SEARCH_DB`) - per-message role/content/
   timestamp. Feeds 11 rules, each narrowing "requests" scope to
   per-user-message text/timestamp and documenting its limitation (grouping by
   `project_path` instead of `workspaceName` for `tunnel-vision`;
   regex-counting `"[tool: X]"` markers instead of structured `toolsUsed[]`
   for `mcp-tool-bloat`, which loses arguments and paths).
2. **`scripts/lib/telemetry.py`** - the harnesses' own stores, read-only:
   Copilot's `events.jsonl` and `session-store.db` (`assistant_usage_events`),
   its per-session `workspace.yaml`, and Claude Code's transcripts. Feeds the
   other 31 rules.

`vendor/coach-rules/tables/` holds three artefacts vendored the same way the
rule files are, and pinned by SHA-256 in `scripts/lib/coachtables.py`:
upstream's `MODEL_TIERS` and `WORK_TYPE_PATTERNS` (verbatim TypeScript slices,
extracted with a loud failure if the anchor is missing) and the
`leo-profanity` 1.9.0 dictionary upstream itself depends on, stored as SHA-256
hashes rather than plaintext. Hashing is behaviour-preserving because
`leoProfanity.check()` is exact whole-word set membership, and it keeps this
repository free of the wordlist - the property Microsoft wanted when they
pushed the list into an external package. A table that changes stops the
adapters that read it until a human updates the pin, which is the same
contract `_pin()` enforces for a rule's detect block, and the mechanism is
tested by executing the mutation rather than asserting it.

**The three rules still skipped**, in full:

- **`no-devcontainer` - genuinely unreachable**, and the only one for which
  that is true. Not because of `requiresIdeContext`: because upstream's own
  `computeDevcontainerStats` opens with
  `sessions.filter(s => VSCODE_HARNESSES.has(...))`
  (`src/core/dsl/interpreter.ts:579-583`), so for a CLI harness the scored
  population is empty inside upstream's function, by a hardcoded gate, before
  any field of ours is consulted.
- **`broken-flow-state` - reachable, deferred, cost stated accurately.** It
  needs a four-component weighted per-session score with hardcoded breakpoints
  (`src/core/analyzer-flow.ts:41`). Every input is captured; this is a
  ~150-line analyzer port, not a data gap. It was the one entry in the old
  table whose reason was already honest.
- **`no-file-context` - reachable, deliberately not shipped under this rule
  id.** Upstream means *context the human attached to the prompt*, which
  Copilot records as `user.message.data.attachments`; but `telemetry.py`
  populates `referencedFiles` from tool arguments, mirroring upstream's own
  CLI parser, and four shipped adapters depend on that definition. Answering
  under upstream's id with a different input is exactly the drift `_pin()`
  exists to prevent. It wants a locally-named signal, not a redefinition.

**Adaptations are declared, not glossed.** Where a CLI mapping differs from
upstream's field the adapter says so and says what differs - the Claude
`CLAUDE.md`-for-`copilot-instructions.md` substitution; `approved-for-location`
as Copilot's analogue of `autoApproveScope: 'always'` (Copilot has no
session-scoped approval, so upstream's `'session'` arm is dead here, and
Claude Code records no confirmations at all); `ExitPlanMode` as Claude Code's
plan-mode marker, because `permissionMode` never carries the value `plan`
even in sessions that plainly used it; and per-request `customInstructions`
redefined as "this workspace has an instruction file", which loses upstream's
ability to tell two requests in one workspace apart.

**One thing was measured, works, and is still not shipped**, recorded here
rather than chosen silently: defining auto-approval by subtracting permission
events from tool executions (1046 `bash` executions against 219 `shell`
permission requests) puts `yolo-mode` at ~0.96 and fires it loudly. It is
rejected under upstream's rule id because Copilot CLI has an unpublished
built-in allow-list of safe read-only commands, so "no permission event"
conflates "the user auto-approved this" with "Copilot never asks about `ls`".

**Two rules ship with replaced remediation text.** `no-slash-commands` and
`agent-mode-for-asks` are genuine findings, but upstream's "How to Improve"
names `/fix`, `/explain`, `/tests`, `/doc` and an Ask/Chat mode, none of which
exist in either CLI - and that text is what gets written into the user's
memory file. Skipping would discard a finding to avoid a text problem;
emitting it would persist bad advice. `SUGGESTION_OVERRIDES` in
`coach-rules-eval.py` substitutes CLI-accurate text, marked `ADAPTED FOR CLI`,
with the rule id and count still upstream's.

No rule is enabled unless it is shown firing on a fixture built from real
event shapes, and every rule keeps a fire/no-fire test PAIR: a rule that
evaluates but can never fire hides a gap instead of reporting it, which is
worse than a loud skip - and the inverse, shipping dead rules to raise a
number, is the failure this section's own history warns about. When a harness
store is absent entirely (CI), the telemetry rules skip loudly naming the
missing source rather than reporting a clean bill of health from no data.

Route A's `detect` parser is a deliberately narrow subset of upstream's DSL
(upstream ships a ~4,300-line lexer/parser/interpreter under `src/core/dsl/`);
each adapter pins the exact predicate it implements and refuses to run if a
re-vendor changes it. Re-vendor rules with
`bash scripts/sync-coach-rules.sh`. The fork lives at
`<org>/ai-engineering-coach-fork` (see its FORK-NOTES.md for the sync protocol).

## Roadmap

| Phase | Name | Status |
|-------|------|--------|
| 1 | Foundation (turn counter, hooks, signal mechanism) | Done |
| 2 | Background Review (review prompts, memory/skill writes) | Done — reviewer proposes JSON on stdout, `scripts/persist-proposal.py` validates and writes, confined to the resolved store |
| 3 | Skill Lifecycle (telemetry, state machine, authoring standards) | Done |
| 4 | Curator + Session Search (consolidation, FTS5 index) | Done |
| 5 | Integration + Polish (config, caching, install, health check) | Done for Claude Code + Copilot CLI; VS Code Copilot Chat adapter not started (tracked separately). For CI status run `gh run list --branch main` — no run id is recorded here, deliberately; see "Agent compatibility" above for the Windows skip caveat |

See "Storage locations" above for the harness-neutral persistence work that
followed the original 5-phase plan: a shared, vendor-neutral store plus a
`doctor.sh` diagnostic, so Claude Code, Copilot CLI, and (eventually) VS Code
Copilot Chat consume the same files as peers.

## Project Structure

```
claude-self-learning/
  config/
    self-learning.yaml          # Default configuration (all parameters)
    settings-hooks.json         # Hook registration template for settings.json
    claude-md-snippet.md        # Self-learning protocol for CLAUDE.md
  prompts/
    memory-review.md            # Memory review prompt
    skill-review.md             # Skill review prompt (with authoring standards)
    combined-review.md          # Combined memory + skill review prompt
    curator-review.md           # Curator consolidation prompt
    authoring-standards.md      # Skill authoring standards reference
  schema/
    session-search-schema.sql   # Base sessions/messages schema, always applied
    session-search-fts5.sql     # FTS5 index + sync triggers, applied only when probe_fts5() confirms support
  scripts/                      # Hook, review, curator, install/uninstall, and doctor scripts (bash + Python)
  tests/                        # test suites discovered by glob and run by tests/run-all.sh
                                #   (no count is recorded here: it drifts on every suite added or
                                #    removed, and has gone stale in this file repeatedly. Run
                                #    `bash tests/run-all.sh` and read its "Discovered N suite(s)" line.)
  docs/
    research/                   # 15 research documents (~789KB)
```

## Documentation

- [`docs/project-creation-plan.md`](docs/project-creation-plan.md) -- The original plan used to create this project (structure, execution steps, verification)
- [`docs/research/07-implementation-guide-for-claude-code.md`](docs/research/07-implementation-guide-for-claude-code.md) -- Full implementation guide (~10,000 lines) with 5-phase roadmap, deliverable tables, verification checklists

## Research

The `docs/research/` directory contains the full analysis of NousResearch's Hermes Agent self-learning architecture:

- `01-architecture-and-structure.md` -- System architecture and code structure
- `02-self-learning-mechanisms.md` -- Eight self-learning mechanisms
- `03-training-and-finetuning.md` -- Training pipeline and trajectory processing
- `04-prompts-and-reflection.md` -- Prompt engineering and reflection patterns
- `05-skill-lifecycle-and-curator.md` -- Skill lifecycle management and curation
- `06-missing-areas-research.md` -- Gap analysis and missing components
- `07-implementation-guide-for-claude-code.md` -- Full implementation guide (~10,000 lines)

## Design Principles

1. **Best-effort, never block** -- All self-learning runs in the background. Failures log at DEBUG level. The user's primary workflow is never interrupted.
2. **Frozen snapshot** -- Memory and skills are snapshotted into the system prompt at session start. Mid-session writes update disk but do not mutate the running prompt (preserves prefix cache hits).
3. **Bounded storage** -- Character limits on memory stores, lifecycle pruning on skills. The system cannot grow without bound.
4. **Class-level skills over narrow skills** -- Prefer broad, reusable skills ("Python testing patterns") over narrow ones ("how to mock datetime in pytest"). The Curator enforces this via consolidation.

## Configuration reference

All settings live in the resolved store's `config_file`
(`self-learning.conf`, shell syntax, `VAR=value`) — see "Storage locations"
above for how that path is resolved; it defaults to
`~/.local/share/agent-learning/self-learning.conf` and is never `~/.claude`
by default. Environment variables with the same names override the file.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SL_HOME` | resolved store root (see "Storage locations") | Root for all state |
| `SL_REVIEW_ENABLED` | `true` | Enable/disable the background review pipeline; supersedes deprecated `CLAUDE_REVIEW_ENABLED` |
| `SL_COACH_RULES_ENABLED` | `false` | Coach Route A (rule evaluation) |
| `SL_COACH_EXPORT_ENABLED` | `false` | Coach Route B (fork auto-export) |
| `SL_COACH_EXPORT_PATH` | `~/.aiec/summary-latest.json` | Route B input file |
| `SL_MEMORY_REVIEW_INTERVAL` | `10` | Turns between memory review signals |
| `SL_SKILL_REVIEW_INTERVAL` | `10` | Tool calls between skill review signals |
| `SL_REVIEW_MIN_TURNS` | `5` | Minimum session turns before a review runs |
| `SL_REVIEW_MAX_TURNS` | `16` | Turn cap for the spawned Claude Code reviewer (`--max-turns`) |
| `SL_COPILOT_REVIEW_MODEL` | (CLI default) | Model for Copilot reviews; use the cheapest available. Must match `^[A-Za-z0-9._-]+$` |
| `SL_COPILOT_MAX_AI_CREDITS` | (empty — off) | Optional cost ceiling for Copilot reviews (`--max-ai-credits`). Integer, minimum 30; anything else is dropped with a reason on stderr. See note below |
| `SL_SKILLOPT_ENABLED` | `false` | Route C: SkillOpt skill optimization (opt-in) |
| `SL_SKILLOPT_REPO` | (empty) | path to a microsoft/SkillOpt checkout |
| `SL_SKILLOPT_RUN_CONFIRMED` | `false` | safety gate; the expensive `run` verb refuses until set true after a dry-run cost review |

### Bounding reviewer cost

The two harnesses bound the background reviewer differently, and the asymmetry is deliberate.

- **Claude Code** takes a hard turn cap: `--max-turns "$SL_REVIEW_MAX_TURNS"`, on by default at 16. It is also spawned with `--allowedTools Read,Glob,Grep --disallowedTools Write,Edit,NotebookEdit`, so the reviewer can read what it needs to review and cannot write anything — every write is `scripts/persist-proposal.py`'s.
- **GitHub Copilot CLI** has no turn cap for headless `-p` runs (`--max-autopilot-continues` is interactive-only). It does have `--max-ai-credits`, documented under `copilot help limits`, minimum 30, and it is a *soft* cap: usage is known only after a response returns, so it bounds a runaway loop rather than any single call.

`SL_COPILOT_MAX_AI_CREDITS` is **off by default** rather than defaulted to the minimum. `copilot` errors on unknown options, so passing the flag unconditionally would hard-break the whole review on any CLI older than the release that added it — and the review runs in a detached pipeline, so the only symptom would be lines in `persist-failures.log` while learning quietly stopped. Set it explicitly if your CLI supports it and you want the ceiling.

To confirm the flags against your own installed binaries at any time (no model calls, no tokens): `bash tests/test-review-cli-flags.sh`.

## License

MIT
