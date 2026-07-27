# Fix round A report — wrong-location and broken-platform cluster

Branch: `harness-neutral-persistence`. Scope: C1, C2, I5, I6 (+ deferred minor 3, 10), I7 (+ deferred minor 7), deferred minor 1.

All fixes follow TDD: failing test written and confirmed to name the real cause, then the fix, then a mutation test (revert the fix in isolation, confirm the same test fails again, restore). `bash tests/run-all.sh` passes: 21 suites discovered (16 shell, 5 python; 18 pre-existing + 3 new), all pass.

## C1 — Windows path resolution + `test-config.sh` exit 127

**Changed:** `scripts/lib/paths.py`

- `resolve_home()`: raises `RuntimeError` when `$HOME` is unset and no override (`AGENT_LEARNING_HOME`, `XDG_DATA_HOME`, `LOCALAPPDATA` on Windows) is set, instead of falling through to `Path("") / ...` (which normalizes to a CWD-relative path). This is also deferred-minor-1.
- `_main()`: added `_to_cli_string(p) -> p.as_posix()` and used it for both the `get` and `all` branches. `resolve_home`/`resolve_all` (the Python API) still return real `Path` objects — only the CLI boundary stringifies. `_main` now catches `RuntimeError` from the resolver and exits 3 with a clear stderr message instead of a traceback or a silently empty stdout.
- Reasoning on `.as_posix()` sufficiency (documented in-code): on native Windows, `Path(...)` is a `WindowsPath`; `str()` on it yields backslashes, which every bash consumer (`config.sh`, `install.sh`, `uninstall.sh`) then treats as escape characters — this was the reported C1 corruption. `.as_posix()` turns `C:\Users\x` into `C:/Users/x`. That is **not** the cygdrive form Git Bash's own tools print (`/c/Users/x`), but MSYS/Git Bash and native Windows tools both accept `C:/Users/x` directly — forward slashes are not special to Win32 path parsing, so no `cygpath` translation step is needed. **I could not verify this on real Windows CI**; the reasoning is sound and documented in `paths.py`, and `tests/test-paths.py::TestCliFormatting` exercises the formatting function directly using `PureWindowsPath` (constructible on any OS) so the logic is at least pinned and testable on Linux. If a future Windows CI run shows `C:/...` does NOT work for some bash builtin, the fallback is a `cygpath -u` step, not attempted here per the "verify rather than assume" instruction — flagging this as the one C1 sub-claim I could not close out.

**Test that fails without the fix:** `tests/test-paths.py` — `TestResolveHome.test_home_unset_raises_instead_of_cwd_relative`, `test_home_unset_raises_on_windows_too`; `TestCliFormatting.test_windows_path_rendered_with_forward_slashes`, `test_main_all_emits_no_backslashes_for_a_windows_style_env`; `TestCliHomeUnset.test_main_get_fails_loudly_when_home_unset`.

**Mutation test:** confirmed the pre-fix `paths.py` (via `git stash`/inspection before editing) prints `WindowsPath.__str__()` form with backslashes and returns a CWD-relative path silently for unset `HOME`; post-fix tests fail exactly there and pass after. (Ran as part of normal edit-then-test cycle, not a separate revert, since this file had no working baseline test before this round — the tests above did not exist pre-fix.)

### The `test-config.sh` exit 127 — separate root cause, addressed independently

Traced the only PATH-restricted block in `test-config.sh` (the "no python3 on PATH" test, which builds a directory with only `dirname` and `bash` and points `PATH` at it). The original used `ln -s`. On Windows, symlink creation can silently fail or need elevated privilege (no admin / Developer Mode) — `set -euo pipefail` would then abort the whole script on an unrelated, environment-dependent error, which is a plausible fit for a suite-level abnormal exit.

