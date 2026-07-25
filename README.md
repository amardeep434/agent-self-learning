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
| python3 | injector, coach signals, session indexing and search (including its bundled `sqlite3` module) | 3.8+ (stdlib only) | `winget install Python.Python.3.12` |
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

Then register the Claude Code hooks by merging `config/settings-hooks.json` into
`~/.claude/settings.json` (the installer prints the exact JSON). The Copilot CLI
hook is installed automatically to `~/.copilot/hooks/self-learning.json` when
`~/.copilot` exists.

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
| Session-end background review | ✅ Stop hook | ✅ sessionEnd hook | both spawn a headless reviewer; covered by `test-session-review.sh` (Claude) and `test-copilot-session-review.sh` (Copilot) |
| Mid-session turn counting | ✅ PostToolUse hook | ❌ not wired | deliberate: session-end loop is the portable core; covered by `test-turn-counter.sh` |
| Copilot path independent of Claude Code | — | ✅ | `test-claude-absent.sh` runs the full Copilot review path with no `claude` binary or `~/.claude` present |
| Session search indexing | ✅ (Claude JSONL) | ❌ planned | Copilot session-state parser is a follow-up plan; not yet exercised by run-all.sh beyond schema tests |
| Coach signals (Routes A/B) | ✅ Route A (11/45 rules, adapted) + ✅ Route B (full, when the fork is installed) | same | reaches the reviewer prompt: `session-review.sh`/`copilot-session-review.sh` call `coach-signals.py` then append its merged output as a "Coach signals" section of the review prompt when present and <7 days old; covered by `test-coach-signals.py`, `test-coach-rules-eval.py`, and `test-session-review.sh`'s "coach signal id reaches prompt" assertion, which fails if that wiring ever regresses. **Route A is not upstream-equivalent**: `scripts/coach-rules-eval.py` evaluates 11 of the 45 vendored rules, each an ADAPTATION to this project's own `messages`/`sessions` columns (per-user-message text/timestamp + session-level counts), never VS Code Copilot Chat's richer per-turn telemetry (modelId, toolsUsed[], referencedFiles[], token counts, etc.) that upstream's `scan: requests` rules actually target and that this project does not capture for either harness. The other 34 rules skip loudly with a reason naming the exact missing field (see the module docstring and `UNSUPPORTED_REASONS` in `coach-rules-eval.py`); `bash tests/run-all.sh` pins this count via `test-coach-rules-eval.py`'s `CoverageAssertionTest` so a future change that silently drops coverage fails the suite. Route B, when the maintained fork is installed, bypasses this gap entirely — it reads Coach's own complete analysis (see "AI Engineering Coach integration" below) rather than re-deriving it from our narrower data. |
| Windows | ✅ green (Git Bash), with skips — see note | ✅ green (Git Bash), with skips — see note | CI results are per-OS (the whole matrix cell passes or fails), not per-harness, so both columns show the same Windows result. All 28 suites run and pass on `windows-latest` × Python 3.9 and 3.13 as of CI run `30157000235`. **But green ≠ equally covered**: 7 write-path security tests in `test-persist-proposal.py` (symlink, hardlink, and `O_NOFOLLOW` cases) and 3 shell assertions skip on Windows, because creating a real symlink needs Developer Mode or elevation and `chmod` does not deny writes on ACL-governed filesystems. Each skip is printed with its reason and is gated on a probe that verifies the limitation rather than assuming it from the platform name. The symlink/hardlink attack surface is therefore exercised on Linux and macOS only. |
| macOS | ✅ green | ✅ green | Same per-OS note as the Windows row. All 28 suites run and pass on `macos-latest` × Python 3.9 and 3.13 as of CI run `30157000235`, with no skips. |
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

**Route A evaluates 11 of the 45 vendored rules (measured, pinned by a test —
see the Coach signals row above), and even those 11 are ADAPTATIONS, not
re-implementations of the upstream rule.** Upstream's `scan: requests` rules
are written against VS Code Copilot Chat's own per-turn telemetry object
(`modelId`, `toolsUsed[]`, `referencedFiles[]`, `isCanceled`, `agentMode`,
`reasoningEffort`, token counts, `toolConfirmations[]`, `customInstructions`,
`skillsUsed[]`, `slashCommand`, `workspaceName`) — none of which this project
captures for Claude Code or Copilot CLI. `scripts/coach-rules-eval.py`
narrows "requests" scope, where evaluable at all, to per-user-message
text/timestamp already stored in the `messages` table, and documents each
substitution's limitation (e.g. grouping by `project_path` instead of
`workspaceName` for `tunnel-vision`; regex-counting the `"[tool: X]"` text
markers already embedded in stored content instead of structured
`toolsUsed[]` for `mcp-tool-bloat`, which loses tool arguments and file
paths). The remaining 34 rules are skipped and logged with the *specific*
missing field named, never guessed at and never silently coerced into a
signal that can only ever fire zero times. Re-vendor rules with
`bash scripts/sync-coach-rules.sh`. The fork lives at
`<org>/ai-engineering-coach-fork` (see its FORK-NOTES.md for the sync protocol).

## Roadmap

| Phase | Name | Status |
|-------|------|--------|
| 1 | Foundation (turn counter, hooks, signal mechanism) | Done |
| 2 | Background Review (review prompts, memory/skill writes) | Done — reviewer proposes JSON on stdout, `scripts/persist-proposal.py` validates and writes, confined to the resolved store |
| 3 | Skill Lifecycle (telemetry, state machine, authoring standards) | Done |
| 4 | Curator + Session Search (consolidation, FTS5 index) | Done |
| 5 | Integration + Polish (config, caching, install, health check) | Done for Claude Code + Copilot CLI; VS Code Copilot Chat adapter not started (tracked separately); CI green on all six matrix cells (run `30157000235`) — see "Agent compatibility" above for the Windows skip caveat |

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
  tests/                        # 18 test suites (13 shell, 5 Python) run by tests/run-all.sh
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
| `SL_REVIEW_MAX_TURNS` | `16` | Turn cap for the spawned reviewer |
| `SL_COPILOT_REVIEW_MODEL` | (CLI default) | Model for Copilot reviews; use the cheapest available. Must match `^[A-Za-z0-9._-]+$` |
| `SL_SKILLOPT_ENABLED` | `false` | Route C: SkillOpt skill optimization (opt-in) |
| `SL_SKILLOPT_REPO` | (empty) | path to a microsoft/SkillOpt checkout |
| `SL_SKILLOPT_RUN_CONFIRMED` | `false` | safety gate; the expensive `run` verb refuses until set true after a dry-run cost review |

## License

MIT
