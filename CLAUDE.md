# agent-self-learning — dev instructions

> **`git log` is the source of truth for what is on the tree.** Read it before trusting
> any document's narrative, including this one. Where a figure below can rot, the command
> that re-derives it is next to it; a number with no command next to it should be
> distrusted and re-measured.

**Repo:** `amardeep434/agent-self-learning` on GitHub. The local folder is still named
`claude-self-learning` — **do not rename it**, it would break the worktree link.

## Project overview

A Hermes-Agent-inspired self-learning system serving **Claude Code, GitHub Copilot CLI and
VS Code Copilot Chat as peers**: background review, skill lifecycle, bounded memory,
periodic curation, cross-session search.

**Claude Code is one adapter among peers, not a dependency.** No shared code path — storage
resolution, the review pipeline, the skill/memory schema — may assume Claude Code's binary,
config, or `~/.claude` layout. `tests/test-claude-absent.sh` is the regression guard: the
Copilot review path must work with no `claude` binary and no `~/.claude` directory present.

## Hard rules

### 1. Sandbox anything that touches the store

`install.sh`, `uninstall.sh`, `scripts/curator-run.sh` (archives and deletes skills), **and
every review/hook script** resolve paths through `lib/paths.py`. Running one from a
checkout with no `AGENT_LEARNING_HOME` writes to the developer's **real** store.

```bash
env -i HOME=<tmp> PATH="$PATH" AGENT_LEARNING_HOME=<tmp>/store SL_CONFIG_FILE=/nonexistent \
    bash scripts/<script>.sh
```

Measured twice: on 2026-07-28 ad-hoc invocations of `session-review.sh` /
`copilot-session-review.sh` / `vscode-session-review.sh` / `turn-counter.sh` left six lines
in the live `persist-failures.log` — payloads with no `sessionId`/`transcript_path`, i.e.
test calls, not sessions — and `doctor.sh` correctly reported UNHEALTHY on them.
`tests/test-review-cli-flags.sh` was **rewritten on 2026-07-31** (fcd8f08, c868c9e, then
78ba7e7) so it no longer starts a session: it probes the real binaries through
`copilot help limits` and `claude … mcp list`, each wrapped in an explicit session-count
guard that fails the suite if the probe created one, and mutation **M6** pins that a
reintroduced `-p ""` probe fails both guards. Re-derive rather than trust this sentence:

```bash
grep -n 'help limits\|mcp list\|sessions 0 -> 0' tests/test-review-cli-flags.sh
git log --oneline -5 -- tests/test-review-cli-flags.sh
```

**HISTORY, kept because the lesson outlives the fix.** Before that rewrite,
`bash tests/run-all.sh` was NOT clean of live-store writes — and an earlier version of this
paragraph claimed it was, which was wrong. The suite invoked the **real installed `copilot`**
(`copilot --max-ai-credits 30 -p ""`), which starts a genuine session, creates
`~/.copilot/session-state/<uuid>` and fires your installed `sessionEnd` hook. MEASURED
2026-07-29, that one suite alone: **+697 bytes to the live `logs/persist.log`, +1 Copilot
session directory** — so it may also have consumed Copilot credits. No memory or skill
content was written; the damage was log noise and a session dir, not corrupted state.

That false "verified clean" claim came from a broken check: `find <store> -newermt … || echo
none`. `find` exits 0 with empty output, so the `||` never fires, and silence was read as
absence. That is this project's signature defect inside its own verification — when
measuring "did anything change", compare a **byte count or checksum before and after**,
never the emptiness of a command's output.

