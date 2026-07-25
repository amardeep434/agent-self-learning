# Claude Self-Learning — Dev Instructions

> **Branch status: `harness-neutral-persistence`.**
> The original 10-task implementation plan is complete, and six post-implementation fix
> rounds (A-F) have since landed addressing findings from a whole-branch final review and
> from the CI matrix it triggered.
> History for that plan and those rounds:
> `docs/superpowers/HANDOFF-2026-07-25-harness-neutral-persistence.md` (the original task-by-task
> handoff, now historical) and `.superpowers/sdd/2026-07-25-harness-neutral-persistence/` (the
> ledger and each round's fix report). `git log` is the source of truth for what is actually on
> the branch now — read that before trusting either document's narrative.
> **CI: all six matrix cells are green** (`ubuntu/macos/windows-latest` × Python `3.9`/`3.13`),
> most recently CI run `30167923350`, 37 suites each at that time (41 now: 29 shell, 12 Python — the four added since that run are unobserved on the matrix; the count grows as
> suites are added — verify against `bash tests/run-all.sh`'s own "Discovered N suite(s)" line
> rather than trusting a number written here). The branch was red on this matrix repeatedly
> through the afternoon of 2026-07-25 (a flaky zero-tolerance timestamp assertion in
> `tests/test-config.sh`, fixed in a subsequent round); read `gh run list --branch
> harness-neutral-persistence` for the true recent history rather than assuming the last green
> run was the only run. Note that Windows green is not equal coverage: 7
> write-path security tests (symlink/hardlink/`O_NOFOLLOW`) and 3 shell assertions skip there,
> each printed with its reason and gated on a probe that verifies the limitation rather than
> assuming it from the platform name.
> **Live Copilot CLI check: DONE (2026-07-25), with one residual.** Run against whatever
> `copilot` was installed that day (1.0.73 at that moment; it auto-updates, and 1.0.75 has
> since been observed installed -- this project targets "current, authenticated `copilot`
> on PATH," never a pinned version, so read any specific number here as a point-in-time
> observation from that run, not a requirement) with a real (paid) model call, real `$HOME`
> for auth, and `AGENT_LEARNING_HOME` pointed at a throwaway store. Two parts:
> (1) `scripts/copilot-session-review.sh` invoked for real end-to-end — the detached pipeline
> completed and `persist-proposal.py` accepted a valid, well-formed **empty** proposal
> (`{"written": [], "skipped": [], "bytes": 0}`). Correct: headless `copilot -p` has no session
> transcript, so there was genuinely nothing to learn.
> (2) The same OUTPUT CONTRACT with a synthetic transcript, piped into the real writer —
> the model emitted a conforming fenced JSON proposal and **real content was persisted** to
> `<store>/memory/MEMORY.md`, append mode preserving the existing entry, mode 0600, nothing
> written outside the store. This is the exact loop that previously burned a model call and
> persisted nothing.
> **Residual:** no genuine *interactive* Copilot session has yet fired the `sessionEnd` hook
> with real conversation history in the payload. Parts (1) and (2) together cover hook script +
> real model + writer, and contract + real model + real content; what remains unexercised is
> Copilot's own session transcript reaching the prompt. That needs ordinary day-to-day use.
> Note: this repo is `amardeep434/agent-self-learning` on GitHub; the local folder name still
> says `claude-self-learning`. Do not rename the folder — it would break the worktree link.

## Project Overview

This project implements a Hermes-Agent-inspired self-learning system that serves Claude Code, GitHub Copilot CLI, and (planned) VS Code Copilot Chat as peers. The system adds background review, skill lifecycle, bounded memory, periodic curation, and cross-session search. **Claude Code is one adapter among peers, not a dependency: no shared code path (storage resolution, the review pipeline, the skill/memory schema) may assume Claude Code's binary, config, or `~/.claude` layout.** `tests/test-claude-absent.sh` is the regression guard for this — the Copilot review path must work with no `claude` binary and no `~/.claude` directory present.

## Repository Layout

- `scripts/` — Deployable hook, review, curator, install/uninstall, and doctor scripts (bash + Python). `install.sh` copies these into the vendor-neutral store resolved by `scripts/lib/paths.py` (its `scripts` key) — not `~/.claude/scripts/self-learning`. See "Storage locations" and "Diagnostics" in `README.md`.
- `prompts/` — Review prompt templates (memory, skill, combined, curator)
- `config/` — Default configuration files, including hook-registration templates (`config/copilot-hooks.json` carries a `__SL_SCRIPTS_DIR__` placeholder substituted by `install.sh` at install time)
- `schema/` — Data schemas (SQLite DDL, JSON Schema)
- `tests/` — Test suite: `tests/run-all.sh` discovers `tests/test-*.sh`/`tests/test-*.py` by glob (never hardcode a count here — it drifts on every suite added or removed; run `bash tests/run-all.sh` for the current total)
- `docs/research/` — Hermes Agent research corpus (15 validated documents + 10K-line implementation guide)

## Key Files

- `docs/research/07-implementation-guide-for-claude-code.md` — THE primary reference. 10,000-line guide with exact implementation details for all 5 subsystems.
- `config/self-learning.yaml` — All configuration parameters with defaults
- `prompts/skill-review.md` — The 100+ line skill review prompt (most important prompt)

## Development Guidelines

- Scripts must be POSIX-compatible bash (`#!/usr/bin/env bash`)
- Python scripts target Python 3.8+ (no external dependencies for core scripts)
- All hooks must complete in <100ms. turn-counter.sh's own target used to be documented as <50ms; measured (fix round C, this machine, `date +%s%N` around 5-6 real runs) at 50-68ms with a native python3 on PATH, consistently over 130-155ms with a pyenv/asdf shim in front of it (the shim itself, not this project's code, costs ~85ms — confirmed by timing the shim vs. the real interpreter binary directly). ~22-25ms of the real-python3 figure is `config.sh`'s one `python3 lib/paths.py all` subprocess spawn per hook invocation. <50ms is not honestly achievable without caching that resolution across hook invocations (e.g. in a state file), which was considered and rejected for this round: caching a store-location resolution risks exactly the silent-wrong-location class this project exists to eliminate if the cache goes stale relative to `AGENT_LEARNING_HOME`/`XDG_DATA_HOME`. Target amended to <100ms (matching the general hook budget above) rather than keep a number the code was already known to miss.
- Test with `tests/test-*.sh` scripts before committing (or `bash tests/run-all.sh` for the full suite)
- `install.sh` deploys into the vendor-neutral store resolved by `scripts/lib/paths.py` (default `~/.local/share/agent-learning`, overridable via `AGENT_LEARNING_HOME`/`XDG_DATA_HOME`) — never test it against a real `$HOME`; use `env -i HOME=<tmp> AGENT_LEARNING_HOME=<tmp>/store` and `--dry-run`
- `uninstall.sh` and `scripts/curator-run.sh` are similarly destructive to real state (curator archives and deletes skills) — sandbox them the same way

