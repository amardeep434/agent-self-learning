# HANDOFF — Harness-Neutral Persistence (SDD execution loop)

> **⚠ SUPERSEDED — historical only. Do not resume from this file.**
> Read [`HANDOFF-2026-07-27-harness-neutral-persistence.md`](./HANDOFF-2026-07-27-harness-neutral-persistence.md) instead.
> Everything below describes the state on 2026-07-25, when 6 of 10 tasks were done and
> the instruction was "resume at Task 7". All 10 tasks have since landed, plus fix rounds
> A–F, P0–P9 and a closeout round; PR #2 merged to `main` as `1c93605`. Following this
> file's "resume here" pointer would redo finished work. Kept for the reasoning and the
> defect history, not for its state.

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

## 3. Status: 6 of 10 tasks COMPLETE — flow deliberately halted here

Last code commit **`a934cb3`** (Task 6, reviewed clean). Branch is pushed to `origin/harness-neutral-persistence`.
**The flow was stopped intentionally after Task 6's review — Task 7 was never dispatched.** Resume at Task 7. Commits (oldest first):

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
88476ca docs: resumable handoff
a934cb3 fix(review): Copilot reviewer proposes on stdout; drop --allow-tool write  [Task 6]
f0fdebc docs(handoff): operating detail appendix
```

| # | Task | State |
|---|---|---|
| 1 | Path resolver (`scripts/lib/paths.py`) | ✅ complete |
| 2 | `config.sh` delegates to resolver + env cleanup | ✅ complete (2 fix rounds) |
| 3 | Proposal schema (`scripts/lib/proposal_schema.py`) | ✅ complete (2 fix rounds) |
| 4 | Secure writer (`scripts/persist-proposal.py`) | ✅ complete (1 fix round) |
| 5 | Invert Claude Code reviewer (`scripts/session-review.sh`) | ✅ complete (1 fix round) |
| 6 | Invert Copilot reviewer (`scripts/copilot-session-review.sh`) | ✅ complete `a934cb3` — review clean, zero findings |
| 7 | Claude-absent regression guard (`tests/test-claude-absent.sh`) | ⬜ not started |
| 8 | Test runner + 3-OS CI (`tests/run-all.sh`, `.github/workflows/ci.yml`) | ⬜ not started |
| 9 | `doctor` (`scripts/doctor.sh`) | ⬜ not started |
| 10 | Docs (`README.md`, `CLAUDE.md`) | ⬜ not started |

Current test counts: 8 shell suites + 5 Python suites (90 Python cases), all green at `1085b6a`.

---

## 4. Resume point: Task 7

Task 6 is **complete and reviewed clean** (Spec ✅, Approved, zero findings; mutation confirmed 7 of 12 checks fail when the spawn is neutered; full suite 14/14). No fix round was needed and none is pending.

**Start here on resume: Task 7** (Claude-absent regression guard). Follow §5 with `BASE = a934cb3`. Nothing is half-finished; there is no in-flight agent.

### Two Important findings carried forward — read before Task 7

**(a) The Copilot reviewer has no cost ceiling.** Verified via `copilot help limits`: `--max-ai-credits` **does** apply to non-interactive `-p` runs, while `--max-autopilot-continues` is interactive-only. The implementer correctly refused to fabricate a turns→credits conversion, but zero bound is the wrong resting point for a framework whose premise is cost efficiency (background agent turns measured at 84% of spend). Follow-up: add a distinct knob `SL_COPILOT_MAX_AI_CREDITS` wired to `--max-ai-credits`, defaulting to the CLI minimum of 30. **Do not reuse `SL_REVIEW_MAX_TURNS`** — the units do not correspond.

**(b) NEW — the plan does not cover install paths, and Task 7's guard will not catch it.** `config/copilot-hooks.json` (and the copy installed at `~/.copilot/hooks/self-learning.json`) invokes:
```
bash ~/.claude/scripts/self-learning/copilot-session-review.sh
```
This plan removed `~/.claude` from the **store** and from **script contents**, but the Copilot adapter's **script install location is still Claude-namespaced**. A Copilot-only install therefore still creates and depends on `~/.claude`, which contradicts the plan's own global constraint. Task 7's guard invokes the script directly from the repo, so it will go **green while the real installed configuration still violates the constraint** — a false pass.

Follow-up task needed: relocate installed scripts to a harness-neutral location (e.g. under the resolved store or an XDG bin path) and update `config/copilot-hooks.json`, `install.sh`, and `install.ps1` together. Consider extending Task 7 to assert on the *shipped hook config* as well as the script, so the guard cannot pass vacuously.

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

---

# APPENDIX — operating detail for identical resumption

Sections 1–11 give state. These give the *how*, so a resumed loop behaves the same rather than merely reaching the same files.

## 12. Baseline suite inventory (regression detector)

Measured at `1085b6a`. Any deviation on resume means something regressed before you touched it.

```
tests/test-config.sh                  PASS      tests/test-coach-rules-eval.py    4 cases PASS
tests/test-copilot-hooks-json.sh      PASS      tests/test-coach-signals.py       7 cases PASS
tests/test-copilot-session-review.sh  PASS      tests/test-paths.py              10 cases PASS
tests/test-hook-input.sh              PASS      tests/test-persist-proposal.py   16 cases PASS
tests/test-inject-agents-md.sh        PASS      tests/test-proposal-schema.py    53 cases PASS
tests/test-session-review.sh          PASS (9 checks)
tests/test-skillopt-run.sh            PASS
tests/test-turn-counter.sh            PASS
tests/test-uninstall.sh               PASS
```
9 shell suites, 5 Python suites, 90 Python cases. No runner exists yet — Task 8 adds `tests/run-all.sh`.

## 13. Model selection actually used

| Task | Implementer | Reviewer | Rationale |
|---|---|---|---|
| 1 paths | cheapest | mid | plan carried complete code = transcription |
| 2 config | mid | mid | surgical edits to existing file, precedence semantics |
| 3 schema | cheapest | **strongest** | complete code to transcribe, but security boundary to review |
| 4 writer | mid | **strongest** | filesystem security, implementer needed judgement to deviate |
| 5 Claude reviewer | mid | mid → cheapest for the small re-review | shell integration |
| 6 Copilot reviewer | mid | mid (suggested) | shell integration, mirrors Task 5 |
| 7 guard, 8 CI, 9 doctor, 10 docs | mid or cheapest | mid | lower risk; do not spend strongest here |
| **final whole-branch review** | — | **strongest** | required by the skill |

Always name the model explicitly in a dispatch; omitting it inherits the session model and silently defeats this.

## 14. Dispatch templates (reproduce this structure)

**Implementer** — sections in this order:
1. One line: what the framework is and where this task fits.
2. `WORKING DIRECTORY: <worktree>` + branch + "work only there, do NOT switch branches".
3. `READ THIS FIRST — it is your requirements, with the exact values to use verbatim: <brief path>`
4. "Follow the brief's TDD step order: write the failing test, run it and confirm it fails, implement, run and confirm it passes, commit."
5. *Why this task exists* — the real-world failure it addresses. This measurably improved judgement.
6. **For Tasks 3+ include verbatim:** "THE PLAN'S CODE IS A STARTING POINT, NOT GOSPEL. An adversarial review found eight real security bypasses in code from this same plan. Assume this task's plan code may have similar holes. You are explicitly authorised to strengthen a check beyond what the brief specifies — never to weaken one. If you deviate, say so clearly with your reasoning."
7. Threat model, where relevant.
8. `GLOBAL CONSTRAINTS` copied verbatim from the plan.
9. `INTERFACES FROM EARLIER TASKS (committed; use, do not modify)` — exact signatures and guarantees. **Never paste prior-task narrative history.**
10. `CONTEXT THE BRIEF CANNOT KNOW` — stale facts corrected, line-number drift warnings, which files already exist.
11. Report-file path + contents contract.
12. `RETURN TO ME (short): status (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED), commit SHA, one-line test summary, concerns.`
13. "If anything in the brief is ambiguous or appears wrong, ask me before implementing rather than guessing."

**Reviewer** — sections in this order:
1. "Produce two verdicts: spec compliance and task quality. Review the code, not the implementer's claims."
2. Three paths: brief, report, review package.
3. `GLOBAL CONSTRAINTS binding this task` verbatim.
4. Threat model for security tasks.
5. `VERIFY SPECIFICALLY` — a numbered list of concrete hypotheses, each demanding evidence. **State attacks as executable commands and say "EXECUTE — do not reason".** This is what caught the ReDoS and the newline bypass.
6. **Mutation testing instruction**: "comment out each protection one at a time, run the suite, confirm at least one test fails, restore. Report killed/survived. Confirm `git status --porcelain` is empty when you finish."
7. Output format: `Spec compliance: ✅/❌`, `Task quality: Approved/Changes requested` with Critical/Important/Minor + file:line + concrete fix, `⚠️ Cannot verify from diff`.
8. "Concluding the code is correct is a fine outcome — do not invent problems. But prefer flagging a plausible bypass over silence." (security tasks only)
9. "Return findings directly; do not write files."

**Never** tell a reviewer what not to flag. If a prompt contains "do not flag", "at most Minor", or "the plan chose" — that is pre-judging; delete it and adjudicate the finding afterwards instead.

**Fix round** (via `SendMessage` to the original implementer, rounds 1–3): open findings verbatim with severity labels, **exact replacement code** for each, the required regression tests, an explicit "verify before reporting" step, and any finding you adjudicated in their favour (say so — it prevents wasted work).

**Scoped re-review**: findings list, brief, report, and `review-package <plan> FIX_BASE HEAD` where FIX_BASE is the head the previous review saw. Instruct: verdict each finding ADDRESSED/NOT ADDRESSED, flag new breakage **in the fix diff only**, out-of-scope observations become deferred notes, never new loop rounds.

## 15. Controller decision heuristics applied

- **DONE_WITH_CONCERNS**: read concerns first. Correctness/scope concerns → dispatch a fix *before* review. Observations → note and proceed to review.
- **⚠️ Cannot verify from diff**: the controller resolves these, not the reviewer. Most were "does a later task cover this?" — resolved against Tasks 8 and 9. If genuinely uncovered, it becomes a failed spec review and enters the fix loop.
- **Severity may be upgraded with reasoning.** The dropped `--max-turns` was labelled Minor by the reviewer; upgraded to Important and fixed, because an uncapped background model loop contradicts the project's cost-efficiency premise. Record the reasoning in the ledger.
- **Severity may be accepted as Minor and deferred.** The surviving UTF-8-decode mutant was left deferred: behaviour is correct via a redundant broader catch, so another full fix+re-review cycle was disproportionate.
- **Fix the plan when pre-flight finds a defect**, before dispatching. Three were fixed pre-flight (synchronous pipeline vs 15s hook timeout, prompt interpolation into `bash -c`, missing failure-log visibility) and committed as `b3f758a`.
- **Never fix findings in the controller session** — it pollutes context and skips review.
- **Never dispatch implementers in parallel.**

## 16. Verbatim Task 6 dispatch (in flight — reuse if re-dispatch is needed)

Sent to a mid-tier implementer. Reproduce faithfully, adding: "READ THIS FIRST … `<workspace>/task-6-brief.md`", the report path `<workspace>/task-6-report.md`, and the standard short-contract return clause.

Distinctive content beyond the standard template:
- *"WHY THIS TASK IS THE POINT OF THE WHOLE PLAN"* — the Copilot allow-list refusal, loop burning a model call and persisting nothing, evidence in the repo's verification log.
- *"CARRY-OVER LESSON FROM TASK 5 — do not repeat this mistake"*: Task 5's plan snippet silently dropped the reviewer's turn cap. **Run `copilot --help`** (installed at `/home/amardeep/.local/bin/copilot`, v1.0.73) and verify what Copilot actually supports — do not assume Claude Code's flags exist. Wire `SL_REVIEW_MAX_TURNS` if there is an equivalent; **state explicitly in the report if there is none** rather than silently omitting cost control. `SL_COPILOT_REVIEW_MODEL` regex validation must be preserved exactly — it guards `--model` against argument injection.
- Six critical design points: `--allow-tool write` **gone** (`read` stays); whole pipeline backgrounded `nohup … &`; `set -o pipefail` inside it; failures appended to `${SL_LOG_DIR}/persist-failures.log`; args **positional** into `bash -c` (**note `COPILOT_ARGS` expands last, shifting positions**); test must **poll** with a bounded timeout.
- Constraint: **no `~/.claude`, no `claude` binary, no `CLAUDE.md` anywhere in this file** — Task 7 enforces it.
- Interfaces block for `config.sh`, `persist-proposal.py`, `proposal_schema.py`, plus: *"read `scripts/session-review.sh` (Task 5) as the reference implementation for spawn shape, OUTPUT CONTRACT prompt text, and the argv-recording test technique. Keep the two scripts structurally parallel."*
- Context: the argv-recording fake-binary shim is the reliable way to assert on a spawned command line (proven in Task 5). `tests/test-copilot-session-review.sh` already exists and passes — **append, do not rewrite**.

## 17. Project-level decisions from the wider session (shape future plans)

- **Two repos, never merged.** `agent-self-learning` is the spine (harness adapters, hooks, install, instruction-file injection, session index). `graphify-offline` is an optional tool. Merging would kill the upstream-contribution path and force a permanent fork burden. Integration surface is exactly three contracts: instruction files (spine is sole owner, marker-delimited), one telemetry sink, and feature detection (spine injects graph commands only if `graphify` is on PATH).
- **`llmwiki` is retired** — superseded except as the reference spec for PDF extraction algorithms, to be *reimplemented* on `pdfplumber` (MIT) because llmwiki's implementation uses `pymupdf` (AGPL, incompatible with graphify's Apache-2.0/MIT). Its artifacts were removed from `/home/amardeep/RioIAM`.
- **VS Code Copilot Chat is must-ship**, accepting that its hooks are Preview. Mitigate with `doctor` self-checks and pinned tested harness versions.
- **MCP is optional, not excluded** — blocked in the org but under review. Keep graphify's `--mcp` intact and adapters shaped so an MCP adapter can slot in. Feature-detect, never depend. Zero build now.
- **Measurement**: Copilot's local `~/.copilot/session-store.db` table `assistant_usage_events` gives **per-turn, per-model, per-`initiator`** cost (`input_tokens`, `output_tokens`, `cache_read_tokens`, `total_nano_aiu`, `request_multiplier`) — far better than the Billing API's per-user daily totals, and `initiator` separates framework overhead from user-driven spend. Pair with a **continuous ~10% holdout** rather than a staged A/B (accumulated memory contaminates a simple off-switch). Report savings with 95% CI and a `measured`/`estimated` label.
- **Cost reality measured on this machine**: agent + sub-agent turns were 84% of spend. Background loops, not human prompting, are the cost centre — which is why the reviewer's turn cap and cheap-model selection matter.
- **Cache**: measured 95–96% `cache_read/input` ratio with the framework live. No bust today because writes happen post-session. Preserve as an invariant: injected blocks append at end, never reorder, and **no volatile content (counts, timestamps) in always-loaded files**.
- **Store path decision**: `$AGENT_LEARNING_HOME` → `$XDG_DATA_HOME/agent-learning` → Windows `%LOCALAPPDATA%\agent-learning` → `~/.local/share/agent-learning`. Override-first exists to make testing and debugging trivial.
- **Env vars**: `SL_*` is already vendor-neutral and stays. Only `CLAUDE_REVIEW_ENABLED` was live; it is honoured as deprecated for one release.

## 18. Sibling repo `graphify-offline` — state and pending action

Created and pushed: `amardeep434/graphify-offline`, **private**, default branch **`v8`** (upstream's active branch, not `main`), 1,241 commits. Local clone `/home/amardeep/graphify-fork-new`, HEAD `2fa6cd3`, remotes: `origin` → the fork, `upstream` → `Graphify-Labs/graphify`.

**⚠️ PENDING AND UNDONE — do this before any other graphify work:** the fork inherited `.github/workflows/publish.yml` from upstream, which would attempt a **PyPI publish of `graphifyy`**. Disable it on the fork. Also pending in that same hygiene step: fork attribution in the README, and the branch convention `lang/xml`, `lang/beanshell`, `feat/offline-docs` (upstream's convention is **one language per PR**, which keeps XML and BeanShell separately upstreamable).

Spike results already established, do not re-run: `tree-sitter-xml` 0.7.0 resolves inside graphify's `tree-sitter<0.26` pin and exposes `CDSect`/`CData`; `tree-sitter-java` 0.23.5 parses BeanShell with **zero ERROR nodes** (no custom grammar needed); bare `.xml` is currently in neither `CODE_EXTENSIONS` nor `DOC_EXTENSIONS`, so `classify_file` returns `None` and the file is **silently ignored entirely**. Reuse graphify's existing `_project_xml_is_safe` / `_PROJECT_XML_MAX_BYTES` (XXE + entity-expansion + 2MiB cap). PDF stack decided: `pdfplumber` required; `rapidocr-onnxruntime`, `camelot-py`, `pikepdf` optional extras; **`pymupdf` banned (AGPL)**.
