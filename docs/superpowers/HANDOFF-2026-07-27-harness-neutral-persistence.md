# HANDOFF — `harness-neutral-persistence`, closing state

**Written:** 2026-07-27 · **Audience:** a reader with zero prior context.
**Supersedes** `HANDOFF-2026-07-25-harness-neutral-persistence.md`, which is historical.
That file went stale within hours of being written because it pinned counts, a task
number, and a "resume here" pointer into prose. This one states, for every figure that
can rot, **the command that re-derives it**. Where you find a number below without a
command next to it, distrust it and go measure.

---

## 0. Next session: start here

Do these in order. Steps 1–2 are prerequisites — skipping them makes the rest of this
file partly unreadable.

1. **Merge PR #3 first** (<https://github.com/amardeep434/agent-self-learning/pull/3>),
   or confirm it is already merged:
   ```bash
   git fetch origin main
   git cat-file -e origin/main:.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md && echo ON-MAIN
   ```
   PR #3 is docs-only (this handoff, the findings report, the ledger). Until it lands,
   **every §4 link into `final-sweep-findings.md` resolves to nothing**, and a session
   starting from `main` will find only the 2026-07-25 handoff — which is stale and says
   "resume at Task 7", work that is long since done.

2. **Branch off `main`, not off `harness-neutral-persistence`.** That branch is merged
   (PR #2 = `1c93605`) and is not the base for anything new:
   ```bash
   git fetch origin && git checkout -b <topic> origin/main
   ```
   Work in a git worktree (`.claude/worktrees/<name>`) if the user's checkout may be in
   use. Never push to `main`, never force-push.

3. **Re-derive state before trusting §3.** Run `bash tests/run-all.sh` and
   `gh run list --branch main`. Numbers in prose rot; the commands next to them do not.

4. **Then take §4 in its ranked order — A1 first.** A1 is the only defect that breaks a
   user-facing path (Claude Code hook registration is wrong in three independent ways,
   so a user following the installer's own output gets hooks that never fire). A2 is a
   documentation correction; B3 is a lint. §5 lists rulings that must not be re-opened
   while doing any of this — read it before you "fix" something that was decided
   deliberately.

---

## 1. What this is, in a paragraph

`agent-self-learning` (GitHub: `amardeep434/agent-self-learning`; the local folder is
still called `claude-self-learning` — **do not rename it**, it would break the worktree
link) is a cross-harness self-learning framework for AI coding sessions. It accumulates
memory and reusable skills across sessions and serves **Claude Code, GitHub Copilot CLI,
and (planned) VS Code Copilot Chat as peers** — Claude Code is one adapter among them,
never a dependency. The `harness-neutral-persistence` branch fixed the defect that
motivated the whole design: on Copilot CLI the background reviewer agent was told to
write `MEMORY.md` and `learned-skills/` itself, into `~/.claude/...`; Copilot's path
allow-list refused writes to that foreign namespace, so the loop ran, **burned a paid
model call, and persisted nothing — exit 0, log file present, no error**. The fix
inverts the contract: the reviewer *proposes* a JSON object on stdout and writes no
files; `scripts/persist-proposal.py` validates it and performs every write, confined to
a vendor-neutral store (`$AGENT_LEARNING_HOME` → `$XDG_DATA_HOME/agent-learning` →
`%LOCALAPPDATA%\agent-learning` → `~/.local/share/agent-learning`). That removes the
allow-list dependency, collapses two divergent write paths into one, makes writes
unit-testable without a live agent, and removes agent-filesystem trust from the design.

---

## 2. Where the authoritative record lives

**`git log` and a live `bash tests/run-all.sh` outrank any number written in prose,
including every number in this file.** The documents below are artifacts of the process,
not the state of the system. Several of them have been wrong; two are corrected in place.

| Thing | Path |
|---|---|
| Repo (main checkout) | `/home/amardeep/claude-self-learning` |
| Worktree where the branch lives | `/home/amardeep/claude-self-learning/.claude/worktrees/hnp` |
| **The ledger — the single most useful file** | `.superpowers/sdd/2026-07-25-harness-neutral-persistence/progress.md` |
| The rest of the SDD record (**tracked in git**, 46 markdown files) | `.superpowers/sdd/2026-07-25-harness-neutral-persistence/` |
| The agreed plan, with eight in-place `SUPERSEDED` callouts | `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md` |
| Prior (Copilot + Coach) plan | `docs/superpowers/plans/2026-07-22-copilot-port-and-coach-integration.md` |
| Historical handoff | `docs/superpowers/HANDOFF-2026-07-25-harness-neutral-persistence.md` |

The SDD directory holds the ledger, per-task briefs and reports (`task-N-brief.md` /
`task-N-report.md`), ~15 fix-round reports (`fix-round-A..F`, `fix-p0..p9`,
`fix-final-closeout`, `fix-empty-session`), the plan-vs-tree audit
(`plan-vs-delivered-audit.md`), the Coach skip re-analysis (`skip-reanalysis-audit.md`),
the residuals research (`residuals-research-report.md`), and the raw review diffs. It is
**tracked in git**, unlike earlier SDD workspaces — `git clean -fdx` will not destroy it.

Two known-stale statements inside that record, so you do not act on them:

- `residuals-research-report.md` discusses "the remaining 10 Coach rules". Later work
  reduced the skip list to **3**. The tree wins.
- The ledger's original "40-iteration TOCTOU race — 0/40 escapes" line is **wrong** and
  is corrected in place at the end of the ledger (real rate ~10–18%). Read the
  correction, not the original line.

---

## 3. Current verified state — with the command for each figure

| Figure | Observed 2026-07-27 | Re-derive with |
|---|---|---|
| Branch HEAD | `ae9e8f6` | `git rev-parse HEAD` |
| Commits ahead of the old base | 121 | `git rev-list --count $(git merge-base origin/main HEAD)..HEAD` |
| Working tree | clean, nothing unpushed | `git status --porcelain && git log @{u}..HEAD` |
| **PR #2** | **MERGED** 2026-07-27T10:02:16Z, merge commit `1c93605` | `gh pr view 2 --json state,mergedAt,mergeCommit` |
| Is HEAD on main? | yes | `git branch -r --contains ae9e8f6` |
| CI | run `30255824383`, 6/6 green on `ae9e8f6` | `gh run list --branch harness-neutral-persistence` then `gh run view <id>` |
| Local suite | 43 suites (29 shell, 14 python), all pass | `bash tests/run-all.sh` |
| Coach rules / evaluable | 45 rules, 3 skipped → 42 evaluable | count `^id:` in `vendor/coach-rules/*.md`; count keys of `UNSUPPORTED_REASONS` in `scripts/coach-rules-eval.py` — **parse it, do not grep it** (see §7) |
| Resolved store paths | see below | `python3 scripts/lib/paths.py all` |
| Claude Code hooks registered | **0** | `python3 -c "import json,os;print(json.dumps(json.load(open(os.path.expanduser('~/.claude/settings.json')))['hooks']))"` and look for the scripts dir |

The CI matrix is `{ubuntu, macos, windows}-latest × Python {3.9, 3.13}` — six cells.
**No run id is pinned in `CLAUDE.md` deliberately**; every previous version that pinned
one went stale within hours. The branch was red on this matrix repeatedly on 2026-07-25,
so read the run *history*, not just the newest entry, before concluding anything.

---

## 4. What is genuinely left, ranked

Full evidence, reproduction commands and proposed fixes for every row live in
**[`.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md`](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md)**
(tracked in git, alongside the ~15 per-round reports). This section is the index.
Read a row here, then read its section there before acting on it.

| # | Item | Category | Detail |
|---|---|---|---|
| **A1** | Claude Code hook registration is broken **three ways** — `settings-hooks.json` names the pre-Task-7b `~/.claude/scripts/self-learning/` path that `install.sh` no longer writes, while `install.sh`'s printed block uses the flat schema Claude Code rejects and timeouts 1000× too large. Following *either* documented route fails. Was mis-carried as a "user decision"; it is a defect that *prevents* the decision. | **OWED** | [§A](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#a-owed--real-defects-found-in-this-audit-not-previously-recorded) |
| **A2** | The documented Windows coverage caveat is wrong on both its numbers (actual: 4 shell + 21 Python skips, 15 of them Windows-only) and its stated reason (the runner reports symlink and hardlink creation *available*; the real causes are `O_NOFOLLOW` and `dir_fd`). Two skip categories are undocumented entirely, including the cross-process store-lock tests. | **OWED** | [§A](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#a-owed--real-defects-found-in-this-audit-not-previously-recorded) |
| **B3** | The detached-pipeline spawn/teardown race. The `sl_wait_for_review_complete` + `sl_rm_rf_retry` pair exists because this broke a macOS suite; it has since been reintroduced at a *new* launch site three times (`cd04308` added the helper, `263a717` swept misses, `ae9e8f6` fixed another). 23 launch sites, held together by convention. A wrapper is the wrong fix — the sites are heterogeneous — a ~30-line lint is the right one. | **OWED, cheap** | [§B](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#b-owed-cheap--a-structural-guard-for-the-class-that-keeps-coming-back) |
| **C** | Three Coach rules still skipped (`broken-flow-state`, `no-devcontainer`, `no-file-context`) — all three re-verified verbatim against upstream `766d0f2`; SkillOpt's `run-sleep.sh` contract intact but upstream now leads with a pip CLI our wrapper cannot drive; `transcript.py`'s two on-disk formats confirmed undocumented, where total breakage is loud but **partial drift is silent**. | **DEFERRED** | [§C](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#c-deferred-with-a-reason-that-holds-up) |
| **D** | Register the Claude Code hooks (use the corrected JSON in §A, **not** `install.sh`'s output) · rotate the `gho_` token if these logs are shared — GitHub documents keychain-first with plaintext fallback, and `/logout` does not revoke. | **USER DECISION** | [§D](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#d-user-decision) |
| **E** | VS Code Copilot Chat adapter — named in the plan's own exclusion list, no half-built code. Caveat: Coach Route B needs a fork `.vsix` this repo neither contains nor tests. | **OUT OF SCOPE** | [§E](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#e-out-of-scope--genuinely-not-silent-debt) |
| **F** | PR #2 **merged** 2026-07-27T10:02:16Z as `1c93605` — every item above is now a defect on `main`, not on a branch. Review thread 5 already resolved by `f65a8bf`. All four earlier review threads were false or already fixed. | **MOOT** | [§F](../../.superpowers/sdd/2026-07-25-harness-neutral-persistence/final-sweep-findings.md#f-moot--resolved-between-measurement-and-now) |

**If you do one thing:** A1. It is the only item that stops a user getting any value from
the Claude Code half of this system, and it has no test because the surface it lives on —
what a user does *after* install — is untested end to end.

## 5. Rulings that must not be re-litigated

From the ledger and the 2026-07-25 handoff §8. These were argued once, with evidence:

- `~/.claude` paths in a file that is **Claude Code's own config** are not violations. The
  no-Claude constraint binds the *Copilot and VS Code* code paths. Harness-owned config
  *locations* (`~/.claude/settings.json`, `~/.copilot/hooks/`) are fine; only the **script
  path each config invokes** must be neutral.
- A **symlinked store root** is allowed by design — the root comes from the environment,
  not from proposal content. Store-*internal* directories (`memory/`, `learned-skills/`)
  must not be symlinks; a link planted there is unambiguously anomalous.
- **Cross-device rename is impossible** here: `mkstemp` stages inside the destination
  directory, so `os.replace` is always intra-directory. No `EXDEV` risk.
- `_MAX_FENCE_CANDIDATES = 10` is **fail-closed** — it can only reject a valid proposal,
  never accept a malicious one.
- Writer files land at **0600 by deliberate policy** (no pre-rename disclosure window),
  accepting that a user's chosen mode is not preserved.
- `doctor.sh`'s exit code covers non-writable paths and a non-empty
  `persist-failures.log` but **not** a detected legacy store — making legacy detection
  fatal would turn every upgraded machine permanently red and train users to ignore the
  exit code.
- Removing `install.sh`'s precondition that `~/.claude` must already exist was
  **correct and intended** — that requirement was the dependency the plan removes.
- **Timeout wrappers must be feature-detected, never assumed.** A bare `timeout` was
  rejected because stock macOS has none; the required shape is detect `timeout`, fall
  back to `gtimeout`, and warn *loudly* if neither exists. A silent loss of protection is
  the pattern this project keeps fixing.

**One ruling that MUST be re-litigated, and this is the exception:** the 2026-07-25
handoff §8 states that "`config/settings-hooks.json` containing `~/.claude` paths in its
hooks block is correct". That ruling was made **before Task 7b relocated installed scripts
out of `~/.claude/scripts/self-learning`** and was never revisited. It is now the rule
that sanctions defect A1. The distinction it was reaching for is right — config
*location* vs. invoked *script path* — but it is being applied to script paths, which the
later Task 7b ruling explicitly says must be neutral.

## 5b. Defects that return if someone "restores" older behaviour

The plan file carries **eight in-place `> SUPERSEDED` callouts**
(`docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md`, at lines 36, 77,
563, 707, 818, 1106, and 1674 — one covers two places). **Read them before implementing
anything from that plan.** The repository is authoritative over the plan; adversarial
review found real vulnerabilities in code the plan specified verbatim. In particular:

- **Line 707 — the flat `<name>.md` skill layout. Reintroducing it is a Critical.** The
  writer must produce `<name>/SKILL.md`; every consumer (`inject-agents-md.py`,
  `curator-run.sh`, `skill-lifecycle.py`) reads that shape. The flat layout made a
  just-persisted skill *invisible* to the injector.
- **Line 563 — the fence regex has quadratic backtracking**, measured 26.1 s on 872 KB;
  the tree scans linearly with `str.find` at 0.00078 s.
- **Line 818 — resolve-then-open is a textbook TOCTOU.** The tree anchors writes on an
  already-open directory fd (`O_NOFOLLOW`, `dir_fd=`) where a *functional probe* says
  that works, and discloses the residual on Windows in three places rather than carrying
  it silently.
- **Line 1106 — polling for the target file races the detached pipeline.** Poll the
  completion marker (see B3), never an output file.
- The Task 3 skill-name regex anchored with `$` also matched before a trailing newline —
  `"evil\n"` validated and would have become the filename `evil\n.md`.
- The Task 4 confinement check compared `target.parent.resolve()` to `root.resolve()`,
  which passes trivially when `root` itself is a symlink pointing outside the store.

---

## 6. What was never verified, and why

Say these plainly rather than letting the green matrix imply otherwise.

- **The live Copilot check ran twice, and the second run is the one that matters.**
  - **Run 1, 2026-07-25** (recorded by `f28b824`; real paid model call, real `$HOME` for
    auth, throwaway store). Two halves: `copilot-session-review.sh` driving the detached
    pipeline for real — which correctly persisted an **empty** proposal, because headless
    `copilot -p` leaves no session transcript — and the OUTPUT CONTRACT exercised with a
    **synthetic** transcript through the real writer, persisting real content at 0600.
    The transcript was the one fabricated part.
  - **Run 2, 2026-07-26** (~22:37 IST / `17:07Z`; no doc commit of its own, which is why
    it is easy to miss). `copilot -s --allow-tool read -p …` produced a **real** Copilot
    session dir (`events.jsonl`: `user.message=1`, `assistant.message=2`); the real
    installed `sessionEnd` hook fired; the detached pipeline wrote **279 bytes of real,
    session-derived content** to `<store>/memory/MEMORY.md`, preserving the pre-existing
    entry, at mode 0600, with `persist-failures.log` empty, nothing under `~/.claude`, and
    the real neutral store never created. The user's hook file was restored byte-identical.
    **So Copilot's own session transcript reaching the prompt is no longer unexercised** —
    the two persisted lines are the two decisions typed into that session, and the
    reviewer ran with `$CLAUDE_JOB_DIR/tmp` as cwd, with no repository to infer them from.
  - **What genuinely remains:** no *human, multi-turn, TUI* Copilot session has fired the
    hook. Run 2 was still a one-shot `-p` invocation, merely one that `-s` gave a real
    transcript. That last gap needs ordinary day-to-day use, not engineering — and it is a
    much narrower gap than this section claimed before 2026-07-27.
  - Artifacts, as long as the job dir survives: `$CLAUDE_JOB_DIR/tmp/live2-store/`
    (`memory/MEMORY.md`, `logs/persist.log`, empty `logs/reviews/transcript.err`). The
    durable record is the session transcript at `2026-07-26T17:07–17:08Z`.
  - **`CLAUDE.md` has been updated to reflect Run 2.** The remaining residual is only that no
    *human, multi-turn, TUI* Copilot session has yet fired the hook; ensure other docs do not
    repeat the older “transcript reaching the prompt is unexercised” wording.
- **Route C (SkillOpt) has never run end-to-end** — needs a `microsoft/SkillOpt` checkout.
- **Route B (Coach export) has never run here** — needs a fork `.vsix` this repo does not
  contain.
- **Live telemetry/transcript extraction is never exercised in CI on any platform** — no
  runner has a Copilot or Claude store; those 4 tests skip in all six cells (A2).
- **Cross-process store-lock writer tests do not run on Windows** (A2). The lost-update
  race fix is verified on Linux and macOS only.
- **The symlink/hardlink/`O_NOFOLLOW` write-path attack surface is exercised on Linux and
  macOS only.** On Windows the corresponding protection is `win_dir_pin.py`'s
  `CreateFileW` share-mode pin, which *is* probe-verified in CI — a different mechanism
  covering the same threat, not the same tests passing.
- Every skip is **printed with its reason and gated on a probe that verifies the
  limitation**, never on a platform name. That is deliberate: a blanket
  `if windows: skip` would hide real Windows regressions forever.

---

## 7. The hard-won operating lessons

These are the most reusable output of this branch. Every one of them cost a round.

1. **Mutation-test every fix, or it may be vacuous.** Comment the protection out, run the
   suite, confirm something fails, restore. The plan's own tests killed 1 of 7 mutants.
   Multiple "passing" assertions here were later proven to pass with the protection
   removed — a doctor test whose fixture never emitted the string it asserted was absent;
   an exit-code-only check that survived printing FAIL lines while exiting 0; a `~/.claude`
   source guard that was **mutation-proven not to catch the very bug it was written for**,
   because it grepped for `".claude"` and the live defect used `expanduser("~/.claude/…")`.
2. **A component that exits 0 while doing nothing is this project's signature bug, and it
   recurred roughly a dozen times.** The founding defect was one. So were: the installer
   never copying `persist-proposal.py`, so the pipeline piped into a nonexistent writer;
   `doctor.sh` not being installed at all; `self-learning-health.sh` reporting HEALTHY
   with the writer deleted; `skill-lifecycle.py` still reading `~/.claude/learned-skills`
   and archiving nothing; a coach-rules directory default that pointed one directory away
   from where install put it; and `copilot-session-review.sh` never reading stdin, so the
   reviewer had zero information about the session it was paid to review. **Design every
   component so that "did nothing" and "succeeded" are distinguishable from outside**, and
   make the detached paths report through `persist-failures.log`, which `doctor.sh`
   surfaces — a detached pipeline has no exit code anyone will ever see.
3. **`grep | wc -l` produced three confident wrong numbers. Parse structurally.** The
   Coach skip count, the rule count (46 `.md` files, but one is `UPSTREAM.md` — 45 rules),
   and the Windows skip figures were all wrong when counted by grep. Even in *this* audit
   a `grep -o` pattern truncated at a parenthesis and nearly produced a false report that
   the Windows directory pin was not engaged. Count `UNSUPPORTED_REASONS` by walking the
   AST; count rules by their `^id:` frontmatter; count CI skips per `=== suite ===` banner.
4. **"Unverifiable locally" was wrong, repeatedly.** `pwsh`, `claude` and `copilot` were
   all installed and available on the machine where each was declared unavailable. Before
   writing "can only be verified in CI", run `command -v`.
5. **Capability probes, never platform-name branches.** Every skip in this suite is gated
   on an executed probe — `[[ -L ]]` after `ln -s`; an actual write attempt after
   `chmod 500`; a functional `dir_fd` call, because `os.supports_dir_fd` is itself
   unreliable (`os.replace` is absent from it on this project's own Linux host while
   accepting `dir_fd` and working correctly). A2 is the payoff: the *documented* reason
   for the Windows skips said "symlinks need elevation", and the probe output proves
   symlink creation is AVAILABLE there. The probe was right and the prose was wrong.
6. **Copilot's PR *suggestions* are invisible to every GitHub API.** Review *comments* come
   back through GraphQL `reviewThreads`, but the suggested-change payloads do not. They
   must be screenshotted or applied through the web UI. Plan for that before assuming a PR
   review can be processed headlessly.
7. **Duplicated logic is this codebase's second signature defect.** Two ISO parsers meant a
   fix landed in one and regressed Python 3.9. The skill layout was restated in five places
   and produced a Critical. The corrupt-`.usage.json` policy was *opposite* in two
   components. Defect A1 is the same shape again: the Claude hook JSON exists twice, in
   `config/settings-hooks.json` and inline in `install.sh`, and the two copies are wrong in
   different halves. The counter-example that worked is `sl_check_hook_fresh()` — extracted
   into `config.sh` so two tools *cannot* disagree by construction. Extract; do not patch
   both copies.
8. **A wrong number repeated as fact is worse than no number.** The "0/40 TOCTOU escapes"
   figure was carried in the ledger as established fact until a re-measurement found
   ~10–18%. It was never reproduced. Re-measure security numbers before trusting them, and
   correct them **in place** where they were recorded.
9. **CI caught two real defects that six rounds of inspection-based review could not.** Do
   not treat a matrix as a formality.

---

## 8. Safety rules for anyone resuming

- **Never run `install.sh`, `uninstall.sh` or `scripts/curator-run.sh` against a real
  `$HOME`.** Use `env -i HOME=<tmp> AGENT_LEARNING_HOME=<tmp>/store` and `--dry-run`. The
  curator archives and deletes skills.
- **Never modify `~/.copilot/` or `~/.claude/`.** Read freely, but **do not read
  `~/.copilot/config.json`** — it holds the plaintext OAuth token (D8).
- **Never `git add -A`** in this repo.
- Python here is **stdlib only, 3.9+** — 3.9 is the CI floor and the lowest version
  anything is actually run against. Any module using `X | None` annotations needs
  `from __future__ import annotations`.
- Shell is POSIX-compatible bash (`#!/usr/bin/env bash`). Hooks must complete in <100 ms.
- Run `bash tests/run-all.sh` before committing. Never hardcode a suite count anywhere —
  the runner discovers by glob and the number drifts on every suite added.
