# Task 10 Report: Documentation

## What changed

### `README.md`

- Rewrote the intro paragraph: was "A self-learning system for Claude Code..."; now states this
  is a cross-harness system serving Claude Code, Copilot CLI, and (planned) VS Code Copilot Chat
  as peers, with the no-shared-code-path-depends-on-Claude rule stated explicitly.
- Added a **"Storage locations"** section: the four-level resolution order exactly as read from
  `scripts/lib/paths.py`, every key `resolve_all()` exposes (`home`, `state`, `skills`, `memory`,
  `logs`, `sessions_db`, `config_file`, `scripts`), and the harness-owned-config-files exception
  (`~/.claude/settings.json`, `~/.copilot/hooks/self-learning.json` stay put; only script paths
  are neutral).
- Added **"Migrating from an existing `~/.claude` install"**: states nothing is moved
  automatically, points at `scripts/doctor.sh`'s legacy-store detection, gives a verified working
  `cp` command using `python3 scripts/lib/paths.py get home`.
- Added **"`CLAUDE_REVIEW_ENABLED` is deprecated"**: describes the actual one-release back-compat
  behavior read from `scripts/lib/config.sh` (used only if `SL_REVIEW_ENABLED` is unset, prints a
  stderr warning, `SL_REVIEW_ENABLED` defaults to `true`).
- Added **"Diagnostics: `scripts/doctor.sh`"**: what it reports (paths, writability, harness hook
  freshness, legacy store, persist-failures.log) and gives `${SL_LOG_DIR}/persist-failures.log`
  the prominence the brief asked for — explained *why* it's the only failure signal (detached
  `nohup` reviewer can't return a hook exit code).
- Rewrote the **"Agent compatibility"** table. Every row now either has test coverage cited
  (`test-persist-proposal.py`, `test-proposal-schema.py`, `test-inject-agents-md.sh`,
  `test-session-review.sh`, `test-copilot-session-review.sh`, `test-turn-counter.sh`,
  `test-claude-absent.sh`, `test-coach-signals.py`, `test-coach-rules-eval.py`) or is marked
  explicitly unverified: Windows ("reasoned-about, not observed"; CI matrix declared but never
  run) and the live Copilot CLI end-to-end check ("pending manual verification"). No row implies
  VS Code Copilot Chat support.
- Rewrote the **Roadmap** table: all 5 phases "Done" (was "Planned" throughout), Phase 5 caveated
  with what's not done (VS Code adapter, unrun CI, unverified live Copilot check).
- Updated the **Background Review** box in the architecture diagram: was "Subagent (Agent tool)
  ... writes MEMORY.md, USER.md" (a Claude-only description that is no longer how persistence
  works); now describes the stdout-JSON-proposal + `persist-proposal.py`-writes flow for both
  harnesses.
- Fixed **Configuration reference**: intro said "All settings live in `~/.claude/self-learning.conf`"
  (false; now vendor-neutral, defaults to `~/.local/share/agent-learning/self-learning.conf`).
  Added the missing `SL_REVIEW_ENABLED` row. `SL_HOME` default corrected from `~/.claude`.
- Fixed **Project Structure**: `scripts/` and `tests/` were still labeled "(future phases)";
  corrected to describe what's actually there and cite `tests/run-all.sh`'s 18 suites.
- Fixed the Coach integration section's stale `~/.claude/self-learning.conf` reference.

### `CLAUDE.md`

- Left the `⚠️ WORK IN PROGRESS ON THIS BRANCH` banner untouched, as instructed.
- Project Overview: added the peers/no-Claude-dependency statement and named
  `tests/test-claude-absent.sh` as the regression guard, per the brief's explicit ask.
- Repository Layout: corrected `scripts/` (was "install.sh copies these to
  `~/.claude/scripts/self-learning/`", now describes the resolved-store `scripts` key and the
  `__SL_SCRIPTS_DIR__` hook-template substitution); corrected `tests/` to cite the actual 18-suite
  count from `tests/run-all.sh` output.
