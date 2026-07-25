# Fix P7 — the concurrent-append data-loss defect

Branch: `harness-neutral-persistence`. Three commits:

| SHA | Subject |
|-----|---------|
| `0bb6c88` | fix: serialise persist-proposal writes across processes (P7 append race) |
| `88854bd` | fix: refuse to delegate install.ps1/uninstall.ps1 to a bash that cannot see the repo |
| `263a717` | test: gate the remaining detached-pipeline assertions on the completion marker |

Suite: **39 suites, all green** (was 37; `test-persist-concurrency.py` and
`test-ps1-wrappers.sh` added). Python suites re-run individually under
`~/.pyenv/versions/3.9.24/bin/python3.9`: all OK.

---

## 1. What was actually broken

`persist-proposal.py` performed read-existing → concatenate → stage → rename
with no lock spanning the cycle across processes. Every step is individually
safe and the final rename is atomic; the *span* is not. Two processes read the
same `MEMORY.md`, each appended its own entry to its own copy, and each renamed
its copy over the other's. One append is destroyed. **Both processes exit 0 and
print a success JSON** — the project's defining failure shape.

### Replace mode was NOT unaffected

The brief reported replace mode as safe and asked me to verify rather than
trust that. It is **not** safe, and this was the more damaging half:

`_plan()` calls `_load_usage_dict()` → `_merge_usage()` → and the merged
`.usage.json` is written at the end of `_write_all()`. That is a
read-modify-write span sitting inside a *replace*-mode skill write. Under
contention it lost nearly every telemetry record while writing every
`SKILL.md`, producing skills that exist on disk with no `.usage.json` entry at
all — invisible to `skill-lifecycle.py`'s state machine, pins and use counts
gone.

Memory *replace* mode itself (`MEMORY.md`, `mode: "replace"`) is genuinely
last-writer-wins and loses nothing beyond the replacement it was asked to
perform. It is serialised anyway, because the lock is taken for the whole
transaction regardless of mode; no reason to make the safety depend on
correctly classifying each mode.

---

## 2. Measurements

Harness: N processes are spawned first and all block in `sys.stdin.read()`;
only once every child is up is any payload written. That is a real barrier, not
a hope that spawns overlap. Store pre-seeded and payloads padded so the span
does real work.

`before` = `git show 1d39954:scripts/persist-proposal.py` (the commit before `0bb6c88`) extracted to a scratch
tree; `after` = the committed code. Same harness, same machine (Linux,
`flock` backend), same N.

| Mode | N | Before (lost) | After (lost) |
|------|---|---------------|--------------|
| memory append | 100 | 98, 98, 98 | 0, 0 |
| memory append | 40 | 30, 38 (barrier) / 1–6 (unsynchronised spawn) | 0 ×3 |
| skills `.usage.json` | 100 | 95, 98 (all 100 `SKILL.md` written) | 0 |
| skills `.usage.json` | 40 | 38, 38 | 0 ×3 |
| memory replace | 40 | 1 survivor (by design) | 1 survivor (by design) |

Every pre-fix writer exited **0**.

Forced-`exclusive`-backend run (see §3), end-to-end through
`persist-proposal.py` via a `sitecustomize.py` that pins
`store_lock.BACKEND`: N=40 append **0 lost**, N=40 skills **0 lost**, and no
lock file left anywhere in the store (that backend unlinks on release).

---

## 3. The locking design

New module `scripts/lib/store_lock.py`. One coarse, **whole-store** exclusive
lock held across the entire `_plan` + `_write_all` transaction.

**Why one lock, not per file.** Writes are rare (once per review) and short
(milliseconds), so finer granularity buys nothing; it costs a canonical
acquisition order to avoid deadlocking a proposal that writes `MEMORY.md` then
`.usage.json` against one that writes them in the other order. A single lock
cannot deadlock against itself.

