# Claude Self-Learning — Dev Instructions

> **Branch status: `harness-neutral-persistence`.**
> The original 10-task implementation plan is complete. Since then the branch has taken
> **fix rounds A-F, rounds P0-P9, and a final closeout round** — collectively ~1,700 lines of
> new production code and ~5,000 of tests that were never part of the agreed plan.
> History: `.superpowers/sdd/2026-07-25-harness-neutral-persistence/` holds the ledger
> (`progress.md`), each round's report, `plan-vs-delivered-audit.md` (plan-vs-tree, item by
> item), and `fix-final-closeout-report.md`.
> `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md` is the agreed plan; it now
> carries in-place `SUPERSEDED` callouts on the eight passages the tree contradicts, plus an
> Appendix A summarising the post-plan rounds. **Read those callouts before implementing
> anything from it** — Task 4's flat `<name>.md` skill layout in particular would reintroduce a
> Critical. `docs/superpowers/HANDOFF-2026-07-25-harness-neutral-persistence.md` is the original
> task-by-task handoff, now historical.
> `git log` is the source of truth for what is actually on the branch — read it before trusting
> any document's narrative, including this one.
>
> **CI.** The matrix is `{ubuntu, macos, windows}-latest × Python {3.9, 3.13}`, six cells.
> **No run id is recorded here, deliberately** — every previous version of this paragraph
> pinned one and went stale within hours. Run `gh run list --branch main` and
> `gh run view <id>`; the last run observed while writing this was green on all six cells
> with the full suite. The branch was red on this matrix repeatedly on 2026-07-25, so read the
> run *history*, not just the newest entry, before concluding anything.
> **Windows green is not equal coverage, and the numbers here are re-derived, not remembered.**
> Count them with `gh run view --job <windows job id> --log`, then `SKIP:` lines and
> `OK (skipped=N)` per `=== tests/… ===` banner — never by eye. Run `30284745998`,
> windows-latest 3.13 against ubuntu-latest 3.13: **4 shell skips** (3 suites) and **21 Python
> skips** (5 suites), of which **11 are Windows-only** — `test-persist-proposal.py` 5,
> `test-adversarial-sweep.py` 3, `test-store-lock-writers.py` 3. `test-win-dir-pin.py` is the
> inverse suite (6 skip on Windows, 9 on Linux). **There is no single cause, and the old
> "symlinks need elevation" line was half wrong.** Per suite, each from its own probe:
> `test-persist-proposal.py` 5 — `O_NOFOLLOW: UNAVAILABLE` and `dir_fd (functional):
> UNAVAILABLE` (that suite also prints `symlink creation: AVAILABLE` and `hardlink creation:
> AVAILABLE`, so Python builds the attack fixtures fine); `test-adversarial-sweep.py` 3 —
> `chmod read-only probed and not enforced` ×2 plus "POSIX permission bits are not meaningful
> on Windows/NTFS ACLs"; `test-doctor.sh` 1 — the same ACL behaviour, verified by writing a
> probe file; `test-copilot-hook-input.sh` 1 — `pty allocation: UNAVAILABLE (No module named
> 'termios')`; `test-path-compare-lib.sh` 2 — these *are* symlink failures, `ln -s` could not
> create one (verified with `[[ -L … ]]`). The shell half cannot make symlinks while the Python
> half can; do not collapse the two. Three gaps to state rather than let green imply otherwise:
> `test-store-lock-writers.py`'s 3 skip because **`bash` is not runnable from Python on that
> runner** (probed) — so the bash-driven concurrent-writer scenarios are unexercised there,
> though the lock backend itself runs (`store_lock backend=msvcrt`); **4 live
> telemetry/transcript tests skip on every cell on every platform**, since no runner has a
> Copilot or Claude store; and conversely Windows covers what POSIX cannot —
> `win32 directory pinning: AVAILABLE (verified: a pinned directory could not be renamed, and
> our own staged replace inside it still succeeded)`.
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
> **A second run on 2026-07-26 closed most of that residual.** `copilot -s --allow-tool
> read -p …` produced a **real** session dir (`events.jsonl`: `user.message=1`,
> `assistant.message=2`); the real installed `sessionEnd` hook fired; the detached pipeline
> persisted **279 bytes of genuinely session-derived content** to `<store>/memory/MEMORY.md`
> — the two decisions typed into that session — preserving the pre-existing entry, mode
> 0600, `persist-failures.log` empty, nothing under `~/.claude`, real neutral store never
> created, user's hook file restored byte-identical. So **Copilot's own session transcript
> reaching the prompt is exercised**; the synthetic transcript of part (2) is no longer the
> only evidence. (Recorded 2026-07-27 after the run was found in the session record — it had
> no doc commit of its own, so this block claimed the gap for a day longer than it existed.)
> **Residual, now narrower:** no *human, multi-turn, TUI* Copilot session has fired the hook.
> Run 2 was still a one-shot `-p`, merely one that `-s` gave a real transcript. Needs
> ordinary day-to-day use.
> Note: this repo is `amardeep434/agent-self-learning` on GitHub; the local folder name still
> says `claude-self-learning`. Do not rename the folder — it would break the worktree link.

## Project Overview

