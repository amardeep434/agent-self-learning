# Final sweep — findings (2026-07-27)

Detailed findings from the closing audit of the `harness-neutral-persistence`
work, extracted from the session handoff so they live with the other round
reports rather than inside a document meant to be skimmed.

**Companion documents**

- `docs/superpowers/HANDOFF-2026-07-27-harness-neutral-persistence.md` — the resumption
  guide. Its section 4 is a ranked index that links back to the sections below.
- `progress.md` (this directory) — the append-only execution ledger; its final entry
  records the closing state.
- The ~15 sibling `fix-*.md` / `*-audit.md` reports here — per-round detail.

`git log` and a live `bash tests/run-all.sh` outrank any figure written below.
Every number here was re-derived on 2026-07-27; commands to reproduce each are
given inline.

---


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
  `test-store-lock-writers.py` 3 — **11**.
  `test-win-dir-pin.py` skips 6 on Windows and 9 on Linux (it is the inverse suite).

  > **Corrected 2026-07-27 while fixing A2.** This bullet originally said **15**,
  > counting `test-telemetry.py`'s 4 as Windows-only. They are not: re-measured on run
  > `30284745998`, telemetry skips 4 on ubuntu-latest 3.13 as well — which the very next
  > bullet already said ("4 telemetry live-store tests skip on every CI cell on every
  > platform"), so this section contradicted itself. 11 is the measured figure.
- The stated *reason* is false. The Windows runner prints
  `[capability probe] symlink creation: AVAILABLE` and
  `[capability probe] hardlink creation: AVAILABLE`. The real causes are
  `[capability probe] O_NOFOLLOW: UNAVAILABLE (POSIX-only primitive)` and
  `[capability probe] dir_fd (functional): UNAVAILABLE (e.g. native Windows)`.

  > **Refined 2026-07-27 while fixing A2.** "The reason is false" is itself too broad, and
  > correcting it that way would have flipped the error rather than fixed it. Both probes
  > above come from the *Python* suites, and there symlink/hardlink creation genuinely
  > works. But `tests/test-path-compare-lib.sh`'s 2 skips are real symlink-creation
  > failures — `ln -s` could not create one, verified with `[[ -L … ]]`. So the shell half
  > cannot make symlinks while the Python half can, and each skip must be attributed to its
  > own probe. Also measured: `test-store-lock-writers.py`'s 3 skips are gated on "bash not
  > runnable here (probed)", not on any lock limitation — the msvcrt backend does run on
  > Windows. Full per-suite breakdown now in `README.md` and `CLAUDE.md`.
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
silently truncated at a parenthesis. See §7 *of the handoff*, "operating lessons".)

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

**B3-adjacent, REFUTED — `test-copilot-session-review.sh` case 9 is *not* racing the
detached pipeline.** The sweep raised this and it is recorded here only so nobody spends
the investigation twice. Case 9 (`tests/test-copilot-session-review.sh:244-253`) asserts
that `persist-failures.log` contains `transcript unavailable` immediately after the hook
script returns, with no `sl_wait_for_review_complete` — which looks exactly like the B3
pattern.

It is safe, for a structural reason. That line is not written by the detached pipeline.
`copilot-session-review.sh:44` runs `python3 lib/transcript.py … --log-file
"${SL_LOG_DIR}/persist-failures.log"` **synchronously**, in a command substitution, at the
top of the script; `transcript.py:659` writes the failure line and returns 0 before the
script continues. The `nohup … &` detach is at line 169, 125 lines later, and never
invokes `transcript.py`. When the transcript is missing there is also no `copilot` call to
detach into. So the log line is durably on disk before the hook returns, and the assertion
cannot observe a partial state.

> **Half of this was wrong, and the B3 lint caught it on 2026-07-27.** The assertion
> genuinely cannot race — that part holds. But this entry went on to claim there is "no
> completion marker to wait on in that path" because no `copilot` call is reached, and told
> the reader not to add a wait. False. `copilot-session-review.sh:40-42` says so in its own
> words: "the failure path below is deliberately UNCHANGED — a real transcript failure still
> logs loudly AND still spawns the review; only the provably-empty case short-circuits."
> A missing session dir is a *failure*, not the empty case, so `TRANSCRIPT_STATUS` is 0, the
> script runs on, and on any machine with `copilot` on PATH case 9 leaves a detached pipeline
> writing into `$TMP9` while the suite tears it down. `sl_rm_rf_retry` made that survivable,
> not correct.
>
> Fixed by pairing the launch the way every other site is paired, gated on the same
> condition the script itself gates on: `command -v copilot` → `sl_wait_for_review_complete`;
> otherwise `sl_expect_no_review_spawned` (2s) rather than waiting out a 30s timeout for a
> pipeline that was never going to start. The lesson worth keeping: "I reasoned it cannot
> race" is not evidence, and here it was contradicted by a comment sitting in the file the
> whole time.

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
**Copilot's PR *suggestions* are invisible to every GitHub API** — see §7 *of the
handoff*, "operating lessons".

---