**Why `_plan` is inside the lock.** Planning is where `.usage.json` is read and
merged. Locking only the write half leaves exactly the span that destroyed 38
of 40 records. This is not theoretical — it is mutation B in §5.

**Where the lock file lives.** `<store>/state/persist.lock`, never inside
`memory/` or `learned-skills/`, whose contents are enumerated by
`inject-agents-md.py`, `curator-run.sh` and `skill-lifecycle.py` — a stray file
there is read as content. `state/` already hosts this kind of thing
(`turn-counter.sh`'s `counter.lock`). Created 0600; the kernel backends leave a
0-byte file behind deliberately (unlinking a flock'd path is what creates the
classic "two holders, two inodes, one name" race).

**Backend selection is a functional probe, never a platform name.** Each
candidate performs a real lock/unlock in a throwaway temp directory:

1. `flock` — `fcntl.flock(LOCK_EX|LOCK_NB)`.
2. `msvcrt` — `msvcrt.locking(LK_NBLCK)`, for Windows.
3. `exclusive` — `O_CREAT|O_EXCL` lockfile, last resort (e.g. a network
   filesystem where neither primitive works).

This follows the discipline already established here (`_probe_dir_fd_support`'s
real open/mkdir/replace/unlink instead of trusting `os.supports_dir_fd`, which
demonstrably misreports `os.replace`; the `[[ -L ]]`-after-`ln -s` probes in
the shell suites). `doctor.sh` prints the selected backend and whether it is
crash-safe. Measured here: `backend=flock releases_on_crash=yes`.

**Stale locks.** Backends 1 and 2 are kernel-held against an open fd: the OS
releases them when the holder dies, SIGKILL and hard crash included. Nothing
can wedge, and no timeout heuristic is involved — this is asserted by
`test_kernel_backend_releases_when_holder_process_dies`, which SIGKILLs a real
holder process and requires the next acquirer to succeed. Only the `exclusive`
fallback can leave a lock behind a dead process, so only it breaks a lock older
than `STALE_SECONDS` (300s — three orders of magnitude above a real hold, and
15× the acquire timeout). Both the break and the *non*-break of a fresh lock
are tested.

**Timeout.** Bounded poll, default 20s, overridable via
`SL_PERSIST_LOCK_TIMEOUT`. On expiry the process:

- exits **2** (the existing write-failure code — not a new code, so nothing
  downstream has to learn one),
- prints `persist-proposal: write failed: timed out after Ns waiting for <path> (backend=…)` to stderr,
- appends `<ISO-8601> persist-proposal: lock timeout: …` to
  `${SL_LOG_DIR}/persist-failures.log`.

Verified with an **external** holder process (not the same process as the
writer): elapsed 1.05s at `SL_PERSIST_LOCK_TIMEOUT=1`, `rc=2`, log line
written, `MEMORY.md` never created, nothing left in `memory/`. `doctor.sh` was
then run against that log and rendered it under "PERSISTENCE FAILURE(S)
RECORDED" with a correctly parsed age and `overall: UNHEALTHY` — i.e. the
timeout is visible through the mechanism that exists precisely because the
detached pipeline cannot use an exit code.

`LockUnavailable` (the lock file itself cannot be created — e.g. an unwritable
`state/`) is a separate exception mapped to the same exit 2. It fails loudly
rather than falling back to unlocked writing: silently degrading to the broken
behaviour when the safety mechanism is unavailable is the pattern this fix
exists to remove.

**Preserved guarantees.** The lock wraps the existing write path; nothing
inside it changed. `test-persist-proposal.py` (26 tests) and
`test-adversarial-sweep.py` (32 tests) — dir_fd anchoring, `O_NOFOLLOW`,
hardlink rejection, root-relative confinement, directory-target refusal,
corrupt-`.usage.json` refusal, all-or-nothing, mode 0600, no `.persist-tmp-*`
leftovers, flat-`<name>.md` preservation — all still pass unchanged, under
3.9 and under the system interpreter.

---

## 4. The regression suite

`tests/test-persist-concurrency.py`, 9 tests, **6.1s** (per-suite CI budget is
120s). Coverage printed at runtime, e.g.:

```
[concurrency] append: 2 rounds x 24 processes, lost entries = 0
[concurrency] skills/.usage.json: 1 round x 24 processes, lost records = 0
[concurrency] timeout path: non-zero exit + persist-failures.log line, bounded at 0.55s
[capability probe] store_lock backend=flock releases_on_crash=True
```

It is not a coin flip: the stdin barrier plus the 200 KiB pre-seed make the
pre-fix failure near-certain rather than probabilistic (23 of 24 records lost
in the mutation run at the reduced CI N). N and rounds are overridable via
`SL_CONCURRENCY_TEST_N` / `SL_CONCURRENCY_TEST_ROUNDS` for deeper manual runs.
The `exclusive` fallback's mutual exclusion, release-unlink, stale-break and
fresh-non-break are unit-tested on **every** platform, not only where that
backend is selected — otherwise the fallback would ship untested everywhere it
matters.

---

## 5. Mutation testing

| Mutation | Result |
|----------|--------|
| A — locking removed entirely (`1d39954` writer restored) | **killed**: 3 failures — `test_no_append_is_lost_under_contention` (24/24 lost), `test_no_usage_record_is_lost_under_contention` (23/24 lost), `test_timeout_exits_nonzero_and_logs` ("0 == 0: a lock timeout must not report success") |
| B — lock narrowed to `_write_all`, `_plan` left outside | **killed**: 1 failure — `test_no_usage_record_is_lost_under_contention` |

Killed 2 / survived 0. Mutation B is the one that matters for review: it is the
plausible half-fix, and the suite distinguishes it from the real one. Both
mutations were applied to a copy and the file restored from a pre-mutation
backup; `git diff --stat` confirmed the restore each time.

---

## 6. Also in scope (a): `install.ps1` / `uninstall.ps1` WSL ambiguity

Both wrappers took `Get-Command bash` and handed it a Windows-style repo path.
If that `bash` is WSL's launcher (`C:\Windows\System32\bash.exe`) it executes
inside the WSL filesystem, where the path does not exist (the same directory is
`/mnt/c/...`) and `$HOME`, `$XDG_DATA_HOME` and the detected harnesses belong to
the WSL user — the silent-wrong-location class this project exists to remove.

New `scripts/lib/find-bash.ps1` (shared by both wrappers, so they cannot drift)
asks the bash it found the only question that matters:

```powershell
& $bash.Source -c 'test -f "$1"' -- $ScriptPath
```

A bash whose filesystem view does not include the repo fails that, whoever it
is. **Functional, not a name/System32 match** — a name check would miss
non-System32 WSL shims entirely and could wrongly reject a working bash
installed somewhere unusual. On failure it throws a message naming the bash it
found, the path it could not see, the WSL explanation, and both fixes (install
Git for Windows, or run `bash install.sh` inside WSL deliberately).

**Not executed on Windows, and not executable here**: this repo's CI has no
PowerShell job and the dev host has no `pwsh` (probed and reported, not assumed).
`tests/test-ps1-wrappers.sh` therefore pins what *can* be checked without
PowerShell — both wrappers route through the shared resolver and no longer call
`Get-Command bash` directly; the helper probes with `test -f` and does not
branch on a System32 match — and executes the probe idiom itself for real in
bash (exit 0 for a visible path, non-zero for a Windows-style one). If `pwsh`
is ever present it additionally parse-checks all three files. When it is
absent the suite **prints that PowerShell behaviour is unverified** rather than
skipping silently. The logic is deliberately small enough to audit by reading,
and the only new failure mode it can introduce is refusing to run under a bash
that demonstrably cannot open the installer.

---

## 7. Also in scope (b): the "don't wait for the detached pipeline" cases

I re-judged these rather than accepting the earlier round's "wide margin"
verdict, and **the earlier verdict was wrong on both of its claims.**

Located: bare `sleep 0.3` before asserting on detached-pipeline side effects at
5 sites in `tests/test-session-review.sh` (cases 1, 2, 3, 6, 7) and 5 in
`tests/test-copilot-session-review.sh` (cases 1, 2, 3, 5, 6) — more than the
four flagged, covering 9 assertion sites.

- **"Wide margin" is false.** 0.3s does not cover `nohup bash -c` plus a bash
  shim on a loaded `windows-latest` runner. This repo's own fix round E
  documents Windows process-spawn overhead as measured and real, and a
  zero-tolerance timing assertion in `test-config.sh` already turned this
  branch's CI red once.
- **"Not mechanical to retrofit" is false.** Both pipelines already write an
  unconditional `.review-complete` marker as their last statement (fix-p6), so
  each sleep maps directly onto `sl_clear_review_marker` +
  `sl_wait_for_review_complete`.

The negative-shaped assertions were the worse problem and the reason I did not
leave these alone: `no model flag when unset`, `hostile model string dropped`
and `guarded entry spawns nothing` all pass **vacuously** against a log that is
empty only because nothing has started yet. A flaky positive fails loudly; a
vacuous negative reports green while testing nothing — the exact pattern this
branch keeps finding. Those now either wait for the pipeline to complete (so
the argv they inspect is the argv that was really used, with an added explicit
"reviewer actually ran" assertion) or use the new
`sl_expect_no_review_spawned`, which watches for a marker that must never
arrive over a bounded window instead of sampling an empty log once.

Both suites still run in ~5–6s; three consecutive clean runs each.

Two `sleep`s were deliberately left alone after inspection and are **not**
pipeline waits: `test-script-paths.sh`'s `sleep 1.2` (filesystem mtime
granularity) and the `sleep 0.2` bodies inside bounded polling loops.

