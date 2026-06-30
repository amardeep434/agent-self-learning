# Claude Self-Learning — Dev Instructions

## Project Overview

This project implements a Hermes-Agent-inspired self-learning system for Claude Code. The system adds background review, skill lifecycle, bounded memory, periodic curation, and cross-session search.

## Repository Layout

- `scripts/` — Deployable hook scripts (bash + Python). install.sh copies these to `~/.claude/scripts/self-learning/`
- `prompts/` — Review prompt templates (memory, skill, combined, curator)
- `config/` — Default configuration files
- `schema/` — Data schemas (SQLite DDL, JSON Schema)
- `tests/` — Test suite (bash-based)
- `docs/research/` — Hermes Agent research corpus (15 validated documents + 10K-line implementation guide)

## Key Files

- `docs/research/07-implementation-guide-for-claude-code.md` — THE primary reference. 10,000-line guide with exact implementation details for all 5 subsystems.
- `config/self-learning.yaml` — All configuration parameters with defaults
- `prompts/skill-review.md` — The 100+ line skill review prompt (most important prompt)

## Development Guidelines

- Scripts must be POSIX-compatible bash (`#!/usr/bin/env bash`)
- Python scripts target Python 3.8+ (no external dependencies for core scripts)
- All hooks must complete in <100ms (turn-counter target: <50ms)
- Test with `tests/test-*.sh` scripts before committing
- The install.sh deploys to `~/.claude/` — test installation on a clean setup

## Implementation Roadmap

This project follows a 5-phase, 10-week roadmap defined in the implementation guide:

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Foundation (turn counting, hooks) | Skeleton |
| 2 | Background Review (prompts, memory/skill writes) | Planned |
| 3 | Skill Lifecycle (telemetry, transitions) | Planned |
| 4 | Curator + Session Search | Planned |
| 5 | Integration + Polish | Planned |
