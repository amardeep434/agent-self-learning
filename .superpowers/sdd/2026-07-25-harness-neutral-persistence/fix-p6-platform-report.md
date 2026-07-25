# Fix round P6 — platform bugs (Windows termios crash, macOS first-run indexing)

Two of the four CI cells broken today, each traced to a distinct root cause on a
distinct platform. Both were honest loud failures (a crashing test, and a failing
assertion) — neither was "fixed" by weakening an assertion or skipping a suite.

## Failure 1 — Windows: `tests/test-copilot-hook-input.sh`

### Real cause (confirmed by reproduction, not assumed)

`scripts/lib/stdin-safe.sh` (the TTY-hang guard itself) and `scripts/lib/copilot-hook-input.sh`
are pure bash — `sl_read_stdin_safe` uses only the portable `[[ -t 0 ]]` builtin, which
works fine on Windows Git Bash. **Neither of those files imports anything Python.**

The crash is in the *test*, not the code under test: `tests/test-copilot-hook-input.sh`
Case 5 allocates a real pseudo-terminal via Python's stdlib `pty` module to prove
`sl_read_stdin_safe` doesn't hang when stdin is a real tty:

```python
import os, pty, subprocess, sys, select
```

`pty` is POSIX-only. On CPython, `pty.py`'s own top-level code unconditionally
imports `termios`, which does not exist in the Windows stdlib — so `import pty` on
Windows fails with exactly the reported `ModuleNotFoundError: No module named
'termios'`, not a `pty`-named error, which is why the surface symptom name didn't
match the actually-missing module.

**Confirmed by direct reproduction**, not inferred from the platform name: a `python3`
shim on `PATH` that raises `ModuleNotFoundError: No module named 'termios'` on
`import pty` (simulating the Windows stdlib) reproduces the CI traceback byte-for-byte
against the pre-fix script (exit 1, `set -euo pipefail` aborting the whole suite at
Case 5, Cases 1–4 having already printed PASS — matching the CI transcript shape).

No other reachable-from-a-hook-path use of `termios`, `fcntl`, `pty`, `tty`, `grp`, or
`pwd` exists anywhere in `scripts/` or `tests/` (verified with `grep -rlw` for each
name across both directories) — this was the only hit.

### Fix

`tests/test-copilot-hook-input.sh`: wrapped `import pty` in `try/except ImportError`
inside the Python heredoc. On failure it prints `PTY_UNAVAILABLE: <message>` and exits
0 (no crash); the bash side detects that sentinel and prints a `[capability probe]`
line plus an explicit `SKIP:` line — loud, not silent — instead of running `check()`.
All other 5 checks in the file are untouched and still assert normally, so a Windows
run still meaningfully exercises Cases 1–4 and 6 (the actual payload-parsing and
piped-stdin behavior); only the one check that structurally requires a POSIX-only
pty allocator is skipped, and it says so explicitly rather than being silently
absent from the output.

This mirrors the existing capability-probe discipline in
`tests/test-persist-proposal.py` (`HAS_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0) != 0`)
for a primitive that is genuinely a structural platform fact, not something to infer
from `sys.platform`/`os.name`.

The behavior actually being guarded — a hook must not hang on a terminal stdin, and
must read a piped payload fully — is unaffected: `sl_read_stdin_safe`'s `[[ -t 0 ]]`
guard is portable bash and needed no change. Only the *test's own means of
manufacturing a real terminal fd* is POSIX-only; that limitation is now stated
explicitly rather than crashing the suite.

### Mutation test

- **Reproduced the original crash**: stashed the fix, ran under the fake `termios`-less
  `python3`, got the exact CI failure (`ModuleNotFoundError`, exit 1) — confirms the
  fix targets the real cause.
- **Killed**: removed the `SKIP` branch (routing `PTY_UNAVAILABLE:...` into `check()`
  as a literal string) under the fake shim → `FAIL: tty stdin does not hang
  sl_read_stdin_safe (expected 'DONE', got 'PTY_UNAVAILABLE: ...')`, exit 1. Restored →
  all 6 checks PASS again.
