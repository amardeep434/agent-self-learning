### Task 2: config.sh delegates to the resolver; env-var cleanup

**Files:**
- Modify: `scripts/lib/config.sh`
- Modify: `config/settings-hooks.json`
- Test: `tests/test-config.sh`

**Interfaces:**
- Consumes: `scripts/lib/paths.py` CLI (`all`).
- Produces: unchanged exported names `SL_HOME SL_STATE_DIR SL_SKILLS_DIR SL_MEMORY_DIR SL_LOG_DIR SL_SEARCH_DB`, plus new `SL_REVIEW_ENABLED`. Every other `SL_*` in the current file keeps its meaning.

**Context the implementer needs:** `scripts/session-review.sh` currently reads `CLAUDE_REVIEW_ENABLED` — it is the **only** live `CLAUDE_*` variable. `config/settings-hooks.json` sets nine `CLAUDE_REVIEW_*` entries; the other eight are read nowhere and are dead weight that implies Claude-coupling. Keep honoring `CLAUDE_REVIEW_ENABLED` for one release so existing installs do not silently change behavior.

- [ ] **Step 1: Write the failing test (append to existing file)**

```bash
# append to tests/test-config.sh, before the final FAILURES check

# Neutral defaults: no ~/.claude anywhere
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
case "$OUT" in
    *.claude*) echo "FAIL: SL_HOME still points into .claude ($OUT)"; FAILURES=$((FAILURES+1)) ;;
    *agent-learning*) echo "PASS: SL_HOME is vendor-neutral" ;;
    *) echo "FAIL: unexpected SL_HOME ($OUT)"; FAILURES=$((FAILURES+1)) ;;
esac

# Explicit override wins over platform default
OUT=$(env -i HOME="$HOME" PATH="$PATH" AGENT_LEARNING_HOME="/tmp/al" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_MEMORY_DIR\"")
check "AGENT_LEARNING_HOME drives SL_MEMORY_DIR" "/tmp/al/memory" "$OUT"

# New review flag defaults on
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED defaults true" "true" "$OUT"

# Legacy variable still honored for one release
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "legacy CLAUDE_REVIEW_ENABLED honored" "false" "$OUT"

# New variable beats legacy when both set
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_REVIEW_ENABLED=true SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED beats legacy" "true" "$OUT"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-config.sh`
Expected: FAIL — `SL_HOME still points into .claude (/home/<user>/.claude)` and `SL_REVIEW_ENABLED` empty.

- [ ] **Step 3: Modify `scripts/lib/config.sh`**

Add `SL_REVIEW_ENABLED` to the snapshot loop variable list (so pre-set env still wins), then replace the hardcoded default block:

```bash
# Replace these lines:
#   SL_HOME="${SL_HOME:-${HOME}/.claude}"
#   SL_STATE_DIR="${SL_STATE_DIR:-${SL_HOME}/state/self-learning}"
#   SL_SKILLS_DIR="${SL_SKILLS_DIR:-${SL_HOME}/learned-skills}"
#   SL_MEMORY_DIR="${SL_MEMORY_DIR:-${SL_HOME}/memory}"
#   SL_LOG_DIR="${SL_LOG_DIR:-${SL_HOME}/logs}"
#   SL_SEARCH_DB="${SL_SEARCH_DB:-${SL_HOME}/sessions/search.db}"
# with:

# Paths come from scripts/lib/paths.py — the single resolver shared with Python.
# Never recompute them here; bash and python disagreeing across three operating
# systems is exactly the drift this indirection prevents.
_sl_paths_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.py"
if [[ -f "$_sl_paths_py" ]]; then
    while IFS='=' read -r _k _v; do
        case "$_k" in
            home)        SL_HOME="${SL_HOME:-$_v}" ;;
            state)       SL_STATE_DIR="${SL_STATE_DIR:-$_v}" ;;
            skills)      SL_SKILLS_DIR="${SL_SKILLS_DIR:-$_v}" ;;
            memory)      SL_MEMORY_DIR="${SL_MEMORY_DIR:-$_v}" ;;
            logs)        SL_LOG_DIR="${SL_LOG_DIR:-$_v}" ;;
            sessions_db) SL_SEARCH_DB="${SL_SEARCH_DB:-$_v}" ;;
        esac
    done < <(python3 "$_sl_paths_py" all 2>/dev/null)
fi
```

Then add the review flag with legacy fallback, after the other defaults:

```bash
# SL_REVIEW_ENABLED supersedes CLAUDE_REVIEW_ENABLED. The legacy name is
# honored for one release so existing installs do not change behavior on
# upgrade; it is Claude-branded and read on the Copilot path, which is
# precisely the vendor coupling this release removes.
if [[ -z "${SL_REVIEW_ENABLED:-}" && -n "${CLAUDE_REVIEW_ENABLED:-}" ]]; then
    SL_REVIEW_ENABLED="$CLAUDE_REVIEW_ENABLED"
    echo "agent-self-learning: CLAUDE_REVIEW_ENABLED is deprecated; use SL_REVIEW_ENABLED" >&2
fi
SL_REVIEW_ENABLED="${SL_REVIEW_ENABLED:-true}"
```

Add `SL_REVIEW_ENABLED` to the final `export` list.

In `config/settings-hooks.json`, replace the entire `"env"` object with:

```json
  "env": {
    "SL_MEMORY_REVIEW_INTERVAL": "10",
    "SL_SKILL_REVIEW_INTERVAL": "10",
    "SL_REVIEW_ENABLED": "true",
    "SL_REVIEW_MIN_TURNS": "5",
    "SL_REVIEW_MAX_TURNS": "16"
  },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-config.sh && python3 tests/test-paths.py`
Expected: PASS, including the pre-existing assertions.

Note: the pre-existing assertion `check "missing file falls back to defaults" "$HOME/.claude" "$OUT"` now contradicts the new default — update its expected value to `$HOME/.local/share/agent-learning`. This is a deliberate behavior change, not a broken test.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/config.sh config/settings-hooks.json tests/test-config.sh
git commit -m "feat(config): resolve paths via paths.py, add SL_REVIEW_ENABLED, drop dead CLAUDE_REVIEW_* entries"
```

---

