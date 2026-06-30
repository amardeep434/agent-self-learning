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

## Quick Start

```bash
# Clone and install
git clone https://github.com/<your-org>/claude-self-learning.git
cd claude-self-learning
bash install.sh

# Verify installation
bash scripts/self-learning-health.sh
```

The install script:
1. Copies hook scripts to `~/.claude/scripts/`
2. Copies review prompts to `~/.claude/scripts/review-prompts/`
3. Registers PostToolUse and Stop hooks in `~/.claude/settings.json`
4. Creates required directories (`state/`, `memory/`, `learned-skills/`, `sessions/`, `logs/`)
5. Initializes the SQLite FTS5 database for session search
6. Appends the self-learning protocol to `~/.claude/CLAUDE.md`

## Subsystems

| # | Subsystem | Description |
|---|-----------|-------------|
| 1 | **Background Review** | Post-turn daemon that spawns a review subagent every N turns to extract memories and skills from the conversation. |
| 2 | **Skill Library** | File-backed repository of reusable knowledge with usage telemetry, lifecycle states (active/stale/archived), and authoring standards. |
| 3 | **Memory System** | Bounded MEMORY.md (agent notes) and USER.md (user profile) stores with frozen snapshot loading and threat scanning. |
| 4 | **Curator** | Periodic maintenance daemon that consolidates narrow skills into class-level umbrellas and archives unused skills. |
| 5 | **Session Search** | SQLite FTS5-indexed cross-session search with four query shapes: discover, scroll, read, browse. |

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

## License

MIT
