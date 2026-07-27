### Task 7b: Harness-neutral install paths

**Added during execution.** Tasks 1-7 removed `~/.claude` from the *store* and from *script
contents*, but not from *install locations*. `install.sh` still hardcodes `${HOME}/.claude/...`
for every data directory, the config file, and the script destination, and
`config/copilot-hooks.json` ships a literal
`bash ~/.claude/scripts/self-learning/copilot-session-review.sh`. A Copilot-only install
therefore still creates and depends on `~/.claude`, which violates the plan's own global
constraint. Task 7's guard cannot catch this: it invokes the script directly from the repo.

**Files:**
- Modify: `scripts/lib/paths.py` (add a `scripts` key), `tests/test-paths.py`
- Modify: `config/copilot-hooks.json` (becomes a template), `install.sh`, `uninstall.sh`,
  `install.ps1`, `uninstall.ps1` (only if they carry hardcoded paths)
- Modify: `tests/test-copilot-hooks-json.sh`, `tests/test-claude-absent.sh`
- Create: `tests/test-install-paths.sh`

**Interfaces:**
- Consumes: `scripts/lib/paths.py` `resolve_all()` / `paths.py get <key>` / `paths.py all`.
- Produces: a `scripts` path key; a placeholder-substitution contract for hook config templates.

**Design decisions (settled — implement these, do not redesign):**

1. **Installed scripts live under the resolved store**, at the new `scripts` key
   (`<home>/scripts`, e.g. `~/.local/share/agent-learning/scripts`). One resolver, one
   location, already platform-aware. Do not invent an XDG bin path.
2. **Harness config files stay where each harness owns them** — `~/.claude/settings.json`
   for Claude Code and `~/.copilot/hooks/self-learning.json` for Copilot CLI. That is not a
   violation: those are the harnesses' own config directories. What must become neutral is
   the *script path each config invokes*.
3. **Hook configs become templates.** A static JSON file cannot call `paths.py`, and the
   resolved path varies with `AGENT_LEARNING_HOME` / `XDG_DATA_HOME` / `LOCALAPPDATA`. So
   `config/copilot-hooks.json` carries the placeholder `__SL_SCRIPTS_DIR__` and `install.sh`
   substitutes the resolved absolute path when writing the installed copy. The same
   substitution applies to the Claude Code settings snippet that `install.sh` echoes for the
   user to paste.
4. **Backward compatibility is preserve-and-notify, never migrate.** Leave any existing
   `~/.claude/scripts/self-learning` files and any existing `~/.claude` data in place —
   an old install keeps working because its files and its settings.json entries still point
   at each other. `install.sh` prints a migration note when it detects a legacy install.
   Never move, copy, or delete user data. (`paths.legacy_home()` already exists for
   detection; Task 9's `doctor` surfaces it.)
5. **`uninstall.sh` must clean both locations** — the resolved paths and the legacy
   `~/.claude/scripts/self-learning` + `~/.claude/self-learning.conf` — because a user may
   have installed before and after this change. Data removal stays behind the same opt-in
   flag it uses today; the deletion set is only files this project installed.

- [ ] **Step 1: Write the failing tests first**

`tests/test-install-paths.sh` — the teeth of this task. With `env -i`, a temp `HOME`, an
explicit `AGENT_LEARNING_HOME` under that temp HOME, and a fake `~/.copilot` directory so the
Copilot adapter step runs, execute `install.sh` for real (not `--dry-run`) and assert:
- every installed script exists under the resolved `scripts` directory;
- **no `${HOME}/.claude` directory was created at all** — this is the assertion the whole task
  exists for;
- the installed `~/.copilot/hooks/self-learning.json` contains the resolved absolute scripts
  path and contains no `.claude`, no `__SL_SCRIPTS_DIR__` placeholder left unsubstituted, and
  no `CLAUDE` string;
- the path in the installed hook config points at a file that actually exists;
- data directories were created under the resolved home, not under `~/.claude`;
- re-running `install.sh` a second time is idempotent and still creates no `~/.claude`.

Extend `tests/test-copilot-hooks-json.sh` to assert the *template* carries the placeholder and
contains no `.claude`. Extend `tests/test-claude-absent.sh` to assert the shipped template
contains no `~/.claude` — closing the vacuity Task 7 documented. Add `tests/test-paths.py`
cases for the new `scripts` key across the whole override chain (`AGENT_LEARNING_HOME`,
`XDG_DATA_HOME`, Windows `LOCALAPPDATA`, and the `~/.local/share` default).

- [ ] **Step 2: Run them and confirm they fail for the right reason**

They must fail naming the hardcoded path, not an environment artifact. A test that fails
because `install.sh` could not find `python3` under `env -i` is a broken test, not a red test.

- [ ] **Step 3: Implement**

Add the `scripts` key to `paths.py`. Rewrite `install.sh`'s path handling to read
`paths.py all` **once** into shell variables and use them everywhere — no second resolution
implementation in bash, per the global constraint. Convert `config/copilot-hooks.json` to a
template plus substitution at install time. Update `uninstall.sh` for both locations. Check
`install.ps1` / `uninstall.ps1` and fix only if they carry hardcoded paths.

- [ ] **Step 4: Run the full suite**

All suites must pass, including the previously green ones. `tests/test-uninstall.sh` is likely
to need updating alongside `uninstall.sh` — update it to match the new behavior, but never
weaken an assertion.

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(install): resolve install paths through paths.py, drop ~/.claude dependency"
```

---

