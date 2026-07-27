# Fix round E report — harness-neutral-persistence

Round E is the last blocker: CI run `30155575042` was green on 4/6 cells (ubuntu
3.9/3.13, macOS 3.9/3.13) after round D. Only `windows-latest` × 2 remained red,
13 of 27 suites failing, plus one Python suite reporting `FAILED (failures=4)`.

## Summary of what changed

Two independent, compounding root causes were found and fixed, plus one
per-suite class of test-fixture bug:

1. **A real product bug, high confidence, previously undiagnosed**:
   `scripts/lib/paths.py`'s CLI output was not forced to LF-only line
   endings. Python's default text-mode `sys.stdout` on native Windows
   translates outgoing `"\n"` to `"\r\n"` **even when the destination is a
   pipe, not a console** — this is `io.TextIOWrapper`'s own behavior,
   unrelated to (and not fixed by) anything MSYS/Git-Bash does. Every bash
   consumer of this CLI (`config.sh`, `install.sh`, `uninstall.sh`) reads
   this output either via `while IFS='=' read -r k v; do ... done < <(python3
   paths.py all)` or via `$(... paths.py get key)` command substitution. In
   **both** cases bash strips only the trailing `\n` record terminator,
   never a `\r` immediately preceding it. Every single resolved path value
   would therefore carry an invisible trailing `\r` on Windows — corrupting
   every downstream use: a directory literally named `...logs\r` is not the
   same directory as `...logs` (silently making every store subpath
   resolved through `config.sh`'s/`install.sh`'s read loops wrong on
   Windows — the exact silent-wrong-location class this project exists to
   eliminate); and where a resolved path is substituted into a JSON
   template (`install.sh`'s `copilot-hooks.json` rendering via `sed`), the
   embedded raw `\r` is an unescaped control character inside a JSON string
   — invalid per RFC 8259 — which breaks strict JSON parsers like `jq`
   downstream. This is confirmed empirically as a **real jq behavior**:
   `echo 'not json' | jq -r '...'` exits **5**, matching the reported
   `test-install-paths.sh` exit code exactly (the suite's one unguarded
   `jq -r` call, against the rendered Copilot hook config, under
   `set -euo pipefail`, with no `||` guard, would abort the whole script
   with jq's exit status the moment it hit malformed JSON).

   **Fix**: `scripts/lib/paths.py`'s `_main()` now calls
   `sys.stdout.reconfigure(newline="\n")` before printing anything, forcing
   LF-only output regardless of platform. This is the single-place fix (the
   CLI boundary every consumer reads), not a per-consumer patch. As defence
   in depth (belt-and-suspenders, since the root fix should make this a
   no-op), `config.sh`, `install.sh`, and `uninstall.sh`'s `while IFS='='
   read` loops now also strip a trailing `\r` from each value
   (`_v="${_v%$'\r'}"`) in case any other producer or CI wrapper ever
   reintroduces one.

   **This is a hypothesis, not confirmed by a live Windows run** — there is
   no Windows execution environment available to this session. It is
   supported by: (a) documented, well-known Python-on-Windows behavior
   (text-mode stdout newline translation is unconditional, not
   console-dependent); (b) an exact, reproduced-locally exit-code match
   (`jq -r` on malformed JSON → exit 5, precisely the reported
   `test-install-paths.sh` exit code); (c) `install.sh` and `config.sh`
   share the identical `while IFS='=' read` parsing pattern, so this single
   bug plausibly explains the WIDE blast radius (13/27 suites) better than
   any narrower per-suite explanation, since it would silently corrupt
   every path resolved through either of those loops. It is the strongest
   available explanation but remains unverified without Windows CI.

2. **A confirmed spelling-mismatch pattern (round D's own diagnosis, not yet
   applied everywhere)**: many test assertions compare a bash-spelled path
   (built by hand from `mktemp -d`, e.g. `"${TMP_HOME}/store/memory"`)
   against a path the product resolved via a native `python3.exe`
   subprocess (`$SL_MEMORY_DIR`, `RESOLVED_SCRIPTS`, etc). On Git Bash/
   MSYS2 these can be the same real directory (MSYS remaps `/tmp` <->
   `%TEMP%`) while being spelled completely differently as strings, because
   MSYS auto-converts POSIX-looking argv/env values crossing into a native
   (non-MSYS) executable. Round D applied the fix (`-ef` comparison) to
   exactly one assertion in `test-config.sh`. Round E generalizes it: **one
   shared helper**, `tests/lib/path-compare.sh`, sourced by every suite that
   needs it, instead of a second (and third, and…) pasted copy — the same
   lesson that produced the isotime 3.9 regression in round D.

3. **The round-D-blocker-(b)-part-3 forwarder-script fix (confirmed working
   by the coordinator's CI evidence: `test-config.sh`'s exit 127 is gone)
   was only ever applied to `test-config.sh`.** `test-doctor-no-python.sh`
   and `test-health-no-python.sh` build an identical restricted PATH using
   the same pre-fix `cp`-based technique (copying `bash`/`mkdir`/etc. into
   an isolated directory, separating them from their DLL siblings on
   Windows). Fixed by routing both through the same shared
   `sl_forwarder` helper.

## `tests/lib/path-compare.sh` — the shared helper

New file, sourced (never copied) by every suite below. Provides:

- **`sl_canon_path <path>`** — canonicalizes an arbitrary path *string* via
  Python's `os.path.realpath` (works on nonexistent paths). Passing the
  string as argv to a native `python3.exe` from bash triggers the same MSYS
  auto-conversion a real product subprocess call would apply, so two
  differently-spelled strings naming the same directory converge to the
  same canonical output.
- **`sl_same_path <a> <b>`** — true if `a`/`b` name the same path.
  Prefers `-ef` when both already exist (strictly stronger — also correctly
  handles a genuine symlink/hardlink relationship); falls back to
  `sl_canon_path` equality otherwise.
- **`sl_check_same_path <desc> <expected> <actual>`** — `check`-shaped
  wrapper (PASS/FAIL, increments the caller's `FAILURES`), for drop-in use
  alongside this project's existing `check "desc" "$expected" "$actual"`
  convention.
- **`sl_resolve_path <paths.py-path> <key> [ENV=VAL ...]`** — calls
  `python3 <paths.py-path> get <key>` under a caller-specified `env -i`
  environment, mirroring exactly how `config.sh`/`doctor.sh` resolve the
  same key. Used where the "expected" value should be *derived* (fixture
  construction), not merely compared after the fact — critical for hook-
  freshness fixtures, where `sl_check_hook_fresh()` in `lib/config.sh` does
  a **textual** grep match, which `sl_same_path` cannot help with after the
  fact if the fixture itself was authored with the wrong spelling.
- **`sl_legacy_home <scripts/lib-dir> [ENV=VAL ...]`** — mirrors
  `doctor.sh`'s own inline `paths.legacy_home()` snippet exactly.
- **`sl_forwarder <src> <dst>`** — writes a forwarder shell script
  (`#!/bin/sh\nexec "<src>" "$@"`) instead of `cp`-ing a binary, for
  building a restricted PATH.

**New test**: `tests/test-path-compare-lib.sh` (28th suite) exercises every
function against synthetic inputs on Linux — symlink canonicalization,
nonexistent-path normalization, forwarder scripts correctly forwarding args
and preserving exit codes, a restricted PATH built from forwarders
correctly resolving the forwarded tool and correctly failing to resolve a
non-forwarded one, and `sl_resolve_path`/`sl_legacy_home` matching a direct
`paths.py`/`paths.legacy_home()` call byte-for-byte. This cannot exercise
the actual MSYS auto-conversion (only happens on real Git Bash/MSYS2); the
file's own header comment states this plainly.

## Per-suite classification

| Suite | Classification | Fix |
|---|---|---|
| `test-config.sh` | Test-spelling artifact (2 assertions) | `sl_check_same_path` for "missing file falls back to defaults" and the I5 `SL_COACH_RULES_DIR` assertion (both compare a bash literal `HOME`-derived path against a python-resolved one). Replaced the round-D one-off `-ef` block and local `_sl_link_or_copy` with the shared `sl_check_same_path`/`sl_forwarder`. |
| `test-doctor.sh` | Test-spelling artifact (3 spots) | `sl_resolve_path` for "doctor prints resolved memory path"; `sl_legacy_home` for "legacy store path reported"; `sl_resolve_path` for section 6b's `RESOLVED_SCRIPTS` hook-config fixture (previously a bash-literal `"${STORE}/scripts"`, textually compared by `sl_check_hook_fresh()` against a python-resolved value). |
| `test-doctor-no-python.sh` | Real bug in test infra, not spelling: the round-D-confirmed `cp`-vs-DLL-siblings bug, just not yet applied here | Routed the restricted-PATH construction through `sl_forwarder`. |
| `test-doctor-persist-log.sh` | **Not independently confirmed** — see below | No suite-specific fix applied; see "Unresolved / unexplained" below. |
| `test-e2e-skill-visibility.sh` | Not a spelling artifact — hypothesis: insufficient poll timeout for slower Windows process-spawn overhead (the pipeline runs fully detached via `nohup ... & disown`, so the test polls for a background result) | Widened both poll loops from 10s to 30s and made a timeout loud (dumps the store's directory tree) rather than just failing silently on "file not found". Unconfirmed without a live Windows run — flagged as a hypothesis in the code comment. |
| `test-health-copilot-hooks.sh` | Test-spelling artifact | `sl_resolve_path` for the "fresh copilot hook" fixture's `RESOLVED_SCRIPTS` (same bash-literal-vs-python-resolved-then-textually-compared shape as test-doctor.sh's 6b). |
| `test-health-no-python.sh` | Real bug in test infra (same as test-doctor-no-python.sh) | Routed the restricted-PATH construction through `sl_forwarder`. |
| `test-health-writer-self-check.sh` | **Not independently confirmed** — see below | No suite-specific fix applied; see "Unresolved / unexplained" below. |
| `test-install-paths.sh` (exit 5) | **Real product bug** (see item 1 above: `jq -r` on malformed JSON from the un-LF'd `paths.py` output) + one spelling artifact | Root fix in `paths.py`/`config.sh`/`install.sh` (item 1). Also fixed "resolved scripts dir is under the store" (bash-literal vs. python-resolved, `check` → `sl_check_same_path`) and defensively strengthened the already-safe `SL_COACH_RULES_DIR` comparison the same way. |
| `test-script-paths.sh` | Test-spelling artifact (4 spots) | `sl_check_same_path` for the three `RESOLVED_STATE`/`RESOLVED_SKILLS`/`RESOLVED_DB` assertions; `sl_resolve_path` for the section's `RESOLVED_SCRIPTS` hook-config fixture (identical shape to test-doctor.sh's 6b). |
| Python suite, `FAILED (failures=4)` | **Not conclusively identified** — see below | No fix applied; best-effort candidate named, with the reasoning for why it does not actually explain the failure. |

## Unresolved / unexplained (honest reporting, not guessed)

- **`test-doctor-persist-log.sh`** and **`test-health-writer-self-check.sh`**:
  read closely for any bash-literal-vs-python-resolved comparison, any
  hardcoded timestamp/path substring check, and any GNU-only flag. Found
  none — both suites' assertions check for content markers
  (`"ABSENT"`/`"SUSPICIOUS"`/`"Status: HEALTHY"`/exit codes), never a raw
  path string, and file-*existence* checks (`[[ -e ]]`/`[[ -f ]]`) are
  immune to the MSYS spelling-mismatch class entirely (bash resolves a path
  through its own consistent MSYS view regardless of how a different
  process spelled an equivalent path internally — that is a filesystem
  lookup, not a string comparison). **These two ARE plausibly explained by
  item 1 above** (the CRLF corruption bug): both suites source `config.sh`
  transitively (via `doctor.sh`/`self-learning-health.sh`), and a stray
  `\r` embedded in `SL_LOG_DIR` would make `${SL_LOG_DIR}/persist-failures.log`
  resolve to a directory (`...logs\r`) that was never created by the
  test's own `mkdir -p "${TMP_HOME}/store/logs"` fixture — every "populated
  log" assertion would then see `ABSENT` regardless of what was actually
  seeded. This is plausible but **not independently verified** — no
  suite-specific code change was made for either file beyond what the
  shared `paths.py`/`config.sh` fix already provides. If CI is still red on
  either after this fix, that disproves this specific explanation and both
  need a fresh, code-level look with real Windows failure output in hand.

- **The Python suite reporting `FAILED (failures=4)`**: could not be
  conclusively identified from static analysis. The strongest name/count
  match is `tests/test-proposal-schema.py`'s `TestImportant5WindowsReserved`
  class (exactly 4 test methods, explicitly about Windows reserved device
  names). However, reading `proposal_schema.py`'s actual check —
  `_need(name.upper() not in _WINDOWS_RESERVED, ...)` — this is pure
  in-memory string/set-membership logic with **zero OS calls**, unconditional
  on platform; it cannot behave differently on Windows by construction (this
  was verified by re-reading the exact code path, not merely inspected at a
  distance). `tests/test-persist-proposal.py`'s symlink/hardlink-dependent
  tests (the other plausible Windows-sensitive candidates, since `os.symlink`
  needs elevated privilege on Windows) already self-skip loudly via
  `if sys.platform.startswith("win"): self.skipTest(...)` on every one of the
  7 tests that create a symlink or hardlink — confirmed by reading every
  `def test_` in that file — so that suite is already Windows-aware and an
  unlikely source of 4 unexplained *failures* (as opposed to skips, which
  unittest reports separately from "failures" in its summary line).
  **This is reported honestly as unresolved** rather than guessed at with a
  fabricated fix — a wrong guess here risks papering over a real, different
  bug. Needs the actual CI log's full test names to identify conclusively.

## Mutation/regression verification

- `bash tests/run-all.sh`: **28/28 suites pass** on Linux/3.13 (up from 27 —
  added `tests/test-path-compare-lib.sh`; the count did not drop, per the
  constraint).
- All 6 Python suites re-run under `~/.pyenv/versions/3.9.24/bin/python3.9`:
  all pass, including the 2 new `TestCliLineEndings` tests in
  `tests/test-paths.py` (29 tests now, up from 27).
- `bash -n`/`ast.parse` syntax-checked every changed shell/Python file.
- Manually confirmed the jq-exit-5 mechanism: `echo 'not json' | jq -r
  '.x'` → exit 5, reproduced locally, matching the reported
  `test-install-paths.sh` failure mode exactly.
- Manually confirmed the `cp`-vs-forwarder distinction is now applied
  uniformly: `grep -rn "cp \"\$_tool_path\"" tests/*.sh` (the pre-fix
  pattern) now returns zero hits across the whole `tests/` directory.

## What remains unverifiable without a live Windows run

- The `paths.py` stdout-CRLF fix (item 1) — the single highest-confidence
  fix in this round — cannot be exercised on Linux/macOS at all, since
  neither platform ever performed the `\n`→`\r\n` translation this fix
  disables. The `TestCliLineEndings` tests added to `tests/test-paths.py`
  assert "no `\r` byte in the CLI's raw output", which is trivially true on
  Linux both before and after the fix — they pin the invariant for future
  regressions but cannot themselves prove the Windows behavior changed.
- The `test-e2e-skill-visibility.sh` timeout widening (Windows process-spawn
  overhead) is a reasoned hypothesis, not a confirmed diagnosis.
- `test-doctor-persist-log.sh` and `test-health-writer-self-check.sh`'s
  presumed transitive fix via item 1 (no suite-specific change made).
- The Python `FAILED (failures=4)` suite's identity.
- Whether windows-latest CI is actually green after this round — no
  Windows execution environment is available to this session at any point
  in this work.

## Files changed

- `scripts/lib/paths.py` — `_main()` now forces LF-only stdout via
  `sys.stdout.reconfigure(newline="\n")`.
- `scripts/lib/config.sh`, `install.sh`, `uninstall.sh` — defence-in-depth
  trailing-`\r` strip in each `while IFS='=' read` loop parsing `paths.py`'s
  output.
- `tests/lib/path-compare.sh` — new, the shared helper.
- `tests/test-path-compare-lib.sh` — new, pins the helper.
- `tests/test-paths.py` — two new `TestCliLineEndings` tests.
- `tests/test-config.sh`, `tests/test-doctor.sh`, `tests/test-doctor-no-python.sh`,
  `tests/test-health-no-python.sh`, `tests/test-health-copilot-hooks.sh`,
  `tests/test-install-paths.sh`, `tests/test-script-paths.sh` — path
  comparisons/fixtures routed through the shared helper.
- `tests/test-e2e-skill-visibility.sh` — widened poll timeouts, loud
  timeout diagnostics.

## Commit

`fix: LF-only paths.py stdout, shared path-comparison test helper (round E)`
— see `git log` for the SHA.

---

# Fix round F — the last three suites

CI run `30156561042`: round E took Windows from 13 failing suites to 3
(`tests/test-paths.py`, `tests/test-path-compare-lib.sh`, `tests/test-doctor.sh`),
with ubuntu ×2 and macOS ×2 staying green. The CRLF diagnosis (round E,
item 1) was confirmed right — it fixed the bulk of the blast radius. This
round works from the coordinator's actual Windows CI log output for the
three remaining suites, rather than re-deriving blind.

## 1. `tests/test-paths.py` — 4 failures, all test-side

**Root cause (3 of 4): test isolation, not production logic.** Three
`TestCliFormatting` tests either passed `msystem=None` expecting it to mean
"force no MSYSTEM" (`test_native_windows_without_msystem_keeps_as_posix_form`),
or didn't pass `is_windows=`/`msystem=` at all and silently read ambient
`os.environ` (`test_windows_path_rendered_with_forward_slashes`,
`test_main_all_emits_no_backslashes_for_a_windows_style_env`). `_to_cli_string`'s
signature treats `msystem=None` as "caller didn't specify, fall back to
`os.environ.get("MSYSTEM")`" — there was no way to explicitly force "no
MSYSTEM" through the sentinel as these tests assumed. On the real
windows-latest CI runner (genuinely Git Bash, `MSYSTEM` genuinely set),
that ambient fallback silently overrode what each test believed it was
asserting, so `os.name == "nt" and MSYSTEM` correctly fired and produced
the MSYS cygdrive form — while the test still expected `.as_posix()`. The
production logic was right throughout; verified by inspection (no code
change to `_to_cli_string`/`_to_msys_path` was needed for these three).

**Fix**: all three now wrap their body in
`with mock.patch.dict(os.environ, {"MSYSTEM": ""}):`, forcing "no MSYSTEM"
deterministically regardless of the ambient shell (empty string is falsy,
same effect as unset, without needing conditional delete/restore
bookkeeping). Verified the fix actually depends on this by re-running the
whole suite with `MSYSTEM=MINGW64` set ambiently before invoking
`python3 tests/test-paths.py` — still 30/30 green, where before this
round's fix the three tests would have read that ambient value and failed
exactly as CI did (this reproduces one half of the real Windows condition
locally; the other half, `os.name == "nt"`, cannot be reproduced without
Windows — see below).

**Root cause (4th, `test_get_prints_single_path`): a genuine bug, but in
the TEST's ground truth, not the CLI.** The failure
(`'/tmp/x/memory' != '\\tmp\\x\\memory'`) is `assertEqual(out, expected)`
printing `actual != expected` — the CLI's own output (`out`) was already
the CORRECT forward-slash form; the test's `expected` value,
`str(Path("/tmp/x/memory"))`, is itself platform-dependent: on native
Windows, `Path(...)` constructs a `WindowsPath`, and a **drive-less**
absolute path (no drive letter — `PureWindowsPath("/tmp/x").drive == ""`,
confirmed by direct inspection) renders via `str()`/`os.fspath()` with
**backslashes**, since that codepath was never routed through
`_to_cli_string` at all — it is the test's raw ground-truth construction,
not anything the product emits. `_to_msys_path` correctly falls back to
`.as_posix()` for a driveless path (documented in its own docstring
already), and `.as_posix()` is forward-slash **by definition**, on every
platform, in every branch — there is no code path in `_to_cli_string`
that can ever produce a backslash. Confirmed by direct repro with
`PureWindowsPath`:
```
>>> PureWindowsPath('/tmp/x').drive, str(PureWindowsPath('/tmp/x')), PureWindowsPath('/tmp/x').as_posix()
('', '\\tmp\\x', '/tmp/x')
```

**Fix**: added an explicit, pinned unit test
(`test_driveless_absolute_path_renders_forward_slash_not_backslash`) that
asserts a driveless `PureWindowsPath` renders forward-slash across all
three `(is_windows, msystem)` combinations that matter (MSYS-form
requested, native-Windows-no-MSYS, and non-Windows) — making this an
explicit, testable decision rather than something only inferred from a
different test's incidental behavior. Fixed `test_get_prints_single_path`
itself to build its expected value via `paths._to_cli_string(Path(...))`
(in-process, same interpreter/OS the subprocess also runs on) instead of
raw `str(Path(...))`, which is correct on every platform since it exercises
the exact same rendering function the CLI subprocess uses, rather than
`pathlib`'s incidental default `str()` behavior.

## 2. `tests/test-path-compare-lib.sh` — two distinct problems

**Problem A: `sl_canon_path` was a second, divergent implementation of path
rendering.** It shelled out to an inline
`python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))'`, which
prints via plain `print()` — i.e. whatever `os.path.realpath` returns in
the platform's native flavour (backslashes on Windows). Every other
resolved value elsewhere in this project's test output is already in MSYS
cygdrive form (`/c/Users/...`) after rounds D/E; this helper — meant to be
the single place path comparison happens — was quietly producing a THIRD
spelling convention, confirmed directly by the reported CI output:
`sl_canon_path` returned `'C:\Users\...\real'` in the same run where every
other resolved value was already `/c/...`. This is exactly the
duplicated-copy pattern flagged in round D's isotime fix and round E's own
module docstring ("do it once, share it").

**Fix**: added a `canon` subcommand to `scripts/lib/paths.py` itself —
`python3 paths.py canon <path>` combines `os.path.realpath` (works on a
nonexistent path, which `sl_canon_path`'s docstring and tests require) with
`_to_cli_string`'s existing MSYS-aware rendering, so it is byte-identical
in spelling convention to every other value this CLI emits. `sl_canon_path`
in `tests/lib/path-compare.sh` now shells out to this subcommand instead of
reimplementing rendering a second time in bash — one implementation, shared,
per this project's own "paths computed in exactly one place" constraint.
Verified unchanged behavior on Linux (all 22 `test-path-compare-lib.sh`
assertions still pass) since `_to_cli_string` on a `PosixPath` reduces to
`.as_posix()`, identical to what the removed inline `print()` produced
there.

**Problem B: the symlink-dependent assertions assumed symlink creation
always succeeds.** On Windows, `ln -s` commonly cannot create a real
symbolic link without Developer Mode or elevation; Git Bash/MSYS's `ln` is
documented to fall back to copying the target rather than failing outright
in that case. A copy is not a symlink — `sl_canon_path` "resolving" a copy
to itself proves nothing about symlink-following, and the assertion would
have been vacuously green for the wrong reason (or wrongly red, depending
on exactly how the copy fallback behaves) either way.

**Fix**: after the `ln -s` attempt, `[[ -L "$LINK_DIR" ]]` is checked
directly — this is the ground truth for whether a real symlink exists,
regardless of which failure mode (silent copy vs. hard failure) actually
occurred, so it is **determined, not assumed**, per the coordinator's
instruction. Two assertions (`sl_canon_path resolves a symlink to its real
target`, `sl_same_path: real dir vs. symlink to it`) are gated on this and
**skip loudly, with the specific reason, printed to stdout** when no real
symlink could be created — never silently, and never by deleting the
assertion. The `sl_check_same_path` wrapper's own self-test ("equal case")
was rerouted to a **non-symlink** example (a trailing-slash spelling of the
same real directory) specifically so that self-test of the helper itself —
not a property of the OS's symlink support — always runs regardless of
symlink privilege. On this Linux dev machine, real symlinks succeed
(`_SL_HAS_REAL_SYMLINKS=1`), so both previously-skippable assertions still
run and pass; the skip path itself was exercised manually by forcing
`_SL_HAS_REAL_SYMLINKS=0` and confirming the two SKIP lines print with
their stated reason and the suite still exits 0.

## 3. `tests/test-doctor.sh` — 2 failures, confirmed platform limitation

**Root cause, verified not assumed.** The coordinator's hypothesis
(`chmod -w` is largely a no-op on Windows, since write access there is
governed by ACLs, not POSIX mode bits) is architecturally correct, and the
fix does not merely assume it — it adds a real probe: after `chmod 500
"$LOCKED_PARENT"`, the test now attempts to actually create a file inside
that directory (`( : > "$_sl_probe" ) 2>/dev/null`) as the same user
running the test (never root — the pre-existing root-skip guard is
untouched). If that probe **succeeds**, the directory is demonstrably still
writable despite `chmod 500`, meaning this test's premise does not hold on
this platform/filesystem — `doctor.sh` reporting it "writable" is CORRECT
behavior (its own `_sl_test_writable` does the identical kind of real
create+delete probe, per its own comment "actually tested, not inferred"),
not a bug to fail the test over.

**Fix**: the two dependent assertions (`NOT WRITABLE` reported,
exit code 1) now run only when the probe genuinely fails (real
non-writability, confirmed). When the probe succeeds, both assertions are
**skipped loudly** with a reason naming exactly what was verified (the
probe file was created despite `chmod 500`) and the most likely platform
explanation, rather than silently passing or silently vanishing. On Linux,
the probe correctly fails (`Permission denied`, suppressed cleanly via a
subshell redirect rather than leaking a raw shell error into the test
output) — verified the full assertions still run and pass here, so the
writability check remains **fully exercised on Linux/macOS**, per the
instruction not to weaken it globally for one platform.

## Skips added (all loud, all named)

| Suite | Skip | Trigger | Reason printed |
|---|---|---|---|
| `test-path-compare-lib.sh` | `sl_canon_path resolves a symlink to its real target` | `[[ -L "$LINK_DIR" ]]` false after `ln -s` | Names the platform (Windows Developer Mode/elevation), the fallback behavior (Git Bash `ln` copying instead of linking), and that this was verified via `-L`, not assumed. |
| `test-path-compare-lib.sh` | `sl_same_path: real dir vs. symlink to it` | Same `-L` check | Same, cross-referenced. |
| `test-doctor.sh` | `non-writable dir reported as NOT WRITABLE` + `non-writable dir flips exit code to 1` (as one skip covering both) | The writability probe succeeds despite `chmod 500` | Names the directory, that this was verified by actually creating a file (not assumed), and the ACL-vs-POSIX-mode-bits explanation. |

No suite was skipped in its entirety; no assertion was deleted; no global
weakening was applied — every skip is scoped to the specific assertions
whose premise (symlink creation / POSIX-mode-bit enforcement) does not
hold, and every skip prints its reason to stdout as part of the suite's own
normal output, visible in `bash tests/run-all.sh`'s log exactly like a
PASS or FAIL line would be.

## Verification

- `bash tests/run-all.sh`: **28/28 suites pass** on Linux/3.13 (unchanged
  count, per the constraint).
- All 6 Python suites re-run under `~/.pyenv/versions/3.9.24/bin/python3.9`:
  all pass, including `test-paths.py`'s 30 tests (up from 29 — added the
  driveless-path pin).
- `bash -n` / `ast.parse` syntax-checked every changed file.
- `python3 scripts/lib/paths.py canon /tmp` / `canon /tmp/nonexistent-xyz`
  manually verified to print correctly on Linux (both existing and
  nonexistent inputs).
- Re-ran `tests/test-paths.py` with `MSYSTEM=MINGW64` set ambiently before
  invocation to confirm the three `mock.patch.dict`-fixed tests no longer
  depend on it — still 30/30 green (this reproduces the `MSYSTEM`-set half
  of the real Windows condition; `os.name == "nt"` cannot be reproduced
  without Windows, so this is a partial, not full, local verification).
- Manually exercised the `test-path-compare-lib.sh` and `test-doctor.sh`
  skip paths by temporarily forcing the "false" branch of each capability
  check and confirming the SKIP line prints with its reason and the suite
  still exits 0, then reverted.

## What remains unverifiable without a live Windows run

- Whether `MSYSTEM=""` inside `mock.patch.dict` behaves identically to a
  genuinely absent `MSYSTEM` on **real** Windows Git Bash (verified
  equivalent via direct code reading of `_to_cli_string`'s `if is_windows
  and msystem:` truthiness check, which treats `""` and absence
  identically — but the ambient environment itself cannot be reproduced).
- Whether `ln -s` on the actual windows-latest runner produces a silent
  copy, a hard failure, or something else entirely — the fix handles all
  three outcomes correctly (via `[[ -L ]]`, plus `|| true` so a hard
  failure doesn't abort the suite under `set -e`), but which one actually
  occurs there is still unconfirmed.
- Whether `chmod 500` genuinely leaves the directory writable on
  windows-latest, as opposed to some other, different failure mode for
  this specific assertion — the probe added this round determines this
  correctly REGARDLESS of which is true (that is the point of probing
  instead of assuming), so this specific suite no longer depends on
  guessing right, but the report cannot confirm which branch actually
  fires on a real run.
- Whether CI is now fully green on windows-latest — no Windows execution
  environment has been available at any point across rounds D, E, or F.

## Files changed

- `scripts/lib/paths.py` — new `canon` subcommand.
- `tests/lib/path-compare.sh` — `sl_canon_path` now shells out to
  `paths.py canon` instead of reimplementing rendering inline.
- `tests/test-path-compare-lib.sh` — symlink-capability detection with
  loud skips; `sl_check_same_path`'s self-test rerouted off symlinks.
- `tests/test-paths.py` — three tests pin `MSYSTEM` via
  `mock.patch.dict`; new driveless-path-rendering test; `test_get_prints_single_path`
  builds its expected value via `_to_cli_string` instead of raw `str(Path(...))`.
- `tests/test-doctor.sh` — real writability probe gates the two
  non-writable-directory assertions, with a loud, named skip when the
  probe shows the premise does not hold.

## Commit

`fix: Windows test-isolation and platform-capability fixes (round F)` — see
`git log` for the SHA.
