# Fix round D report — harness-neutral-persistence

Round D is the blocking set from the scoped re-review that kept the branch at
NO-GO (rounds B and C judged complete, round A judged unfinished). This round
addresses blockers (a), (b), (c), and the four "also in scope" items.

## Blocker (a) — duplicate ISO parser (the eighth instance)

**Root cause**: `scripts/skill-lifecycle.py` carried its own copy of
`iso_to_epoch`, independent of the fix `sl_iso_to_epoch` in
`scripts/lib/config.sh` already had. It was missing both of that fix's
defenses:
1. No `Z`-suffix swap — Python 3.9's `datetime.fromisoformat` rejects a
   trailing `Z` outright (accepted only from 3.11 on), so every shell
   producer's timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) silently failed to
   parse under 3.9, `compute_activity_anchor` found no activity, and the
   script printed "Nothing to do." and exited 0 — CI run `30149706340`
   failed on exactly this, both 3.9 cells.
2. No naive-datetime-as-UTC guard — a tz-naive timestamp's `.timestamp()`
   is interpreted in the interpreter's local time, silently shifting the
   result by up to ±14h. Live on every Python version.

**Fix**: extracted a single shared module, `scripts/lib/isotime.py`, exposing
`parse_iso(s) -> int | None` and `now_iso() -> str`, plus a `parse`/`now` CLI.
Migrated every call site to import it instead of keeping a local copy:

- `scripts/skill-lifecycle.py` — `iso_to_epoch` deleted; `compute_activity_anchor`
  now calls `isotime.parse_iso`.
- `scripts/persist-proposal.py` — local `_now_iso()` deleted; `_now_iso` is now
  an alias import (`from isotime import now_iso as _now_iso`) so the rest of
  the file's call sites needed no further edits.
- `scripts/index-session.py` — both `now = datetime.now(timezone.utc).isoformat()`
  call sites replaced with `now_iso()`; added the `lib` sys.path insert (this
  file previously imported nothing from `lib`).
- `scripts/coach-signals.py` — `generated_at` now built via `now_iso()`;
  unused `datetime`/`timezone` import removed.
- `scripts/lib/config.sh`'s `sl_iso_to_epoch` python3 fallback no longer
  embeds its own inline `python3 -c '...'` copy of the parser — it now shells
  out to `python3 "$_sl_isotime_py" parse "$ts"`. `_sl_isotime_py` is derived
  from the same `_sl_lib_dir` the existing `_sl_paths_py` derivation uses.

**Install coverage**: `install.sh`'s Step 2b copies `scripts/lib/*.py` by
glob, so `lib/isotime.py` is picked up automatically — no `SCRIPTS`/glob
change needed. Added `lib/isotime.py` to `tests/test-install-paths.sh`'s
`EXPECTED_FILES`. Confirmed the structural guard actually catches a miss:
temporarily removed `scripts/lib/isotime.py` and re-ran the suite — it failed
loudly (`FAIL: expected installed file present: lib/isotime.py`), and
cascaded into a real end-to-end failure of the installed `persist-proposal.py`
(`ModuleNotFoundError: No module named 'isotime'`, install.sh's own
"[FAIL] Script not found" fatal check firing) — restored, suite green again.

Also updated `tests/test-script-paths.sh`'s manual `cp` list for its isolated
`index-session.sh` fixture (that test builds its own scratch "install" by
hand, not via `install.sh`) to include `lib/isotime.py`, since
`index-session.py` now imports it.

**New test**: `tests/test-isotime.py` — pins `Z`, `+00:00`, a non-UTC
positive offset, a **negative** non-UTC offset (checks the sign is not
flipped), fractional seconds, and a naive timestamp (asserted treated as UTC
under an explicit non-UTC `TZ`), plus CLI subcommand coverage.

