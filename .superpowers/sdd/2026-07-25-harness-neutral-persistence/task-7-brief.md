### Task 7: Claude-absent regression guard

**Files:**
- Create: `tests/test-claude-absent.sh`

**Interfaces:**
- Consumes: `scripts/copilot-session-review.sh`, `scripts/persist-proposal.py`.
- Produces: no symbols. This is the executable form of the rule "no Copilot code path may depend on Claude Code."

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-claude-absent.sh
# The Copilot path must work on a machine with no `claude` binary and no
# ~/.claude directory. This is the regression guard for harness independence.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"

# A PATH containing copilot and the system basics, but deliberately no `claude`.
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "no-claude-needed"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/copilot"
MINIMAL_PATH="${FAKE_BIN}:/usr/bin:/bin"

if PATH="$MINIMAL_PATH" command -v claude >/dev/null 2>&1; then
    echo "FAIL: test setup is wrong — claude is reachable"; FAILURES=$((FAILURES+1))
else
    echo "PASS: claude is absent from PATH"
fi

env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "persisted without claude" "no-claude-needed" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: nothing persisted with claude absent"; FAILURES=$((FAILURES+1))
fi

# Nothing may have been created under ~/.claude.
if [[ -e "${TMP_HOME}/.claude" ]]; then
    echo "FAIL: Copilot path created ${TMP_HOME}/.claude"; FAILURES=$((FAILURES+1))
else
    echo "PASS: no ~/.claude created"
fi

# No shipped script referenced by the Copilot path may mention the claude binary.
if grep -nE '(^|[^a-z-])claude -p' "${SCRIPT_DIR}/scripts/copilot-session-review.sh" >/dev/null 2>&1; then
    echo "FAIL: copilot-session-review.sh invokes the claude binary"; FAILURES=$((FAILURES+1))
else
    echo "PASS: copilot path does not invoke claude"
fi

rm -rf "$TMP_HOME" "$FAKE_BIN"
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All claude-absent tests passed."
```

- [ ] **Step 2: Run test to verify it fails or passes for the right reason**

Run: `bash tests/test-claude-absent.sh`
Expected after Tasks 1-6: PASS. If it fails, the failure names the exact coupling still present — fix that, do not weaken the test.

- [ ] **Step 3: Make it executable and wire it into the runner (Task 8 creates the runner; if running out of order, just verify manually)**

```bash
chmod +x tests/test-claude-absent.sh
```

- [ ] **Step 4: Run once more to confirm**

Run: `bash tests/test-claude-absent.sh`
Expected: `All claude-absent tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tests/test-claude-absent.sh
git commit -m "test: guard that the Copilot path never depends on Claude Code"
```

---

