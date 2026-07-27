# Final whole-branch audit — `harness-neutral-persistence`

Date: 2026-07-25 (session start commit `c1f8a6a`, ended at commits below).
Auditor: fresh session, no prior context beyond the brief. Every claim below was executed
and observed unless explicitly marked "reasoned-only" or "not executed."

## Scope note on concurrency

Another agent was mid-edit on `tests/test-config.sh` at the start of this session (fixing a
flaky zero-tolerance timestamp round-trip assertion: `BEFORE_EPOCH` was sampled after `WRITTEN`
via a separate `date` spawn, and the window had zero width). That work landed as
`9c8c973`/`ccf8f2f` before I made any edits. I did not touch `tests/test-config.sh`,
`tests/test-transcript.py`, or `tests/test-isotime.py` — no fix in this report required
touching them, and the coordinator's sweep already confirmed no other test has the same
zero-tolerance pattern.

## PHASE 1 — Fresh audit findings

### 1. `scripts/persist-proposal.py` + `scripts/lib/proposal_schema.py` (trust boundary)

Command: `bash tests/run-all.sh` and `~/.pyenv/versions/3.9.24/bin/python3.9 tests/test-*.py`
(each individually, since `run-all.sh` uses `python3` off PATH, not the CI-pinned 3.9
interpreter). Result: all 10 Python suites pass under actual 3.9.24, including
`test-adversarial-sweep.py` (95 attacks executed, floor 55; 1 attack loudly skipped —
case-collision, correctly detected as inapplicable on this case-sensitive filesystem via a
functional probe, not a platform-name branch). TOCTOU probe: `dir_fd=supported 0/40 (0%)
iterations escaped the store under active symlink-swap contention` — re-measured live, matches
the fix-round-P3 claim.

I read the full 820-line `persist-proposal.py` and 173-line `proposal_schema.py` end to end.
The design is sound: allow-listed filenames, slash-free skill-name regex, exact byte caps,
all-or-nothing validation, stage-then-atomic-rename writes, dir_fd-anchored O_NOFOLLOW writes
on POSIX with a disclosed path-based fallback on Windows.

I then ran independent attacks not in the suite:

- Skill name length boundary (64 chars accepted, 65 rejected) — correct, matches
  `SKILL_NAME_RE`'s `{0,63}` after the first required char.
- A skill named `persist-tmp-` (colliding textually, but not exactly, with the internal
  `.persist-tmp-<hex>` temp-file prefix) — writes cleanly, no collision (leading dot
  distinguishes them; temp names are files, this is a directory).

**New finding — concurrent-append lost-update race (not previously documented anywhere on
this branch):**

Command (reproduced 3 times):
```
echo "seed" > $STORE/memory/MEMORY.md
for i in 1..20: printf '{"version":1,"memory":[{"file":"MEMORY.md","mode":"append","content":"entry-$i\n"}],"skills":[]}' | python3 scripts/persist-proposal.py &
wait
wc -l $STORE/memory/MEMORY.md
```
Expected 21 lines (seed + 20 appends) if every proposal's append survived. Observed: **20,
21, then 18** lines across three trials — i.e. up to 3 of 20 concurrent appends silently
lost, with **every individual `persist-proposal.py` invocation exiting 0 and reporting success**
(`{"written": [...], "skipped": [], "bytes": N}`) regardless of whether its append actually
survived the final on-disk state.

Root cause: `_write_all_path`/`_write_all_fd` each do read-existing → concatenate → stage →
rename, but there is no lock across the whole read-modify-write cycle spanning two separate
OS processes. Two concurrent `persist-proposal.py` invocations can both read the same "before"
content, both append their own line to it, and the later `os.replace()` wins — the earlier
process's line is gone, even though it already printed a success JSON line claiming it was
written. This is real concurrent, non-adversarial use, not an attacker: two harnesses'
Stop/sessionEnd hooks (Claude Code and Copilot CLI) can plausibly fire review pipelines within
seconds of each other if a user runs both in parallel terminals against the same store, or two
Claude Code sessions in different terminals both end near-simultaneously.

