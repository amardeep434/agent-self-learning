# Plan: Create `claude-self-learning` Standalone Project

> **Origin:** Created during the initial project setup session (2026-07-01).
> **Source:** `/home/amardeep/.claude/plans/sprightly-discovering-fiddle.md`

## Context

We completed ultra-deep research on NousResearch's Hermes Agent self-learning system (15 docs, ~789KB) including a 10,000-line implementation guide. The research and implementation guide currently live in `MyApp/docs/research/hermes-agent/` but this system is a general Claude Code extension, not VyapaarLink-specific. The user wants a standalone GitHub project at `~/claude-self-learning`.

## What This Plan Does

1. Create the project at `~/claude-self-learning` with proper structure
2. Move all research docs from MyApp
3. Initialize git + create GitHub repo
4. Set up the project skeleton with README, directory structure, and install script

## Project Structure

```
~/claude-self-learning/
├── README.md                          # Project overview, quick start, architecture
├── LICENSE                            # MIT
├── install.sh                         # One-command installer -> deploys to ~/.claude/
├── uninstall.sh                       # Clean removal
│
├── scripts/                           # Deployable scripts (install.sh copies to ~/.claude/scripts/)
│   ├── turn-counter.sh                # PostToolUse hook: increment turn counter
│   ├── session-review.sh              # Stop hook: trigger end-of-session review
│   ├── build-digest.sh                # Extract last N messages as review digest
│   ├── index-session.py               # Index session JSONL into SQLite FTS5
│   ├── index-session.sh               # Stop hook wrapper for indexer
│   ├── batch-index-sessions.sh        # Catch-up indexer for missed sessions
│   ├── session-search.sh              # Four-shape search CLI
│   ├── session-search-schema.sql      # SQLite + FTS5 schema
│   ├── scan-threats.py                # Memory/skill write security scanner
│   ├── skill-lifecycle.py             # Lifecycle state transitions
│   ├── skill-pin.sh                   # Pin/unpin skills
│   ├── curator-run.sh                 # Periodic maintenance runner
│   ├── detect-project-type.sh         # Coding posture detection
│   ├── rebuild-skills-cache.sh        # Skills prompt cache rebuilder
│   ├── load-config.sh                 # Config loader utility
│   ├── self-learning-health.sh        # Health check / diagnostics
│   └── pre-compress-extract.sh        # Pre-compression knowledge extraction
│
├── prompts/                           # Review prompt templates
│   ├── memory-review.md               # Memory-only review prompt
│   ├── skill-review.md                # Skill-only review prompt (100+ lines)
│   ├── combined-review.md             # Merged memory + skill review
│   ├── curator-review.md              # Curator consolidation prompt (150+ lines)
│   └── authoring-standards.md         # Skill creation rules
│
├── config/                            # Default configuration
│   ├── self-learning.yaml             # Full config with defaults
│   ├── settings-hooks.json            # Hook registrations to merge into ~/.claude/settings.json
│   └── claude-md-snippet.md           # Self-learning protocol to append to CLAUDE.md
│
├── schema/                            # Data schemas
│   ├── usage-telemetry.json           # .usage.json JSON Schema
│   ├── curator-state.json             # .curator_state JSON Schema
│   ├── turn-counter.json              # Turn counter state schema
│   └── review-log.json               # Review action log schema
│
├── tests/                             # Test suite
│   ├── test-turn-counter.sh
│   ├── test-review-cycle.sh
│   ├── test-memory-bounds.sh
│   ├── test-skill-lifecycle.sh
│   ├── test-session-search.sh
│   ├── test-threat-scanner.sh
│   └── test-end-to-end.sh
│
├── docs/                              # Documentation
│   ├── architecture.md                # System architecture overview
│   ├── configuration.md               # Full config reference
│   ├── troubleshooting.md             # Common issues + fixes
│   └── research/                      # Hermes research (MOVED from MyApp)
│       ├── README.md
│       ├── 01-architecture-and-structure.md
│       ├── 01-validation-notes.md
│       ├── 02-self-learning-mechanisms.md
│       ├── 02-validation-notes.md
│       ├── 03-corrections.md
│       ├── 03-training-and-finetuning.md
│       ├── 03-validation-notes.md
│       ├── 04-prompts-and-reflection.md
│       ├── 05-skill-lifecycle-and-curator.md
│       ├── 05-validation-notes.md
│       ├── 06-missing-areas-research.md
│       ├── 07-implementation-guide-for-claude-code.md
│       ├── validation-03-training.md
│       └── validation-04-prompts.md
│
└── CLAUDE.md                          # Dev instructions for working on this repo
```

## Execution Steps

### Step 1: Create project directory and structure
```bash
mkdir -p ~/claude-self-learning/{scripts,prompts,config,schema,tests,docs/research}
```

### Step 2: Move research docs from MyApp
```bash
mv ~/MyApp/docs/research/hermes-agent/* ~/claude-self-learning/docs/research/
rmdir ~/MyApp/docs/research/hermes-agent
```

### Step 3: Create core project files
- `README.md` — project overview with architecture diagram, quick start, roadmap status
- `LICENSE` — MIT
- `CLAUDE.md` — dev instructions for working on this repo
- `install.sh` — copies scripts/prompts/config to `~/.claude/`, registers hooks, creates directories
- `uninstall.sh` — reverses install

### Step 4: Create Phase 1 skeleton scripts
From the implementation guide roadmap:
- `scripts/turn-counter.sh` — PostToolUse hook
- `scripts/session-review.sh` — Stop hook skeleton
- `config/self-learning.yaml` — default config
- `config/settings-hooks.json` — hook registration template
- `config/claude-md-snippet.md` — self-learning protocol

### Step 5: Initialize git + create GitHub repo
```bash
cd ~/claude-self-learning
git init
git add .
git commit -m "feat: initial project structure with research docs and Phase 1 skeleton"
gh repo create claude-self-learning --private --source=. --push
```

### Step 6: Clean up MyApp
- Remove empty `docs/research/hermes-agent/` directory
- Add memory file noting the project moved

## What This Plan Does NOT Do

- Does not implement the full self-learning system (that's the 10-week roadmap)
- Creates project skeleton + moves research + sets up Phase 1 foundations only
- Full implementation follows the 5-phase roadmap in `07-implementation-guide-for-claude-code.md`

## Verification

1. `ls ~/claude-self-learning/docs/research/` shows all 15 research files
2. `ls ~/MyApp/docs/research/hermes-agent/` -> directory removed
3. `gh repo view claude-self-learning` -> repo exists on GitHub
4. Research docs accessible at new location with intact content
