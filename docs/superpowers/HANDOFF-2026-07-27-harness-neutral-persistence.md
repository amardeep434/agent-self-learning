# HANDOFF — `harness-neutral-persistence`, closing state

**Written:** 2026-07-27 · **Audience:** a reader with zero prior context.
**Supersedes** `HANDOFF-2026-07-25-harness-neutral-persistence.md`, which is historical.
That file went stale within hours of being written because it pinned counts, a task
number, and a "resume here" pointer into prose. This one states, for every figure that
can rot, **the command that re-derives it**. Where you find a number below without a
command next to it, distrust it and go measure.

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

### A. OWED — real defects, found in this audit, not previously recorded

**A1 — Claude Code hook registration is broken three separate ways.** This is not a
pending user decision (it was carried as one); it is a bug that *prevents* the decision.
It fully explains the observed "0 self-learning hooks registered / health UNHEALTHY with
3 failures" on this machine.

1. `config/settings-hooks.json` still hardcodes
   `bash ~/.claude/scripts/self-learning/{turn-counter,session-review,index-session}.sh`.
   Task 7b relocated installed scripts to the resolved store's `scripts` key
   (`~/.local/share/agent-learning/scripts` by default). `install.sh` has not written to
   `~/.claude/scripts/self-learning` since. **`README.md:88` tells users to merge this
   file into `~/.claude/settings.json`** — following the README registers three hooks
   pointing at paths that do not exist. No test covers this file's script paths.