**3.9 run results** (`~/.pyenv/versions/3.9.24/bin/python3.9`):
- `tests/test-isotime.py`: 16/16 pass.
- `tests/test-paths.py`: 27/27 pass.
- `tests/test-persist-proposal.py`: 22/22 pass.
- `tests/test-proposal-schema.py`: 53/53 pass.
- `tests/test-coach-rules-eval.py`: 4/4 pass.
- `tests/test-coach-signals.py`: 7/7 pass.
- `tests/test-skill-lifecycle.sh` (invoked with `python3` resolved to the 3.9
  interpreter via a scratch PATH symlink): all 9 (now 11, see "also in
  scope" below) assertions pass — this is the direct regression pin for CI
  run `30149706340`.
- Direct smoke: `env -i ... python3.9 scripts/skill-lifecycle.py --dry-run`
  and `scripts/coach-signals.py` both import and exit 0 cleanly under 3.9.

## Blocker (b) — Windows

Three-part fix, per the re-review's recommendation. All three are
implemented and unit-tested on Linux since this repo cannot run Windows CI
directly; nothing here has been observed to actually pass a live Windows CI
run.

1. **`scripts/lib/paths.py`'s `_to_cli_string`**: now takes optional
   `is_windows=`/`msystem=` keyword overrides (defaulting to
   `os.name == "nt"` / `os.environ.get("MSYSTEM")`). When both are truthy
   (a real Git Bash/MSYS2 shell — MSYSTEM is always set there, never by
   native cmd.exe/PowerShell), it renders the MSYS/cygdrive form
   (`/c/Users/...`) via a new pure-Python helper, `_to_msys_path`, derived
   from `PureWindowsPath.drive` + `.parts` — no `cygpath` subprocess, no new
   PATH dependency. Falls back to the existing `.as_posix()` form for a
   driveless/UNC path (no single-letter cygdrive equivalent) or when
   `msystem` is unset (native Windows Python invoked from cmd/PowerShell,
   which expects and already gets the plain `C:/...` form). Six new tests in
   `tests/test-paths.py::TestCliFormatting` cover both branches plus the
   UNC/driveless fallback and a direct `_to_msys_path` unit check, all built
   with `PureWindowsPath` so they run on Linux. 27/27 `test-paths.py` tests
   pass on both 3.13 and 3.9.24.

2. **`tests/test-config.sh`'s "AGENT_LEARNING_HOME drives SL_MEMORY_DIR"
   assertion** no longer does a raw string `==` — it now `mkdir -p`s both
   sides and compares with `-ef` (same underlying directory/inode), which is
   robust to MSYS's `/tmp` → `%TEMP%` remapping producing a differently
   *spelled* but identical directory. Verified still passes on Linux (where
   both sides are trivially the same literal path, so `-ef` is a no-op
   strengthening, not a weakening).

3. **`tests/test-config.sh`'s restricted-PATH helper** (`_sl_link_or_copy`,
   used to build a no-python3 PATH for the fallback tests) no longer `cp`s
   `bash`/`dirname` binaries into an isolated directory — it now writes a
   tiny forwarder shell script (`#!/bin/sh\nexec "<original-absolute-path>" "$@"`)
   instead. **This is a hypothesis, not a confirmed diagnosis** — there is no
   Windows CI evidence pinpointing the `tests/test-config.sh` exit-127
   failure the way the `AGENT_LEARNING_HOME`/`SL_MEMORY_DIR` mismatch was
   CI-confirmed. The reasoning: copying `bash.exe`/`dirname.exe` into an
   otherwise-empty directory separates them from `msys-2.0.dll` (and
   siblings), which the Windows loader resolves relative to the executable's
   own directory, not via PATH; a missing DLL load surfaces as exit 127,
   indistinguishable from "tool genuinely absent" without inspecting the
   failure directly on a Windows box. A forwarder text file has no DLL
   dependency of its own — its shebang execs the original binary by its
   real, unmoved absolute path every time. `command -v python3` still
   correctly reports "not found" on the restricted PATH, since no forwarder
   is ever created for `python3`. Verified this produces identical passing
   behavior on Linux (`tests/test-config.sh`: all assertions still pass).
   **Explicitly not implemented**: `MSYS_NO_PATHCONV=1`/`MSYS2_ARG_CONV_EXCL=*`
   as a product fix — not used anywhere in this change; the forwarder-script
   approach and the `-ef` comparison are both test-harness-only changes that
   do not touch how a real Git Bash user's environment behaves.