- Development Guidelines: replaced "The install.sh deploys to `~/.claude/` — test installation on
  a clean setup" (false) with the actual sandboxing requirement (`env -i HOME=<tmp>
  AGENT_LEARNING_HOME=<tmp>/store`, `--dry-run`) and added a line calling out that `uninstall.sh`
  and `curator-run.sh` are equally destructive and must be sandboxed the same way.
- Corrected the **Implementation Roadmap** table: all 5 phases were "Skeleton"/"Planned"; now
  "Done" with per-phase detail, an explicit note that this reflects the merged tree (63 commits
  on this branch, none yet merged to `main` — verified via `git log --oneline main..HEAD` /
  `HEAD..main`), and a closing paragraph naming the harness-neutral-persistence plan and the
  Copilot-path-allowlist defect it fixes.

## Every factual claim verified, and how

- **Storage resolution order and path keys** — read `scripts/lib/paths.py` in full (not summarized
  from the brief). Confirmed `resolve_home()`'s 4-step chain and `_SUBPATHS` dict for all 8 keys
  including `home`.
- **`CLAUDE_REVIEW_ENABLED` deprecation behavior** — read `scripts/lib/config.sh` lines 77-85;
  confirmed it's read only when `SL_REVIEW_ENABLED` is unset, a stderr warning is printed, and the
  final default is `true`.
- **`doctor.sh` behavior** — read the full script; ran it sandboxed three times: (1) clean tmp
  HOME with `AGENT_LEARNING_HOME` set, confirming "resolved paths"/"writability"/"harnesses
  detected"/"legacy store: none found"/"persistence failures: ABSENT"/"overall: HEALTHY"; (2) same
  with a populated fake `~/.claude/memory` and `~/.claude/learned-skills`, confirming legacy-store
  detection reports the path and prints a non-destructive `cp` suggestion without moving anything;
  (3) confirmed exit code 0 on the healthy run.
- **Test suite composition** — ran `bash tests/run-all.sh`: "Discovered 18 suite(s): 13 shell, 5
  python. Ran 18. All 18 suites passed." Also `ls tests/` and read the harness-identifying content
  of each suite (`grep`/`head`) to build the compatibility-table citations, confirming which
  suites actually exercise Claude Code vs. Copilot CLI vs. neither (no VS Code suite exists).
- **CI matrix and unrun status** — read `.github/workflows/ci.yml` (confirms `ubuntu-latest,
  macos-latest, windows-latest` × Python `3.9, 3.13`). Confirmed no CI has ever run: `gh run list`
  (no runs on this branch), `gh workflow list` (only shows the pre-existing "Copilot" review
  workflow, not "CI" — because `ci.yml` does not exist on `origin/main`, per
  `git show origin/main:.github/workflows/ci.yml` failing with "not in 'origin/main'").
- **Reviewer proposes on stdout / `persist-proposal.py` writes, confined to the store** — read
  `scripts/copilot-session-review.sh` header comment and cross-checked against `git log` commit
  history (`a934cb3 fix(review): Copilot reviewer proposes on stdout`,
  `9ed5405 feat(security): script-owned writer with store confinement`).
- **`__SL_SCRIPTS_DIR__` template substitution** — read `install.sh` lines around the Copilot hook
  render step: `sed "s|__SL_SCRIPTS_DIR__|${SL_SCRIPTS}|g" "$COPILOT_HOOK_SRC" > "$COPILOT_HOOK_DST"`.
- **Scripts install location** — ran `bash install.sh --dry-run` sandboxed (`env -i HOME=<tmp>
  AGENT_LEARNING_HOME=<tmp>/store`), confirmed installed hook commands point at
  `<tmp>/store/scripts/*.sh`, not `~/.claude/scripts/self-learning`.
- **No `~/.claude` default / no `claude` binary invocation in the neutral-path-critical files** —
  ran the exact grep from the verification gate:
  `grep -rn 'claude' scripts/copilot-session-review.sh scripts/persist-proposal.py
  scripts/lib/paths.py` — only 3 hits, all comments/legacy-detection code in `paths.py`
  (`legacy_home()`), none a binary invocation or default path.
  Confirmed `bash tests/test-claude-absent.sh` passes as part of the full suite run.
- **63 commits on this branch, unmerged to `main`** — `git log --oneline | wc -l` = 63;
  `git log --oneline main..HEAD | wc -l` = 29 (note: brief said "34 merged commits" against
  `CLAUDE.md`'s stale table — actual count is higher and the branch is not merged at all, so I
  described it as "commits on this branch" rather than repeating the brief's "merged" framing).
- **`cp -r ... "$(python3 scripts/lib/paths.py get home)/"` command** — ran it in a sandboxed tmp
  HOME to confirm `paths.py get home` prints a usable path with no error.
- **VS Code has no test coverage** — `grep -iE "vscode|vs code"` across all 18 test files: zero
  hits outside `doctor.sh`'s own detection logic (not a test file). Confirmed via `ls tests/` that
  no `test-vscode*.sh` or similar exists.
- **`config/self-learning.yaml`, `docs/project-creation-plan.md`, and all `docs/research/*.md`
  links referenced in README "Documentation"/"Research" sections** — confirmed present with `ls`.

## Pre-existing claims found false and corrected (beyond the brief's explicit list)

1. README's opening sentence framed the whole project as "for Claude Code" — directly
   contradicts the peers architecture; the intro paragraph now states the peer relationship and
   the no-dependency rule.
2. README's Architecture diagram's "Background Review" box said a Claude Code "Subagent (Agent
   tool)" "writes MEMORY.md, USER.md" — this is exactly the old behavior the plan replaced;
   corrected to describe the stdout-JSON-proposal / `persist-proposal.py`-writer flow.
3. README's "Configuration reference" intro claimed "All settings live in
   `~/.claude/self-learning.conf`" — false since the paths.py resolver landed; fixed.
4. README's `SL_HOME` default was documented as `~/.claude` — false; fixed to reference the
   resolved store.
5. README's Coach integration section told users to edit `~/.claude/self-learning.conf` — same
   staleness; fixed.
6. README's Project Structure section still labeled `scripts/` and `tests/` "(future phases)" —
   both are fully implemented and tested; fixed.
7. CLAUDE.md's Repository Layout claimed `install.sh copies these to
   ~/.claude/scripts/self-learning/` — false; fixed.
8. CLAUDE.md's Development Guidelines said "install.sh deploys to `~/.claude/` — test installation
   on a clean setup" with no sandboxing warning — given this task's own instructions forbid
   running install.sh against a real `$HOME`, the old guidance was actively unsafe advice for a
   future contributor; replaced with the sandboxing requirement.

## Code defects found, not fixed (reported here per instructions)

- None found. Everything read (`paths.py`, `config.sh`, `doctor.sh`, `install.sh`, `ci.yml`,
  `copilot-session-review.sh`) matched its own documentation and passed its tests. No behavior
  changes were made in this task.

## Concerns

- The brief's "34 merged commits" figure doesn't match what I found (63 commits on the branch,
  29 ahead of `main`, zero merged to `main`). I did not treat this as a defect to report — it's
  simply a stale number in the brief's own context section — but flagging it here in case it
  signals a different `main`/merge-base was intended.
- `tests/run-all.sh` passing does not itself prove the *content* of what's persisted is correct
  (e.g., `test-persist-proposal.py` validates the writer's schema/confinement logic in isolation,
  not a full live reviewer round-trip). I've been careful in the compatibility table to only claim
  what the suites actually exercise (schema/unit-level validation, mocked harness binaries) and to
  keep the live Copilot CLI end-to-end check flagged as still-pending, per the brief.
- I did not touch `docs/superpowers/HANDOFF-2026-07-25-harness-neutral-persistence.md` or the
  progress ledger — out of scope per the brief (README.md and CLAUDE.md only), and the WIP banner
  explicitly says not to touch resume-pointer material.