**Fixed:** replaced `ln -s` with `cp` in both the original no-python block and my new I6 test block (`_sl_link_or_copy()` helper). `cp` needs no special privilege on any platform and preserves the source basename (including a `.exe` suffix, so Windows path resolution still finds it). Also confirmed and preserved that `bash` itself must be present in the restricted directory: `env -i ... PATH=... bash -c ...` resolves `argv[0]` (`bash`) using the **new** `PATH` that `env` just set, not the invoking shell's own `PATH` — this was implicit in the original code but not stated; now commented.

**Second, independently-justified change:** added `.gitattributes` forcing `eol=lf` for `*.sh`, `*.py`, and other text files. Windows' default `core.autocrlf=true` silently converts LF→CRLF on checkout for anything Git guesses is text; a trailing `\r` on every line of a bash script is a well-documented cause of exactly this class of failure (a shebang line ending in `bash\r` fails to exec; a value read via a subshell picks up a stray `\r` attached to the last field on a line, corrupting comparisons and paths). This is the single most plausible explanation for a Windows-only, hard-to-reproduce `exit 127` independent of the separator issue, per the finding's own framing.

**I could not verify this is THE cause** — I have no Windows CI to run this against. What I verified: (1) the repo had no `.gitattributes` at all before this change (confirmed via `git check-attr`), so nothing prevented CRLF corruption on any Windows checkout; (2) the `ln -s` fragility is real and independently worth fixing regardless of whether it's the exit-127 cause. Added `tests/test-line-endings.sh` to pin the defense (`.gitattributes` present and correctly configured, no tracked `.sh`/`.py` file already contains a literal CR) — mutation-tested by removing `.gitattributes` and confirming the test fails.

## C2 — `skill-lifecycle.py` hardcoded legacy store

**Changed:** `scripts/skill-lifecycle.py`

`_default_skills_dir()` now resolves, in order: `SL_SKILLS_DIR` (vendor-neutral, what `curator-run.sh` actually exports via `lib/config.sh`) → `CLAUDE_LEARNED_SKILLS_DIR` (deprecated alias, with a stderr notice) → `scripts/lib/paths.py`'s `"skills"` key (the single resolver — never a hardcoded `~/.claude` literal, satisfying "paths computed in exactly one place").

**Test that fails without the fix:** new `tests/test-skill-lifecycle.sh`, all 4 scenarios:
1. `SL_SKILLS_DIR` set alone → transitions actually run (not "Nothing to do.").
2. `CLAUDE_LEARNED_SKILLS_DIR` alone still works (deprecated alias) + deprecation notice on stderr.
3. Both set → `SL_SKILLS_DIR` wins, and the directory named by `CLAUDE_LEARNED_SKILLS_DIR` is left **completely untouched** — this is the destructive-wrong-directory scenario from the finding.
4. Neither set → falls back through `paths.py` (`AGENT_LEARNING_HOME` override), and a populated legacy `~/.claude/learned-skills` sitting on disk is left untouched — the "upgraded machine" destructive regression.

