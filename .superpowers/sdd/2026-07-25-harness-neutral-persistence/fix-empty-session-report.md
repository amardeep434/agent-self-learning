# fix-empty-session — benign empty sessions must not read as persistence failures

Date: 2026-07-26. Branch: `harness-neutral-persistence`.

Two defects reported from a real install, both fixed here.

---

## Defect 1 — a session with no conversation was reported as a persistence failure

`doctor` on the user's real store:

```
!!! 3 PERSISTENCE FAILURE(S) RECORDED -- most recent: 2026-07-26T17:26:48Z
overall: UNHEALTHY
```

All three lines were `copilot-session-review: transcript unavailable (events.jsonl
not found under ~/.copilot/session-state/<id>)` for sessions that never conversed.

### Why this mattered more than the symptom

`persist-failures.log` is the *only* channel that can surface a silently-failed
background review — the pipeline is detached, so its failures cannot reach a hook
exit code. Filling that channel with benign no-ops teaches the user to ignore it.
That is the original bug wearing the opposite costume, so the fix was weighted
toward "a log a user can trust", not "a quieter log".

## The discriminator

**Presence, in the session's own state dir, of either `events.jsonl` (the
transcript) or `session.db` (Copilot's per-session conversation DB).**
Neither present *and the state dir itself exists* ⇒ the session never took a
turn ⇒ benign. Implemented as `transcript.copilot_session_conversed()`.

Copilot creates the state dir, `checkpoints/`, `files/`, `research/` and
`workspace.yaml` at session **start**; it creates `events.jsonl` and `session.db`
only once a turn happens.

### Evidence (measured, whole corpus, read-only)

179 dirs under `~/.copilot/session-state/` at the time of investigation:

| population | count | `events.jsonl` | `session.db` |
|---|---|---|---|
| never conversed | 95 | absent | absent |
| conversed | 84 | present | present |

The two markers co-occurred **perfectly** — no dir had one without the other.
All 84 marker-bearing dirs yielded ≥1 user/assistant message through
`summarize_events()`; **zero** would be misclassified as empty.

### Rejected candidates, and the measurement that rejected each

- **`turns` / membership in the shared `~/.copilot/session-store.db`.** This was
  the reporter's leading hypothesis and **it is wrong**, in the dangerous
  direction. Cross-joining the corpus against that DB:

  | `events.jsonl` | in `sessions` table | `turns > 0` | dirs |
  |---|---|---|---|
  | absent | **yes** | no | **82** |
  | absent | no | no | 13 |
  | present | no | no | **13** |
  | present | yes | no | **1** |
  | present | yes | yes | 70 |

  So (a) 82 of the 95 empty sessions **do** appear in the `sessions` table —
  membership is not a signal at all; and (b) **14 sessions that genuinely
  conversed have `turns == 0` or no `turns` rows**. Keying on `turns` would have
  silently classified 14 real sessions as empty — restoring the original bug.
  It is also the expensive option: opening a shared, concurrently-written SQLite
  DB inside a hook with a <100ms budget.

  *This is the point where the reporter's read of the evidence was wrong; the
  conclusion (these sessions are benign) was right, the stated mechanism was not.*

- **`workspace.yaml` size / its `name:` key.** 18 of the 84 conversed sessions
  have no `name:` key. Size tracks `name:`, so it fails identically. Would
  misclassify real sessions as empty.
- **`checkpoints/index.md`.** Byte-identical (172 bytes) in both populations. No
  signal.

### Cost and safety

Two `stat()` calls inside the session's own directory. No shared state, no lock,
no DB handle. Biased safe: "conversed" if **either** marker exists, so
`session.db` present with `events.jsonl` missing — a genuinely lost transcript —
stays a loud failure.

## What changed

- `scripts/lib/transcript.py` — three-way outcome (`OUTCOME_OK`,
  `OUTCOME_FAILURE`, `OUTCOME_NO_CONVERSATION`) returned as a `TranscriptResult`
  NamedTuple; `copilot_session_conversed()`; new `--notice-log`; new
  `EXIT_NO_CONVERSATION = 20`. "No state dir at all" is still a **failure**, not
  benign — the dir is created at session start, so its absence means a wrong
  state root or an externally deleted session.
- `scripts/copilot-session-review.sh` — on exit 20, record and stop: no paid
  model call for a session with provably nothing in it (~53% of sessions). **The
  failure path is deliberately unchanged** — a real transcript failure still logs
  loudly *and* still spawns the review, so this fix cannot mask a failure by also
  suppressing its review.
- `scripts/doctor.sh` §5b — `no-conversation` lines are excluded from the
  no-proposal streak window (they would otherwise both dilute the 10-run window
  until real outcomes fell out of it, **and** break a genuine streak mid-run,
  silently disabling that check) and are counted and printed separately.

### Where the benign case is recorded, and why

`persist.log`, in persist-proposal.py's own line shape:

```json
{"bytes": 0, "component": "copilot-session-review", "reason": "not applicable -- session ended without a turn (…)", "skipped": ["no-conversation"], "timestamp": "…", "written": []}
```

Same file, same JSON envelope, distinct `skipped` value. It is not silent:
**"the hook never ran" leaves no line at all**, which is what keeps the two
distinguishable. It is deliberately *not* a `persist-failures.log` line and
deliberately *not* counted as `no-proposal`.

## The Claude Code path: checked, deliberately left loud

`build_claude_session_digest()` never returns `OUTCOME_NO_CONVERSATION`.
Copilot's `sessionEnd` fires for sessions that never took a turn; Claude's `Stop`
fires when the assistant finishes responding, so a conversation exists by
construction and there is no "dir created but never used" state. Verified against
the whole corpus on this machine: **369 of 369 real session transcripts** under
`~/.claude/projects/` yield ≥1 user/assistant message. (The 355 `agent-*.jsonl`
files that yield none are subagent sidechains, never passed to `Stop`; the 17
other zero-message files are `journal.jsonl`, not transcripts.) Adding an
"empty" class there on symmetry alone would invent a benign explanation for a
condition that has never been benign.

## Verification against the real corpus (read-only, no model calls)

Re-classifying every real session dir with the new code:

```
whole real corpus (181 dirs): {'no-conversation': 96, 'ok': 85}   # 0 failures
```

The three reported session ids now exit 20 and write a `persist.log` line, with
`persist-failures.log` untouched. The contrast session `025527be-…` still
produces a 1307-char digest.

## Mutation results

The property most at risk is "a genuine failure still lands in
`persist-failures.log`". Three mutations, each reverted after measuring:

| mutation | Python failures | shell failures |
|---|---|---|
| M1 `copilot_session_conversed` → always `False` (the dangerous loosening) | 3 | 2 |
| M2 discriminator drops `session.db`, keys on `events.jsonl` only | 3 | 2 |
| M3 `no-conversation` routed to `persist-failures.log` after all | 1 | 2 |
| (unmutated) | 0 | 0 |

M1/M2 are caught by `test_session_db_without_events_is_still_a_failure`,
`test_conversed_predicate_needs_only_one_marker`,
`test_genuine_failure_still_goes_to_failure_log_even_with_notice_log_set`, and
the shell mutation guard case 11. M3 is caught by
`test_empty_session_goes_to_notice_log_never_to_failure_log` and shell case 10.

`doctor` reporting healthy for a store whose only history is empty sessions is
pinned by `tests/test-doctor-persist-log.sh` case 5; cases 6 and 7 pin that the
new lines neither break nor pad the no-proposal streak (i.e. this change does not
silently disable the case-3 safeguard).

---

## Defect 2 — `install.sh` made an upgrade a silent no-op

`install.sh:338` printed `Already exists: …/self-learning.json (skipping)` for any
pre-existing Copilot hook file. A user upgrading from the pre-branch layout kept a
hook pointing at `~/.claude/scripts/self-learning/…`, re-ran the installer, was
told it succeeded, and got nothing. It had to be re-rendered by hand on the
reporter's machine. `grep -rln "Already exists" tests/` matched nothing.

### The decision

"Leave it alone" and "overwrite it" are both wrong as blanket rules, so Step 4b
now distinguishes four states:

| state | detection | action |
|---|---|---|
| up to date | byte-identical to what we would render | report, touch nothing |
| **ours, stale** | replacing every path in front of `copilot-session-review.sh` with the template placeholder reproduces the template verbatim | **re-render**, print old → new path. Nothing of the user's is in there to lose. |
| ours, edited | references our script but does not normalize to the template | re-render + timestamped `.bak-<UTC>` alongside, and say where it went |
| **not ours** | never mentions our script | **do not overwrite**; loud refusal at Step 4b *and* an `ACTION REQUIRED` block in the final summary, with the exact JSON to merge |

The normalization uses basic (not `-E`) `sed` for GNU/BSD/MSYS portability.
The final-summary repeat exists because Step 4b scrolls past on a normal install,
and "hook never registered" is otherwise indistinguishable from "working" until
sessions quietly stop being reviewed.

### Coverage

`tests/test-install-paths.sh` cases U1–U4 (a real, sandboxed `install.sh` run per
case, `env -i` + temp HOME + explicit `AGENT_LEARNING_HOME`). Mutation: restoring
the old `Already exists … (skipping)` branch fails **10** of them, including
U1's direct check that the stale path is gone from the rendered hook.

---

## Results

- 43 suites, all pass (`bash tests/run-all.sh` → `All 43 suites passed.`). Suite
  count unchanged; all new coverage went into existing suites.
- Python 3.9.24 (`~/.pyenv/versions/3.9.24/bin/python3.9`, absolute path): all 14
  Python suites exit 0. `tests/test-transcript.py` 61 tests OK.
- stdlib only; `from __future__ import annotations` already present in
  `transcript.py`; `typing.NamedTuple` is 3.9-safe.

## Only CI can confirm

- **Windows (Git Bash/MSYS).** `_normalize_copilot_hook`'s `sed` runs against a
  file install.sh itself wrote; CRLF has bitten this repo before
  (`paths.py` stdout, fix round E). The `==` comparison of a normalized file
  against the template is byte-exact, so a CRLF-vs-LF difference would show up as
  "ours, edited" (backup + re-render) rather than a wrong result — degraded, not
  incorrect — but the U2 "unchanged / up to date" assertion is the one to watch.
- **macOS `sed`/`date`.** `date -u +%Y%m%dT%H%M%SZ` for the `.bak` suffix and the
  basic-`sed` normalization are both POSIX, but this branch has been burned by
  GNU-only `date` usage before.
- The empty-session path is exercised in CI only through synthetic fixtures. The
  real-corpus numbers above come from one machine; another user's Copilot version
  could in principle create `session.db` eagerly at session start, which would
  make the discriminator conservative (empty sessions classified as failures
  again — the old behavior, loud) rather than unsafe (real failures silenced).
  That asymmetry was the point of the "either marker ⇒ conversed" bias.
- No genuine *interactive* Copilot session has yet fired `sessionEnd` through
  this new code path; that residual is unchanged from the branch-status note in
  `CLAUDE.md`.

---

# Addendum — the two windows-latest failures (CI run `30213545777`)

Ubuntu ×2 and macOS ×2 green; both Windows cells red. Both failures were in
work added by this round, on the one platform not runnable locally.

## 3 — `tests/test-install-paths.sh` U1/U2/U3: the *test* was wrong, not the installer

### The reported symptom

```
FAIL: U1: a stale Copilot hook is re-rendered, not silently skipped (expected 'yes', got 'no')
FAIL: U2: an already-correct hook is unchanged (expected '{ ...
FAIL: U3: a locally-edited hook is still repointed at the real store (expected 'yes', got 'no')
```

### Two hypotheses, and why the leading one is wrong

The coordinator's reading was that `got 'no'` means **no re-render happened**,
i.e. every state fell through to "not ours → refuse", with CRLF breaking the
byte comparisons — one cause explaining all three.

That is ruled out twice over:

1. **CRLF cannot be it.** `.gitattributes` already carries `*.json text eol=lf`,
   and `tests/test-line-endings.sh` pins that. The template checks out LF on
   windows-latest.
2. **The re-render demonstrably DID happen.** Under the "falls through to
   not-ours" theory these assertions must also fail — and every one of them
   **passed** on Windows:
   - U1 `the update is reported, not silent` (matches `UPDATED (was stale)`,
     printed *only* by the stale branch)
   - U1 `the stale path is gone from the hook`
   - U1 `the silent-skip branch is gone`
   - U2 `an already-correct hook is reported up to date`
   - U3 `the user's previous file is preserved as a .bak`
   - U3 `the backup location is printed`
   - all four U4 assertions

   The classifier reached the *right* branch every time. Exactly three
   assertions failed, and they are exactly the three that mention
   `${STORE}/scripts`.

### Actual cause

The MSYS path-form hazard **this same file already warns about**, twelve lines
above where the new block was added:

```
# -- RESOLVED_SCRIPTS crossed a python3.exe subprocess boundary (subject to
# MSYS auto-conversion on Git Bash) while "${STORE}/scripts" never did.
sl_check_same_path "resolved scripts dir is under the store" "${STORE}/scripts" "$RESOLVED_SCRIPTS"
```

`${STORE}` is the MSYS form (`/c/Users/...`) that never left the shell;
`$RESOLVED_SCRIPTS` comes back from `paths.py` in native form (`C:/Users/...`).
`install.sh` renders the hook from the **same paths.py value**, so the file on
disk holds the native form — and a `grep -F` for the MSYS form finds nothing.
The pre-existing assertion at line 191 uses `$RESOLVED_SCRIPTS` and passes on
Windows today, which is the empirical proof of which token is correct.

**The installer is correct on Windows. A Windows user upgrading does get the
hook re-rendered.** The new tests asserted it in a spelling that cannot match.

### Reproduced on Linux

Giving `AGENT_LEARNING_HOME` a `//` that `pathlib` normalizes and the shell does
not creates the same shape — same directory, different string:

```
shell-side  ${STORE}/scripts = /tmp/tmp.AexYp4hZlz//store/scripts
paths.py    RESOLVED_SCRIPTS = /tmp/tmp.AexYp4hZlz/store/scripts
same dir?     YES
same string?  NO

OLD grep -qF "${STORE}/scripts/..."    -> no   <-- the 3 CI failures
NEW grep -qF "${RESOLVED_SCRIPTS}/..." -> yes
```

### Fix

- Every expectation now uses `$RESOLVED_SCRIPTS`.
- The stale/edited fixtures are built by **rewriting the hook `install.sh` just
  wrote** (with the same basic-`sed` normalization the installer uses) instead of
  re-rendering the template with a shell-constructed path — so they no longer
  know or care which form is in use.
- U2 is now a **before/after byte snapshot** of the file rather than a
  reconstructed expectation: immune to path form *and* line endings, and it
  asserts the actual property (nothing changed).
- Three assertions added: the re-rendered hook points at a script that exists,
  and the `.bak` really retains the user's edit.

No production code changed. Commit `89601af`.

## 4 — `tests/test-coach-rules-eval.py`: 150 interpreter starts

Not mine by authorship (untouched by `add8e39..8309c31`) but red and in scope.
Exit 124 at the 120s per-suite ceiling on Windows only.

### Cause, measured

`cProfile` over the whole suite on Linux:

```
150 subprocess.run calls -> 11.28s cumulative of an 11.77s run (96%)
  10.92s of that is select.poll waiting on the child
```

Not a hang and not fixture I/O — **one cold Python interpreter start per test**.
`run_eval` (121 calls) and `run_both` (22) each spawned
`python coach-rules-eval.py`. Process creation plus interpreter startup is
several times more expensive on Windows than on Linux; at roughly 0.79s per
spawn there, 150 spawns account for essentially the entire 120s budget on their
own. The timeout was not masking a hang, and raising it would have hidden a real
150× multiplier.

### Fix — remove the spawns, not the ceiling

`coach-rules-eval.py` is a stdlib-only module whose `main()` takes its input from
`sys.argv` and the environment and writes to stdout/stderr, and it captures no
environment at import (verified: no module-level `os.environ`/`getenv` binding in
it, `telemetry.py`, or `transcript.py`; `TelemetrySource()` is constructed per
call, and `load_sessions` closes its connection in a `finally`). The suite
already imported it in-process as `CRE` for other assertions.

`eval_in_process()` now calls `CRE.main()` with `argv`, `os.environ` and both
streams redirected and exactly restored, returning the same
`(exit_code, stdout, stderr)` triple callers took off a `CompletedProcess`.

**What that would have silently dropped, and how it is kept:** in-process calls
never touch the script's entry point, so a broken shebang, a broken
`if __name__` guard, an exit status that stops tracking `main()`'s return value,
or diagnostics on the wrong stream would all go unnoticed. A new
`CliContractTest` keeps a handful of genuine spawns for precisely those, including
`test_in_process_and_subprocess_agree_on_the_same_input`, which runs identical
input **both ways** and asserts identical exit code, stdout and stderr — so the
equivalence the speedup rests on is pinned, not assumed. `test_missing_db_yields_empty`
and the `coach-signals.py` integration tests stay subprocess-based too.

### Before / after (Linux, `~/.pyenv/versions/3.9.24/bin/python3.9`, 3 runs each)

| | run 1 | run 2 | run 3 | tests | spawns |
|---|---|---|---|---|---|
| before | 11.999s | 11.266s | 11.597s | 172 | 150 |
| after | 2.715s | 2.537s | 2.470s | 175 | 10 |

~4.7× faster wall clock; subprocess cumulative time 11.28s → 0.90s. Three tests
added, none removed. Commit `f602d1d`.

`os.environ` patching is process-global, so this is correct only while `unittest`
runs tests serially — the default. Noted at the helper.

## Suite state

43 suites, all pass (`All 43 suites passed.`). Full-suite wall clock 1:41.
All 14 Python suites exit 0 on 3.9.24. No production code changed in this
addendum — both fixes are in tests.

## What only the Windows runner can confirm

- **The three U-assertions now matching.** Reproduced on Linux via `//`
  normalization, which produces the same *shape* of divergence (same dir,
  different string) but not the same *strings*. If Git Bash's conversion differs
  from `paths.py`'s output in some further way, the U2 byte-snapshot and U1/U3
  greps would still fail — though U2 can now only fail if install.sh genuinely
  rewrote a correct file, which would be a real defect rather than a spelling
  mismatch.
- **The coach suite fitting the ceiling.** The 0.79s-per-spawn figure is inferred
  from "150 spawns ≈ 120s", not measured on the runner. With 10 spawns the
  extrapolation is ~8s of spawn cost plus a few seconds of in-process work —
  large margin, but the margin itself is an estimate.
- **`repoint_hook_to`'s `sed` under MSYS.** It edits a file install.sh wrote, in
  the test's own temp dir, with no `#`-delimiter or bracket-expression
  constructs that differ between GNU/BSD/MSYS `sed` — but this branch has been
  burned by `sed` and `date` portability before.
