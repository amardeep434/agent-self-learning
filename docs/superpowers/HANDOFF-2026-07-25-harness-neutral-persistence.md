# HANDOFF — Harness-Neutral Persistence (SDD execution loop)

**Written:** 2026-07-25 · **Reason:** context window heavy, work resumes from here.
**Read this file top to bottom before touching anything.** It is written for a reader with zero prior context.

---

## 1. What this work is

`agent-self-learning` (GitHub: `amardeep434/agent-self-learning`, renamed from `claude-self-learning`) is a cross-harness framework that learns from AI coding sessions — accumulating memory and reusable skills across sessions — for **Claude Code, GitHub Copilot CLI, and VS Code Copilot Chat as peers**.

**The defect this plan fixes:** on Copilot CLI the background reviewer agent was told to write `MEMORY.md` / `learned-skills/` itself, into `~/.claude/...`. Copilot's **path allow-list refuses writes to that foreign namespace**, so the loop ran, burned a model call, and persisted **nothing** — exit 0, log file present, no error. Evidence: `~/.claude/logs/reviews/20260723-125206-copilot-session-review.log`. The framework's own verification gate marked this PASS because it only checked "hook fired, reviewer completed."

**The fix:** invert the contract. The reviewer **proposes** a JSON object on stdout and writes no files; a deterministic Python writer **validates and performs every write**, confined to a vendor-neutral store. This removes the path-allow-list dependency, collapses two divergent write paths into one, makes writes unit-testable without a live agent, and removes agent-filesystem trust from the design.

---

## 2. Where everything is

