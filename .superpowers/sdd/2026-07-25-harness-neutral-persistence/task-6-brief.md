### Task 6: Invert the Copilot reviewer

**Files:**
- Modify: `scripts/copilot-session-review.sh` (spawn at lines 75-76)
- Test: `tests/test-copilot-session-review.sh`

**Interfaces:**
- Consumes: `scripts/persist-proposal.py`, `SL_COPILOT_REVIEW_MODEL`, `SL_MEMORY_DIR`, `SL_SKILLS_DIR`.
- Produces: no new symbols. `--allow-tool write` is removed — the reviewer no longer needs it.

- [ ] **Step 1: Write the failing test (append to `tests/test-copilot-session-review.sh`)**

```bash
# Copilot reviewer output is persisted, and no write tool is requested.
TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "write" ]]; then
        echo "FAIL_MARKER: write tool was requested" >&2
        exit 3
    fi
done
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "copilot-persisted"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/copilot"

env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "copilot proposal persisted" "copilot-persisted" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: Copilot path did not persist"; FAILURES=$((FAILURES+1))
fi
rm -rf "$TMP_HOME" "$FAKE_BIN"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-copilot-session-review.sh`
Expected: FAIL — `Copilot path did not persist`, and the fake binary may print `FAIL_MARKER: write tool was requested`.

- [ ] **Step 3: Modify `scripts/copilot-session-review.sh`**

Replace the spawn block (lines 75-76 and its continuation) with:

```bash
# No --allow-tool write: the reviewer proposes, this script persists. Copilot
# CLI's path allow-list refused writes to the store, which made this loop a
# silent no-op; removing the write tool removes the dependency entirely.
COPILOT_ARGS=(-s --allow-tool read)
[[ -n "${SL_COPILOT_REVIEW_MODEL}" ]] && COPILOT_ARGS+=(--model "${SL_COPILOT_REVIEW_MODEL}")

# Entire pipeline detached, for the same reason as the Claude Code path: a
# review outlives the hook timeout. Failures land in persist-failures.log,
# which doctor surfaces — that log replaces the exit code as the visibility
# mechanism, and without it this is a silent no-op again.
mkdir -p "${SL_LOG_DIR}"
SL_REVIEW_ACTIVE=1 nohup bash -c '
    set -o pipefail
    prompt="$1"; logdir="$2"; writer="$3"; shift 3
    copilot "$@" -p "$prompt" 2>>"$logdir/copilot-review-stderr.log" \
        | python3 "$writer" >>"$logdir/persist.log" 2>&1
    status=$?
    if [[ $status -ne 0 ]]; then
        printf "%s copilot-session-review: pipeline failed (status %s)\n" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" >>"$logdir/persist-failures.log"
    fi
' _ "$REVIEW_PROMPT" "$SL_LOG_DIR" "${SCRIPT_DIR}/persist-proposal.py" \
    "${COPILOT_ARGS[@]}" >/dev/null 2>&1 &
disown 2>/dev/null || true
```

The Task 6 test must poll for the file rather than assert immediately, exactly as in Task 5:

```bash
for _ in $(seq 1 50); do
    [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]] && break
    sleep 0.2
done
```

Replace this script's write instruction with the same stdout-only contract (repeated here in full so this task can be implemented without reading Task 5):

```bash
OUTPUT CONTRACT — follow exactly:
Do NOT write, create, or edit any file. You have no permission to do so and
any attempt will be discarded. Emit exactly one JSON object as your entire
final message, in a fenced json block:

```json
{"version": 1,
 "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "<full new contents>"}],
 "skills": [{"name": "kebab-case-name", "content": "<full skill markdown>"}]}
```

Rules: "file" must be MEMORY.md or USER.md. "mode" is "replace" or "append".
"name" must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}. Omit "memory" or "skills"
entirely when there is nothing to record. Emit nothing after the block.
```

The existing model-string regex validation must be kept exactly as-is — it guards `--model` against argument injection.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-copilot-session-review.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/copilot-session-review.sh tests/test-copilot-session-review.sh
git commit -m "fix(review): Copilot reviewer proposes on stdout; drop --allow-tool write"
```

---