---

## 8. Residuals and what I could not execute

- **Windows and macOS are unverified for this change.** No CI run has been
  observed since these commits. `msvcrt.locking` has never executed anywhere in
  this session — it is selected by a probe that itself has never run on
  Windows. CI run `30167923350` covered the 37 suites that existed then; the two
  new suites are unobserved on the matrix. README/CLAUDE.md were corrected to
  say exactly that rather than keep a "37 suites, all green" claim that now
  reads as covering work it never saw.
- **PowerShell was never executed** (no `pwsh`, no PowerShell CI job). §6.
- **The `exclusive` backend was exercised end-to-end only by pinning
  `store_lock.BACKEND` from a `sitecustomize.py`**, not by a machine on which
  the probe actually selects it. There is no env var to force a backend in
  production, deliberately — it would be a footgun.
- **Other writers of the store are still unserialised against this lock.**
  `skill-lifecycle.py` and `curator-run.sh` rewrite `.usage.json` and move
  skills without taking it. That is a pre-existing, separate exposure (curator
  runs weekly, not on a hook), out of scope for this fix, and now cheap to
  close: `StoreLock` is a standalone module with a stable interface. Flagging
  it rather than silently widening scope.
- **A lock timeout makes `doctor.sh` report UNHEALTHY.** Intended: contention
  severe enough to exhaust a 20s wait means reviews are being dropped, and the
  operator should see it. It is also the only case in this file that is
  expected to be transient, which is why it is logged directly rather than left
  to the wrapper's generic "pipeline failed (status 2)" line.