This is squarely in the "component reports success while something is broken" pattern this
branch has been asked to hunt for — arguably the **twelfth instance**, distinct from the
eleven already fixed because the failure mode here is data loss under legitimate concurrency,
not a hostile proposal or a wiring gap.

**Disposition: documented as an open finding requiring a decision, not fixed in this session.**
Reason: this is the single most heavily hardened, most recently re-reviewed file on the branch
(TOCTOU-fixed twice already). A real fix needs a cross-process lock around the whole
read-modify-write span (e.g. `fcntl.flock`/`msvcrt.locking` on the target file or a lock file
in the store directory, held across `_read_existing`→`_stage`→`os.replace` for append-mode
entries specifically), which is new design surface in the write path, not a small patch — and
this session's remaining budget did not allow implementing and adversarially re-testing a
change to this file with the rigor the rest of it has already received. Recommend a dedicated
fix round (P7) scoped to this alone, with its own adversarial-sweep additions for concurrent
legitimate writers (as distinct from the existing hostile-single-writer sweep). Replace-mode
entries (skills, and memory in "replace" mode) are NOT subject to this race in the same way —
last-write-wins is the correct, expected semantics for a replace; only *append*'s
read-then-write span is vulnerable to a lost update.

### 2. Six new library modules

Read all of: `isotime.py`, `transcript.py`, `skill_layout.py`, `skill-layout.sh`,
`session_db.py`, `list-transcripts.py`, `stdin-safe.sh`, `copilot-hook-input.sh`.

- `transcript.py` (468 lines): parses untrusted Copilot `events.jsonl` and Claude Code
  transcript JSONL. Size cap confirmed: `MAX_DIGEST_CHARS = 20_000`, oldest-first truncation
  (`build_digest`), single-oversized-message tail-truncation so one huge turn never empties the
  digest. Redaction confirmed: `redact_secrets()` reuses `scan-threats.py`'s
  `api_keys_and_tokens`/`jwt_tokens`/`private_keys_and_connection_strings` categories only —
  behavioral categories (prompt injection, exfiltration, shell injection) are deliberately left
  unredacted with a stated reason (the transcript is framed as untrusted data downstream, not
  instructions; stripping an injection attempt would hide that it was attempted). I verified
  both reviewer scripts actually call this with the right `--harness` flag
  (`grep -n "transcript.py" scripts/session-review.sh scripts/copilot-session-review.sh`):
  Claude uses `--harness claude "${HOOK_TRANSCRIPT_PATH}"`, Copilot uses the sessionId form —
  both wired, not another instance of "reviewer summarizes nothing."
- `scan-threats.py` (not previously listed as "new" but also unexamined this session): confirmed
  wired into `transcript.py` (secret redaction) and `self-learning-health.sh` (existence check);
  not itself a write-path gate — it's a detection/redaction tool, used correctly for its stated
  purpose.
- `skill_layout.py`/`skill-layout.sh`: single canonical source for skill-directory layout
  constants (`SKILL_MD_FILENAME`, `USAGE_FILENAME`), imported/sourced by every consumer I could
  find (`persist-proposal.py` imports the Python module directly). No literal duplication found
  in the files I checked.
- `isotime.py`: shared ISO-8601 parser/formatter, imported by `persist-proposal.py`,
  `skill-lifecycle.py`, `index-session.py`, `coach-signals.py` per the comments left in each
  call site.

### 3. Cross-task seam hunt (fifth instance)