**Mutation test:** reverted `skill-lifecycle.py` via `git stash`; 7 of 9 checks failed, correctly naming the cause (transitions didn't run against `SL_SKILLS_DIR`, no deprecation notice, wrong-directory processing). Restored; all 9 pass.

## I5 — coach rules directory (Task 7b regression)

**Changed:** `scripts/lib/config.sh`

`SL_COACH_RULES_DIR` default now derives from the same resolved `"scripts"` key (`_sl_pp_scripts`, newly captured from `paths.py all`) that `install.sh`'s Step 3b actually installs coach rules under (`${DEST_DIR}/coach-rules`), instead of the stale `${SL_HOME}/scripts/self-learning/coach-rules` literal that no install step has written to since Task 7b moved `DEST_DIR`.

**Test that fails without the fix:**
- `tests/test-config.sh` — "I5: SL_COACH_RULES_DIR matches install.sh's actual coach-rules destination".
- `tests/test-install-paths.sh` — new assertions after a **real** `install.sh` run: `SL_COACH_RULES_DIR` (as `lib/config.sh` resolves it for a real caller, sourced directly rather than re-deriving the expected path a second time) both resolves to a directory that **exists on disk** and equals `${RESOLVED_SCRIPTS}/coach-rules`. This closes exactly the blind spot named in the finding: the old default passed every prior install-paths assertion (script-array membership etc.) while pointing at a directory `install.sh` never creates.

**Mutation test:** reverted only the `SL_COACH_RULES_DIR` line to the pre-fix literal; both the existence-after-install assertion and the exact-path assertion in `test-install-paths.sh`, and the `test-config.sh` assertion, failed with the old (nonexistent) path shown. Restored via file backup (not `git checkout`, see note below); confirmed identical to pre-mutation state.

## I6 + deferred minor 3 + deferred minor 10

**Changed:** `scripts/lib/config.sh`, `scripts/self-learning-health.sh`

- **I6:** the python3-less fallback (used only when `python3`/`paths.py` cannot run at all) now computes `_sl_fallback_home` by mirroring paths.py's override chain — `AGENT_LEARNING_HOME` → `XDG_DATA_HOME/agent-learning` → `$HOME` default — via a small `_sl_compute_fallback_home()` function, instead of the bare `${HOME}/.local/share/agent-learning` literal introduced by commit `384a319`. All six path defaults (`SL_HOME`, `SL_STATE_DIR`, `SL_SKILLS_DIR`, `SL_MEMORY_DIR`, `SL_LOG_DIR`, `SL_SEARCH_DB`) and `SL_CONFIG_FILE` now derive from this. Deliberately does **not** add a `LOCALAPPDATA`/Windows branch — python3 is a hard dependency of this project's Windows CI, so this fallback path is Linux/macOS/Git-Bash-only in practice; mirrors the chain minimally as instructed, with a comment stating paths.py remains authoritative.
- **Deferred minor 3:** added `SL_STATE_DIR`, `SL_SKILLS_DIR`, `SL_MEMORY_DIR`, `SL_LOG_DIR`, `SL_SEARCH_DB` to `_sl_env_snapshot`'s variable list, so "env beats file" now holds for all of them (previously only `SL_HOME` and the coach/review/skillopt variables were snapshotted).
- **Deferred minor 10:** `scripts/self-learning-health.sh`'s hook-freshness section now checks `command -v python3` explicitly before attempting per-hook checks. When python3 is absent it emits one clear `FAIL: cannot verify hook freshness -- python3 not found on PATH` and skips the per-hook checks entirely, instead of silently resolving `SL_SCRIPTS_DIR=""` and letting `sl_check_hook_fresh()` report every hook as STALE regardless of truth.

**Tests that fail without the fix:**
- `tests/test-config.sh` — "I6: no python3, AGENT_LEARNING_HOME still drives SL_HOME", "...XDG_DATA_HOME still drives SL_HOME", "deferred minor 3: env beats file for all five path vars".
- `tests/test-health-no-python.sh` (new) — asserts the clear python3-FAIL message appears and a genuinely-fresh hook is NOT misreported as STALE, using a restricted PATH built with `cp` (portable, no `ln -s`).

**Mutation test:** for I6/minor-3, reverted the relevant `config.sh` lines via a `cp`-backup/restore (see note below); 4 checks failed correctly. For minor-10, reverted the `self-learning-health.sh` guard the same way; the "clear FAIL" assertion failed and the raw output showed the misleading per-hook STALE/MISSING verdicts the fix eliminates — confirming the fix is load-bearing. Restored both files; full diff against pre-mutation state confirmed identical.

**Process note:** the very first mutation-restore attempt used `git checkout -- scripts/lib/config.sh`, which reverted the file all the way to the pre-round `HEAD` and discarded every fix made in this round (not just the intended one-line mutation). Caught immediately via `git status`/`git diff --stat`, reapplied every `config.sh` change from the read-back content, and switched to `cp`-based backup/restore for every mutation test from that point on. Verified with `diff` after each restore.

## I7 + deferred minor 7 — `sl_iso_to_epoch` on macOS

**Changed:** `scripts/lib/config.sh`

The `python3` fallback branch now does a real ISO-8601 parse via `datetime.fromisoformat` (stdlib only) instead of a hardcoded `strptime(..., "%Y-%m-%dT%H:%M:%SZ")` that only ever matched the exact `Z`-suffixed form. A trailing `Z` is swapped for `+00:00` first (Python 3.9, this project's oldest CI target, does not accept `Z` in `fromisoformat`). Naive (no-offset) results are assumed UTC, matching this project's writer contract.

Deferred minor 7 (negative offset silently flipped positive) is resolved as a consequence: `fromisoformat` parses the sign itself, so there is no hand-rolled step that could drop or flip it. Added an explicit test pinning this: `2024-06-15T07:04:56-05:30` must equal the same epoch as `2024-06-15T18:04:56+05:30` (`1718454896`), not its mirror or some other wrong value.

**Test that fails without the fix:** `tests/test-config.sh`, `I7 python3-fallback: *` (4 cases) and `I7 python3-fallback (deferred minor 7): negative -05:30 offset is not flipped positive`. These force **both** the GNU and BSD `date` strategies to fail (a fake `date` binary ahead of the real one on `PATH` that always exits 1) so the assertions exercise the python3 fallback specifically — necessary because Linux's real GNU `date -d` is lenient enough to mask a python3-fallback regression entirely, which is how this bug shipped in the first place (encoded as passing on Linux CI).

**Mutation test:** reverted the python3 fallback body to the original `strptime` version via a scripted string-replace + `cp`-restore; 4 of 5 new assertions failed with `got '0'` (the documented sentinel — exactly the "infinitely stale" failure mode described in the finding), confirming the tests catch the real regression. Restored; `diff` confirmed identical to pre-mutation.

## New instances of the exit-0-while-wrong pattern noticed (not fixed — round B/C)

1. **`scripts/inject-agents-md.py:102`** — `skills_dir = Path(os.environ.get("SL_SKILLS_DIR", str(home / ".claude" / "learned-skills")))`. Same shape as C2: falls back to a hardcoded `~/.claude/learned-skills` literal when `SL_SKILLS_DIR` is unset, rather than consulting `paths.py`. Not fixed here — out of this round's named scope (only `skill-lifecycle.py` was named for C2).
2. **`scripts/doctor.sh`'s `_sl_report_hooks()`** (shares `sl_check_hook_fresh()` with `self-learning-health.sh`) has the identical deferred-minor-10 shape: when `python3` is unavailable, `SL_SCRIPTS_DIR=""` and every hook is reported `STALE` rather than a clear "cannot verify" message. `doctor.sh` at least prints `<unresolved: python3/paths.py unavailable>` in its resolved-paths section, so a careful reader has a clue, but the per-hook `STALE` lines in the "harnesses detected" section are still misleading on their own. Only `self-learning-health.sh` was named in the finding, so `doctor.sh` was left as-is.

## Suite summary

`bash tests/run-all.sh`: **21/21 suites passed** (16 shell, 5 python; 3 new shell suites added this round: `test-skill-lifecycle.sh`, `test-health-no-python.sh`, `test-line-endings.sh`).

## Unverifiable locally (CI-dependent)

- Whether `.as_posix()` output (`C:/Users/x` form) is actually accepted by every bash builtin/tool this project's scripts use under Git Bash / MSYS on `windows-latest`. Reasoned through and documented; `PureWindowsPath`-based unit tests pin the formatting logic itself, but the end-to-end claim needs real Windows CI.
- Whether the `.gitattributes` LF fix actually eliminates the `test-config.sh` exit 127 on Windows — plausible and well-justified independently, but unconfirmed without a Windows CI run. The `ln -s` → `cp` portability fix is a second, independently-justified change to the same test that also removes a plausible non-CRLF cause of the same symptom.
- Whether Git Bash's `ln -s` failure mode (if that turns out to be unrelated to the 127) would have produced exactly `127` rather than some other nonzero code — could not reproduce locally.
