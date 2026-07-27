### Task 9: `doctor` — make failures visible

**Files:**
- Create: `scripts/doctor.sh`
- Test: `tests/test-doctor.sh`

**Interfaces:**
- Consumes: `scripts/lib/config.sh`, `scripts/lib/paths.py`.
- Produces: `bash scripts/doctor.sh` — prints resolved paths, writability, detected harnesses, and legacy-store warning. Exit 0 when healthy, 1 when a required path is not writable.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-doctor.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP_HOME="$(mktemp -d)"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1) || true

case "$OUT" in
    *"${TMP_HOME}/store/memory"*) echo "PASS: doctor prints resolved memory path" ;;
    *) echo "FAIL: memory path missing from doctor output"; FAILURES=$((FAILURES+1)) ;;
esac
case "$OUT" in
    *writable*) echo "PASS: doctor reports writability" ;;
    *) echo "FAIL: no writability report"; FAILURES=$((FAILURES+1)) ;;
esac

# Legacy store detection
mkdir -p "${TMP_HOME}/.claude/memory"
OUT=$(env -i HOME="$TMP_HOME" PATH="$PATH" AGENT_LEARNING_HOME="${TMP_HOME}/store" \
      SL_CONFIG_FILE="/nonexistent/x.conf" bash "${SCRIPT_DIR}/scripts/doctor.sh" 2>&1) || true
case "$OUT" in
    *legacy*) echo "PASS: legacy store detected" ;;
    *) echo "FAIL: legacy store not reported"; FAILURES=$((FAILURES+1)) ;;
esac

rm -rf "$TMP_HOME"
[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All doctor tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-doctor.sh`
Expected: FAIL — `scripts/doctor.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/doctor.sh — resolve and report framework state.
#
# The defect this framework shipped with was invisible: the hook exited 0, a
# log file existed, and nothing was persisted. `doctor` exists so that state is
# inspectable in seconds instead of months.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"

STATUS=0

echo "agent-self-learning doctor"
echo "--------------------------"
echo "resolved paths:"
for pair in "home:${SL_HOME}" "memory:${SL_MEMORY_DIR}" "skills:${SL_SKILLS_DIR}" \
            "state:${SL_STATE_DIR}" "logs:${SL_LOG_DIR}" "sessions_db:${SL_SEARCH_DB}"; do
    key="${pair%%:*}"; value="${pair#*:}"
    printf '  %-12s %s\n' "$key" "$value"
done

echo "writability:"
for dir in "${SL_MEMORY_DIR}" "${SL_SKILLS_DIR}" "${SL_STATE_DIR}" "${SL_LOG_DIR}"; do
    if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
        printf '  %-40s writable\n' "$dir"
    else
        printf '  %-40s NOT writable\n' "$dir"
        STATUS=1
    fi
done

echo "harnesses detected:"
command -v claude  >/dev/null 2>&1 && echo "  claude  (Claude Code)"  || echo "  claude  absent"
command -v copilot >/dev/null 2>&1 && echo "  copilot (Copilot CLI)"  || echo "  copilot absent"

if [[ -d "${HOME}/.claude/memory" || -d "${HOME}/.claude/learned-skills" ]]; then
    echo "legacy store found at ${HOME}/.claude"
    echo "  this release stores data at ${SL_HOME}"
    echo "  migrate deliberately, e.g.:"
    echo "    cp -r ${HOME}/.claude/memory ${HOME}/.claude/learned-skills ${SL_HOME}/"
fi

echo "review enabled: ${SL_REVIEW_ENABLED}"

# The review pipeline runs detached, so its failures cannot reach the hook's
# exit code. This log is where they surface — reporting it here is what keeps
# a broken loop from being invisible.
FAILURE_LOG="${SL_LOG_DIR}/persist-failures.log"
if [[ -s "$FAILURE_LOG" ]]; then
    echo "recent persistence failures (${FAILURE_LOG}):"
    tail -n 5 "$FAILURE_LOG" | sed 's/^/  /'
    STATUS=1
else
    echo "persistence failures: none recorded"
fi

exit "$STATUS"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-doctor.sh`
Expected: `All doctor tests passed.`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/doctor.sh
git add scripts/doctor.sh tests/test-doctor.sh
git commit -m "feat(doctor): report resolved paths, writability, harnesses, legacy store"
```

---

