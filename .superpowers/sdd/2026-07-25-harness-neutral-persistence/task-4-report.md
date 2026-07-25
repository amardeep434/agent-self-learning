# Task 4 Report: Secure writer (`scripts/persist-proposal.py`)

## What was implemented

- `scripts/persist-proposal.py` — the only component in this framework that writes to
  `memory/` or `learned-skills/`. Reads reviewer stdout, calls
  `proposal_schema.extract_proposal` / `validate_proposal`, then writes.
- `tests/test-persist-proposal.py` — copied verbatim from the brief (7 tests).

Followed TDD order: wrote the test first, ran it and confirmed it failed
(`can't open file .../persist-proposal.py`), implemented, ran again and
confirmed all 7 pass, then ran extra adversarial checks not in the brief
(below) before committing.

## Test command and output

```
$ python3 tests/test-persist-proposal.py -v
test_invalid_proposal_exits_1_and_writes_nothing ... ok
test_partial_validity_writes_nothing ... ok
test_symlinked_target_is_refused ... ok
test_append_mode_appends ... ok
test_dry_run_writes_nothing ... ok
test_no_json_is_success_and_writes_nothing ... ok
test_writes_memory_and_skill ... ok

----------------------------------------------------------------------
Ran 7 tests in 0.254s

OK
```

Before the implementation existed, the same command failed with 6 errors,
each `FileNotFoundError: [Errno 2] No such file or directory:
'.../scripts/persist-proposal.py'` — confirming the RED step.

`python3 -m py_compile scripts/persist-proposal.py` succeeds; the file only
uses syntax valid under 3.9 (`from __future__ import annotations` makes the
`list[tuple[...]]` hints lazy strings, no match-statements, no walrus, no
3.10+-only stdlib calls). I did not have a 3.9 interpreter available in this
environment to execute directly — flagging this as unverified rather than
claiming it.

## Deviations from the plan's code, with reasoning

The brief explicitly authorised strengthening checks. I made four
substantive changes beyond the plan's literal code, each triggered by
adversarial testing I ran myself (not just the given 7 tests):

1. **Root-directory symlink check added.** The plan's `_assert_inside` only
   compared `target.parent.resolve()` against `root.resolve()`. If `root`
   itself (e.g. `memory/`) is a symlink to somewhere outside the store, both
   sides of that comparison resolve to the *same* external location and the
   check passes — a silent bypass of the entire confinement mechanism. I
   added an explicit `root.is_symlink()` check before doing anything else.
   Verified with a manual adversarial test: symlinking `store/memory` to an
   external directory and attempting a write. Before the fix this would have
   silently written the "pwned" content into the external directory; after
   the fix it exits 2 with `refusing to use symlinked store directory` and
   the external directory is confirmed empty.