## Implementation Roadmap

This project originally followed a 5-phase, 10-week roadmap defined in the implementation guide. That roadmap is complete; the table below reflects the merged state of the tree, not the original plan (verified against `git log` — none of this branch's commits are yet merged to `main`; run `git rev-list --count <merge-base>..HEAD` for the current commit count rather than trusting a number written here, since it drifts on every commit — and by reading the current scripts, not by trusting either the guide or a previous version of this table):

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Foundation (turn counting, hooks) | Done |
| 2 | Background Review (prompts, memory/skill writes) | Done — reviewer proposes JSON on stdout, `scripts/persist-proposal.py` validates and performs every write, confined to the resolved store |
| 3 | Skill Lifecycle (telemetry, transitions) | Done |
| 4 | Curator + Session Search | Done |
| 5 | Integration + Polish | Done for Claude Code + Copilot CLI, including a `doctor.sh` diagnostic; VS Code Copilot Chat adapter/hooks not started (tracked separately). Windows support (Git Bash, PowerShell wrappers) is now CI-verified: all six matrix cells green at CI run `30167923350` (the 37 suites that existed then; 41 now, the four newest unobserved on the matrix), after fix rounds A-F plus later same-day rounds fixed real defects the matrix exposed — a Python 3.9 `fromisoformat` failure on `Z` timestamps, GNU-only `date` use on macOS, CRLF-corrupted `paths.py` stdout plus MSYS path-form mismatches on Windows, and (most recently) a zero-tolerance timestamp round-trip assertion in `tests/test-config.sh` that was flaky under real wall-clock ticks. Windows green is not equal coverage: 7 write-path security tests and 3 shell assertions skip there (symlinks need elevation; `chmod` does not deny writes under ACLs), each announced with its reason. The live Copilot CLI end-to-end check with a real model call is still pending manual verification. |

A subsequent, still-in-progress plan (`harness-neutral-persistence`) replaced the original Claude-Code-only storage defaults with the vendor-neutral store described in `README.md` under "Storage locations" — the fix for a defect where Copilot CLI's path allow-list silently discarded review output written to `~/.claude`.