I did not find a clear fifth seam distinct from the four already logged (two ISO parsers,
skill-layout literals in five places, opposite corrupt-`.usage.json` policies, reviewers vs.
their prompts) within this session's time budget. The concurrent-append race above is a
different *kind* of defect (not two files disagreeing on a fact, but a missing lock across one
file's own read-modify-write), so I am not counting it as a "seam." This should be read as
**not fully executed** — a targeted grep-and-diff sweep across every place a concept is
implemented twice (e.g. skill name validation: regex lives in `proposal_schema.py`; is it
re-validated identically anywhere else that touches skill directories, such as
`skill-lifecycle.py` or `curator-run.sh`?) was not completed. Flagging as an open item rather
than asserting the search was exhaustive.

### 4. Six never-examined scripts

- `scripts/skillopt-run.sh` — opt-in wrapper around an external `microsoft/SkillOpt` checkout.
  Guard paths (disabled / missing checkout / unconfirmed `run`) all exit 0 by explicit design,
  documented in its own header comment as intentional (`|| true` is the caller's job). Not
  wired into any hook path — confirmed via grep across `scripts/`, `prompts/`, `config/`; it is
  a standalone maintainer tool with its own test (`tests/test-skillopt-run.sh`). Not another
  instance of the exit-0 pattern: it correctly reports why it's a no-op instead of silently
  doing nothing while claiming success.
- `scripts/coach-export-read.py` — reads a Coach export JSON, returns `[]` + stderr note on
  any read/parse failure, exit 0. Confirmed wired into `coach-signals.py`
  (`run_route([sys.executable, ... "coach-export-read.py", ...])`), not dead code.
- `scripts/sync-coach-rules.sh` — maintainer-only vendoring tool (`gh`+`jq`, writes into the
  repo checkout's `vendor/coach-rules/`). Correctly exempted in `tests/test-install-paths.sh`
  with a stated reason ("never run from an installed store"). Uses `date -u +%Y-%m-%dT%H:%M:%SZ`
  (portable, not GNU-only) — fine for macOS.
- `install.ps1` / `uninstall.ps1` — thin wrappers that locate `bash` on PATH and delegate to
  `install.sh`/`uninstall.sh`. Logic is minimal and looks correct for the Git-for-Windows case
  (the repo-root path is passed as its own argv token to `bash.exe`, which Git Bash's MSYS path
  translation does handle). **One real, previously undocumented gap**: `Get-Command bash` will
  also match WSL's `C:\Windows\System32\bash.exe` launcher stub if a user has WSL installed and
  no separate Git-for-Windows bash on PATH. The script's own error message tells WSL users to
  run `bash install.sh` *from inside WSL* rather than through `install.ps1`, but the code has no
  branch to detect "this `bash` is the WSL launcher, not Git Bash" — it will proceed and hand
  the WSL launcher a Windows-style path (`C:\Users\...\install.sh`) as an argv token, which WSL's
  bash is not guaranteed to interpret the way Git Bash does. **Not executed** (no Windows/WSL
  host available in this sandbox) — this is reasoned-only. Recommend either detecting the WSL
  launcher specifically (e.g. checking `$bash.Source` for `System32`) and refusing with a
  pointed error, or leaving as documented-but-unverified since the existing error message already
  steers WSL users away from this path in the common case where Git-for-Windows bash isn't also
  present.
- `scripts/scan-threats.py` — read above; correctly wired as `transcript.py`'s redaction source
  and `self-learning-health.sh`'s existence check.

No new instance of "exits 0 while doing nothing" was found among these six scripts.

## PHASE 2 — Known-open list

| Item | Disposition |
|---|---|
| Windows TOCTOU residual (`dir_fd` POSIX-only) | **Accepted residual.** Re-confirmed: `os.supports_dir_fd`/`os.mkdir(..., dir_fd=...)` genuinely raise `NotImplementedError` on Windows per stdlib docs; nothing in the stdlib closes this. Disclosure (module docstring, `_write_all_path` docstring, `doctor.sh` probe) is adequate and was re-read; no better achievable stdlib-only fix exists. |
| `O_NOFOLLOW` POSIX-only | **Accepted residual**, correctly gated by a functional capability probe (confirmed in `test-persist-proposal.py`'s and `test-adversarial-sweep.py`'s own probe output: `[capability probe] O_NOFOLLOW: AVAILABLE` on this Linux runner). |
| 34/45 Coach rules unreachable | **Accepted residual**, verified the pinned count is enforced (`CoverageAssertionTest.EXPECTED_EVALUATED = 11`, `EXPECTED_TOTAL_RULES = 45`, `UNSUPPORTED_REASONS` has exactly 34 entries — counted directly via `len(m.UNSUPPORTED_REASONS)` → 34). README's "11/45" claim is accurate. |
| Four "don't wait for detached pipeline" cases | **Not independently re-audited this session** — time did not permit locating and re-judging the specific four cases; the brief's characterization ("wide-margin, documented") is taken on trust here, which is exactly the kind of unverified claim the brief warns against, so flagging explicitly as **not executed** rather than silently endorsing it. |
| Claude Stop-hook `transcript_path` live verification | **Correctly not attempted** — would require installing a probe hook into the user's real `~/.claude/settings.json`, which this session runs inside. Per the brief, this needs the user's explicit go-ahead. |
| Transient `run-all.sh` failure | Superseded by the concurrent agent's work: the actual flaky failure mode (zero-tolerance timestamp window in `tests/test-config.sh`) was found, mutation-tested, and fixed (`9c8c973`) before I touched anything. Confirmed the fix's own claim by re-running `bash tests/run-all.sh` after — 37/37 pass. |
| `self-learning-health.sh` / `doctor.sh` overlap | Confirmed both call the same `sl_check_hook_fresh()` from `scripts/lib/config.sh` (grepped both files), so hook-freshness answers cannot diverge between them. **Judgment: coherent as-is** — `doctor.sh` is the broader diagnostic (paths, writability probes, dir_fd status, legacy-store detection) while `self-learning-health.sh` is the narrower hook/install health check likely meant for a different consumer (e.g. a lighter-weight periodic check vs. an on-demand deep diagnostic). Not recommending a merge; the shared helper already prevents disagreement, which was the actual risk. |
| **New: concurrent-append lost-update race** | See Phase 1 §1 above. Documented, not fixed, recommended as a scoped follow-up (P7). |

## PHASE 3 — Documentation accuracy

- `README.md`: sqlite3-as-optional-diagnostic claim was already accurate (verified:
  `scripts/lib/session_db.py` and `scripts/index-session.py` both `import sqlite3` — the stdlib
  module, not a shell-out to a CLI; the CLI is only used by `self-learning-health.sh`'s DB
  check, which degrades to a warning per its own code). Coach "11/45" claim verified accurate
  (see table above). **Fixed stale claims**: suite count ("18 test suites (13 shell, 5 Python)"
  at line 268, three separate CI-run-id/count references citing `30157000235`/"28 suites") —
  actual count as of this session is 37 (27 shell, 10 Python, per `run-all.sh`'s own
  "Discovered 37 suite(s)" line), and the most recent CI run is `30167923350`, confirmed green
  on all six matrix cells by polling `gh run view` to completion during this session. Edited to
  cite the current run id/count and to explicitly tell readers not to trust a frozen number —
  check `bash tests/run-all.sh`'s own output or `gh run list` instead.
- `CLAUDE.md`: same stale `30157000235`/"28 suites" references in the branch-status banner and
  the roadmap table, fixed the same way. Also added a note that the branch was red repeatedly
  through the afternoon of 2026-07-25 before the final green run, since a reader trusting only
  "CI is green" without the run history would have an inaccurate picture of how stable that
  green state is.
- PR #2 body: was stale exactly as the brief described (claimed "18 suites" and "this PR is its
  first ever run; all six matrix cells were unverified", with a "Draft until CI reports" line
  even though the PR was already not-draft). Rewrote via `gh pr edit 2 --body-file` with
  accurate suite count (37), an honest CI history note (repeated red runs before the current
  green, verified against `gh run list --branch harness-neutral-persistence`), and did not touch
  draft/ready state or merge status.
- `docs/superpowers/plans/2026-07-25-harness-neutral-persistence.md`: **not edited.** Judgment:
  leave it historical with the ledger as the fuller record — this matches the brief's own
  framing that the ledger (tracked in git, and now including round-four's report) is the fuller
  record, and appending six-plus rounds' worth of summary into a plan file that already has a
  living pointer to that ledger risks becoming a second place the same facts can drift, which is
  the exact failure class (duplicated-and-diverging state) this branch has repeatedly hit.

## VERIFICATION GATE

1. `bash tests/run-all.sh` — **37/37 suites pass** (Linux, system `python3`). Re-run under
   `~/.pyenv/versions/3.9.24/bin/python3.9` per-suite for every Python test file — all 10 pass.
2. `bash tests/test-claude-absent.sh` — included in and passing as part of the 37-suite run.
3. CI — could not push (working in a worktree, per instructions). Observed via `gh`: the latest
   run on this branch, `30167923350` (triggered by the concurrent agent's `9c8c973`/`ccf8f2f`
   push), is **green on all six matrix cells**, polled to completion during this session
   (`ubuntu-latest`/`macos-latest`/`windows-latest` × Python `3.9`/`3.13`). Prior runs today
   (`30164684399` through `30167556385`) were red — mostly the macOS 3.13 timestamp flake, one
   run also showed Windows and macOS 3.9 failures together — all superseded by the fix rounds
   that landed before this session's edits.
4. `bash scripts/doctor.sh` against real `HOME` with `AGENT_LEARNING_HOME` pointed at a temp
   dir: reported `overall: HEALTHY`, correctly detected the real legacy `~/.claude` store
   ("*** legacy ~/.claude store found ***", "nothing has been moved or modified"), and correctly
   flagged that Claude Code hooks are not currently registered in this machine's real
   `~/.claude/settings.json` (accurate — not a bug, just this machine's actual state).
   Verified via a controlled before/after filesystem fingerprint
   (`find ~/.claude -printf '%p|%s|%T@\n' | sort`) taken immediately before and after the
   `doctor.sh` invocation: **zero diff — `~/.claude` was untouched.** (An earlier, looser
   attempt using `md5sum` over the whole 2.8 GB / 82k-file tree showed a spurious difference
   caused by this very session's own live Claude Code process writing its own transcript/state
   files between the two scans — not by `doctor.sh` — resolved by tightening the before/after
   window around the actual command.)
5. `grep -rn 'claude' scripts/copilot-session-review.sh scripts/persist-proposal.py
   scripts/lib/paths.py` — zero hits in `copilot-session-review.sh` or `persist-proposal.py`;
   three hits in `paths.py`, all in comments/docstring prose (the module docstring explaining
   *why* the store is vendor-neutral, and `legacy_home()`'s own docstring describing its
   detect-only purpose) — no binary invocation, no default path. Consistent with the brief's
   expectation.
6. Live Copilot check — not repeated, per instruction (already done twice with real paid model
   calls; documented in `README.md`/`CLAUDE.md`, not re-verified this session).

## Where this brief was wrong or imprecise

- The brief's Phase 2 table said the "transient run-all.sh failure" was "never reproduced" —
  by the time I started, the concurrent agent HAD found and fixed a real, reproducible cause
  (the zero-tolerance timestamp window), so that framing was already stale relative to
  same-day work. Not a brief error exactly, but worth noting the brief was written before that
  fix landed.
- The brief asked me to hunt for "a fifth" cross-task seam; I did not find one and did not
  complete an exhaustive sweep for it — see Phase 1 §3. Reporting this as incomplete rather
  than claiming either "none exists" or fabricating a fifth to satisfy the ask.

## Summary of session actions

- Read and independently attacked `persist-proposal.py`/`proposal_schema.py` beyond the
  existing 95-attack suite; found and reproduced (3/3 trials) a genuine concurrent-append
  lost-update race, not previously documented anywhere on this branch. Documented as an open
  finding, not fixed (see Phase 1 §1 for reasoning).
- Read and confirmed correct wiring for all six previously-unexamined scripts plus
  `transcript.py`; found one reasoned-only (not executed) Windows/WSL ambiguity in
  `install.ps1`/`uninstall.ps1`.
- Fixed stale suite-count and CI-run-id claims in `README.md` and `CLAUDE.md`.
- Rewrote PR #2's body to reflect 37 suites and real CI history; did not touch draft/merge state.
- Re-verified `doctor.sh` leaves a real, populated `~/.claude` untouched, via a tight
  before/after filesystem fingerprint around the actual invocation.
- Re-confirmed CI green on all six matrix cells for the latest run, by polling to completion.
- Did not modify `tests/test-config.sh`, `tests/test-transcript.py`, or `tests/test-isotime.py`
  (owned by the concurrent agent this session; confirmed clean and unmodified by me via
  `git status --porcelain`).