This project implements a Hermes-Agent-inspired self-learning system that serves Claude Code, GitHub Copilot CLI, and VS Code Copilot Chat as peers. The system adds background review, skill lifecycle, bounded memory, periodic curation, and cross-session search. **Claude Code is one adapter among peers, not a dependency: no shared code path (storage resolution, the review pipeline, the skill/memory schema) may assume Claude Code's binary, config, or `~/.claude` layout.** `tests/test-claude-absent.sh` is the regression guard for this — the Copilot review path must work with no `claude` binary and no `~/.claude` directory present.

## Repository Layout

- `scripts/` — Deployable hook, review, curator, install/uninstall, and doctor scripts (bash + Python). `install.sh` copies these into the vendor-neutral store resolved by `scripts/lib/paths.py` (its `scripts` key) — not `~/.claude/scripts/self-learning`. See "Storage locations" and "Diagnostics" in `README.md`.
- `prompts/` — Review prompt templates (memory, skill, combined, curator)
- `config/` — Default configuration files, including the three hook-registration templates, each carrying a `__SL_SCRIPTS_DIR__` placeholder substituted by `install.sh` at install time: `settings-hooks.json` (Claude Code), `copilot-hooks.json` (Copilot CLI — note its different per-command shape: `bash`/`powershell`/`timeoutSec`), and `vscode-hooks.json` (VS Code Copilot Chat — Claude Code's nested schema, which VS Code parses, with `timeout` in SECONDS). `install.sh` renders the VS Code one into the store and prints the `chat.hookFilesLocations` entry; it never edits VS Code's settings.json.
- `schema/` — Data schemas (SQLite DDL, JSON Schema)
- `tests/` — Test suite: `tests/run-all.sh` discovers `tests/test-*.sh`/`tests/test-*.py` by glob (never hardcode a count here — it drifts on every suite added or removed; run `bash tests/run-all.sh` for the current total)
- `docs/research/` — Hermes Agent research corpus (15 validated documents + 10K-line implementation guide)

## Key Files

- `docs/research/07-implementation-guide-for-claude-code.md` — THE primary reference. 10,000-line guide with exact implementation details for all 5 subsystems.
- `config/self-learning.yaml` — All configuration parameters with defaults
- `prompts/skill-review.md` — The 100+ line skill review prompt (most important prompt)

## Development Guidelines

- Scripts must be POSIX-compatible bash (`#!/usr/bin/env bash`)
- Python scripts are **stdlib only** and target **Python 3.9+** — that is the CI floor (`python-version: ["3.9", "3.13"]` in `.github/workflows/ci.yml`) and the lowest version anything here is actually run against. 3.8 is untested; do not claim it. Write `from __future__ import annotations` in any module using `X | None` annotations.
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
| 5 | Integration + Polish | Done for Claude Code + Copilot CLI, including a `doctor.sh` diagnostic; **the VS Code Copilot Chat adapter shipped 2026-07-28** (`scripts/vscode-session-review.sh`, `config/vscode-hooks.json`, `scripts/lib/review-common.sh`, `tests/test-vscode-*.sh`) after the spike in `docs/superpowers/vscode-adapter-spike.md` passed on Linux / VS Code 1.130.0 / `GitHub.copilot-chat` 0.58.0. Read §4 of that file before touching any review script: **VS Code's default `chat.hookFilesLocations` includes `~/.claude/settings.json`**, so registering the Claude Code hooks also registers them inside VS Code — that is VS Code core behaviour, not the Claude extension, and it means Claude Code and VS Code Copilot Chat **cannot be told apart by which config invoked the hook**. `session-review.sh` therefore runs `transcript.py --harness auto`, which sniffs the transcript's own `type` values (330/330 Claude files bare-word, 21/21 VS Code files dotted, 351/351 classified correctly). Reverting that to `--harness claude` reopens a measured defect: an empty digest, a `persist-failures.log` line, AND a paid contentless review, once per VS Code turn (VS Code's `Stop` is per turn, not per session). It is **Linux-only measured** — no real VS Code hook has ever invoked our scripts, and Windows/macOS/VS-Code-Server are entirely untested. Windows support (Git Bash, PowerShell wrappers) is CI-verified across the six-cell matrix — for current status run `gh run list --branch main` rather than trusting a run id written here. Fix rounds A-F and P0-P9 fixed real defects the matrix exposed: a Python 3.9 `fromisoformat` failure on `Z` timestamps, GNU-only `date` use on macOS, CRLF-corrupted `paths.py` stdout plus MSYS path-form mismatches on Windows, a flaky zero-tolerance timestamp round-trip in `tests/test-config.sh`, a lost-update race in concurrent appends (now a cross-process store lock), and a PowerShell syntax checker that had itself been the parse error. Windows green is not equal coverage: 4 shell and 21 Python assertions skip there (11 of them Windows-only), each announced with its reason — see the CI paragraph at the top of this file for the measured breakdown and the real causes, which are missing POSIX primitives rather than the elevation this row used to claim. **The live Copilot CLI end-to-end check is DONE** (2026-07-25, real paid model call — see the branch-status block at the top of this file for exactly what it did and did not cover); an earlier version of this row said it was still pending, contradicting that block. |

The `harness-neutral-persistence` plan, now complete, replaced the original Claude-Code-only storage defaults with the vendor-neutral store described in `README.md` under "Storage locations" — the fix for a defect where Copilot CLI's path allow-list silently discarded review output written to `~/.claude`.