If a live-store line does get written, **archive it before clearing**: `doctor.sh`
distinguishes an ABSENT log ("never ran, or ran and never failed") from an EMPTY one ("ran
and recorded zero failures"), so deleting the file asserts something different from
truncating it.

> ⚠️ **A sandboxed `HOME` is not automatically hermetic** — MEASURED 2026-07-29,
> **PRE-rewrite; needs re-measurement against the current suite.**
> `tests/test-review-cli-flags.sh` invokes the *real* `claude` and `copilot` binaries, which
> materialise `$HOME/.claude` and `$HOME/.copilot` in whatever `HOME` is set — including an
> **empty** Copilot `session-store.db`. `tests/test-telemetry.py` then failed later in the
> same run with `copilot session-store.db store exists but parsed to zero records`. The
> subcommand probes still invoke the real binaries, so the failure mode is plausibly intact,
> but nobody has reproduced it since the rewrite. Until someone does, run the suite either
> against a real populated `$HOME`, or with a `PATH` that has neither binary on it (which is
> what CI does).

### 2. Fail loudly, never silently

A degraded outcome gets a named reason in `persist-failures.log` that `doctor.sh`
surfaces. The review pipeline is detached (`nohup … &`), so a failure **can never surface
as a non-zero hook exit code** — the log is the only replacement signal. A silently empty
result is this project's signature failure mode and is treated as a defect, not a
degradation.

### 3. Probe, never infer from a platform name

FTS5 support, lock backends, symlink creation, `chmod` enforcement, pty availability — all
decided by running the thing and looking. Every CI skip is gated on a probe that *verifies*
the limitation and prints its own reason.

## Development guidelines

- Bash scripts: POSIX-compatible, `#!/usr/bin/env bash`.
- Python: **stdlib only**, target **3.9+** — that is the CI floor
  (`python-version: ["3.9", "3.13"]` in `.github/workflows/ci.yml`) and the lowest version
  anything here is actually run against. **3.8 is untested; do not claim it.** Write
  `from __future__ import annotations` in any module using `X | None` annotations.
- **Hook budget: <100ms.** `turn-counter.sh` was once documented at <50ms. Measured (fix
  round C, `date +%s%N` over 5-6 real runs): **50-68ms** with a native `python3` on PATH,
  **130-155ms** with a pyenv/asdf shim in front of it — the shim itself costs ~85ms,
  confirmed by timing it against the real interpreter binary. ~22-25ms of the native figure
  is `config.sh`'s one `python3 lib/paths.py all` subprocess spawn per invocation. <50ms is
  not achievable without caching that resolution across invocations, which was **considered
  and rejected**: a stale cache relative to `AGENT_LEARNING_HOME`/`XDG_DATA_HOME` recreates
  exactly the silent-wrong-location class this project exists to eliminate. The target was
  amended rather than left as a number the code was known to miss.
- Run `bash tests/run-all.sh` before committing. Never hardcode a suite count anywhere —
  it drifts on every suite added or removed and has gone stale repeatedly.

## Repository layout

- `scripts/` — deployable hook, review, curator, install/uninstall and doctor scripts
  (bash + Python). `install.sh` copies these into the vendor-neutral store resolved by
  `scripts/lib/paths.py` (its `scripts` key) — **not** `~/.claude/scripts/self-learning`.
- `prompts/` — curator review prompt and authoring standards (`curator-review.md`,
  `authoring-standards.md`); the per-review prompts were inlined into the review scripts
  (26aaf68).
- `config/` — defaults plus the three hook-registration templates, each carrying a
  `__SL_SCRIPTS_DIR__` placeholder substituted by `install.sh` at install time:
  `settings-hooks.json` (Claude Code), `copilot-hooks.json` (Copilot CLI — note its
  different per-command shape: `bash`/`powershell`/`timeoutSec`), and `vscode-hooks.json`
  (VS Code — Claude Code's nested schema, which VS Code parses, with `timeout` in SECONDS).
  `install.sh` renders the VS Code one into the store and prints the
  `chat.hookFilesLocations` entry; it never edits VS Code's settings.json.
  `self-learning.conf` is the file that actually ships and is sourced at runtime;
  `self-learning.yaml` is the annotated reference for all parameters.
- `schema/` — SQLite DDL, split so the FTS5 half is applied only when `probe_fts5()` passes.
- `tests/` — `tests/run-all.sh` discovers `tests/test-*.sh` / `tests/test-*.py` by glob.
- `vendor/coach-rules/` — vendored MIT Coach rules and SHA-256-pinned tables.
- `docs/research/` — Hermes Agent research corpus (15 documents + the 10K-line
  implementation guide, `07-implementation-guide-for-claude-code.md`, the primary reference).

## Current state

The original 5-phase roadmap is **complete for all three harnesses**, and the
`harness-neutral-persistence` branch is **merged to `main`** (verify:
`git merge-base --is-ancestor origin/harness-neutral-persistence origin/main`). Do not
branch off it. Its ledger, round reports, and `plan-vs-delivered-audit.md` live under
`.superpowers/sdd/2026-07-25-harness-neutral-persistence/`;
`docs/superpowers/HANDOFF-2026-07-27-harness-neutral-persistence.md` is the closing
handoff and supersedes the 2026-07-25 one.

`docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md` is the agreed plan and
carries in-place `SUPERSEDED` callouts on the eight passages the tree contradicts.
**Read those callouts before implementing anything from it** — Task 4's flat `<name>.md`
skill layout in particular would reintroduce a Critical.

### CI

Matrix: `{ubuntu, macos, windows}-latest × Python {3.9, 3.13}`, six cells.
**No run id is pinned here, deliberately** — every previous version of this paragraph
pinned one and went stale within hours.

```bash
gh run list --branch main        # read the history, not just the newest entry
```

**Windows green is not equal coverage.** The per-suite skip breakdown, the real probed
causes, and the commands to re-derive every figure live in
[`docs/platform-coverage.md`](docs/platform-coverage.md). Do not restate the numbers here;
they moved on 2026-07-29 (4 shell skips across 3 suites → 5 across 4) and again on
2026-07-31 (→ 9 across 6, re-derived from run 30588076535), and will move again.

Fix rounds A-F and P0-P9 fixed real defects the matrix exposed: a Python 3.9
`fromisoformat` failure on `Z` timestamps, GNU-only `date` use on macOS, CRLF-corrupted
`paths.py` stdout plus MSYS path-form mismatches on Windows, a flaky zero-tolerance
timestamp round-trip in `tests/test-config.sh`, a lost-update race in concurrent appends
(now a cross-process store lock), and a PowerShell syntax checker that had itself been the
parse error.

### VS Code Copilot Chat — read before touching any review script

The adapter shipped 2026-07-28 (`scripts/vscode-session-review.sh`,
`config/vscode-hooks.json`, `scripts/lib/review-common.sh`, `tests/test-vscode-*.sh`) after
the spike in `docs/superpowers/vscode-adapter-spike.md` passed on Linux / VS Code 1.130.0 /
`GitHub.copilot-chat` 0.58.0. Read §4 of that file.

**VS Code's default `chat.hookFilesLocations` includes `~/.claude/settings.json`.** So
registering the Claude Code hooks also registers them inside VS Code — that is VS Code core
behaviour, not the Claude extension — and it means Claude Code and VS Code Copilot Chat
**cannot be told apart by which config invoked the hook**. `session-review.sh` therefore
runs `transcript.py --harness auto`, which sniffs the transcript's own `type` values
(330/330 Claude files bare-word, 21/21 VS Code files dotted, 351/351 classified correctly).

Reverting that to `--harness claude` reopens a measured defect: an empty digest, a
`persist-failures.log` line, **and a paid contentless review**, once per VS Code turn —
VS Code's `Stop` is per turn, not per session.

The adapter is **Linux-only measured**: no real VS Code hook has ever invoked our scripts,
and Windows/macOS/VS-Code-Server are entirely untested.

### Copilot CLI live end-to-end — DONE, with a narrow residual

Verified with real paid model calls on 2026-07-25 and 2026-07-26. The second run produced a
real session directory via `copilot -s --allow-tool read -p …`, fired the real installed
`sessionEnd` hook, and persisted 279 bytes of genuinely session-derived content to
`<store>/memory/MEMORY.md` — append mode preserving the prior entry, mode 0600,
`persist-failures.log` empty, nothing written under `~/.claude`, the user's hook file
restored byte-identical. So Copilot's own session transcript reaching the prompt **is**
exercised.

**Residual:** no *human, multi-turn, TUI* Copilot session has fired the hook. Run 2 was
still a one-shot `-p`, merely one that `-s` gave a real transcript. That needs ordinary
day-to-day use, not engineering.

This project targets "current, authenticated `copilot` on PATH", never a pinned version;
treat any specific version number in the history as a point-in-time observation.

### Coach rule coverage

44 of the 45 vendored rules evaluate; `no-devcontainer` is the only skip and is genuinely
unreachable upstream. The partition (11 from our own index + 33 from harness telemetry + 1
unsupported) is pinned by `tests/test-coach-rules-eval.py`. Full detail, and the history of
why that number was wrong three times, in [`docs/coach-integration.md`](docs/coach-integration.md).
