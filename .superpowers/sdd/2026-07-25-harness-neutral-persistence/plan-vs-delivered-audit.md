# Plan-vs-Delivered Audit — `harness-neutral-persistence`

**Contract audited:** `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md` (1611 lines)
**Tree audited:** branch `harness-neutral-persistence` @ `f7cfe95`, 73 commits ahead of `befd131`
**Date:** 2026-07-26 · **Mode:** read-only. Every claim below was re-derived from the tree,
`git log`, or live command output in this session. Where the ledger
(`progress.md`) or a round report disagreed with the tree, the tree is recorded and the
discrepancy is flagged.

Method note: the plan's own task checkboxes are all still unticked. That is expected — execution
ran through `.superpowers/sdd/.../progress.md`, not the plan file — and an unticked box is
treated here as carrying zero information.

---

## Scoreboard

| Classification | Count |
|---|---|
| DONE | 30 |
| DONE DIFFERENTLY | 8 |
| PARTIAL | 3 |
| NOT DONE | 0 |
| OUT OF SCOPE (deliberately deferred by the plan) | 8 |

Nothing the plan agreed to is entirely absent. Three items landed incompletely; eight landed by a
different mechanism than the plan text specified, and in seven of those eight the deviation is an
improvement over a plan that was demonstrably wrong.

---

## 1. Global Constraints

### GC1 — Python: standard library only, no new pip dependencies — **DONE**

Executed: every `import`/`from` across `scripts/**/*.py` and `tests/**/*.py` resolves to the
stdlib (`argparse ast collections datetime errno fcntl __future__ importlib json msvcrt os
pathlib re shutil sqlite3 stat subprocess sys tempfile threading time typing unittest`) or to a
local sibling module (`paths`, `proposal_schema`, `isotime`, `skill_layout`, `store_lock`).
No `requirements*.txt`, `pyproject.toml`, or `setup.py` exists in the tree.

### GC2 — Bash runs on Linux, macOS, Windows Git Bash; no GNU-only flags — **DONE**

CI run `30174843845` @ `f7cfe95` is **green on all six matrix cells** (ubuntu/macos/windows ×
3.9/3.13) — verified live via `gh run view`, not from a document. Python 3.9 compatibility
independently re-derived here: `~/.pyenv/versions/3.9.24/bin/python3.9 -m compileall scripts
tests` is clean, and all 12 Python suites pass under that interpreter.

The one apparent GNU-ism, `self-learning-health.sh:292` `stat -c %Y`, carries a BSD fallback
(`|| stat -f %m || echo 0`) — portable. `lib/config.sh` documents and implements a portable
replacement for GNU `date -d`; `lib/list-transcripts.py` exists specifically to replace a
`find | stat | sort` pipeline whose flags differ GNU-vs-BSD.

Note for the record: the ledger (line 48) predicted `self-learning-health.sh:171 stat -c %Y`
would break macOS CI. It did not, because the line acquired a `stat -f` fallback. The ledger's
prediction is stale; the tree is correct.

### GC3 — No Copilot/VS Code code path may reference `~/.claude`, the `claude` binary, or `CLAUDE.md` — **DONE**

`grep -rn '\.claude' scripts/copilot-session-review.sh scripts/lib/copilot-hook-input.sh
config/copilot-hooks.json` → **no matches**. `config/copilot-hooks.json` now ships the
`__SL_SCRIPTS_DIR__` placeholder, not a literal path. `tests/test-claude-absent.sh` (109 lines)
is the executable guard and passes in the full-suite run below.