- **Nothing measured here says anything about the live Copilot CLI end-to-end
  check**, which remains pending manual verification as before.

---

# Fix P8 — the other writers of `.usage.json`

Follow-up to §8's flagged residual, confirmed live by the coordinator. Commits:

| SHA | Subject |
|-----|---------|
| `186f7d9` | fix: make skill-lifecycle.py and curator-run.sh take the same store lock (P8) |

Suite: **40 suites, all green** (`test-store-lock-writers.py` added). All Python
suites pass individually under `~/.pyenv/versions/3.9.24/bin/python3.9`.

## P8.1 What was broken

`skill-lifecycle.py` performs the identical read-modify-write P7 fixed, over the
same file: `load_usage()` → decide transitions → `shutil.move()` skill
directories → `save_usage()`. Nothing serialised it against
`persist-proposal.py`. `curator-run.sh` reads the same file with `jq` and takes
the pre-run backup that all of the curator's destruction is supposed to be
recoverable from.

## P8.2 Measurements

Barrier harness (every child blocks in `stdin.read()`; a shim gives
`skill-lifecycle.py`, which reads no stdin, the same barrier), 24 persist
writers + 1 lifecycle pass over 1500 seeded records, Linux, 3 runs each:

| Direction | Before | After |
|-----------|--------|-------|
| lifecycle transitions lost | **1500 / 1500**, every run | **0 / 1500**, every run |
| persisted skill records lost | 0 / 24 | 0 / 24 |
| lifecycle exit code | 0 | 0 |