**Unverifiable without Windows**: all three of the above — this repo has no
Windows execution environment. The `AGENT_LEARNING_HOME`/`SL_MEMORY_DIR`
round-trip diagnosis was itself CI-confirmed by a prior run; the MSYS
cygdrive-form fix addresses that confirmed root cause directly. The exit-127
diagnosis and its forwarder-script fix remain a reasoned hypothesis until a
green (or at least differently-red) Windows CI run is observed.

## Blocker (c) — `~/.claude` guard mutation coverage

**Root cause**: `tests/test-script-paths.sh`'s repo-wide guard used
`grep -c '"\.claude"'` (Python, double-quoted only) and
`grep -c '\${HOME}/\.claude'` (bash, braced only). Six mutations from the
task's table were tested against both the OLD and NEW patterns:

| injected literal | OLD pattern | NEW pattern |
|---|---|---|
| `os.path.join(home, ".claude", "x")` | caught | caught |
| `BAD="${HOME}/.claude/x"` | caught | caught |
| `os.path.join(home, '.claude', 'x')` (single quotes) | **missed** | caught |
| `os.path.expanduser("~/.claude/learned-skills")` | **missed** | caught |
| `BAD="$HOME/.claude/x"` (unbraced) | **missed** | caught |
| `BAD=~/.claude/x` (bare tilde) | **missed** | caught |

Confirmed by direct `grep` reproduction against six scratch files (not
checked into the repo — created and removed under `/tmp` during
verification): the OLD patterns produced count=0 (missed) on exactly the
four rows the task named as MISSED, and the NEW patterns produced count≥1
(caught) on all six.

**Fix**: widened to `\.claude` (Python — any quote style, any construction)
and `\$\{?HOME\}?/\.claude` plus a separate bare-`~/\.claude` check that
excludes lines that are entirely a comment (`grep -vE '^[[:space:]]*#'` first)
so prose like `# see ~/.claude for details` is not flagged but
`BAD=~/.claude/x` (real code, no leading `#`) is.

**Consequence — exemption list growth**: the widened Python pattern also now
matches prose mentions of `.claude` inside docstrings/comments (there are
many, by design — this whole test file's premise is documenting why code
must not go there). Per the task's guidance ("prose false-positives go in
the existing exemption list, which is already the mechanism"), extended
`PY_CLAUDE_EXEMPTIONS`/`BASH_CLAUDE_EXEMPTIONS` to also cover:
- Python: `scripts/coach-signals.py`, `scripts/inject-agents-md.py`,
  `scripts/skill-lifecycle.py` — all prose-only, no actual `.claude` path
  construction in any of the three (verified by reading every matched line).
- Bash: `scripts/lib/config.sh` — prose-only (two comments stating the
  vendor-neutral-defaults rule itself).