2. **Direct `open()` replaced with stage-then-`os.replace()`.** The plan
   checked `target.is_symlink()` then `open(target, "w"/"a")` directly. That
   is a TOCTOU window: a symlink swapped in between the check and the open
   would be followed by `open()`, writing through it. I instead write every
   entry to a `tempfile.mkstemp()`-created temp file inside the same
   directory, fsync it, and only then `os.replace(tmp, target)`.
   `os.replace`/`rename` never dereferences a symlink at the destination —
   it atomically swaps the directory entry — so even a symlink planted in
   the race window cannot redirect the write elsewhere. The explicit
   `is_symlink()` check is kept and still fires first, so a planted symlink
   is a loud, explicit failure (matching the test's expectation of exit 2)
   rather than a silent "successful" overwrite of the link entry.

3. **Read-side TOCTOU (append mode).** Reading the existing file for append
   mode had the same symlink-follow risk (information disclosure into the
   store, e.g. reading `/etc/passwd` into `MEMORY.md`). I open the read with
   `os.open(path, os.O_RDONLY | os.O_NOFOLLOW)` where `O_NOFOLLOW` exists
   (POSIX), which makes the open itself atomic against a symlink swap
   (kernel returns `ELOOP` instead of following). Windows has no
   `O_NOFOLLOW`; there I fall back to the `is_symlink()` pre-check alone,
   documented as a narrower, unclosable race on that platform.

4. **All-or-nothing writes across a multi-entry proposal.** The plan's
   per-entry loop wrote each file directly and only wrapped the whole loop
   in one `try`/`except`; a failure on entry 2 of 3 left entry 1 already
   overwritten on disk. I split the write into two phases: stage every
   entry to a temp file first (touching no real target), and only rename
   into place once every entry staged successfully. I found this gap
   through adversarial testing (not the brief's 7 tests): I constructed a
   proposal with a memory write and a skill write where the skill's target
   path was pre-occupied by a directory of the same name. In the plan's
   direct-write code, the memory file would commit before the skill entry's
   `open()` failed with `IsADirectoryError`, leaving the store
   partially — and silently, from the proposal's perspective —
   modified despite a `return 2`. My first version of the two-phase
   staging still had this hole for this *specific* case (directory
   collisions are detected by `os.replace`, i.e. during the rename phase,
   which happens after some earlier renames may have already committed), so
   I added an explicit `target.is_dir()` pre-check during the staging phase
   before any renames start. Verified: the same reproduction now returns 2
   with the memory file **not** written.

   This does **not** achieve full cross-file atomicity — a failure at the
   exact moment of `os.replace()` for entry 2 (after entry 1's rename
   already completed) still leaves entry 1 committed and entry 2 not. I
   consider this an accepted, documented residual risk: true multi-file
   transactional commit needs a journal or directory-swap technique that
   is out of proportion for a stdlib-only, cross-platform script, and the
   remaining failure modes (disk exactly full between two renames, a
   permission change mid-flight) are far less likely to be adversary-
   triggerable than a validation-time or staging-time failure, which are
   now both fully atomic. This is stated in the module docstring and in
   `_write_all`'s docstring rather than left implicit.

5. **Filename sanity check retained as belt-and-suspenders.** Added a check
   in `_assert_inside` that `target.name` contains no `/` or `\` and isn't
   `""`, `.`, or `..`. This is currently unreachable given the schema's
   guarantees (exact allow-listed memory filenames; skill names matching
   `\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z`), but costs nothing and protects
   against a future schema regression being the only thing standing between
   proposal content and the filesystem.

All of the above are strengthenings; nothing in the plan's checks was
weakened or removed.

## Answers to the four specific questions

**TOCTOU: `is_symlink()` then `open()` — can the target be swapped in
between? Is there a safer primitive?**
Yes, it's a real race on POSIX (and in principle on Windows, though
symlink creation there needs privilege by default). I closed it two ways:
(a) writes go through `mkstemp` + `os.replace`, and `replace`/`rename` never
follows a destination symlink — it replaces the directory entry — so the
race is structurally irrelevant for writes regardless of timing; (b) reads
(needed for append mode) use `os.open(..., os.O_NOFOLLOW)` on platforms that
define it, which is a single atomic syscall, closing the race entirely
there. Windows has no `O_NOFOLLOW`; the `is_symlink()` pre-check is the best
available stdlib primitive and leaves a narrow, disclosed residual race for
reads only (not writes, which are race-free everywhere via `replace`).

**Does `Path.resolve()` behave as expected when the target doesn't exist,
and on Windows?**
`Path.resolve(strict=False)` (the default) does not raise for a
non-existent path on any platform: it resolves symlinks and normalises
`.`/`..` in the parts that do exist, and appends the remaining (as yet
non-existent) components literally. I rely on this only for
`target.parent.resolve()` — the parent is always created via `mkdir(parents=
True, exist_ok=True)` before this call, so by the time we resolve it, it
exists and any symlinks in it are properly followed for the comparison. I
never call `.resolve()` on `target` itself before it exists, which avoids
any platform-dependent surprises around resolving a non-existent leaf.

**Append mode with a failure partway through a multi-file proposal: what
state is left, and is that acceptable?**
See deviation #4 above. With staging-then-rename, a failure during staging
(the common case — bad content, disk full while writing a temp file, a
symlinked or directory-occupied target detected before any rename) leaves
every real file untouched: fully acceptable. A failure during the rename
phase itself, after one or more renames already completed, can leave the
store with some but not all of the proposal's entries applied — I judged
this an acceptable, documented residual risk given the low likelihood of a
rename specifically failing (renames are near-instant local filesystem
operations) versus the cost of building a true multi-file transaction with
stdlib only, across three operating systems.

**Directory creation: could `mkdir(parents=True)` itself be induced to
create something outside the store?**
No new exposure beyond what's already covered by the root symlink check.
`target` is always `root / <single-path-component>` because the schema
guarantees the memory filename is an exact allow-list match and the skill
name regex forbids `/` and `\`, so `target.parent` is always `root` itself
— `mkdir(parents=True)` on `root` can only create `root`'s own ancestor
chain (all under the trusted `AGENT_LEARNING_HOME`/`XDG_DATA_HOME`-derived
`home`, which is environment-controlled, not proposal-content-controlled,
per the threat model), never anything named by attacker-supplied content.
The one thing `mkdir(parents=True, exist_ok=True)` does NOT protect against
is `root` already existing as a symlink — `exist_ok=True` silently accepts
an existing symlinked directory without creating anything, which is exactly
deviation #1's finding; the explicit `is_symlink()` check now catches it
before `mkdir` is even called in the normal case (already-existing root),
and unconditionally after `mkdir` returns.

## Things I was unsure about / did not fully resolve

- **Windows directory junctions.** `Path.is_symlink()` on Windows does not
  reliably detect NTFS directory junctions (`mklink /J`), which — unlike
  symlinks — do not require an elevated privilege to create. A store
  directory replaced with a junction could theoretically bypass the
  `is_symlink()` check on Windows. I did not add junction detection (would
  require `ctypes`/`ctypes.wintypes` calls against `GetFileAttributes` /
  reparse point tags, since the stdlib has no portable API for this), and I
  had no Windows environment to verify behaviour either way. Flagging this
  as an unresolved, Windows-specific gap rather than silently accepting it.
- **No Python 3.9 interpreter available** in this environment to actually
  execute the test suite under 3.9; I verified only via `ast.parse` /
  `py_compile` under 3.13 plus manual review that no 3.10+-only syntax or
  stdlib features are used.
- I did not add a check that `resolved["home"]` itself isn't a symlink,
  reasoning that `AGENT_LEARNING_HOME`/`XDG_DATA_HOME` are trusted
  environment inputs outside the adversary's control per the stated threat
  model (only proposal *content* is adversarial), and that legitimately
  symlinked home directories are common enough on real systems that
  rejecting them could break honest setups. This is a judgement call, not a
  correctness gap discovered by testing — flagging it in case the threat
  model is broader than I assumed.

---

## Fix round 1 (adversarial review response)

All Important and Minor findings addressed except Minor 3, which was explicitly
"document only, do not fix." The two residuals the reviewer adjudicated in my
favour (cross-device rename impossibility; store-root-as-symlink being an
acceptable trust boundary since the root comes from the environment, not
proposal content) required no changes.

### Important 1 — UnicodeDecodeError collapsing the exit-code contract

Fixed in `_read_existing`: reading now catches `UnicodeDecodeError` and
re-raises as `PersistError`, so a non-UTF-8 pre-existing file on an append
proposal reports as a write failure (exit 2) with a clean message, never a
raw traceback under exit 1. Also widened `main`'s `except` clause from
`(OSError, PersistError)` to `(OSError, PersistError, ValueError)` —
`UnicodeDecodeError` is a `ValueError` subclass, and this also covers any
future decode/parse-shaped failure in the write path without needing to
enumerate every possible stdlib exception type.

### Important 2 — hardlink leaking outside content into the store

Fixed in `_read_existing`: after opening (via `_open_nofollow_fd`), calls
`os.fstat(fd)` and refuses with `PersistError` if `st_nlink > 1`. Neither
`is_symlink()` nor `O_NOFOLLOW` see a hardlink — it's an ordinary regular
file from the filesystem's point of view, just with two directory entries
pointing at the same inode — so this needed its own check.

### Important 3 — zero test coverage on all four deviations

Added 6 CLI-level regression tests (`TestFixRound1Regressions`), matching the
reviewer's scenarios exactly: symlinked `memory/` root directory, target
path occupied by a directory, second-entry directory collision leaving the
first entry uncommitted, append through a symlinked existing file, append
through a hardlinked existing file, and append onto a non-UTF-8 existing
file. All assert both the exit code and (where applicable) that outside
content is untouched or no traceback leaked to stderr.

Two of the seven originally-surviving protections (the outside-store parent
comparison in `_assert_inside`, and `_open_nofollow_fd`'s O_NOFOLLOW/ELOOP
handling) are not reachable through the CLI at all given the current schema
guarantees (exact allow-listed memory filenames, slash-free skill-name
regex) — no proposal that passes `validate_proposal` can ever produce a
`target` outside `root`, or a filename containing a separator. For those I
added direct unit tests (`TestInternalGuardsUnreachableThroughSchema`) that
import `persist-proposal.py` via `importlib.util` (hyphenated filename, no
normal import) and call the internals directly:
`test_assert_inside_rejects_target_outside_root`,
`test_open_nofollow_fd_rejects_symlink`, and — because the first version of
this file passed on POSIX simply because the redundant O_NOFOLLOW
protection also happens to catch the same scenario —
`test_read_existing_rejects_symlink_even_without_o_nofollow`, which
monkeypatches `os.O_NOFOLLOW` away (simulating Windows) to isolate the
explicit `is_symlink()` pre-check in `_read_existing` from that overlap.

**Mutation results (16 tests total after these additions):**

| # | Protection | Mutation applied | Result |
|---|---|---|---|
| 1 | root-symlink check (`_assert_inside`) | removed the `_reject_if_symlink(root, ...)` call | **killed** — `test_symlinked_root_directory_is_refused` fails (exit 0/2 mismatch) |
| 2 | target-symlink check, READ path (`_read_existing`) | removed the explicit `is_symlink()` call | **killed** — `test_read_existing_rejects_symlink_even_without_o_nofollow` fails (needed the isolating test; the CLI-level append/symlink test alone did not catch it, because O_NOFOLLOW independently catches the same scenario on POSIX) |
| 3 | directory pre-check (`target.is_dir()`) | removed the check | **killed** — `test_directory_collision_on_second_entry_leaves_first_uncommitted` fails (MEMORY.md is committed when it shouldn't be) |
| 4 | staging-before-rename (two-phase commit) | interleaved rename immediately after each stage instead of after the whole loop | **killed** — same directory-collision test fails, for the same underlying reason: entry 1 gets committed before entry 2's failure is discovered |
| 5 | outside-store parent comparison (`root_r`/`parent_r`) | removed the comparison | **killed** — `test_assert_inside_rejects_target_outside_root` fails |
| 6 | O_NOFOLLOW | forced `nofollow = 0` unconditionally | **killed** — `test_open_nofollow_fd_rejects_symlink` fails |
| 7 | suspicious-filename check (`target.name` separator check) | removed the check | **survives** — no test fails |

Mutant 7 surviving is expected and, on inspection, not a coverage gap:
`pathlib.Path.name` cannot contain a path separator by construction — the
separator is what pathlib uses to split a path into parts in the first
place, so `target.name` (built from `root / entry["file"]` or
`root / f"{entry['name']}.md"`, both single path components) can never
contain `/` or `\`. This check is defensive against a hypothetical future
regression where `target` is constructed some other way, not something a
current test can exercise short of monkeypatching pathlib itself, which
would test the mock, not the code. Left as-is with its existing comment
explaining it is a backstop.

Exact commands run for each mutation (repeated for all seven, restoring the
original file after each from a saved copy at `/tmp/persist-proposal.orig.py`):

```
$ python3 - <<'EOF'
# mutate scripts/persist-proposal.py in place, string-replace the target line
EOF
$ python3 tests/test-persist-proposal.py 2>&1 | tail -8
$ cp /tmp/persist-proposal.orig.py scripts/persist-proposal.py   # restore
```

Final full suite after restoring the fixed (non-mutated) file:

```
$ python3 tests/test-persist-proposal.py -v
...
----------------------------------------------------------------------
Ran 16 tests in 0.469s

OK
```

### Important 4 — Windows junction detection does exist in stdlib

Confirmed and corrected: `os.lstat(path).st_reparse_tag` is available on
Windows since Python 3.8 and flags both symlinks and junctions (my original
report's claim that this "would need ctypes" was wrong — retracted here).
Added to `_reject_if_symlink`: after the existing `is_symlink()` check,
reads `getattr(path.lstat(), "st_reparse_tag", 0)` and refuses if truthy,
guarded so it's a silent no-op on POSIX where the attribute doesn't exist
(caught via `getattr(..., 0)` plus a `try/except OSError` around the
`lstat()` call itself for the not-yet-existing-path case). Not independently
unit-testable in this Linux environment (the attribute is simply absent
here, so `getattr` always returns 0) — flagged as unverified on an actual
Windows machine rather than claimed as tested.

### Minor 1 — 0600 policy documented

Added a paragraph to `_stage`'s docstring stating that `mkstemp`'s 0600 mode
carrying onto the final target via `os.replace` is deliberate policy (closes
any disclosure window during a partial write), not an accidental mode
downgrade of a previously-0644 file.

### Minor 2 — unbounded append growth

Added `MAX_MEMORY_FILE_BYTES = 1 * 1024 * 1024` (1 MiB) as a module
constant. In `_write_all`, after computing `data` (existing content plus new
content for append mode, or just new content for replace), checks
`len(data.encode("utf-8")) > MAX_MEMORY_FILE_BYTES` and raises `PersistError`
before staging if exceeded. This bounds the file's size *after* the write,
which is the quantity that actually matters — `proposal_schema` only bounds
a single proposal's contribution.

### Minor 3 — directory-level TOCTOU (documentation only, no fix)

Added one sentence to `_write_all`'s docstring: the gap between
`_assert_inside(root, ...)` and `tempfile.mkstemp(dir=root)` inside `_stage`
admits, in principle, `root` being swapped for a symlink in between; closing
it would need `dir_fd`-relative operations throughout, and `mkstemp` has no
`dir_fd` parameter to hang that off of. No code change, per the reviewer's
instruction.

## Files changed in this round

- `scripts/persist-proposal.py` — all six code fixes above (+84/-4 lines)
- `tests/test-persist-proposal.py` — 9 new tests: 6 CLI-level regressions
  (`TestFixRound1Regressions`) plus 3 direct-unit tests
  (`TestInternalGuardsUnreachableThroughSchema`) (+162 lines)

## Final test command and output

```
$ python3 tests/test-persist-proposal.py -v
test_append_on_non_utf8_existing_file_is_refused_without_traceback ... ok
test_append_through_hardlinked_existing_file_is_refused ... ok
test_append_through_symlinked_existing_file_is_refused ... ok
test_directory_collision_on_second_entry_leaves_first_uncommitted ... ok
test_symlinked_root_directory_is_refused ... ok
test_target_is_a_directory_is_refused_without_traceback ... ok
test_assert_inside_rejects_target_outside_root ... ok
test_open_nofollow_fd_rejects_symlink ... ok
test_read_existing_rejects_symlink_even_without_o_nofollow ... ok
test_invalid_proposal_exits_1_and_writes_nothing ... ok
test_partial_validity_writes_nothing ... ok
test_symlinked_target_is_refused ... ok
test_append_mode_appends ... ok
test_dry_run_writes_nothing ... ok
test_no_json_is_success_and_writes_nothing ... ok
test_writes_memory_and_skill ... ok

----------------------------------------------------------------------
Ran 16 tests in 0.469s

OK
```

## Still unsure about / unresolved

- Windows junction handling (`st_reparse_tag`) is implemented per the
  reviewer's exact guidance but genuinely unverified on Windows — this
  environment is Linux-only, so the attribute is always absent here and the
  code path exercising it (the `if reparse_tag:` branch actually firing) has
  never executed. Worth a real Windows CI run before trusting it fully.
- Mutant 7 (suspicious-filename check) surviving is, on reflection, expected
  rather than a gap — see above — but flagging in case the reviewer wants a
  test anyway (would require monkeypatching `Path.name`/`PurePath`
  internals, which felt like testing the mock rather than the code).