An entire curator sweep — 1500 state transitions — silently discarded by
concurrent reviews, reported as success. Which side loses depends only on who
renames last; the harness happened to catch the lifecycle losing, and the
regression suite asserts both directions.

Reduced for CI (16 writers, 1200 records): whole suite **5.7s**.

## P8.3 A correction to the brief

The brief said the curator "moves skill directories while doing so" and framed
that as worse than the memory case. Half right:

- The directory moves are in **`skill-lifecycle.py`** (`shutil.move`), not
  `curator-run.sh`, which only reads (`jq`, `tar`) and delegates. Locking
  `curator-run.sh`'s own loops would not have touched the moves at all.
- I tried hard to reproduce a **filesystem-level** corruption from the move —
  a purpose-built harness that forces the lifecycle to take its snapshot
  first, then releases 8 writers targeting the very skill it is about to
  archive, across many iterations. It produced **zero** anomalies against the
  pre-fix code: no directory without a `SKILL.md`, no stray temp files, no lost
  content, no non-zero exits. `os.replace` and `shutil.move` are both
  rename-based, so each individual file stays intact whoever wins.

  So the directory-move corruption is **reasoned, not reproduced**. I am not
  claiming it. What *is* measured, and what the fix closes, is the lost-update
  on `.usage.json` — which for an archive transition means the record and the
  directory can disagree about where a skill lives, without any filesystem race
  being involved.

## P8.4 Design: spans, deadlock, starvation

Chosen: **several short spans, not one long hold.**

- `skill-lifecycle.py` holds the lock across its entire pass — read, decide,
  move, write. Not `save_usage()` alone: the snapshot must be read under the
  lock, or anything committed in between is discarded. This is the same
  half-fix P7's mutation B already disproved, and mutation D below proves it
  again here.
- `curator-run.sh` holds it only for the pre-run backup (`tar`), so the safety
  net is a point-in-time snapshot. It **releases before invoking**
  `skill-lifecycle.py`. That is not a preference — the lock is not reentrant
  across processes, so holding it across that child would deadlock the curator
  against itself for the full acquire timeout and apply nothing. A regression
  test runs the real curator end-to-end and fails if it takes more than 20s or
  applies no transitions.
- The curator's read-only loops (`jq` inventory counts, the opt-in LLM
  inventory) are deliberately **not** locked. Renames are atomic, so each read
  sees an intact file; the worst case is a count in a Markdown report being off
  by one. Locking them would extend the hold time — the thing a session-end
  review can be starved behind — to buy nothing.

**Starvation.** The worst case a review can wait behind is one `tar` of the
skills directory, not a whole curator sweep. The default 20s bounded wait
applies, and on expiry the review fails loudly rather than hanging a hook.
Conversely the curator, if it cannot get the lock, **aborts** rather than
running destructive transitions with an unverified backup.