| Thing | Path |
|---|---|
| Repo (main checkout, branch `main`) | `/home/amardeep/claude-self-learning` |
| **Worktree — all work happens here** | `/home/amardeep/claude-self-learning/.claude/worktrees/hnp` |
| Branch | `harness-neutral-persistence` |
| Branch point | `befd131` (merge of PR #1 into main) |
| Plan | `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md` |
| SDD workspace (git-ignored) | `.superpowers/sdd/2026-07-25-harness-neutral-persistence/` |
| **Ledger (recovery map)** | `<workspace>/progress.md` |
| Briefs / reports / review diffs | `<workspace>/task-N-brief.md`, `task-N-report.md`, `review-<a>..<b>.diff` |
| SDD helper scripts | `/home/amardeep/.claude/plugins/cache/claude-plugins-official/superpowers/6.2.0/skills/subagent-driven-development/scripts/` (`task-brief`, `review-package`, `sdd-workspace`) |

**The ledger is authoritative over anyone's recollection.** A task with a `Task N: complete` line is DONE — never re-dispatch it. Trust the ledger and `git log` over memory.

⚠️ The workspace is git-ignored scratch. `git clean -fdx` destroys it; recover from `git log` and this file.

---

## 3. Status: 5 of 10 tasks complete

Branch HEAD at handoff: **`1085b6a`**. Commits (oldest first):

```
646e967 docs(plan): harness-neutral persistence implementation plan
b3f758a docs(plan): background review pipeline, positional prompt, persist failures in doctor
3e6b418 feat(paths): platform-aware vendor-neutral path resolver              [Task 1]
8dcbdeb feat(config): resolve paths via paths.py, add SL_REVIEW_ENABLED       [Task 2]
320b60f fix(config): resolve SL_CONFIG_FILE default via paths.py              [Task 2 fix 1]
384a319 fix(config): literal fallbacks when python3 unavailable               [Task 2 fix 2]
81b7545 feat(security): strict proposal schema                                [Task 3]
0fa15f5 fix(security): 8 critical/important bypasses in proposal schema       [Task 3 fix 1]
0a0ae8f fix(security): eliminate quadratic backtracking (ReDoS)               [Task 3 fix 2]
9ed5405 feat(security): script-owned writer with store confinement            [Task 4]
3157475 fix(security): close 4 Important + 2 Minor gaps in writer             [Task 4 fix 1]
050a106 fix(review): reviewer proposes on stdout, script persists (Claude)    [Task 5]
1085b6a fix(review): restore --max-turns/--output-format                      [Task 5 fix 1]
```

| # | Task | State |
|---|---|---|
| 1 | Path resolver (`scripts/lib/paths.py`) | ✅ complete |
| 2 | `config.sh` delegates to resolver + env cleanup | ✅ complete (2 fix rounds) |
| 3 | Proposal schema (`scripts/lib/proposal_schema.py`) | ✅ complete (2 fix rounds) |
| 4 | Secure writer (`scripts/persist-proposal.py`) | ✅ complete (1 fix round) |
| 5 | Invert Claude Code reviewer (`scripts/session-review.sh`) | ✅ complete (1 fix round) |
| 6 | Invert Copilot reviewer (`scripts/copilot-session-review.sh`) | 🔄 **IN FLIGHT** — see §4 |
| 7 | Claude-absent regression guard (`tests/test-claude-absent.sh`) | ⬜ not started |
| 8 | Test runner + 3-OS CI (`tests/run-all.sh`, `.github/workflows/ci.yml`) | ⬜ not started |
| 9 | `doctor` (`scripts/doctor.sh`) | ⬜ not started |
| 10 | Docs (`README.md`, `CLAUDE.md`) | ⬜ not started |

Current test counts: 8 shell suites + 5 Python suites (90 Python cases), all green at `1085b6a`.

---

## 4. Task 6 is in flight — resolve this first

An implementer subagent was dispatched for Task 6 (invert the Copilot reviewer) and had **not reported** when this handoff was written. Its brief exists at `<workspace>/task-6-brief.md`; no `task-6-report.md` existed at handoff time.

**On resume:**
1. `cd` to the worktree and run `git log --oneline 1085b6a..HEAD`.
2. **If there are new commits** — the implementer finished. Read `<workspace>/task-6-report.md`, then go straight to the review step (§5, step 3) with `BASE=1085b6a`.
3. **If there are no new commits** — the agent was lost with the session. Re-dispatch Task 6 from scratch using the brief plus the requirements in §6 below.

---

## 5. The loop protocol (repeat per task, 7 → 10)

Follow `superpowers:subagent-driven-development`. Per task:

1. **Record BASE**: `git rev-parse HEAD` — needed for the review package. Never use `HEAD~1`; multi-commit tasks would be truncated.
2. **Generate the brief**: `bash <sdd-scripts>/task-brief <plan> N` → prints a path. Dispatch an implementer subagent with: one line of project context, the brief path ("read this first — it is your requirements, use its exact values verbatim"), interfaces from earlier tasks the brief cannot know, your resolution of any ambiguity, and the report-file path. **Never paste prior-task history into a dispatch.** Never run two implementers in parallel.
3. **Review**: `bash <sdd-scripts>/review-package <plan> BASE HEAD` → prints a diff path. Dispatch a reviewer with the brief path, report path, diff path, and the Global Constraints. Require **both** verdicts: spec compliance AND task quality. Do not pre-judge findings; do not tell a reviewer what not to flag.
4. **Fix loop** (max 5 rounds/task): rounds 1–3 resume the original implementer via `SendMessage` with findings verbatim; rounds 4–5 dispatch a fresh implementer on a stronger model. Every round ends with a **scoped re-review** over `review-package <plan> FIX_BASE HEAD`. Minor findings never enter the loop — they go to the ledger as deferred.
5. **Ledger**: append `Task N: complete (commits <base7>..<head7>, review clean)` plus any deferred minors and rulings. Then next task.

**Model selection used so far** (worked well): cheapest tier when the plan carries complete code (Tasks 1, 3); mid tier for integration and shell work (Tasks 2, 5, 6); **strongest tier for reviewing the two security tasks** (3, 4) — that is where it paid for itself; cheap tier for small mechanical re-reviews.

---

## 6. Requirements for the remaining tasks

Beyond each brief, these were learned during execution and must be carried in:

**Task 6 (Copilot reviewer)** — `--allow-tool write` must be **gone** (`--allow-tool read` stays); entire pipeline backgrounded with `nohup … &`; `set -o pipefail` inside it; failures appended to `${SL_LOG_DIR}/persist-failures.log`; args passed **positionally** into `bash -c` (note `COPILOT_ARGS` expands last, shifting positions); `SL_COPILOT_REVIEW_MODEL` regex validation preserved exactly (it guards `--model` against argument injection); **verify via `copilot --help` whether Copilot CLI has a turn cap** — wire `SL_REVIEW_MAX_TURNS` to it if so, and state explicitly in the report if it has none rather than silently omitting cost control; test must **poll** with a bounded timeout, not sleep; **no `~/.claude`, no `claude` binary, no `CLAUDE.md` anywhere in this file**.

**Task 7 (Claude-absent guard)** — the executable form of "the Copilot path never depends on Claude Code." Must pass with no `claude` on PATH and no `~/.claude` directory, and must assert no `~/.claude` is created. If it fails, fix the coupling — never weaken the test.

**Task 8 (runner + CI)** — the repo has **no CI and no test runner today**. Matrix: `ubuntu-latest, macos-latest, windows-latest` × Python `3.9, 3.13`, with `shell: bash` (Windows then uses Git Bash, which is what the Windows hook path actually delegates to). This CI is what finally verifies the Python-3.9 and Windows claims that every task so far could only assert by inspection.

**Task 9 (`doctor`)** — must print resolved paths, writability, detected harnesses, legacy `~/.claude` store detection (**detect only — never move user data**), and **surface `${SL_LOG_DIR}/persist-failures.log`**. That last item is load-bearing: the review pipeline is detached, so its failures cannot reach a hook exit code, and this log is the only visibility mechanism replacing it. Without it the silent-failure bug returns in a new shape.

**Task 10 (docs)** — storage-location resolution order, migration note, `CLAUDE_REVIEW_ENABLED` deprecation, and a corrected roadmap (`CLAUDE.md` still claims Phase 1 "Skeleton" / Phases 2–5 "Planned" against 34 merged commits). No compatibility-table row may claim a harness is supported unless `tests/run-all.sh` covers it.

---

## 7. ⚠️ The plan file is defective in places — the repository is authoritative

Adversarial review found **real vulnerabilities in code the plan specified verbatim**. Do not "restore" plan code over repository code.

- **Task 3 code block** specified a skill-name regex using `$`, which in Python also matches before a trailing newline — `"evil\n"` validated and would have become the filename `evil\n.md`. Also an uncaught `RecursionError`, and a fence regex with quadratic backtracking (**26.1s on 872KB**, fixed to 0.00078s via linear `str.find` scanning). The plan's tests were weak: mutation testing killed **1 of 7** mutants.
- **Task 4 code block**'s confinement check compared `target.parent.resolve()` with `root.resolve()` — which passes trivially when `root` **itself** is a symlink pointing outside the store. Mutating the fix out yields a full write-outside-store at exit 0.
- **Task 5's Step-1 test was vacuous** — the script exits early on a missing `turn_counter.json`, so the test never reached the spawn path and would have gone "red" for the wrong reason.
- **Task 5's spawn snippet dropped `--max-turns`**, orphaning `SL_REVIEW_MAX_TURNS` and leaving a background model loop uncapped.

**Lesson for the remaining tasks:** treat plan code as a starting point. Implementers are explicitly authorised to strengthen a check beyond the brief — never to weaken one — and must report any deviation with reasoning.

---

## 8. Rulings already made (do not re-litigate)

- `config/settings-hooks.json` containing `~/.claude` paths in its **hooks** block is **correct** — that file is Claude Code's own adapter config. The no-Claude constraint binds the **Copilot and VS Code** paths.
- A **symlinked store root** is allowed by design: the root comes from the environment, not from proposal content, and symlinked data directories are legitimate. Store-**internal** directories (`memory/`, `learned-skills/`) must not be symlinks — a link planted there is unambiguously anomalous.
- **Cross-device rename is impossible** — `mkstemp` stages inside the destination directory, so `os.replace` is always intra-directory. No `EXDEV` risk.
- `_MAX_FENCE_CANDIDATES = 10` is **fail-closed**: it can only cause a valid proposal to be rejected, never a malicious one to be accepted.
- Writer files land at **0600 by deliberate policy** (removes any pre-rename disclosure window), accepting that a user's chosen mode is not preserved.

---

## 9. Deferred minors — triage at the final review

1. `paths.resolve_home` returns a CWD-relative path when `HOME` is unset and no other branch matches; should fail loudly.
2. Windows separator handling is only truly verified once the `windows-latest` CI job exists (Task 8).
3. `tests/test-paths.py` line 1 multi-import style nit (inherited from plan text).
4. **PRE-EXISTING**: only `SL_HOME` and `SL_CONFIG_FILE` are in `_sl_env_snapshot`, so a config file silently overrides a pre-set env var for `SL_STATE_DIR`, `SL_SKILLS_DIR`, `SL_MEMORY_DIR`, `SL_LOG_DIR`, `SL_SEARCH_DB` — "env beats file" is broken for those five (`config.sh:7-11`).
5. `_MAX_FENCE_CANDIDATES = 10` deserves an explanatory code comment.
6. The UTF-8 decode guard in `_read_existing` has no dedicated test; behaviour is still correct via the broader `except ValueError` in `main()`.

---

## 10. Finishing

After Task 10: dispatch the **whole-branch final review** on the strongest available model using `review-package <plan> $(git merge-base main HEAD) HEAD`, pointing it at the deferred-minor list above so it can triage what must be fixed before merge. If it returns findings, dispatch **ONE** fix subagent with the complete list (not one fixer per finding), then exactly one scoped re-review. Then `superpowers:finishing-a-development-branch`.

**Verification gate before opening the PR** (from the plan):
- `bash tests/run-all.sh` passes locally
- `bash tests/test-claude-absent.sh` passes
- all six CI matrix jobs green
- `bash scripts/doctor.sh` on a machine with an existing `~/.claude` store reports the legacy path and moves nothing
- `grep -rn 'claude' scripts/copilot-session-review.sh scripts/persist-proposal.py scripts/lib/paths.py` finds no binary invocation and no `~/.claude` default
- **manual live check on Copilot CLI**: run a real session and confirm a file with real content appears under the resolved memory directory. This is the specific failure the plan exists to fix and no automated test substitutes for it.

Delete the workspace only after the final review is clean and merged.

---

## 11. Wider context (out of scope for this plan)

This plan is the first shippable unit of a larger framework. **Not** in scope here, planned separately: session-source adapters (Copilot `session-store.db`, Claude JSONL) · VS Code hook spike and adapter · Copilot `postToolUse` turn counting · measurement (usage reader over `assistant_usage_events`, continuous holdout, CI-labelled reporting) · failure-triggered review · install UX, install manifest, manifest-driven uninstall · deep security audit · and all `graphify-offline` work (XML, BeanShell, offline structured PDF extraction) in the separate repo `amardeep434/graphify-offline` (branch `v8`).
