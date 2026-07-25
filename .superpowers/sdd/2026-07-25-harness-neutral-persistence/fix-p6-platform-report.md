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

## Suite count / interpreter results

- `bash tests/run-all.sh`: **35/35 suites passed** (34 baseline + 1 new,
  `tests/test-list-transcripts.py`), both under system Python 3.13 and with Python 3.9
  (`~/.pyenv/versions/3.9.24/bin/python3.9`) shimmed first on `PATH`.
- All Python suites also run directly under the 3.9 interpreter individually: all
  pass, including the new `tests/test-list-transcripts.py` (8/8) and
  `tests/test-adversarial-sweep.py` (95 attacks executed, 1 loudly skipped for an
  unrelated, pre-existing capability reason — case-sensitive filesystem here).