**Loud everywhere.** `skill-lifecycle.py` exits **3** on lock failure —
deliberately distinct from its exit 2 for a corrupt `.usage.json`, so
"contended, retry later" is not confused with "the store is damaged" — and
logs to `persist-failures.log`. The bash front end exits **75** (`EX_TEMPFAIL`)
and logs the same way. And `curator-run.sh`'s previous `|| true` around the
lifecycle call, which swallowed *every* failure including these, now records a
non-zero status in its own report and on stderr.

## P8.5 The bash front end

`scripts/lib/store-lock.sh` exposes `sl_with_store_lock <cmd>...`, which runs
the command through `store_lock.py run`. There is deliberately **no**
acquire/release pair for bash: `set -euo pipefail` plus a held lock plus an
early `exit` is a leaked lock, and bash has no `finally`. The wrapper holds the
lock for exactly the child's lifetime.

Cost: one `python3` spawn per protected span. Verified — not assumed — that this
is off the hot path: `grep` names `curator-run.sh` as the only caller, and
`turn-counter.sh` (the sole per-tool-call hook) sources only `config.sh`,
`hook-input.sh` and `stdin-safe.sh`.

`store_lock.default_lock_dir()` is the single definition of the lock path,
honouring `SL_STATE_DIR` (what `config.sh` exports for bash) and otherwise
`paths.py`. A lock only serialises processes that pick the same path, so a test
pins that agreement: without it, every other test here would still pass while
the writers silently stopped excluding each other.

## P8.6 Mutation testing

| Mutation | Result |
|----------|--------|
| C — `skill-lifecycle.py` lock removed | **killed 3/3**: lost-update test, forced-interleaving test, timeout test |
| D — lock narrowed to `save_usage()` only | **killed 3/3** (see below) |
| E — `curator-run.sh` backup no longer locked | **killed 3/3**: curator abort-path test |

**Mutation D initially SURVIVED 2 runs in 3.** The plain concurrency race only
caught the half-fix when the timing happened to cooperate — precisely the
"passes by luck" property that makes a concurrency test worthless. Rather than
report a 1-in-3 kill, I added
`TestLifecycleSnapshotIsTakenUnderTheLock`, which does not race at all: the
test itself takes the real lock, starts the lifecycle underneath it, commits a
`sentinel` record while still holding it, and only then releases. If the
snapshot is read under the lock the sentinel is necessarily preserved; if it
was read before, it is destroyed. Deterministic in both directions, and it
also asserts the lifecycle blocked at all rather than sailing past a held lock.
That took D from 1/3 to 3/3.

## P8.7 Windows probe visibility

`tests/test-persist-concurrency.py` now prints, **at import** rather than inside
a test, in the established `[capability probe]` shape:

```
[capability probe] store_lock backend=flock releases_on_crash=yes platform=linux os.name=posix
```

At import, because reading the answer out of a CI log must not depend on a
particular test being reached, not skipped and not reordered. On the next
Windows job this line states whether `msvcrt.locking` was actually selected —
the primitive that has still never executed anywhere in this project. The
accompanying test now also asserts `BACKEND_RELEASES_ON_CRASH` matches the
backend, so a renamed/typo'd backend cannot print happily and silently fall
through to no locking. `doctor.sh` reports the same thing for a real install.

`test-ps1-wrappers.sh` is unchanged: it still prints PowerShell as unverified
rather than skipping silently, and no PowerShell CI job was invented.

## P8.8 Still unverified after P8

- Windows and macOS: unchanged from §8. `msvcrt.locking` remains unexecuted;
  the next CI run is what proves it, and now says so in its log.
- The directory-move corruption: reasoned, **not** reproduced (P8.3). The
  regression suite asserts the invariants it would violate (no directory
  without `SKILL.md`, no strays, content findable) as a standing guard, but
  those assertions have never been observed failing, so they are a guard, not a
  proof.
- `curator-run.sh`'s read-only `jq` loops remain unlocked by design (P8.4); a
  report count can still be momentarily skewed by a concurrent review.
- Nothing here touches the live Copilot CLI end-to-end check, still pending.
