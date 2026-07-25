### Task 7c: Three scripts still hardcode the store path

**Added during execution**, from Task 7b's review. Task 7b migrated the *installer*, but three
installed scripts recompute the store location internally from a hardcoded `${HOME}/.claude`
instead of resolving it through `config.sh` / `paths.py`:

- `scripts/self-learning-health.sh` — lines 64-69, 95, 113, 145, 161
- `scripts/curator-run.sh` — lines 21-29
- `scripts/index-session.sh` — lines 11-13

Demonstrated live during review: a freshly-installed `self-learning-health.sh` reports **every**
check as `[FAIL] ... missing / Fix: Run install.sh` on a machine that had just installed
successfully, and `curator-run.sh` would manage skills at a nonexistent path — silently doing
nothing to the real `learned-skills` directory. This violates global constraint 4 (paths are
computed in exactly one place) and reproduces the project's signature failure mode: a component
that appears to run fine while operating on the wrong location.

**Files:**
- Modify: `scripts/self-learning-health.sh`, `scripts/curator-run.sh`, `scripts/index-session.sh`
- Create: `tests/test-script-paths.sh`

**Interfaces:**
- Consumes: `scripts/lib/config.sh` (already exports every needed variable and already delegates
  to `paths.py`).
- Produces: no new symbols.

**The one distinction that must not be flattened:**

`index-session.sh:13` sets `SESSIONS_DIR="${HOME}/.claude/projects"`. That is **Claude Code's own
transcript directory** — the session *source* this script reads, not the framework's store. It is
legitimately Claude-specific and **must stay**, exactly as `config/settings-hooks.json` legitimately
references `~/.claude`. Neutralizing it would break session indexing. What must change is only the
framework's **own** paths: script dir, state, skills, logs, backups, sessions DB, config file.
`~/.claude/settings.json` in `self-learning-health.sh:113` is likewise Claude Code's own config
file and stays — but the *check* around it should be clearly labelled as Claude-Code-specific
rather than presented as a framework-wide health requirement.

- [ ] **Step 1: Write the failing test**

`tests/test-script-paths.sh`: with `env -i`, a temp `HOME`, and an explicit `AGENT_LEARNING_HOME`
pointing somewhere under it, seed the resolved store so a healthy install is simulated, then run
`self-learning-health.sh` and assert it does **not** report the store as missing. Assert that none
of the three scripts resolves a framework path under `${HOME}/.claude` — by observing behavior
under a redirected `AGENT_LEARNING_HOME`, not by grepping source, since a grep cannot distinguish
the legitimate Claude-Code-source references from the illegitimate store references. Add a
narrowly-scoped source assertion **only** for the specific legitimate exceptions, so a future edit
that reintroduces a hardcoded store path is caught.

- [ ] **Step 2: Run it and confirm it fails for the right reason** — naming the hardcoded store
      path, not a missing dependency under `env -i`.

- [ ] **Step 3: Implement.** Each script sources `scripts/lib/config.sh` and uses the exported
      variables. Do not add a second resolution path in bash. Scripts locate their own directory
      via `dirname "${BASH_SOURCE[0]}"` — the pattern `turn-counter.sh`, `session-review.sh` and
      `skillopt-run.sh` already use correctly — never a hardcoded install dir.

- [ ] **Step 4: Full suite.** All suites pass, including `tests/test-install-paths.sh`.

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(scripts): resolve store paths via config.sh in health, curator, index-session"
```

---