- Extended the reasons on the four pre-existing entries
  (`index-session.sh`, `self-learning-health.sh`, `doctor.sh`,
  `paths.py`'s `legacy_home()`) to note they now also cover prose hits on
  the same files, not just the one legitimate line each was originally
  written for. **The four original entries were re-verified genuinely
  legitimate and unchanged in substance** — no entry was padded to hide a
  real hit; every added hit on every exempted file was read and confirmed
  prose- or already-legitimate-line-only before exempting.

All 27 suites still pass with the widened guard and the new/updated
exemption lists.

## Also in scope

- **Corrupt `.usage.json` policy split**: `scripts/skill-lifecycle.py`'s
  `load_usage()` now raises a new `UsageCorruptError` for a present-but-invalid
  (bad JSON, or valid JSON that isn't an object) `.usage.json`, instead of
  silently returning `{}`. `main()` catches it, prints
  `skill-lifecycle: refusing to proceed: ...` to stderr, and exits 2 — matching
  `persist-proposal.py`'s existing refusal policy for the exact same file
  (both now refuse rather than silently treating corrupt-but-present as
  absent-and-empty). `scripts/curator-run.sh`'s caller
  (`python3 skill-lifecycle.py 2>&1 ... || true`) already tolerates and
  surfaces a non-zero exit in its transition log, so no caller-side change
  was needed. New test in `tests/test-skill-lifecycle.sh`: seeds a corrupt
  `.usage.json`, asserts the exit is non-zero AND that "Nothing to do" is
  never printed (that message is only true when the file is absent).

- **`prompts/authoring-standards.md:13`**: the naming-format cell changed
  from the stale, dot-inclusive `^[a-z0-9][a-z0-9._-]*$` to
  `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`, matching
  `scripts/lib/proposal_schema.py`'s enforced `SKILL_NAME_RE` exactly (no
  dots, 1–64 chars). Noted inline that this now matches the enforced schema.

- **`README.md`'s Windows/Copilot column swap**: the table's columns are
  per-harness (Claude Code / Copilot CLI), but the single "Windows" row
  crammed a Windows CI result into the Claude Code column and a macOS CI
  result into the Copilot column — conflating an OS dimension with the
  harness dimension the table's columns actually represent. Split into two
  rows, "Windows" and "macOS", each showing the *same* CI result in both
  harness columns (since a red CI job for an OS fails the whole matrix cell,
  not one harness specifically), with a note explaining why both columns
  match.

- **Read-oracle hoist** (`scripts/persist-proposal.py`'s `_plan`): `_plan`
  used to call `_load_usage_dict(skills_dir)` — which reads
  `<skills_dir>/.usage.json` — before `_write_all` ever symlink-checked
  `skills_dir` itself (only the `.usage.json` *file* was symlink-checked, via
  `_read_existing`, not its parent directory). With a symlinked `skills_dir`,
  that let a proposal touching skills leak a boolean "is `.usage.json` valid
  JSON?" signal (via `PersistError`'s message vs. success) from *outside*
  the store, before any write-path confinement check ran. Fixed by hoisting
  `_reject_if_symlink(skills_dir, ...)` (and, symmetrically,
  `_reject_if_symlink(memory_dir, ...)`) to the top of `_plan`, before
  `_load_usage_dict` is called — the read can no longer happen at all when
  `skills_dir` is a symlink. No other check in `_write_all` was touched.
  Verified manually: a symlinked `learned-skills` pointing at a directory
  with a genuinely-valid `.usage.json` containing `{"secret":"leak-me"}` now
  gets `persist-proposal: write failed: refusing to use symlinked store
  directory: .../learned-skills` (exit 2) with nothing written and nothing
  read, instead of getting as far as parsing the target's `.usage.json`
  before the pre-existing `_write_all`-time checks would eventually have
  refused the write.

## Write-path attack re-run (persist-proposal.py / proposal_schema.py)

The full 29+22+8-attack-class + 40-iteration-TOCTOU-race re-review was
performed once by the prior round and is not re-runnable here as a scripted
harness (it was a manual/external adversarial exercise, not a checked-in
fuzz script). What was re-verified after this round's two changes to this
file (the `now_iso` import swap and the `_plan` symlink hoist):

- Full existing regression suites: `tests/test-persist-proposal.py` (22
  tests) and `tests/test-proposal-schema.py` (53 tests) — both still 100%
  green on Python 3.13 and 3.9.24. These suites already encode a substantial
  slice of the original attack classes (Windows reserved names, traversal,
  non-UTF-8 append targets, directory-as-target, oversized content, etc.).
- Manual spot-checks specifically targeting the two changed code paths:
  - Symlinked `skills_dir` + a skill-write proposal: refused before any
    read, as described above (new behavior — previously would eventually
    have been refused by `_write_all`, but only after `_load_usage_dict`
    had already read through the symlink).
  - Ordinary (non-symlinked) corrupt `.usage.json`: still refused, exit 2,
    `persist-proposal: write failed: ... exists but is not valid JSON: ...`
    — unchanged from before this round.
  - Full valid write (memory + skill + `.usage.json`): succeeds, exit 0,
    every written file confirmed mode `0600`.
  - Traversal in a skill name (`../../etc/evil`): still refused at the
    schema layer (exit 1), never reaches the filesystem layer — unchanged.
- No change was made to `_assert_inside`, `_reject_if_symlink`'s Windows
  reparse-point handling, `_open_nofollow_fd`'s `O_NOFOLLOW` usage,
  `_read_existing`'s hardlink (`st_nlink`) rejection, `_stage`'s
  `tempfile.mkstemp` + `os.replace` atomicity, or `proposal_schema.py` at
  all — every property those checks establish is structurally unchanged by
  this round's diff (`git diff` on this file is additive: two new
  `_reject_if_symlink` calls at the top of `_plan`, and an import swap for
  `_now_iso`).

**Conclusion**: no regression identified in the re-run. The full external
adversarial re-review (all 29/22/8/40 cases individually re-executed) was
not repeated in this round; the above is what could be practically
re-verified given the scope of this round's changes to the file.

## Test suite summary

- `bash tests/run-all.sh`: **27/27 suites pass** on Linux/3.13 (up from 26 —
  added `tests/test-isotime.py`).
- All 6 Python suites individually re-run under
  `~/.pyenv/versions/3.9.24/bin/python3.9`: all pass (`test-isotime.py`,
  `test-paths.py`, `test-persist-proposal.py`, `test-proposal-schema.py`,
  `test-coach-rules-eval.py`, `test-coach-signals.py`).
- `tests/test-skill-lifecycle.sh` re-run with `python3` resolved to the 3.9
  interpreter via a scratch-PATH shim: all assertions pass, including the
  new corrupt-`.usage.json` assertions.

## Files changed

- `scripts/lib/isotime.py` — new, shared ISO-8601 parser/formatter.
- `scripts/skill-lifecycle.py` — imports `isotime.parse_iso`; local
  `iso_to_epoch` removed; new `UsageCorruptError` + refusal policy in
  `load_usage()`/`main()`.
- `scripts/persist-proposal.py` — imports `isotime.now_iso` as `_now_iso`;
  local `_now_iso()` removed; `_plan` hoists `skills_dir`/`memory_dir`
  symlink checks before `_load_usage_dict`.
- `scripts/index-session.py` — imports `isotime.now_iso`; both inline
  `datetime.now(timezone.utc).isoformat()` call sites replaced.
- `scripts/coach-signals.py` — imports `isotime.now_iso`; unused
  `datetime`/`timezone` import removed.
- `scripts/lib/config.sh` — `sl_iso_to_epoch`'s python3 fallback now shells
  out to `lib/isotime.py parse` instead of an inline copy.
- `scripts/lib/paths.py` — `_to_cli_string` gains the MSYS-form branch;
  new `_to_msys_path` helper; `PureWindowsPath` import added.
- `prompts/authoring-standards.md` — naming-format regex corrected to match
  the enforced schema.
- `README.md` — Windows/macOS row split, per-harness column conflation fixed.
- `tests/test-isotime.py` — new.
- `tests/test-paths.py` — six new `TestCliFormatting` cases for the MSYS
  branch.
- `tests/test-config.sh` — `AGENT_LEARNING_HOME drives SL_MEMORY_DIR`
  assertion now uses `-ef`; `_sl_link_or_copy` now writes forwarder scripts
  instead of `cp`-ing binaries.
- `tests/test-install-paths.sh` — `lib/isotime.py` added to `EXPECTED_FILES`.
- `tests/test-script-paths.sh` — widened `~/.claude` guard patterns; expanded
  exemption lists with reasons; added `lib/isotime.py` to the manual
  `index-session.sh` scratch-install copy list.
- `tests/test-skill-lifecycle.sh` — new corrupt-`.usage.json` assertions.

## Commit

`fix: shared isotime module, MSYS path form, ~/.claude guard mutation
coverage (round D blockers a/b/c + scope items)` — see `git log` for the SHA.
