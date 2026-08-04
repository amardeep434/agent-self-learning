# Windows reality audit — agent-self-learning @ main (150155e), 2026-08-04

Legend: [VBC] = VERIFIED-BY-CODE-READ, [NWP] = NEEDS-WINDOWS-PROBE (probe command given).

## PROGRESS
- [x] 1a. README Windows install instructions traced
- [x] 1b. install.ps1 / find-bash.ps1 chain traced (PATH forwarding, command names required)
- [x] 1c. install.sh preflight — exact failure point for python.org-Windows user
- [x] 2a. Catalog python3 call-site classes (guards, direct calls, shebangs, config.sh spawn, jsonio, .ps1, config/*.json templates)
- [x] 2b. Exec'd-directly scripts (shebang relevance)
- [x] 2c. Fix design: SL_PYTHON single resolution point + mechanical migration viability
- [x] 3. Hook-fire reality: how each harness spawns hooks on Windows; bash/jq PATH requirements
- [x] 4a. CRLF: other python-prints-consumed-by-bash sites beyond paths/jsonio/coach_render
- [x] 4b. HOME/store divergence: bash $HOME vs native python Path.home()/%LOCALAPPDATA% — same store?
- [x] 4c. msvcrt locking, chmod semantics status on main
- [x] 5. CI honesty + regression-guard test design
- [x] 6. Other Windows-journey breaks found en route

## Findings
### AREA 1 — Acquisition + install chain [VBC]

**1a README** (`README.md:34-59`): Windows path is `winget install Python.Python.3.12` + Git for Windows, then `.\install.ps1`. The winget/python.org installer creates `python.exe` + `py.exe` launcher and NEVER a `python3.exe` (python.org has shipped no `python3` alias on Windows, ever). Git for Windows ships **no python at all**. So the README's own recommended acquisition steps guarantee a machine with `python`/`py` but no `python3` — the exact machine the repo then refuses. README dependency table (`README.md:53`) literally names the dependency "`python3`", codifying the wrong command name as if it were the package.

**1b install.ps1 → find-bash.ps1** (`install.ps1:27`, `scripts/lib/find-bash.ps1:43-88`): `& $bashExe $scriptPath @args` is a plain child-process spawn — the user's full environment incl. PATH IS inherited by bash (Git Bash prepends its own `/usr/bin`, `/mingw64/bin` etc. but keeps the Windows PATH converted to POSIX form appended). PATH forwarding is NOT the problem. find-bash.ps1 probes only `bash` (functional `test -f` probe — good design); it never probes for a Python. So the wrapper happily delegates into a bash where no `python3` exists.

**1c The exact failure point** (`install.sh:92-103`):
```
for cmd in python3; do
    if ! command -v "$cmd" &>/dev/null; then MISSING_DEPS+=("$cmd")
```
Two concrete Windows outcomes:
- **Owner's laptop (python.org install, aliases off or PATH-ordered):** `command -v python3` fails → `Error: Missing required dependencies: python3` → hard exit 1. Matches the field report. HYPOTHESIS CONFIRMED.
- **Default Windows 10/11 (App Execution Aliases ON):** `%LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe` — the Microsoft Store STUB — is on the inherited PATH, so `command -v python3` SUCCEEDS. Preflight passes, then `install.sh:141` runs `python3 "$PATHS_PY" all`; the stub prints "Python was not found…" to stderr and exits 9009, the `while read` loop gets empty stdin, and the user gets the misleading `Error: could not resolve install paths via …paths.py` (`install.sh:143-145`). So the stub converts a clear dependency error into a wrong one. Any fix MUST validate `python3 --version` output, not mere presence. [NWP for the stub's exact exit code under Git Bash: `cmd //c 'python3 --version'` and `python3 --version; echo $?` in Git Bash on the laptop.]

Owner probe commands (laptop, Git Bash):
```bash
command -v python3; echo rc=$?
command -v python;  python --version
command -v py;      py -3 --version
where.exe python3 python py 2>/dev/null   # shows whether the Store stub is what resolves
```

### AREA 2 — Interpreter resolution: full call-site catalog [VBC]

`grep -rwn python3 scripts/ install.sh uninstall.sh config/ tests/` = **422 hits / 45 files**. Classes:

| Class | Sites | Notes |
|---|---|---|
| Preflight guard | `install.sh:93` | the field-report failure |
| `command -v python3` guards | `session-review.sh:59`, `vscode-session-review.sh:82`, `session-start-context.sh:33`, `doctor.sh:146,482`, `self-learning-health.sh:145,203,217,257`, `uninstall.sh:37,109,193` | each degrades or refuses per-script; all wrong-name on Windows |
| Direct `python3 file.py` | `config.sh:55` (paths spawn, `2>/dev/null` — SILENT), `config.sh:284` (isotime), `install.sh:141,186,204,220,627`, `uninstall.sh` (16 hits), `hook-input.sh:33`, `copilot-hook-input.sh:35`, `store-lock.sh:40,48`, `skill-layout.sh:45`, `review-common.sh:287`, review scripts' `jsonio.py set` calls, `session-start-context.sh:68` (`nohup python3 mirror-skills.py`), `index-session.sh`, `curator-run.sh`, `doctor.sh` (21), `self-learning-health.sh` (20), `sync-coach-rules.sh` (6), `turn-counter.sh` (comment only — real dep is jq) |
| Inline `python3 -c` / heredoc | `install.sh:220` (LEGACY_HOME), `doctor.sh` heredocs | |
| Shebangs `#!/usr/bin/env python3` | every `scripts/*.py`, `scripts/lib/*.py` (~27 files) | **2b: no shell script exec's a .py directly** (verified: every invocation is `python3 "$file"`; the `persist-proposal.py` path is passed as `$writer` and run as `python3 "$writer"` at `review-common.sh:287`). Shebangs are inert on the hook path; only a human running `./scripts/foo.py` hits them. Cosmetic. |
| `config/*.json` hook templates | none | they invoke `bash '<script>.sh'` only — python3 never appears in a template. Good. |
| `.ps1` files | none | install.ps1/uninstall.ps1/find-bash.ps1 contain zero python references — they neither need nor probe python. The .ps1 "parity" work is: add a python preflight so the failure surfaces in PowerShell with a good message instead of deep inside bash. |

**The one nasty quoting site**: `review-common.sh:281-287` — `python3 "$writer"` lives inside a SINGLE-QUOTED `nohup bash -c '…'` string. A mechanical sed to `"${SL_PYTHON}"` breaks here: inside single quotes the variable never expands, and the nohup'd child is a fresh bash. Fix: `export SL_PYTHON` (env inheritance survives nohup+bash -c), and inside the string use `"${SL_PYTHON:-python3}"` — expansion happens in the CHILD shell reading the env var, which is correct and race-free.

**2c Fix design (single resolution point)**:
- New ~20-line block at the top of `scripts/lib/config.sh` (it is already sourced by every hook/review/curator script before any python3 call — verified: config.sh's own paths spawn at line 55 is the first python3 use in every flow):
  ```bash
  sl_resolve_python() {  # Store-stub-proof: presence is not enough, it must RUN and be 3.x
      local cand v
      for cand in python3 python "py -3"; do
          v=$($cand --version 2>&1) || continue
          case "$v" in "Python 3."*) printf '%s' "$cand"; return 0 ;; esac
      done
      return 1
  }
  SL_PYTHON="${SL_PYTHON:-$(sl_resolve_python)}" || SL_PYTHON=""
  export SL_PYTHON
  ```
  (`py -3` as a word-split two-token command; call sites use unquoted `$SL_PYTHON` or an array — decide once. Simpler alternative: resolve to an absolute exe path via `command -v` after the version check, so it stays one token and `"${SL_PYTHON}"` quoting works everywhere incl. `< <(…)` process substitutions.)
- `install.sh` preflight (line 92-103) gets the same function (install.sh does NOT source config.sh — verified, it only calls paths.py directly — so the function must live where both can reach it, e.g. `scripts/lib/python-resolve.sh`, or be duplicated 10 lines in install.sh with a comment; the former honors the single-resolver constraint).
- Error message on total failure must name all three names tried AND the Store-stub trap: "a `python3`/`python` that opens the Microsoft Store does not count".
- `.ps1` parity: in install.ps1, before delegating, `Get-Command python3, python, py` + run `--version`, warn-and-continue (bash side is authoritative) or hard-fail with the winget line.
- **Mechanical migration viability: YES with 3 exceptions.** `sed -i 's/\bpython3 /"${SL_PYTHON}" /g'` per shell file works for ~95% of sites because every call is `python3 "$abs/path.py"` in ordinary command position. Exceptions needing hand edits: (1) `review-common.sh:287` single-quoted bash -c (see above); (2) all `command -v python3` guards — replace with `[[ -n "$SL_PYTHON" ]]`; (3) `install.sh` preflight loop. Tests: leave `python3` in tests that run on CI (CI shims it — see Area 5), EXCEPT add the new no-python3 regression test. Shebangs: leave as-is (inert) or flip to `#!/usr/bin/env python3` → no change needed.
- Python-side: nothing to do — .py files never re-invoke `python3` by name (verified: `grep -rn "python3" scripts/*.py scripts/lib/*.py` → only comments/docstrings — RE-CHECK during implementation; store_lock.py `run` subcommand re-executes the passed argv, which the caller builds).

### AREA 3 — Hook-fire reality on Windows

**What gets registered** [VBC]: install.sh renders `__SL_SCRIPTS_DIR__` from `SL_SCRIPTS` = paths.py CLI output. Under Git Bash (os.name==nt + MSYSTEM set) that is **MSYS form** `/c/Users/<u>/AppData/Local/agent-learning/scripts` (`paths.py:184-186`). So the registered hook command is literally `bash '/c/Users/.../session-review.sh'` in `~/.claude/settings.json` / `<store>/vscode-hooks.json`, and the two-flavour copilot file has `"powershell": "bash -lc \"'/c/.../copilot-session-review.sh'\""` (`config/copilot-hooks.json:8,16`).

**The fire-time gamble** [NWP — no hook has ever fired on Windows, per README:348 and docs/windows-verification-runbook.md]:
1. `bash` is resolved by BARE NAME at fire time by whatever shell the harness uses (cmd.exe or PowerShell on native Windows). None of find-bash.ps1's WSL-stub protection applies here — install-time carefully picks the right bash, fire-time takes PATH pot luck. Git for Windows' DEFAULT install puts only `Git\cmd` (git.exe) on PATH, **not** `Git\bin\bash.exe`; meanwhile `C:\Windows\System32\bash.exe` (WSL) may exist. Outcomes: no bash → hook silently dead; WSL bash → `/c/...` path does not exist there (`/mnt/c/...`) → hook dies, AND per rule 2's design the failure never reaches an exit code anyone looks at.
2. If the harness spawns via **cmd.exe**, single quotes are not quote characters to cmd or to the MSVCRT argv parser bash.exe uses on receipt — the argument may arrive as literal `'/c/...'` including quotes. [NWP]
3. `turn-counter.sh` additionally requires **jq** on the fire-time PATH (`turn-counter.sh:153` refuses loudly — correct behavior, but on Windows this is one more bare-name PATH dependency; winget jq lands in the WinGet Links dir which is on user PATH — usually fine).
4. `copilot-hooks.json`'s powershell variant uses `bash -lc` — a LOGIN shell: sources /etc/profile + ~/.bash_profile, which on Git Bash rewrites PATH and costs ~100ms+; any user profile error kills the hook. The bash variant is non-login. Inconsistent by design? No comment explains `-l`.

Owner probes (laptop):
```powershell
# what bash would a hook get?
Get-Command bash | Format-List Source
cmd /c "where bash"
# does the registered command actually run from PowerShell / cmd?
bash '/c/Users/<you>/AppData/Local/agent-learning/scripts/turn-counter.sh' < NUL   # after a fixed install
cmd /c "bash '/c/anything'"   # observe whether quotes survive
```

### AREA 4 — Downstream Windows landmines

**4a CRLF — the fix is NOT complete** [VBC]: only `paths.py`, `jsonio.py`, `coach_render.py` force LF stdout (`grep -rln "reconfigure(newline" scripts/` = those 3). Consumers with a `\r`-strip: config.sh, install.sh, skill-layout.sh read loops. **Unprotected producer→bash-value flows** (native Windows python emits \r\n on every print; command substitution strips only trailing \n):
- `scripts/lib/isotime.py` → `config.sh:284` `epoch=$(python3 isotime.py parse …)` → `"…\r"` breaks the arithmetic that compares timestamps. (Mitigated in practice because Git Bash has GNU date so the fallback rarely runs — but the fallback exists precisely for when it does.)
- `scripts/lib/list-transcripts.py` → `index-session.sh:92,95` `LATEST_SESSION=$(…)` → transcript path with trailing `\r` → file-not-found.
- `scripts/lib/session_db.py` → `index-session.sh:56`, `install.sh:627` `SCHEMA_RESULT=$(…)` string-compared downstream.
- `scripts/lib/transcript.py` digest → `session-review.sh:116`, `vscode-session-review.sh:122`, `copilot-session-review.sh:46` — every digest line carries `\r` into the paid review prompt (cosmetic-to-harmful).
- `doctor.sh:195,232,395,483` inline `python3 -c` probe outputs case-matched against literals (`yes`/`no`) → `"yes\r"` matches nothing → probes report "could not probe".
- `review-common.sh:210` `signals_mtime=$(python3 -c …getmtime…)`.
- `sync-coach-rules.sh:52` `LEO_VERSION`.
Fix: either add `reconfigure(newline="\n")` to the 5 producer modules + a shared helper for inline `-c` (or simpler: consumer-side `${var%$'\r'}` at each substitution; producer-side is DRYer and matches the established round-E pattern).
CI passes today because Windows CI's Git Bash cells either have GNU date (isotime path unused) or skip the affected suites — see docs/platform-coverage.md. [NWP to confirm each actually misbehaves on the laptop.]

**4b HOME/store divergence** [VBC]: with a working python, bash and python cannot diverge — both go through paths.py, and LOCALAPPDATA (inherited by Git Bash) wins on Windows (`paths.py:65-68`), giving `%LOCALAPPDATA%\agent-learning` regardless of who asks. THE DIVERGENCE IS IN THE FALLBACK: `config.sh:55` runs `python3 paths.py all 2>/dev/null` — when python3 is missing/is-the-Store-stub this fails **silently** and `_sl_compute_fallback_home` (`config.sh:76-84`) has **no LOCALAPPDATA branch** (self-documented at config.sh:63: "python3 is a hard dependency of this project's Windows CI"). Result on a real Windows box without `python3`: every sourced hook script resolves the store to `$HOME/.local/share/agent-learning` (= `C:\Users\<u>\.local\share\agent-learning`) while paths.py/install resolve `%LOCALAPPDATA%\agent-learning`. Two stores, silently — the exact class the project exists to eliminate, and the `2>/dev/null` violates hard rule 2 (fail loudly). Once SL_PYTHON resolution lands this branch becomes near-unreachable, but it should still (a) mirror the LOCALAPPDATA branch, (b) log a named reason instead of `2>/dev/null`.

**4c Locks / chmod / TOCTOU status on main** [VBC, re-verified]: `store_lock.py` picks msvcrt vs flock by functional probe (doctor.sh:232-249 reports backend + crash-release semantics). chmod-0600 enforcement is probe-gated per CLAUDE.md; `tests/` gate the search.db perms assertion on a probe. Known-open and documented: dir_fd TOCTOU anchoring is POSIX-only, Windows runs the pre-hardening code path (README:413-417) — unchanged, acknowledged, not a new break.

### AREA 5 — CI honesty: the defect was KNOWN and shimmed [VBC]

`.github/workflows/ci.yml:29-46` — verbatim comment: "actions/setup-python on Windows only provides `python.exe`, never a `python3` on PATH (this is a known upstream gap, not a project bug). Every script in this repo shells out to `python3` by convention … every Windows job would fail with 'python3: command not found'". The workflow then **copies `python.exe` to `python3.exe`** ("Ensure python3 resolves (Windows)" step). So Windows CI green is manufactured: CI recreates exactly the alias real Windows machines don't have. The comment's claim "not a project bug" is backwards — hardcoding a command name that the platform's standard Python distributions never provide IS the project bug; CI institutionalized it. This is why 6 green Windows cells never caught the owner's failure.

**Regression guard design** (`tests/test-no-python3-name.sh`):
1. Build `$TMP/bin` with symlinks/copies: `python` → real interpreter (resolved once via `command -v python3 || command -v python`), plus the coreutils the scripts need (`bash`, `grep`, `mkdir`, …) — or simpler: a full PATH minus a shadowing dir; simplest robust form: create `$TMP/shadow/python3` as an executable that exits 127? No — `command -v` would still find it. Correct form: `PATH="$TMP/bin:/usr/bin:/bin"` where `$TMP/bin/python` exists and NO `python3` exists anywhere on that PATH (probe-verify inside the test: `command -v python3 && skip "cannot construct a python3-free PATH here"` — a probe-gated skip in the project's own style; on CI add a step that constructs it deterministically).
2. Optionally add `$TMP/bin/python3` simulating the Store stub: prints "Python was not found…" to stderr, exits 9009 — asserts the version-validation half of the fix.
3. Assert: `install.sh --dry-run` passes preflight; `source scripts/lib/config.sh` resolves SL_HOME via paths.py (NOT the bash fallback — assert against `AGENT_LEARNING_HOME` round-trip); one hook end-to-end: `echo '{}' | bash scripts/turn-counter.sh` exits 0 with the counter file written under a sandbox `AGENT_LEARNING_HOME`.
This test fails on today's main at step 3 (and step 1), i.e. it would have caught the field failure. After the fix lands, also DELETE the ci.yml python3-shim step — keeping it would re-mask any regression the new test misses.

### AREA 6 — Other breaks found en route

- **6.1 Misleading preflight UX behind the Store stub** (install.sh:99-103 vs 141-145): with default App Execution Aliases, preflight PASSES on the fake python3 and the user instead gets "could not resolve install paths via …paths.py". Covered in 1c; listed here because it means the owner's colleagues will see a DIFFERENT error from the owner for the same root cause.
- **6.2 `config.sh:55` `2>/dev/null`** on the single most important spawn in the project — silent by construction, violates hard rule 2. (Detailed in 4b.)
- **6.3 README dependency table** (`README.md:53`) names the dependency "python3" next to `winget install Python.Python.3.12`, a package that never provides `python3`. Doc correction required alongside the code fix; same for `docs/windows-verification-runbook.md` if it tells the human to check `python3 --version` [checked: run `grep -n python3 docs/windows-verification-runbook.md` during fix].
- **6.4 `uninstall.sh:37,109,193`** guards on `command -v python3` — on the owner's laptop TODAY the uninstaller would silently skip paths.py resolution and mirror cleanup. Same fix, same single resolution point.
- **6.5 `copilot-hooks.json` powershell variant's `bash -lc`** (login shell) — unexplained inconsistency vs the non-login bash variant; profile errors/PATH rewrites become hook failures. Low severity; document or drop `-l`.
- **6.6 Windows-python-first port plan** (`docs/superpowers/plans/2026-07-31-windows-python-first-port.md`, README:51) exists but is "not started; blocked on a real-hardware probe" — the SL_PYTHON fix here is independent of and prerequisite to it; the owner's laptop IS the real-hardware probe opportunity.

## Fix plan skeleton (ordered)

**WP1 — Interpreter resolution single point.** New `scripts/lib/python-resolve.sh` defining `sl_resolve_python()` (try `python3`, `python`, `py -3`; each must run `--version` and print `Python 3.*` — presence is not enough, defeats the Store stub; resolve to an absolute path via `command -v` so `"$SL_PYTHON"` stays one word). Sourced by `config.sh` (top, before line 55) and `install.sh` preflight; `export SL_PYTHON`.

**WP2 — Mechanical migration.** Per-file `sed 's/\bpython3 /"${SL_PYTHON}" /g'` across scripts/*.sh, scripts/lib/*.sh, install.sh, uninstall.sh; then hand-fix the 3 exception classes: (a) `review-common.sh:287` single-quoted `bash -c` body → `"${SL_PYTHON:-python3}"` reading the exported env var in the child; (b) every `command -v python3` guard → `[[ -n "${SL_PYTHON:-}" ]]`; (c) install.sh preflight loop → call the resolver, error message naming all three tried names + the Store-stub trap + the winget line. Leave shebangs (inert) and tests (CI shim) alone except as WP4 dictates. Run full `bash tests/run-all.sh` sandboxed after.

**WP3 — .ps1 parity + fallback repair.** install.ps1: probe python3/python/py functionally before delegating (warn with the winget line). config.sh: add LOCALAPPDATA branch to `_sl_compute_fallback_home` (Git Bash exports LOCALAPPDATA) and replace `2>/dev/null` on the paths.py spawn with a captured-stderr + named `persist-failures.log` reason.

**WP4 — Regression test** `tests/test-no-python3-name.sh` per Area 5 design (python3-free PATH + fake-stub variant; asserts preflight, config.sh store resolution, one live hook). **Delete the ci.yml "Ensure python3 resolves (Windows)" shim step in the same PR** so Windows CI runs the code the way real Windows does.

**WP5 — CRLF completion.** Add `sys.stdout.reconfigure(newline="\n")` (round-E pattern) to `isotime.py`, `list-transcripts.py`, `session_db.py`, `transcript.py`, and audit the inline `python3 -c` substitutions in doctor.sh / review-common.sh / sync-coach-rules.sh (consumer-side `${var%$'\r'}` is acceptable there).

**WP6 — Doc corrections.** README.md:49-59 dependency table (dependency is "Python 3.9+ (`python3`, `python`, or `py -3`)"), README Windows quickstart, windows-verification-runbook.md, CLAUDE.md hook-budget note if SL_PYTHON changes the config.sh spawn cost.

**WP7 — NEEDS-WINDOWS-PROBE checklist for the owner** (run in Git Bash unless noted):
```bash
# P1 interpreter reality
command -v python3; echo rc=$?; command -v python; python --version; py -3 --version
where.exe python3 python py            # PowerShell/cmd: is the Store stub what resolves?
python3 --version; echo rc=$?          # stub behavior + exit code under Git Bash
# P2 after the fix: full sandboxed install
env AGENT_LEARNING_HOME=/tmp/slstore bash install.sh --dry-run
# P3 hook-fire chain (PowerShell):
#   Get-Command bash | fl Source ; cmd /c "where bash"
#   cmd /c "bash '/c/Windows'" — do single quotes survive cmd?
# P4 does a real Claude Code hook fire? Register, run one turn, then:
ls "$LOCALAPPDATA/agent-learning/logs" ; cat .../persist-failures.log
# P5 CRLF spot check (native python, PowerShell):
#   python scripts\lib\isotime.py parse 2026-01-01T00:00:00Z | od -c   (look for \r)
# P6 jq: jq --version from cmd AND Git Bash
```

Post-check: `docs/windows-verification-runbook.md` has 4 bare `python3` invocations (lines 65, 120, 147, 210) — the runbook itself fails at its first command on the very machine it targets. Add to WP6. ci.yml shim confirmed at `.github/workflows/ci.yml:37-47` ("Ensure python3 resolves (Windows)", `cp "$PY_PATH" "${PY_DIR}/python3.exe"`).