- Confirmed the fixed script still passes normally on this Linux sandbox (pty
  available here, so Case 5 takes the real path and asserts `DONE`, not the skip
  path).

## Failure 2 — macOS: `tests/test-index-session-first-run.sh`

### Investigation

`scripts/index-session.sh`'s first-run branch (added in commit `0798ef0`, "fix:
deferred minors — first-run indexing...") does **not** compare against the DB's mtime
at all when `DB_EXISTED=0` — it lists every `*.jsonl` unconditionally, so the
"ordering between database creation and comparison" candidate the task sketched does
not apply here; there is no comparison on that path to get the ordering wrong on.

What the first-run branch *did* do (before this fix) was hand-roll the listing itself:

```bash
find "$SESSIONS_DIR" -name "*.jsonl" -type f 2>/dev/null \
    | while IFS= read -r _f; do
          _mtime=$(stat -c %Y "$_f" 2>/dev/null || stat -f %m "$_f" 2>/dev/null || echo 0)
          printf '%s\t%s\n' "$_mtime" "$_f"
      done \
    | sort -rn | cut -f2- | head -20
```

and the subsequent-run branch used `find -newer "$DB_PATH"`.

I could not get a macOS runner to reproduce the exact failure, and static analysis of
each individual piece (BSD `stat -f %m` is the documented, standard BSD equivalent of
GNU `stat -c %Y`; BSD `find -type f`/`-name` are not documented to differ from GNU in
a way that would drop a plain file; the `while read | sort | cut | head` pipeline's
exit-status/pipefail interaction was tested directly on this Linux box and does not
propagate a false failure) did not turn up a single conclusively-provable smoking gun
I could confirm without macOS access. Rather than ship a narrow patch aimed at a
guessed single point in that chain — which the task explicitly warned could "pass
locally and fail again in CI" — I removed the entire class of GNU/BSD CLI-text-parsing
divergence this pipeline depended on: three independently-driftable comparisons
(`stat`'s two incompatible flag/output conventions, `find -newer`'s own filesystem-
timestamp comparator, and `sort -n`'s numeric-prefix parsing of that text) collapsed
into one syscall (`os.path.getmtime()`) and one Python `>` comparison, which CPython
guarantees behaves identically across platforms.

### Fix

Added `scripts/lib/list-transcripts.py` (stdlib-only, 3.9-compatible): recursively
lists `*.jsonl` files under a root directory via `os.walk`, using `os.path.getmtime()`
for each, with an optional `--since-mtime <float>` floor (strict `>`, matching
`find -newer`'s own strict-greater-than semantics) and a `--limit`. `index-session.sh`
now calls it instead of the hand-rolled pipeline for both the first-run case (no
`--since-mtime`) and the subsequent-run case (`--since-mtime` = the DB's own
`os.path.getmtime()`, read via a one-line `python3 -c`).

This is not a platform-name branch — it's a straight replacement of
platform-varying shell/CLI logic with a stdlib call that has one behavior everywhere
Python runs, the same "shell out to Python for the primitive that needs to agree
across OSes" pattern `paths.py`/`isotime.py`/`config.sh`'s python3 fallback already
use elsewhere in this codebase.

### Tests

- `tests/test-list-transcripts.py` (new, 8 tests): unit-tests `list_transcripts()`
  directly with `os.utime()`-controlled mtimes — no wall-clock sleeps, no ordering
  race. Covers: missing/empty root, a file whose mtime predates any reference point
  still included when `since_mtime=None` (the exact regression), `since_mtime`'s
  strict-`>` exclusion at and below the floor, newest-first ordering, `limit`
  keeping the newest N, non-`.jsonl` files ignored, and recursion into project
  subdirectories.
- `tests/test-index-session-first-run.sh` (existing, unchanged assertions) — updated
  only to copy the new `lib/list-transcripts.py` into its sandboxed script copy;
  still exercises the same real `index-session.sh` end to end.
- `tests/test-script-paths.sh` also sandboxes a copy of `index-session.sh` for its
  own dependency/path checks and needed the same one-line fixture update to copy
  `list-transcripts.py` — caught by running the full suite, not missed.
- Manually verified the subsequent-run (`--since-mtime`) path end-to-end (a second
  session added after the DB exists gets indexed alongside the first, not instead of
  it) — no dedicated automated test for that path pre-existed and adding one was out
  of scope for this fix, but the manual run confirms the refactor didn't regress it.

### Mutation test

- Broke `list_transcripts()` to always `return []` → all 8 new unit tests failed
  (6 explicit assertion failures) **and** `test-index-session-first-run.sh` failed
  with the identical signature as the original CI report: `FAIL: pre-existing
  transcript is indexed on the very first run (expected '1', got '0')`. Restored →
  both green again.

### What only CI can confirm

I have no macOS access, so I cannot directly confirm the *original* pipeline's exact
failure point (stat flag parsing, `find -newer`'s comparator, or something else in
that chain I didn't consider) — only that I removed every platform-varying piece of
it, tested the replacement's logic exhaustively with controlled timestamps on Linux,
and confirmed the Linux integration test still passes end to end. Only a green macOS
CI run confirms this fix actually resolves the specific CI failure rather than
coincidentally sidestepping it. If macOS CI is still red after this, the next place to
look is something outside the code I touched — e.g. a real sub-second-resolution race
between transcript-file creation and DB creation in the *test's own fixture* timing
on a fast APFS runner (the task's fourth candidate cause), which `os.path.getmtime()`
does not paper over since it still reads real filesystem timestamps.

## macOS FTS5 (follow-up: CI run 30165496986)

Round two. Both Windows cells went green and Ubuntu stayed green after the fixes
above; macOS was still red on `tests/test-index-session-first-run.sh`, but with a
different failure than before:

```
PASS: DB was created on first run
FAIL: pre-existing transcript is indexed on the very first run (expected '1', got '0')
--- index-session.sh first-run output ---
Runtime error near line 37: no such module: fts5
```

The `find`/`stat`/`sort` rewrite (the round-one fix above) was **not** the cause —
it correctly listed the pre-existing transcript. The DB row never landed because
schema initialization itself failed: macOS's bundled `/usr/bin/sqlite3` CLI is
commonly built without the FTS5 extension, and the old
`sqlite3 "$DB_PATH" < "$SCHEMA_FILE"` line hit `CREATE VIRTUAL TABLE messages_fts
USING fts5(...)` (line 37) and errored.

### Probe result: CLI vs. Python sqlite3 — verified, not assumed

Ran a direct functional probe (`CREATE VIRTUAL TABLE ... USING fts5(x)`) against
both the system `sqlite3` CLI and Python's bundled `sqlite3` module on this
development machine, and separately against the CI-pinned Python 3.9.24
interpreter:

```
CLI FTS5 probe:                    (silent — succeeded; this Linux box's CLI has FTS5)
Python sqlite3 FTS5 (3.13):        AVAILABLE
Python sqlite3 FTS5 (3.9.24):      AVAILABLE
```

This machine's CLI happens to have FTS5 too, so it doesn't reproduce the CLI/Python
split macOS shows — the CI log is the actual evidence for that split (CLI: `no such
module: fts5`; the same code path via Python succeeds once rewritten, see below).
The reasoning for *why* Python's module is expected to have it even where the CLI
doesn't, on macOS specifically: GitHub Actions' `macos-latest` (and `ubuntu-latest`,
`windows-latest`) runners resolve `python3` through `actions/setup-python`, which
installs a relocatable, from-source Python build (the `actions/python-versions` /
`python-build-standalone` artifacts) that compiles its own bundled SQLite with FTS5
enabled — independent of whatever the OS's own `/usr/bin/sqlite3` CLI ships with.
Apple's system CLI is a separate, Apple-built binary with its own compile flags.
This is why the CLI and Python diverged in the CI log: two different SQLite builds
from two different vendors, not two views of the same one.

### Was `index-session.sh` masking a failed schema behind exit 0? Yes — checked, not assumed

Reproduced directly: piping a multi-statement script containing a bad
`CREATE VIRTUAL TABLE ... USING nosuchmodule5(...)` into `sqlite3 file <
script.sql` on this machine's sqlite3 (3.53) DOES propagate exit 1 and does NOT
process statements after the error. But the CI log shows the opposite behavior
happened on macOS: `set -euo pipefail` never fired (execution continued to
`echo "  Initialized: ..."`/the subsequent listing step), and the base
`sessions`/`messages` tables were never created either (queries against them
during the test failed rather than returning 0 rows). Both facts are only
explainable if macOS's older bundled `sqlite3` CLI batch-processes past a
mid-script error without setting a non-zero exit status by default (`.bail` is
off by default in the CLI, and this behavior is version-dependent) — i.e. the
exact "component reports success while doing nothing" pattern. **Yes, it was
masking a failure**, on a build/version of the CLI I don't have local access to
reproduce byte-for-byte, but the CI log's shape (WARNING/table-missing evidence,
no non-zero-exit abort) is only consistent with that explanation.

### Approach and why

Verified Python's `sqlite3` module has FTS5 here (goal 1 confirmed on this
machine, reasoned about for macOS CI above) → stopped shelling out to the
`sqlite3` CLI for schema management and per-session writes entirely, rather than
patching the CLI invocation to check its own exit code more carefully. Added
`scripts/lib/session_db.py`:

- `probe_fts5()` — a functional probe (create a scratch FTS5 table in a throwaway
  `:memory:` database), matching this repo's existing capability-detection
  discipline (`os.supports_dir_fd`, the `[capability probe]` lines added in the
  Windows fix above). Not a version or platform check.
- `ensure_schema()` — applies `schema/session-search-schema.sql` (split out as the
  BASE schema: `sessions`/`messages` tables + plain indexes, always applied,
  needs no FTS5) via `Connection.executescript()`, which raises immediately on a
  real SQL error — no CLI batch-mode continue-past-failures. Then probes FTS5 and,
  only if available, applies the new `schema/session-search-fts5.sql` (the
  `messages_fts` virtual table + sync triggers, split out from the old combined
  file). A genuine base-schema failure propagates as a raised exception;
  FTS5-unavailable is a distinct, non-error return value.
- `search()` — FTS5 `MATCH` (ranked, stemmed) when `messages_fts` exists; a plain
  `content LIKE '%...%'` query (escaped for literal `%`/`_`) against the same
  `messages` table when it doesn't. Never a silently empty index.

`index-session.sh` now calls `session_db.py ensure-schema` instead of the CLI, and
treats its result two ways: a non-zero exit (a REAL failure) is `FATAL`, logged,
and aborts with exit 1; a `no-fts5:<reason>` result (FTS5 genuinely unavailable) is
logged as a `WARNING` naming the degradation and continues normally, exit 0 — this
is a handled, intentional degradation, not a bug. `install.sh`'s equivalent schema-
init step (Step 5, same CLI-masking bug, same fix) and `scripts/index-session.py`
(folded the shell wrapper's separate `sqlite3` CLI "already indexed → DELETE"
check into a single unconditional `DELETE FROM messages WHERE session_id = ?`
before insert, via the same Python connection already used for the insert) were
updated the same way. Net effect: `sqlite3` (the CLI) is no longer a runtime
dependency of the index/search path at all — only `self-learning-health.sh`'s
manual DB-inspection diagnostic still shells out to it, and it already degraded to
a `warn`, not a `fail`, when absent (fixed the adjacent "Dependencies" check in the
same file, which *did* hard-`fail` on a missing `sqlite3` — now also a `warn`,
consistent with the CLI genuinely being optional). `README.md`'s requirements
table, file-layout listing, and Session Search feature description were updated to
match this reality.

Explicitly avoided per the coordinator's constraint: did not install `sqlite3`
with FTS5 in CI. Not a platform-name branch anywhere in this fix — `probe_fts5()`
is called on every platform, and its result (not `sys.platform`) decides which
schema gets applied.

### Tests

- `tests/test-session-db.py` (new, 8 unit tests): `ensure_schema()`/`probe_fts5()`/
  `search()` exercised directly, with `probe_fts5` monkeypatched to `False` to hit
  the degraded path deterministically — not dependent on this machine (which has
  real FTS5) happening to lack it. Covers: base tables created regardless of FTS5
  availability, FTS5 tables created when available, a missing FTS5 schema file
  degrading rather than raising, a **genuine** base-schema failure raising
  (`sqlite3.Error`) rather than being swallowed, FTS5 `MATCH` search, LIKE-fallback
  search, and LIKE-fallback `%`/`_` escaping correctness.
- `tests/test-index-session-fts5-fallback.sh` (new, shell integration): simulates
  FTS5 unavailable *inside Python's own sqlite3 module* (worse than the real macOS
  gap, where only the CLI lacked it) via a `sitecustomize.py` on `PYTHONPATH` that
  makes any `CREATE VIRTUAL TABLE ... USING fts5(...)` raise the real
  `sqlite3.OperationalError` SQLite itself raises — a functional-probe simulation,
  not a platform branch, with a sanity check that `probe_fts5()` genuinely observes
  `UNAVAILABLE` through the shim before trusting anything downstream. Runs the
  real `index-session.sh` end to end and asserts: exit 0 (handled degradation), a
  WARNING naming FTS5 and the LIKE fallback, `sessions`/`messages` tables present,
  `messages_fts` correctly absent (not half-created), the row actually indexed, and
  — the "verify search still works end-to-end" ask — `session_db.py search` finds
  the indexed content via the LIKE path. A second scenario in the same file uses a
  deliberately invalid base schema (not an FTS5 problem) with zero session files
  present, isolating the schema-init check itself, and asserts `index-session.sh`
  exits 1 with a `FATAL` message — the true silent-success reproduction, since with
  no files to index the script's only other exit path is the normal "nothing to do"
  `exit 0`.
- `tests/test-index-session-first-run.sh`: added an end-to-end `session_db.py
  search` assertion after the existing row-exists check, so this test now catches
  "a row landed but search is broken" (the actual macOS symptom), not only "a row
  is missing" (the round-one symptom).
- `tests/test-script-paths.sh`'s own sandboxed `index-session.sh` copy needed the
  same fixture update (`session_db.py`, `session-search-fts5.sql`) as the
  dedicated index-session tests.
- Manually verified via a real sandboxed `install.sh` run (`env -i` + temp `HOME` +
  explicit `AGENT_LEARNING_HOME`, never the real `$HOME`): schema initializes,
  `messages_fts` and its FTS trigger-backing tables exist, and
  `self-learning-health.sh`'s Dependencies section now reports `sqlite3` as an
  optional PASS rather than a required one.

### Mutation testing

- **`ensure_schema()`'s FTS5 detection** — patched `if not probe_fts5():` to
  `if False:` (never detect unavailability): 2 explicit assertion failures + 1
  error in `tests/test-session-db.py` (`Ran 8 tests ... FAILED (failures=2,
  errors=1)`). Restored → 8/8 pass.
- **`index-session.sh`'s exit-code handling** — replaced the `if !
  SCHEMA_RESULT=$(...); then FATAL; exit 1; fi` guard with `SCHEMA_RESULT=$(...)
  || true` (silently swallow any real failure, reproducing the suspected old CLI
  behavior in the new code). Reproduced true silent success directly: with a
  deliberately broken base schema and zero session files to index, the mutated
  script exited **0 with no output at all** — the exact "component reports success
  while doing nothing" pattern this branch exists to eliminate. The new dedicated
  regression check in `tests/test-index-session-fts5-fallback.sh` failed as
  expected (`FAIL: a genuinely broken base schema is FATAL ... expected '1', got
  '0'`; `FAIL: the FATAL message names the real cause`). Restored → all 12 checks
  in that file pass again, and the real (non-mutated) script correctly exits 1
  with `[index-session] FATAL: failed to initialize session search database
  (...): ensure-schema failed: near "THIS": syntax error` against the same broken
  schema.
- **`search()`'s FTS5 query** — caught during development, not left for mutation
  testing to find: aliasing `messages_fts` (`FROM messages_fts f ... WHERE f
  MATCH ?`) raised `no such column: f` on this machine's SQLite build; fixed by
  querying the virtual table's own name directly (`FROM messages_fts ... WHERE
  messages_fts MATCH ?`), verified against a real end-to-end index-then-search run
  before it was in the test suite.

### What only CI can confirm

Confirmed here: Python's `sqlite3` module has FTS5 on this development machine
and on the CI-pinned 3.9.24 interpreter; the degraded (LIKE) path works end to end
when FTS5 is genuinely absent (simulated, not just asserted); a genuine schema
failure is now loud. **Not confirmed here, because I have no macOS access**: that
`actions/setup-python`'s macOS Python build actually has FTS5 the way I've reasoned
it does — this is a well-documented property of those relocatable builds, not a
guess pulled from nowhere, but it is still an inference about a build I have not
personally inspected. If macOS CI is still red after this fix, the next thing to
check is whether that inference was wrong (Python's own bundled SQLite on that
specific macOS runner also lacks FTS5) — in which case `ensure_schema()` already
degrades correctly rather than crashing (it was built and tested for exactly that
case, see the FTS5-unavailable simulation above), so a red run at that point would
mean the WARNING should be visible in the log rather than any test failing. If the
suite is still failing outright rather than degrading, that would point to
something in `session_db.py` itself I haven't accounted for on that platform.

## Suite count / interpreter results

- `bash tests/run-all.sh`: **37/37 suites passed** (34 baseline + 1 from the
  Windows/macOS round-one fix [`tests/test-list-transcripts.py`] + 2 from this
  FTS5 follow-up [`tests/test-session-db.py`, `tests/test-index-session-fts5-fallback.sh`]),
  both under system Python 3.13 and with Python 3.9
  (`~/.pyenv/versions/3.9.24/bin/python3.9`) shimmed first on `PATH`.
- All Python suites also run directly under the 3.9 interpreter individually: all
  pass, including `tests/test-session-db.py` (8/8), `tests/test-list-transcripts.py`
  (8/8), and `tests/test-adversarial-sweep.py` (95 attacks executed, 1 loudly
  skipped for an unrelated, pre-existing capability reason — case-sensitive
  filesystem here).

## Round three (CI run 30166469526): Windows test-harness path bug + macOS teardown race

Both prior fixes held: macOS 3.13 green, Ubuntu green both cells, and the macOS
log showed the FTS5 fallback behaving exactly as designed. Two failures
remained, both confirmed test-infrastructure, not product bugs.

### Failure A — Windows ×2: `tests/test-index-session-fts5-fallback.sh`

```
Traceback (most recent call last):
  File "<string>", line 4, in <module>
    import session_db
ModuleNotFoundError: No module named 'session_db'
```

**Real cause, confirmed by reading the test, not re-derived**: the suite's own
sanity check (added in round two, to prove the FTS5-unavailable simulation
actually works before trusting anything downstream) shelled into
`python3 -c "..."` with the lib directory baked in as a bash-interpolated
string literal inside the Python source:

```bash
PROBE_RESULT="$(... "${NOFTS5_BIN}/python3" -c "
import sys
sys.path.insert(0, '${IDX_SCRIPTS}/lib')
import session_db
...
")"
```

Git Bash auto-translates POSIX-style paths (e.g. `/tmp/xyz`) to Windows form
(`C:\...` or the native equivalent) only when they appear as their OWN argv
token passed to a native (non-MSYS) executable — not when embedded inside a
larger quoted string. `${IDX_SCRIPTS}/lib` here is the middle of a Python
source string, not its own argv token, so it reached native Windows
`python3.exe` untranslated and unresolvable. Every OTHER `python3` call in
this same test file (and in `index-session.sh` itself, which the coordinator
confirmed already passes on Windows) passes a file path or a value via
`sys.argv[N]` as its own token — the safe pattern.

**Fix**: write the probe as a real `.py` file (`_probe_fts5_sanity.py`) and
invoke it with its path as a normal argv token, so Git Bash's translation
applies the same way it already does everywhere else in this suite; the file
derives `sys.path` from `Path(__file__).resolve().parent` (the exact pattern
`index-session.py` and friends already use), with no manually constructed
path string anywhere.

**Verified on Linux (can't reproduce the failure itself — no Windows
access)**: reverting to the old embedded-string pattern still passes here,
confirming the bug is invisible on Linux (exactly why it shipped) and that
the fix is behavior-neutral where it can be tested directly — it only
removes a failure mode that requires Windows path translation to trigger.

**Bonus finding, same bug class, in production code**: grepped for the same
`python3 -c "..."` + bash-interpolated-path-in-source-string pattern across
`scripts/` and `install.sh`. Two hits, both untouched by the current CI
matrix's coverage of those code paths: `install.sh`'s legacy-install
detection and `scripts/doctor.sh`'s dir_fd capability probe. Both fixed the
same way (`sys.path.insert(0, sys.argv[1])`), in a separate commit, since it
is the identical class of latent Windows bug this branch exists to catch —
matches the safe pattern doctor.sh's own legacy-home probe and
`tests/lib/path-compare.sh`'s `sl_legacy_home` already use a few lines away
in the same files.

### Failure B — macOS 3.9 only: `tests/test-e2e-skill-visibility.sh`

```
PASS: dotted skill name: failure logged to persist-failures.log (not a silent no-op)
rm: /var/folders/.../store/logs: Directory not empty
rm: /var/folders/.../store: Directory not empty
```

**Real cause, confirmed by reasoning about the pipeline structure + the
coordinator's diagnosis, not re-derived**: `session-review.sh` and
`copilot-session-review.sh` both detach their ENTIRE pipeline (`nohup ... &`
+ `disown`), since a real review can take minutes while the hook that
launched it has a short timeout. Every test driving either path for real
used to poll for ONE target file to appear (`SKILL.md`,
`persist-failures.log`, `MEMORY.md`, a captured prompt file) and treat that
as "the pipeline is done." That is "a write started," not "the pipeline
finished" — `persist-proposal.py` can still be mid-write on other files (or
the shell wrapper still finishing its own bookkeeping) when the polled-for
file first appears. Read-only tests got away with this by luck (teardown
deferred to a trap firing much later, after many more instructions). This
suite's second scenario followed its poll with `rm -rf "$TMP_HOME2"` on the
very next line — the tightest possible window, and the one that actually
raced in CI.

**Two things fixed, per the coordinator's framing, in priority order:**

1. **Teardown robustness** (defense in depth): added `sl_rm_rf_retry` to
   `tests/lib/wait-for-review.sh` — a short, bounded retry loop around plain
   `rm -rf` (POSIX; no GNU-only flags, works identically under BSD rm and
   GNU rm). A transient "directory gained a file mid-delete" failure gets a
   few retries; a genuine persistent failure (permissions, a stuck process)
   still fails loudly after exhausting them, not silently swallowed.

2. **The real fix — wait for the pipeline to actually finish**: both
   `session-review.sh` and `copilot-session-review.sh` now write an
   unconditional (success or failure) completion marker —
   `"$SL_LOG_DIR/.review-complete"` — as the LAST statement of their detached
   pipeline. `sl_wait_for_review_complete` (same bounded-polling idiom this
   repo already uses in `tests/test-copilot-session-review.sh` and
   `tests/test-session-review.sh` — sleep-between-checks, bounded iteration
   count, loud diagnostics on timeout) polls for THAT marker instead of any
   file the pipeline's output happens to produce. `sl_clear_review_marker`
   removes any stale marker from a prior run in the same log dir before
   launching, so a reused store can never mistake an old completion for the
   current run's.

**Applied to** `tests/test-e2e-skill-visibility.sh` (both launches — this is
the suite that broke), `tests/test-claude-absent.sh` (one launch, same
poll-then-continue shape), and the real-pipeline-with-file-polling cases in
`tests/test-session-review.sh` (case 5) and `tests/test-copilot-session-review.sh`
(cases 7 and 8).

**Other suites checked for the same pattern, per the coordinator's ask**:
grepped every test file for `session-review.sh`/`copilot-session-review.sh`.
Two categories exist:

- **Live invocations without the marker wait, now fixed**: the four files
  above.
- **No live invocation at all**: `tests/test-script-paths.sh`,
  `tests/test-uninstall.sh`, `tests/test-install-paths.sh`,
  `tests/test-config.sh`, `tests/test-doctor.sh`,
  `tests/test-health-copilot-hooks.sh` all reference
  `session-review.sh`/`copilot-session-review.sh` only inside **static JSON
  hook-config fixture strings** the test asserts against textually (e.g.
  "does the hook-config template point at the right path") — none of them
  execute either script for real, so none carry this race.
- **Deliberately left as-is**: cases 1–4 and 6 in
  `tests/test-copilot-session-review.sh`/`tests/test-session-review.sh` use a
  DIFFERENT mechanism — a fake `claude`/`copilot` binary that itself
  synchronously appends to an argv-recording log file the instant it's
  invoked, checked with a bare `sleep 0.3` (not a poll loop) — and teardown
  in both files is a single EXIT trap firing only after every remaining case
  in the file has run, not an immediate post-poll delete. This is the same
  underlying class of unbounded-wait assumption, just with a much wider,
  unmeasured safety margin and no observed CI failure; retrofitting all of
  it would mean restructuring both files' shared `SL_LOG_DIR="$TMP/logs"`
  setup (global, not per-launch) to support per-launch marker clearing
  without cross-case interference — judged non-mechanical and out of scope
  for this round. Flagging here rather than silently leaving it undocumented,
  per the coordinator's ask.

### Mutation testing

The real pipeline is too fast on this development machine (trivial fake
binaries, no real model latency) to reliably reproduce the exact CI race
through the full stack without artificial slowdown, so the mechanism was
mutation-tested directly, which is also more rigorous (deterministic, not
timing-dependent luck):

- **`sl_wait_for_review_complete` actually waits, not just polls-and-returns
  early**: seeded a log dir where a target-shaped file appears at t=0.2s but
  the completion marker doesn't land until t=1.0s (matching the real
  pipeline's shape: an early write, more work after). A naive
  target-file poll returned at **0.22s** (mid-pipeline); the new
  marker-based wait correctly blocked until **1.05s** (after the pipeline's
  true last statement). This is the exact mechanism of the original bug,
  reproduced on demand.
- **`sl_rm_rf_retry` survives what a bare `rm -rf` does not**: built a
  deterministic (not probabilistic) transient-failure reproduction — a
  subdirectory made undeletable (`chmod 000`) for 0.6s, then unlocked by a
  background job. Mutation (bare `rm -rf`, no retry) under this exact
  scenario: **left the directory behind, rc=1** — precisely the CI symptom
  class (`Directory not empty` under `set -e`). Restored
  (`sl_rm_rf_retry`): **recovered in ~0.75s**, rc=0, directory gone.
- **Full-suite regression check**: `tests/test-e2e-skill-visibility.sh`,
  `tests/test-claude-absent.sh`, `tests/test-session-review.sh`, and
  `tests/test-copilot-session-review.sh` all still pass after every change
  (multiple repeated runs, no flakiness observed locally).

### What only CI can confirm

Confirmed here: the mechanism (wait-for-marker, retry-on-delete) is sound
under direct, deterministic mutation testing, and the full local suite is
green and repeatably so. **Not confirmed here**: whether 30s
(`sl_wait_for_review_complete`'s default budget, unchanged from the
existing convention) is generous enough for a real, loaded macOS/Windows CI
runner under whatever process-spawn overhead it has — if a genuine hang ever
happens there, the loud `find`-based timeout diagnostic will show a log dir
missing `.review-complete`, which is now distinguishable from "the pipeline
finished but produced the wrong content" (my target-shaped assertions run
afterward). For Failure A, only a green Windows run confirms the
`Path(__file__).resolve().parent` fix actually resolves cleanly through Git
Bash's real argv translation on a real Windows box, as opposed to my
reasoning about how that translation works.

## Suite count / interpreter results (round three)

- `bash tests/run-all.sh`: **37/37 suites passed** (unchanged from round two
  — round three added no new test files, only fixed existing ones and two
  production scripts), under both system Python 3.13 and Python 3.9
  (`~/.pyenv/versions/3.9.24/bin/python3.9`) shimmed first on `PATH`.
- All Python suites pass individually under the 3.9 interpreter directly.