2. `install.sh` (Step 7, the "NEXT STEP (Claude Code only)" block) prints the *correct*
   `${SL_SCRIPTS}` path but in the **flat schema** — `matcher`, `command` and `timeout`
   as siblings, with no nested `"hooks": [ … ]` array. That is precisely the schema the
   2026-07-22 plan's Task 4 declared invalid and rewrote `settings-hooks.json` to fix.
   Claude Code requires three levels: event → matcher group → `hooks[]`
   (<https://code.claude.com/docs/en/hooks>). Pasting install.sh's output registers nothing.
3. install.sh's printed timeouts are `3000` / `10000` / `15000`. Claude Code's hook
   `timeout` is in **seconds** (command default 600). `settings-hooks.json` correctly
   uses `3` / `15` / `10`. As printed, `turn-counter.sh` would get a 50-minute timeout on
   every `PostToolUse`.

So the two sources disagree, and each is wrong in a different half. The correct block,
for a default store, is:

```json
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "bash ~/.local/share/agent-learning/scripts/turn-counter.sh", "timeout": 3 } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "bash ~/.local/share/agent-learning/scripts/session-review.sh", "timeout": 15 },
        { "type": "command", "command": "bash ~/.local/share/agent-learning/scripts/index-session.sh",  "timeout": 10 } ] }
    ]
  }
}
```

Substitute the `scripts=` line from `python3 scripts/lib/paths.py all` rather than
assuming the default. **Fix owed:** make `config/settings-hooks.json` a
`__SL_SCRIPTS_DIR__` template exactly like `config/copilot-hooks.json` already is; make
install.sh print that template after substitution instead of hand-rolling a second copy
of the JSON; add a test that the printed JSON parses, matches Claude Code's nested
schema, and names a path install.sh actually created. This is the same
one-definition-in-two-places class as C4/I5/the two ISO parsers — a third copy of the
hook JSON is what produced it.

**A2 — the documented Windows coverage caveat is wrong on both numbers and on its
reason.** `CLAUDE.md` and `README.md` say "7 write-path security tests and 3 shell
assertions skip there (symlinks need elevation; `chmod` does not deny writes under
ACLs)". Re-derived from CI run `30255824383`, `windows-latest, 3.13`:

- Shell skips: **4** announcements across 3 suites (`test-path-compare-lib.sh` prints
  two), not 3.
- Python skips: **21** cases across 5 suites. Windows-only (these skip **zero** on
  Linux): `test-adversarial-sweep.py` 3, `test-persist-proposal.py` 5,
  `test-store-lock-writers.py` 3, `test-telemetry.py` 4 — **15**.
  `test-win-dir-pin.py` skips 6 on Windows and 9 on Linux (it is the inverse suite).
- The stated *reason* is false. The Windows runner prints
  `[capability probe] symlink creation: AVAILABLE` and
  `[capability probe] hardlink creation: AVAILABLE`. The real causes are
  `[capability probe] O_NOFOLLOW: UNAVAILABLE (POSIX-only primitive)` and
  `[capability probe] dir_fd (functional): UNAVAILABLE (e.g. native Windows)`.
- Two categories are unmentioned anywhere: **3 cross-process store-lock writer tests do
  not run on Windows** — that is the lost-update-race fix, unverified there — and **4
  telemetry live-store tests skip on every CI cell on every platform**, because no runner
  has a Copilot or Claude store. Live transcript/telemetry extraction is therefore
  exercised only on a developer machine that has both harnesses installed.

Re-derive with: `gh run view --job <windows job id> --log`, then count `SKIP:` lines and
`OK (skipped=N)` lines per `=== tests/... ===` banner. Do not count them by eye.

One thing the docs *understate*: the Windows write-path is not simply unprotected.
`test-win-dir-pin.py` prints `[capability probe] win32 directory pinning: AVAILABLE
(verified: a pinned directory could not be renamed, and our own staged replace inside it
still succeeded)` on the Windows runner — the `CreateFileW` share-mode hardening is live
and probe-verified there. (I nearly reported this as a gap because a `grep -o` pattern
silently truncated at a parenthesis. See §7.)

### B. OWED, cheap — a structural guard for the class that keeps coming back

**B3 — the detached-pipeline spawn/teardown race.** `scripts/session-review.sh` and
`scripts/copilot-session-review.sh` both detach their entire pipeline (`nohup … &` +
`disown`), so the launching call returns long before anything is written. Each writes an
unconditional completion marker `$SL_LOG_DIR/.review-complete` as its last statement, and
`tests/lib/wait-for-review.sh` provides `sl_clear_review_marker` /
`sl_wait_for_review_complete` / `sl_expect_no_review_spawned` / `sl_rm_rf_retry`.

There are **23 launch sites across 4 shell suites** (`test-copilot-session-review.sh` 14,
`test-session-review.sh` 6, `test-e2e-skill-visibility.sh` 2, `test-claude-absent.sh` 1)
and the helper is applied **by convention only**. History: `cd04308` introduced it after
the race broke a macOS suite; `263a717` swept sites it had missed; `ae9e8f6` — the branch
HEAD — fixed a site added *after* the helper existed, which had neither the wait nor
`sl_rm_rf_retry`, and which surfaced as ubuntu-3.13 failing with **every assertion passed
and a non-zero exit from teardown**.

A helper that couples spawn-to-wait is the obvious idea and is the **wrong** one: the call
sites are genuinely heterogeneous (some pipe stdin, some run under `env -i` with a
different `HOME`, some assert the reviewer must *not* spawn, one runs two sequential
scenarios against two stores). Wrapping them would need an option surface as large as the
sites. The cheap durable fix is a **lint suite**: read each `tests/test-*.sh`, and for
every line launching either review script, require `sl_wait_for_review_complete` or
`sl_expect_no_review_spawned` within a small window after it. ~30 lines of Python,
mutation-testable by deleting one wait and confirming the lint fires, and it catches the
next occurrence at authoring time rather than as a red cell on one OS.

### C. DEFERRED with a reason that holds up

**C4 — the three remaining Coach skips.** Re-verified against upstream
`microsoft/AI-Engineering-Coach` at the pinned commit `766d0f2`:

- `no-devcontainer` — **genuinely unreachable, confirmed verbatim.**
  `computeDevcontainerStats` opens with
  `const vscodeSessions = sessions.filter(s => VSCODE_HARNESSES.has(asStr(s.harness)));`
  and `VSCODE_HARNESSES = new Set(['VS Code', 'VS Code Insiders', 'Local Agent', 'Local
  Agent (Insiders)'])`. For a CLI harness the scored population is empty *inside
  upstream's own function*, by a hardcoded gate, before any field of ours is consulted.
- `broken-flow-state` — **reachable, deferred, cost stated accurately.** The four weights
  in the skip reason (rapid-followup 40%, median latency 30%, duration 15%, density 15%)
  match upstream's
  `Math.round(rapidScore * 0.4 + latencyScore * 0.3 + durationScore * 0.15 + densityScore * 0.15)`
  exactly. Every input is already captured; it is a ~150-line analyzer port.
- `no-file-context` — **reachable, deliberately not shipped under upstream's rule id.**
  Verified structurally: `scripts/lib/telemetry.py` populates `referencedFiles` from tool
  arguments (mirroring upstream's own CLI parser), and at least four evaluated rules in
  `scripts/coach-rules-eval.py` consume it under that definition. Redefining it for one
  rule really would silently change the others. It wants a locally-named signal.

Two **citation drifts** to fix at the next `sync-coach-rules.sh` run: the skip reason
cites `interpreter.ts:579-583`, but at `766d0f2` the set is at line 571 and the filter at
573–576; and it calls `analyzer-flow.ts` a 275-line file, which is now ~310. The
substance is right in both cases; only the coordinates rotted.

**C5 — SkillOpt / Route C.** `scripts/skillopt-run.sh` is an opt-in wrapper that landed
on `main` *before* this branch (`6238654`, `535ef91`) and is not in PR #2's diff. It
requires `SL_SKILLOPT_REPO` to point at a checkout containing `plugins/run-sleep.sh`.
Checked upstream today: **`plugins/run-sleep.sh` still exists** (3,162 bytes, alongside
`run-sleep.cmd` and `run-sleep.ps1`), so the wrapper's contract has not broken. But the
deferral reason needs updating rather than repeating: upstream now ships a pip-installed
`skillopt-sleep` CLI as its *documented* entry point, and `docs/sleep/README.md` no
longer mentions `run-sleep.sh` at all. Our wrapper cannot use an installed
`skillopt-sleep`, only a source checkout — so it targets the entry point upstream is
de-emphasising. It has still never been exercised end-to-end, and doing so needs a real
checkout. The automatic optimisation loop remains deferred behind a cost spike.
Sources: <https://github.com/microsoft/SkillOpt>,
<https://github.com/microsoft/SkillOpt/blob/main/docs/sleep/README.md>.

**C6 — `transcript.py` parses two undocumented, unversioned third-party on-disk
formats.** Confirmed for both:

- Copilot CLI `~/.copilot/session-state/<id>/events.jsonl` — no published schema. There
  is an open upstream request to *make* it one
  (<https://github.com/github/copilot-cli/issues/3551>, "Formalize events.jsonl as an
  official hook/integration API"), which is itself the evidence that GitHub has not.
- Claude Code `~/.claude/projects/<slug>/<session>.jsonl` — carries a `version` field
  holding the *CLI* version, but no schema version and no stability guarantee; it is an
  internal implementation detail that changes with CLI releases.

The breakage mode is **mostly good and deliberately so**. A total format change yields
`OUTCOME_FAILURE` → a line in `persist-failures.log` → `doctor.sh` reports UNHEALTHY. It
cannot be made immune; it is built to refuse to hide. The residual is **partial drift**:
if, say, `event["data"]["content"]` stops being a plain string for some event types, the
digest silently gets shorter and still reports `OUTCOME_OK`. That is a quiet degradation
of exactly this project's signature failure class, and nothing currently detects it. A
cheap canary would assert a floor on messages-extracted relative to events-seen.

### D. USER DECISION

**D7 — register the Claude Code hooks.** Currently zero are registered, so Claude Code
sessions contribute nothing; the Copilot CLI side is registered and working. **Do not
paste what `install.sh` prints today** — see A1; use the JSON in A1 with the `scripts=`
value from `paths.py all`. The tradeoff: `turn-counter.sh` then runs on **every**
`PostToolUse`. Measured on this machine, 50–68 ms with a native `python3` on PATH, but
consistently 130–155 ms behind a pyenv/asdf shim — ~85 ms of which is the shim itself,
not this project's code. Roughly 22–25 ms of the native figure is `config.sh`'s single
`python3 lib/paths.py all` subprocess per hook invocation. Caching that resolution across
invocations was considered and **rejected**: a stale cache relative to
`AGENT_LEARNING_HOME`/`XDG_DATA_HOME` reintroduces exactly the silent-wrong-location bug
this project exists to eliminate. The documented hook budget is therefore <100 ms, not
the <50 ms an earlier doc claimed. `Stop` adds two more hooks (review + index).

**D8 — the plaintext `gho_` OAuth token in `~/.copilot/config.json`.** Not introduced by
this work; the Copilot CLI writes it. GitHub documents the OS keychain (Windows
Credential Manager, macOS Keychain, libsecret/GNOME Keyring/KWallet) as the storage
location *when available*, with plaintext `~/.copilot/config.json` as the fallback when
no keyring is — which is what happened here. Rotation is two steps and the first is not
enough: `/logout` at the Copilot prompt removes the local copy but **does not revoke the
token server-side**; revocation is GitHub → Settings → Applications → Authorized OAuth
Apps → GitHub CLI → Revoke, then re-authenticate. Because a subagent read that file
during an audit, revoke-and-reauth (ideally with a working keyring present) is the
conservative call. **Do not read the file to check** — it contains the live secret.
Sources: <https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli>,
<https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/troubleshoot-copilot-cli-auth>.

### E. OUT OF SCOPE — genuinely, not silent debt

**E9 — the VS Code Copilot Chat adapter.** Named in the plan's own out-of-scope list
(`2026-07-25-…​.md:1681`), and both `README.md:448` and `CLAUDE.md:88` say "not started
(tracked separately)". There is no half-built adapter in the tree, no dead config, no
test asserting a capability that does not exist. This is real exclusion, not debt. One
caveat worth knowing: `README.md:311` documents Coach **Route B**
(`SL_COACH_EXPORT_ENABLED=true`) as requiring "our maintained fork's `.vsix` installed in
VS Code". That fork is an external dependency this repository does not contain, does not
pin, and does not test. Route B is documented but unexercised here.

### F. MOOT — resolved between measurement and now

**F10 — PR #2 is merged.** Merged 2026-07-27T10:02:16Z into `main` as `1c93605`;
`ae9e8f6` is contained in `origin/main`. The "should we merge, and with what
preconditions" question is closed. The consequence: **A1 and A2 are now defects on
`main`**, not on a branch.

**F11 — the cleanup-trap review thread is resolved**, and the fix is committed as
`f65a8bf`. Nothing owed there.

**F12 — the four still-unresolved PR threads are all Copilot-reviewer findings that are
either false or already fixed.** Verified against the tree:

- `scripts/lib/isotime.py:44` and `scripts/lib/list-transcripts.py:49` — "PEP 604 union
  is a `SyntaxError` on 3.9 *even with* `from __future__ import annotations`". **False.**
  Both files carry the future import (`isotime.py:38`, `list-transcripts.py:28`), the
  unions are in annotation position, and both `ubuntu-latest, 3.9` cells are green.
- `scripts/lib/skill-layout.sh:46` — "still unconditionally runs `python3`". **False.**
  The three defaults are assigned *before* the probe, and the `while … read` loop over a
  failed process substitution simply reads nothing, leaving them intact.
- `tests/test-review-cli-flags.sh:33` — "calls `timeout` directly, which macOS lacks".
  **Already fixed** in `fddcc4a`, which feature-detects `timeout`/`gtimeout` and says so
  loudly when neither exists.

Closing these with a one-line reply each is the only PR bookkeeping left. Note that
**Copilot's PR *suggestions* are invisible to every GitHub API** — see §7.

---

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

- **No genuine *interactive* Copilot session has ever fired `sessionEnd` with real
  conversation history in the payload.** The live end-to-end check (2026-07-26, real paid
  model call, real `$HOME` for auth, throwaway store) covered two halves: the hook script
  driving the detached pipeline for real, and the OUTPUT CONTRACT with a synthetic
  transcript through the real writer persisting real content at 0600. What remains
  unexercised is Copilot's *own* session transcript reaching the prompt. That needs
  ordinary day-to-day use, not engineering.
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