The `~/.claude` strings that *do* remain are the three the plan itself ruled legitimate:
`config/settings-hooks.json` (Claude Code's own adapter config), `index-session.sh`'s
`SESSIONS_DIR` (Claude Code's transcript **source**), and `self-learning-health.sh`'s
`SETTINGS_FILE`. Task 7c's text explicitly protects the latter two.

### GC4 — Paths computed in exactly one place (`scripts/lib/paths.py`) — **DONE DIFFERENTLY**

Two bash sites now know something about resolution order:

- `scripts/lib/config.sh:60-94` — `_sl_fallback_home()`, a literal
  `AGENT_LEARNING_HOME > XDG_DATA_HOME/agent-learning > $HOME/.local/share/agent-learning` chain
  used **only when `python3` is unavailable** (commit `384a319`). It deliberately omits the
  `LOCALAPPDATA` branch and is documented in-file as a fallback, not a reimplementation.
- `scripts/doctor.sh:71-76` — re-tests the same env vars purely to *print* which override is in
  effect ("override source: AGENT_LEARNING_HOME"). It does not compute a path.

**Judgement: net improvement, with a small honest cost.** The plan's strict reading would have
had `config.sh` silently resolve `SL_HOME` to empty string on a python3-less box — reintroducing
the exact "component runs fine at the wrong location" failure this branch exists to eliminate.
The cost is real: bash and Python can now disagree on Windows when python3 is missing (bash
would pick `$HOME/.local/share`, Python `%LOCALAPPDATA%`). That divergence is undocumented in
the plan and is listed under Open Items.

### GC5 — Reviewer agent must not be granted file-write tools — **PARTIAL**

- Copilot path: **enforced mechanically.** `copilot-session-review.sh:103` is
  `COPILOT_ARGS=(-s --allow-tool read)`; `--allow-tool write` is gone. The Task 6 test kills the
  build if `write` reappears in argv.
- Claude Code path: **enforced by prompt only.** `session-review.sh:178-198` spawns
  `claude -p "$REVIEW_PROMPT" --max-turns N --output-format text` with **no `--allowedTools` /
  `--disallowedTools`**. The background reviewer therefore still holds Claude Code's default tool
  set, including Write/Edit. The only thing stopping it writing is the prompt's "Do NOT write,
  create, or edit any file."

This matches the plan's own spawn snippet verbatim — the plan is at fault, not the implementer.
But the constraint as written ("must not be **granted**") is not met on the Claude path. The
consequence is bounded (persist-proposal.py is still the only thing anything downstream reads,
so a rogue write is inert rather than dangerous) but it is a live prompt-injection surface: a
poisoned transcript could steer the reviewer into writing outside the store, and nothing would
catch it. Closing it is a one-line `--disallowedTools "Write Edit NotebookEdit"` plus an argv
assertion in `test-session-review.sh`, mirroring what the Copilot side already has.

### GC6 — Existing test style (standalone scripts, `check()`, `FAILURES`, `env -i`, `exit 1`) — **DONE**

All 29 shell suites follow the convention. Verified by reading `test-claude-absent.sh`,
`test-install-paths.sh`, `test-script-paths.sh`, `test-doctor.sh`.

### GC7 — Backward compatibility: `~/.claude` installs keep working, told how to migrate, never silently relocated — **DONE**

`paths.legacy_home()` detects but never moves. `doctor.sh` prints
`*** legacy ~/.claude store found ***` with an explicit, user-run `cp -r` migration command and
the words "nothing has been moved or modified". Verified live in Gate 4 below against the user's
genuinely populated `~/.claude`: detected, reported, **byte-identical fingerprint before and
after**. `uninstall.sh` was extended (+54 lines) to clean both the resolved and the legacy script
locations. `CLAUDE_REVIEW_ENABLED` still honoured with a deprecation warning on stderr
(`config.sh:132-136`).

### GC8 — Every task ends with a commit, conventional prefixes — **DONE**

All 73 commits carry `feat:`/`fix:`/`test:`/`ci:`/`docs:` prefixes. Verified from `git log`.

---

## 2. File Structure — Create list

All 11 planned files exist. Line counts are from the tree; the delta against the plan's inline
source is the story.

| Planned file | Status | Evidence |
|---|---|---|
| `scripts/lib/paths.py` | **DONE DIFFERENTLY** | 248 lines vs. the plan's ~100. Gained a `scripts` key (Task 7b), Windows/MSYS path-form handling, LF-only stdout (`07ed30e`). Superset of the contract. |
| `scripts/lib/proposal_schema.py` | **DONE DIFFERENTLY** | 173 lines. Plan's spec is present *plus* `MAX_INPUT_BYTES`, `MAX_MEMORY_ENTRIES=4`, `\A...\Z` anchors (the plan's `^...$` was a real trailing-newline bypass), NUL rejection, Windows reserved-name rejection, and a linear `str.find` fence scanner replacing a regex with quadratic backtracking (26.1s → 0.00078s, `0a0ae8f`). **The plan's code was insecure; the deviation is a straight improvement.** |
| `scripts/persist-proposal.py` | **DONE DIFFERENTLY** | 883 lines vs. the plan's ~95. See §4 Task 4. |
| `scripts/doctor.sh` | **DONE DIFFERENTLY** | 460 lines vs. ~60. Superset; see §4 Task 9. |
| `tests/test-paths.py` | **DONE** | 308 lines, 10 planned cases plus the `scripts`-key override chain. |
| `tests/test-proposal-schema.py` | **DONE** | 359 lines, **53** tests vs. the plan's 18. |
| `tests/test-persist-proposal.py` | **DONE** | 607 lines, **26** tests vs. the plan's 7, with functional capability probes for symlink/hardlink/`O_NOFOLLOW`/`dir_fd` rather than platform-name guessing. |
| `tests/test-claude-absent.sh` | **DONE** | 109 lines; extended per Task 7b to assert the shipped hook template contains no `~/.claude`. |
| `tests/run-all.sh` | **DONE DIFFERENTLY** | 208 lines vs. the plan's 20. Glob discovery, per-suite timeout with `gtimeout`/`timeout` feature detection, process-group orphan sweep, summary line. |
| `tests/test-install-paths.sh` | **DONE** | 280 lines. |
| `.github/workflows/ci.yml` | **DONE** | 78 lines, 3-OS × 2-Python exactly as specified, plus jq/sqlite provisioning steps the plan omitted. |

Also created and named by the plan mid-flight: `tests/test-script-paths.sh` (375 lines, Task 7c).

## 3. File Structure — Modify list

`git diff --stat befd131..HEAD` confirms every file on the Modify list was genuinely touched:

| File | Lines changed | Status |
|---|---|---|
| `scripts/lib/config.sh` | +217 | **DONE** — delegates to `paths.py all`, `${HOME}/.claude` defaults gone, `SL_REVIEW_ENABLED` added with legacy fallback and export. |
| `scripts/session-review.sh` | +118 | **DONE** — OUTPUT CONTRACT at line 103, detached pipeline into `persist-proposal.py` at 178-198. |
| `scripts/copilot-session-review.sh` | +94 | **DONE** — same inversion, `--allow-tool write` removed. |
| `config/settings-hooks.json` | +7 | **DONE** — `env` block is exactly the five `SL_*` keys the plan specified; all eight dead `CLAUDE_REVIEW_*` entries gone. Verified by parsing the JSON. |

The plan listed `scripts/lib/hook-input.sh` and `scripts/coach-signals.py` as **"unchanged but
load-bearing."** Both were in fact modified (+11 and +53). This is **DONE DIFFERENTLY** and worth
naming: the plan asserted stability it did not get. `hook-input.sh` gained the shared
`stdin-safe.sh` handling; `coach-signals.py` was touched by the P5 Coach widening. Neither change
is unreasonable, but both are unreviewed against a plan section that said they would not move.

Also modified without appearing on the Modify list (all justified by Tasks 7b/7c or later
rounds): `install.sh` (+195), `uninstall.sh` (+54), `install.ps1`, `uninstall.ps1`,
`config/copilot-hooks.json`, `scripts/self-learning-health.sh` (+216), `scripts/curator-run.sh`
(+104), `scripts/index-session.sh` (+110), `scripts/skill-lifecycle.py` (+189),
`scripts/coach-rules-eval.py` (+645), `scripts/inject-agents-md.py`, `scripts/index-session.py`,
`scripts/turn-counter.sh`, `schema/*.sql`, `README.md`, `CLAUDE.md`.

---

## 4. Tasks

### Task 1 — Path resolver — **DONE**

`resolve_home` / `resolve_all` / `legacy_home` / CLI `get`|`all` all present with the exact key
set the plan named, plus `scripts` (Task 7b). `tests/test-paths.py` passes.
*Ledger-vs-tree note:* the ledger recorded a deferred minor — "`resolve_home` returns a
CWD-relative path when HOME unset". Not re-derived in this session; carried to Open Items rather
than asserted closed.

### Task 2 — config.sh delegates; env cleanup — **DONE**

All five planned test assertions exist in `tests/test-config.sh` (now 327 lines) and pass. The
plan's own note about updating the pre-existing `"$HOME/.claude"` expectation was followed.

### Task 3 — Proposal schema and validator — **DONE DIFFERENTLY (improvement)**

Delivered as specified and then hardened well past it. Eight schema bypasses found adversarially
in the plan's own code were fixed in `0fa15f5`, and the ReDoS in the plan's `_FENCE_RE` in
`0a0ae8f`. Test count 18 → 53. **This is a case where the plan was concretely wrong and the tree
is right.**

### Task 4 — Secure writer — **DONE DIFFERENTLY (improvement)**

The plan's `_assert_inside()` is a resolve-then-open check — a textbook TOCTOU. The delivered
writer (883 lines) instead anchors every write on `dir_fd` with `O_NOFOLLOW` (`c24c977`), holds a
cross-process store lock (`0bb6c88`), uses `os.replace` not `Path.rename` (`e890fd6`), and writes
mode 0600.

**One deliberate contract change:** the plan specified skills written flat as
`learned-skills/<name>.md`. The tree writes `learned-skills/<name>/SKILL.md` plus a shared
`.usage.json` and `.archive/` (`4432883`, later single-sourced into `scripts/lib/skill_layout.py`
by `39de89e`). **The plan was wrong** — every reader in this repo (`skill-lifecycle.py`,
`inject-agents-md.py`, `curator-run.sh`, `self-learning-health.sh`) requires `<name>/SKILL.md`,
so the plan-specified writer would have burned a paid model call, written a file, and produced
something nothing downstream could ever see. This is the single most consequential correction on
the branch and it is a clear improvement.

### Task 5 — Invert the Claude Code reviewer — **DONE DIFFERENTLY**

Delivered, with two corrections to the plan's snippet:
1. The plan's spawn **dropped `--max-turns`**, orphaning `SL_REVIEW_MAX_TURNS` and leaving the
   background reviewer's model loop unbounded. Restored in `1085b6a`, along with
   `--output-format text` (load-bearing: without it the proposal is nested inside a JSON
   envelope and extraction breaks).
2. A `.review-complete` marker was added as the pipeline's last statement, because the plan's
   "poll for the target file" pattern raced teardown on macOS CI.

Both are strengthenings. See GC5 for the one thing this task did *not* get right.

### Task 6 — Invert the Copilot reviewer — **DONE**

`--allow-tool write` removed, OUTPUT CONTRACT installed, positional-argument scheme preserved,
model-string regex kept intact. `tests/test-copilot-session-review.sh` (+158) passes.

**Known gap the plan never considered:** Copilot CLI has **no hard turn cap** for headless `-p`
runs (`--max-autopilot-continues` is interactive-only). `SL_REVIEW_MAX_TURNS` is deliberately not
force-mapped. `grep -rn 'max-ai-credits\|SL_COPILOT_MAX' scripts/ config/ README.md` → **no
matches**, so the recommended `--max-ai-credits` knob was never built. The Copilot reviewer
therefore has **no cost ceiling** while the Claude reviewer does. See Open Items.

### Task 7 — Claude-absent regression guard — **DONE**

`tests/test-claude-absent.sh` exists, is executable, is discovered by `run-all.sh`, and passes.

### Task 7b — Harness-neutral install paths — **DONE**

`scripts` key added to `paths.py`; `config/copilot-hooks.json` is a `__SL_SCRIPTS_DIR__`
template; `install.sh` reads `paths.py all` once; `uninstall.sh` cleans both locations;
`tests/test-install-paths.sh` (280 lines) asserts no `${HOME}/.claude` is created. Passing.

A structural fix landed here that the plan did not ask for and should have: `install.sh` now
copies `lib/` by loop rather than by hand-list (`install.sh:251-253`), after the same
"new file never added to install.sh" defect bit twice — `persist-proposal.py` +
`proposal_schema.py` in 7b, then `doctor.sh` in Task 9.

### Task 7c — Three scripts still hardcode the store path — **DONE**

`self-learning-health.sh`, `curator-run.sh`, `index-session.sh` all resolve through `config.sh`
now. The two legitimate `~/.claude` references the plan protected (`SESSIONS_DIR`,
`SETTINGS_FILE`) are intact. `tests/test-script-paths.sh` passes.

*Honest caveat carried from the ledger and not re-derived here:* the exit-code-only assertion in
that suite is individually vacuous, backstopped by content assertions in the same run.

### Task 8 — Test runner and 3-OS CI — **DONE**

`tests/run-all.sh` discovers by glob and passes; `.github/workflows/ci.yml` is the exact
3×2 matrix. Green on all six cells at HEAD.

### Task 9 — `doctor` — **DONE DIFFERENTLY (improvement)**

All plan-specified output present. Beyond it: `--strict` mode (`1732afc`), harness hook-freshness
verdicts unified with `self-learning-health.sh`, `dir_fd`/lock-backend status, `persist.log`
outcome summary, and an explicit "ABSENT — absence alone is not proof of health" disclaimer on
the failures log. Live output reproduced in Gate 4 below.

### Task 10 — Documentation — **DONE**

`README.md` (+214) and `CLAUDE.md` (+71) both rewritten. Storage-resolution order, migration
note, `CLAUDE_REVIEW_ENABLED` deprecation, and a compatibility table tied to actual test coverage
are all present. Notably, the implementer **refused to propagate a wrong "34 merged commits"
figure** from the handoff doc — exactly the behaviour this branch's history demands.

---

## 5. Verification Gate — re-run in this session

| # | Gate item | Result |
|---|---|---|
| 1 | `bash tests/run-all.sh` passes locally | **PASS.** Executed. `Discovered 41 suite(s): 29 shell, 12 python. Ran 41. All 41 suites passed.` The "41 suites" figure in `CLAUDE.md` is confirmed correct. |
| 2 | `bash tests/test-claude-absent.sh` passes | **PASS**, within the run above. |
| 3 | All six CI matrix jobs green | **PASS.** `gh run view 30174843845` @ `f7cfe95` (= HEAD): ubuntu 3.9 ✓, ubuntu 3.13 ✓, macos 3.9 ✓, macos 3.13 ✓, windows 3.9 ✓, windows 3.13 ✓. |
| 4 | `doctor.sh` on a machine with an existing `~/.claude` reports the legacy path and moves nothing | **PASS.** Run with **real `HOME`** and `AGENT_LEARNING_HOME` at a temp dir. Output: `*** legacy ~/.claude store found: /home/amardeep/.claude ***` + `nothing has been moved or modified`. `find $HOME/.claude -printf '%p %s %T@'` fingerprint identical before and after (`18e4dcfe…`). The writability probe created directories only under the temp store. |
| 5 | `grep -rn 'claude' scripts/copilot-session-review.sh scripts/persist-proposal.py scripts/lib/paths.py` shows no binary invocation and no `~/.claude` default | **PASS.** Three hits, all in `paths.py`, all in the `legacy_home()` detector and its docstring — which is the plan's own required feature, not a default. Zero hits in the other two files. |
| 6 | Manual live check on Copilot CLI: real session, file under the resolved memory directory | **PARTIAL.** Commit `f28b824` records a real run against `copilot` 1.0.73 with a real paid model call: the hook script ran end-to-end and the writer accepted a well-formed empty proposal, and the same OUTPUT CONTRACT with a transcript produced a conforming proposal that persisted real content at mode 0600. **Not verified by me** (would cost a paid call). The residual, disclosed in the commit itself: no *genuine interactive* Copilot session has fired `sessionEnd` with real conversation history in the payload. |

**Gate verdict: 5 of 6 fully passing; item 6 substantively satisfied with a disclosed residual
that only day-to-day use can close.**

---

## 6. Out of Scope — deliberately deferred by the plan, NOT gaps

The plan's Out-of-Scope list names: session-source adapters · VS Code hook spike and adapter ·
Copilot `postToolUse` turn counting · measurement (usage reader, continuous holdout, reporting
norms) · failure-triggered review · install UX, install manifest, manifest-driven uninstall ·
deep security audit · all `graphify-offline` work.

Status of each in the tree:

| Deferred item | Status |
|---|---|
| Session-source adapters (Copilot `session-store.db`, Claude JSONL) | **BUILT ANYWAY** — see §7. This is the largest scope breach on the branch. |
| VS Code hook spike / adapter | Correctly absent. `doctor.sh` reports VS Code as detected-but-unsupported. |
| Copilot `postToolUse` turn counting | Correctly absent. |
| Measurement (usage reader, holdout, reporting norms) | Correctly absent. |
| Failure-triggered review | Correctly absent. |
| Install UX / manifest / manifest-driven uninstall | Correctly absent — `install.sh` was hardened but no manifest exists. |
| Deep security audit | **BUILT ANYWAY** — `tests/test-adversarial-sweep.py` (828 lines) codifies a full adversarial sweep. |
| `graphify-offline` work | Correctly absent. |

---

## 7. Delivered beyond the plan

Roughly **20,000 of the branch's ~25,500 added lines are outside the agreement.** Enumerated so
the true delivered scope is visible next to the agreed scope:

**New production modules never in the plan (~1,700 lines):**
- `scripts/lib/transcript.py` (468) + `scripts/lib/list-transcripts.py` (105) — the P0/P0b fix.
  Both reviewers were spawned with **no session transcript at all**: `copilot-session-review.sh`
  never read stdin, so the hook learned only a session id, and the Claude path had the identical
  defect. Every review before `7cf4782` was a paid model call that could not, by construction,
  learn anything. Fixing it required parsing `~/.copilot/session-state/<id>/events.jsonl` and
  `~/.claude/projects/<slug>/<id>.jsonl` — i.e. **the session-source adapters the plan explicitly
  deferred.**
- `scripts/lib/store_lock.py` (444) + `scripts/lib/store-lock.sh` (49) — cross-process `flock`
  serialisation, after a lost-update race was found in concurrent append (P7), then extended so
  `skill-lifecycle.py` and `curator-run.sh` take the same lock (P8).
- `scripts/lib/session_db.py` (241) — replaces `sqlite3` CLI schema init, which had no FTS5 on
  macOS runners.
- `scripts/lib/skill_layout.py` (87) + `skill-layout.sh` (48) — single-sources the five-way
  re-typed skill layout.
- `scripts/lib/isotime.py` (99), `copilot-hook-input.sh` (37), `stdin-safe.sh` (19),
  `find-bash.ps1` (88).

**Coach DSL widening:** `scripts/coach-rules-eval.py` +645 lines, taking adapted rule coverage
from **1/45 to 11/45** (`85b6f21`). Pinned by `EXPECTED_EVALUATED = 11` /
`EXPECTED_TOTAL_RULES = 45` in `tests/test-coach-rules-eval.py:524`, which passes.

**Test suites never in the plan (~5,000 lines, 21 new suites):** `test-adversarial-sweep.py`
(828), `test-transcript.py` (635), `test-persist-concurrency.py` (368), `test-store-lock-writers.py`
(423), `test-session-db.py`, `test-isotime.py`, `test-list-transcripts.py`,
`test-e2e-skill-visibility.sh`, `test-skill-layout-pinning.sh`, `test-ps1-wrappers.sh`,
`test-review-cli-flags.sh`, `test-line-endings.sh`, `test-path-compare-lib.sh`,
`test-index-session-fts5-fallback.sh`, `test-doctor-strict.sh`, `test-doctor-no-python.sh`,
`test-doctor-persist-log.sh`, `test-health-*.sh` ×3, `test-copilot-hook-input.sh`, plus
`tests/lib/` helpers.

**Eleven post-plan fix rounds:** A, B, C, D, E, F and P0–P9 — hook-freshness, Windows path
handling in `python3 -c` strings, LF-only stdout, `pty` probing instead of a `termios` import
crash, PowerShell wrapper delegation guards, macOS teardown races, a flaky clock-tick round-trip
window, `os.replace` portability, and a repaired PowerShell syntax checker that had itself been
the parse error.

**Assessment of the overshoot.** Most of it is not gold-plating — P0 in particular fixed a defect
that made the branch's entire reason for existing moot, and finding it was worth more than the
plan. But three things deserve to be said plainly:

1. **The scope breach is real and was never re-agreed.** ~1,700 lines of new production code plus
   ~5,000 lines of tests entered the branch through fix rounds, not through an amended plan. Tasks
   7b and 7c were properly written into the plan file before execution (`44209dc`, `612816e`);
   **P0–P9 were not.** The plan file has no record of them.
2. **`transcript.py` parses two undocumented third-party on-disk formats.** Its own docstring
   admits the schema was "verified against the real event schema written by Copilot CLI 1.0.75"
   — i.e. reverse-engineered, and unversioned. A Copilot or Claude Code update can silently break
   session digestion, and the failure mode would be the branch's signature one: a review that
   runs, exits 0, and learns nothing. This is exactly the class of dependency the plan deferred
   for a reason.
3. **The Coach widening (P5, +645 lines) is unrelated to harness-neutral persistence.** It is
   good work in the wrong branch, and it inflates the review surface of a PR that is already
   large.

---

## 8. Open Items

### Agreed-but-undelivered (debt against the contract)

| Item | Why open | Cost to close |
|---|---|---|
| **GC5: Claude Code reviewer holds write tools** | The plan's own spawn snippet omitted any tool restriction, so it was never implemented. Enforced by prompt only. Live prompt-injection surface, though inert downstream. | ~1 line: `--disallowedTools "Write Edit NotebookEdit"` in `session-review.sh:180`, plus an argv assertion in `tests/test-session-review.sh` mirroring the Copilot side. Under an hour. |
| **GC4: bash/Python resolution can diverge on python3-less Windows** | The literal fallback in `config.sh` omits `LOCALAPPDATA` by design. Undocumented divergence. | Either add the `LOCALAPPDATA` branch to `_sl_fallback_home()`, or make the python3-less path fail loudly instead of guessing. ~2 hours with a test. |
| **Gate 6 residual: no genuine interactive Copilot session** | Requires ordinary day-to-day use; cannot be forced in a test harness. | Zero engineering; days of real usage, then re-read the resolved memory dir. |

### Discovered-later-and-deferred (debt the plan never anticipated)

| Item | Why open | Cost to close |
|---|---|---|
| **Copilot reviewer has no cost ceiling** | Copilot CLI's `--max-autopilot-continues` is interactive-only; `--max-ai-credits` (min 30) was identified as the right knob but never wired. Confirmed absent from the tree. Asymmetric with the Claude path's `--max-turns`. Financial exposure on a background loop. | New `SL_COPILOT_MAX_AI_CREDITS` knob, default 30, wired into `COPILOT_ARGS`, plus an argv test. Half a day. |
| **Windows TOCTOU residual** | `dir_fd` and `O_NOFOLLOW` are POSIX-only; the stdlib offers no Windows equivalent. Accepted residual, disclosed in the module docstring and probed by `doctor.sh`. | Not closable stdlib-only. Would need a Windows-specific reimplementation. |
| **34/45 Coach rules unreachable by the adapted evaluator** | The vendored rule DSL exceeds what the port supports. Pinned and documented, not hidden. | Incremental; each rule family is its own increment. |
| **`self-learning-health.sh` does not check Copilot's hook config** | Only `doctor.sh` does. The two tools now agree on Claude hooks but health is blind to Copilot. | Reuse `sl_check_hook_fresh()`. ~2 hours. |
| **`sl_check_hook_fresh` uses an unanchored `grep -qF`** | A hook pointing at `<script>.bak` reads as fresh. Both tools share the bug, so they still *agree* — which is why no test caught it. | Anchor the match. ~1 hour. |
| **`resolve_home` returns a CWD-relative path when `HOME` is unset** | Ledger-recorded Task 1 minor; **not re-derived in this audit** — recorded as believed-open, not asserted. | Raise instead of returning. ~1 hour. |
| **`index-session.sh` `-newer` can miss pre-existing transcripts on first run** | Pre-existing staleness bug; partially addressed by `0798ef0` but not verified closed here. | Needs a fresh-store first-run test; `tests/test-index-session-first-run.sh` exists — verify it actually covers this. |
| **P0–P9 rounds are absent from the plan file** | Process debt: the plan is now an incomplete record of the branch. Tasks 7b/7c set the right precedent and it was abandoned. | Append P0–P9 sections to the plan, or accept `progress.md` + this audit as the record. |

---

## 9. What the plan got wrong

Recorded explicitly, because the plan is still cited as the contract and parts of it are now
actively misleading:

1. **The skill write path is wrong.** Task 4's `learned-skills/<name>.md` is incompatible with
   every reader in the repo. Anyone re-implementing from the plan text reintroduces a Critical.
   Superseded by `scripts/lib/skill_layout.py`.
2. **`proposal_schema.py`'s `_FENCE_RE` has quadratic backtracking**, and `^…$` in `SKILL_NAME_RE`
   permits a trailing-newline bypass. Both are in the plan verbatim. Fixed in the tree.
3. **`_assert_inside()` is a TOCTOU.** Resolve-then-open. Replaced by `dir_fd`-anchored writes.
4. **Task 5's spawn drops `--max-turns`**, leaving a background paid model loop unbounded, and
   omits `--output-format text`, which silently breaks proposal extraction.
5. **Task 5/6's "poll for the target file" pattern races the detached pipeline** on macOS. A file
   appearing means a write *started*, not that the pipeline finished. Replaced by an explicit
   `.review-complete` marker.
6. **"Unchanged but load-bearing: `hook-input.sh`, `coach-signals.py`"** — both changed.
7. **The Out-of-Scope deferral of session-source adapters was untenable.** Deferring them meant
   shipping a review loop whose reviewer sees nothing. The plan could not have delivered its own
   Goal without them; the deferral should have been caught at planning time.
8. **`tests/run-all.sh`'s 20-line form has no timeouts and no orphan reaping**, so one hung suite
   would hang CI indefinitely.
