# Claude Self-Learning

A self-learning system for Claude Code, adapted from NousResearch's Hermes Agent architecture. Claude Code sessions learn from every interaction, accumulating reusable skills, refined memories, and searchable session history -- without requiring the user to manually curate any of it. The system runs entirely in the background via hooks and subagents, writing to disk-backed stores that persist across sessions and are loaded as frozen snapshots at session start.

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
| Background Review |     Subagent (Agent tool)
| - Memory review   |---> writes MEMORY.md, USER.md
| - Skill review    |---> writes learned-skills/
| - Combined review |     (max 16 tool uses)
+--------+----------+
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
| python3 | injector, coach signals, session indexing | 3.8+ (stdlib only) | `winget install Python.Python.3.12` |
| sqlite3 | session search index | 3.35+ | bundled with Python or `winget install SQLite.SQLite` |
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
| 5 | **Session Search** | SQLite FTS5-indexed cross-session search with four query shapes: discover, scroll, read, browse. |

## Agent compatibility

| Capability | Claude Code | GitHub Copilot CLI | Notes |
|------------|-------------|--------------------|-------|
| Learned memory + skills stores | ✅ | ✅ | shared files, agent-agnostic |
| AGENTS.md learned-context injection | ✅ | ✅ | Copilot also reads CLAUDE.md |
| Session-end background review | ✅ Stop hook | ✅ sessionEnd hook | both spawn a headless reviewer |
| Mid-session turn counting | ✅ PostToolUse hook | ❌ not wired | deliberate: session-end loop is the portable core |
| Session search indexing | ✅ (Claude JSONL) | ❌ planned | Copilot session-state parser is a follow-up plan |
| Coach signals (Routes A/B) | ✅ | ✅ | consumed by both reviewers |
| Windows | ✅ via Git Bash/WSL | ✅ via Git Bash/WSL | Copilot hooks additionally need PowerShell 7+ |

## AI Engineering Coach integration (optional)

Two independent, off-by-default integrations with
[microsoft/AI-Engineering-Coach](https://github.com/microsoft/AI-Engineering-Coach).
Enable either or both in `~/.claude/self-learning.conf`:

| Flag | Route | What it does | Requires |
|------|-------|--------------|----------|
| `SL_COACH_RULES_ENABLED=true` | A — rules mode | Evaluates Coach's MIT-licensed anti-pattern rules (vendored in `vendor/coach-rules/`) against our own session index; triggered rules steer the background review. Fully automatic. | nothing extra |
| `SL_COACH_EXPORT_ENABLED=true` | B — export mode | Reads the full Coach analysis from `~/.aiec/summary-latest.json`, written automatically by our maintained fork's auto-export patch. Richer signals than Route A. | the fork's `.vsix` installed in VS Code |

When both are enabled, signals are merged and deduplicated by rule id; Route B
(export) data wins because it comes from Coach's complete analyzer.

Route A rule coverage is a documented subset of Coach's detect DSL; unsupported
rules are skipped and logged, never guessed at. Re-vendor rules with
`bash scripts/sync-coach-rules.sh`. The fork lives at
`<org>/ai-engineering-coach-fork` (see its FORK-NOTES.md for the sync protocol).

## Roadmap

| Phase | Name | Timeframe | Status |
|-------|------|-----------|--------|
| 1 | Foundation (turn counter, hooks, signal mechanism) | Week 1-2 | Planned |
| 2 | Background Review (review prompts, memory/skill writes) | Week 3-4 | Planned |
| 3 | Skill Lifecycle (telemetry, state machine, authoring standards) | Week 5-6 | Planned |
| 4 | Curator + Session Search (consolidation, FTS5 index) | Week 7-8 | Planned |
| 5 | Integration + Polish (config, caching, install, health check) | Week 9-10 | Planned |

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
    session-search-schema.sql   # SQLite FTS5 schema for session search
  scripts/                      # (implementation scripts, future phases)
  tests/                        # (test suite, future phases)
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

All settings live in `~/.claude/self-learning.conf` (shell syntax, `VAR=value`).
Environment variables with the same names override the file.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SL_HOME` | `~/.claude` | Root for all state |
| `SL_COACH_RULES_ENABLED` | `false` | Coach Route A (rule evaluation) |
| `SL_COACH_EXPORT_ENABLED` | `false` | Coach Route B (fork auto-export) |
| `SL_COACH_EXPORT_PATH` | `~/.aiec/summary-latest.json` | Route B input file |
| `SL_MEMORY_REVIEW_INTERVAL` | `10` | Turns between memory review signals |
| `SL_SKILL_REVIEW_INTERVAL` | `10` | Tool calls between skill review signals |
| `SL_REVIEW_MIN_TURNS` | `5` | Minimum session turns before a review runs |
| `SL_REVIEW_MAX_TURNS` | `16` | Turn cap for the spawned reviewer |
| `SL_COPILOT_REVIEW_MODEL` | (CLI default) | Model for Copilot reviews; use the cheapest available. Must match `^[A-Za-z0-9._-]+$` |

## License

MIT
