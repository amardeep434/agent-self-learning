# Claude Self-Learning — Dev Instructions

> **⚠️ WORK IN PROGRESS ON THIS BRANCH — read this first.**
> Branch `harness-neutral-persistence` is mid-execution of a 10-task plan, 6 tasks complete.
> **Before doing anything else, read:**
> `docs/superpowers/HANDOFF-2026-07-25-harness-neutral-persistence.md`
> It is written for a reader with zero context and contains the resume point (Task 7,
> `BASE = a934cb3`), the loop protocol, prompt templates, rulings already made, and two
> Important findings carried forward. Then reconcile it against `git log` and the ledger at
> `.superpowers/sdd/2026-07-25-harness-neutral-persistence/progress.md` — the handoff records
> state as of writing; git is the source of truth for what is actually there now.
> Note: this repo is `amardeep434/agent-self-learning` on GitHub; the local folder name still
> says `claude-self-learning`. Do not rename the folder — it would break the worktree link.

## Project Overview

This project implements a Hermes-Agent-inspired self-learning system that serves Claude Code, GitHub Copilot CLI, and (planned) VS Code Copilot Chat as peers. The system adds background review, skill lifecycle, bounded memory, periodic curation, and cross-session search. **Claude Code is one adapter among peers, not a dependency: no shared code path (storage resolution, the review pipeline, the skill/memory schema) may assume Claude Code's binary, config, or `~/.claude` layout.** `tests/test-claude-absent.sh` is the regression guard for this — the Copilot review path must work with no `claude` binary and no `~/.claude` directory present.

## Repository Layout

- `scripts/` — Deployable hook, review, curator, install/uninstall, and doctor scripts (bash + Python). `install.sh` copies these into the vendor-neutral store resolved by `scripts/lib/paths.py` (its `scripts` key) — not `~/.claude/scripts/self-learning`. See "Storage locations" and "Diagnostics" in `README.md`.
- `prompts/` — Review prompt templates (memory, skill, combined, curator)
- `config/` — Default configuration files, including hook-registration templates (`config/copilot-hooks.json` carries a `__SL_SCRIPTS_DIR__` placeholder substituted by `install.sh` at install time)
- `schema/` — Data schemas (SQLite DDL, JSON Schema)
- `tests/` — Test suite: `tests/run-all.sh` discovers and runs 18 suites (13 shell, 5 Python)
- `docs/research/` — Hermes Agent research corpus (15 validated documents + 10K-line implementation guide)

## Key Files

- `docs/research/07-implementation-guide-for-claude-code.md` — THE primary reference. 10,000-line guide with exact implementation details for all 5 subsystems.
- `config/self-learning.yaml` — All configuration parameters with defaults
- `prompts/skill-review.md` — The 100+ line skill review prompt (most important prompt)

## Development Guidelines

- Scripts must be POSIX-compatible bash (`#!/usr/bin/env bash`)
- Python scripts target Python 3.8+ (no external dependencies for core scripts)
- All hooks must complete in <100ms (turn-counter target: <50ms)
- Test with `tests/test-*.sh` scripts before committing (or `bash tests/run-all.sh` for the full suite)
- `install.sh` deploys into the vendor-neutral store resolved by `scripts/lib/paths.py` (default `~/.local/share/agent-learning`, overridable via `AGENT_LEARNING_HOME`/`XDG_DATA_HOME`) — never test it against a real `$HOME`; use `env -i HOME=<tmp> AGENT_LEARNING_HOME=<tmp>/store` and `--dry-run`
- `uninstall.sh` and `scripts/curator-run.sh` are similarly destructive to real state (curator archives and deletes skills) — sandbox them the same way

## Implementation Roadmap

This project originally followed a 5-phase, 10-week roadmap defined in the implementation guide. That roadmap is complete; the table below reflects the merged state of the tree, not the original plan (verified against `git log` — 63 commits on this branch, none yet merged to `main` — and by reading the current scripts, not by trusting either the guide or a previous version of this table):

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Foundation (turn counting, hooks) | Done |
| 2 | Background Review (prompts, memory/skill writes) | Done — reviewer proposes JSON on stdout, `scripts/persist-proposal.py` validates and performs every write, confined to the resolved store |
| 3 | Skill Lifecycle (telemetry, transitions) | Done |
| 4 | Curator + Session Search | Done |
| 5 | Integration + Polish | Done for Claude Code + Copilot CLI, including Windows support (Git Bash/WSL, PowerShell wrappers) and a `doctor.sh` diagnostic. VS Code Copilot Chat adapter/hooks not started (tracked separately). No CI run has ever executed on this branch — the 3-OS × 2-Python matrix in `.github/workflows/ci.yml` is unverified — and the live Copilot CLI end-to-end check (a real session persisting a real file under the resolved memory directory) is still pending manual verification. |

A subsequent, still-in-progress plan (`harness-neutral-persistence`) replaced the original Claude-Code-only storage defaults with the vendor-neutral store described in `README.md` under "Storage locations" — the fix for a defect where Copilot CLI's path allow-list silently discarded review output written to `~/.claude`.
