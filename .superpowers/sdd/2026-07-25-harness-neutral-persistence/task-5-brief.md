### Task 5: Invert the Claude Code reviewer

**Files:**
- Modify: `scripts/session-review.sh` (prompt around line 58-66; spawn at line 113)
- Test: `tests/test-session-review.sh`

**Interfaces:**
- Consumes: `scripts/persist-proposal.py`, `SL_MEMORY_DIR`, `SL_SKILLS_DIR`, `SL_LOG_DIR`, `SL_REVIEW_ENABLED`.
- Produces: no new symbols. Behavioral contract: the reviewer's stdout is piped to the writer; the script exits non-zero if the writer fails.

- [ ] **Step 1: Write the failing test (append to `tests/test-session-review.sh`)**

```bash
# Reviewer output is persisted by the writer, not by the agent.
TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cat > "${FAKE_BIN}/claude" <<'FAKE'
#!/usr/bin/env bash
# Ignore all arguments; emit a valid proposal on stdout and write nothing.
cat <<'JSON'
```json
{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "persisted-by-writer"}]}
```
JSON
FAKE
chmod +x "${FAKE_BIN}/claude"

env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/session-review.sh" </dev/null >/dev/null 2>&1 || true

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "reviewer proposal persisted" "persisted-by-writer" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: MEMORY.md was not written by the writer"; FAILURES=$((FAILURES+1))
fi
rm -rf "$TMP_HOME" "$FAKE_BIN"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-session-review.sh`
Expected: FAIL — `MEMORY.md was not written by the writer` (the current script tells the agent to write, and the fake agent writes nothing).

- [ ] **Step 3: Modify `scripts/session-review.sh`**

Replace the write instruction in the prompt (currently line 66, `... Write to MEMORY.md or USER.md as appropriate.`) with an explicit stdout-only contract:

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

Replace the spawn (currently line 113) so stdout flows into the writer:

```bash
# The reviewer proposes; this script persists. The ENTIRE pipeline is
# backgrounded: a review takes minutes while the Stop hook timeout is
# 15000 ms, so running it synchronously would have the harness kill the
# review mid-flight. Backgrounding the pipeline (not merely the reviewer)
# keeps the hook fast while still ensuring the writer — never the agent —
# owns every write.
mkdir -p "${SL_LOG_DIR}"
SL_REVIEW_ACTIVE=1 nohup bash -c '
    set -o pipefail
    "$1" -p "$2" 2>>"$3/review-stderr.log" \
        | python3 "$4" >>"$3/persist.log" 2>&1
    status=$?
    if [[ $status -ne 0 ]]; then
        printf "%s session-review: pipeline failed (status %s)\n" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" >>"$3/persist-failures.log"
    fi
' _ claude "$REVIEW_PROMPT" "$SL_LOG_DIR" "${SCRIPT_DIR}/persist-proposal.py" \
    >/dev/null 2>&1 &
disown 2>/dev/null || true
```

Notes for the implementer:

1. Arguments are passed **positionally** into `bash -c`, never interpolated into the script body. `$REVIEW_PROMPT` contains model-generated text; interpolating it would be a shell-injection hole.
2. Because the pipeline is detached, the hook cannot report persistence failure through its own exit code. Failures are appended to `${SL_LOG_DIR}/persist-failures.log`, which `scripts/doctor.sh` surfaces (Task 9). **That log is the visibility mechanism replacing the exit code** — without it, this reintroduces exactly the silent-failure mode this plan exists to remove.
3. The Task 5 test must therefore wait for the detached pipeline before asserting. Poll for the file with a bounded timeout rather than sleeping a fixed interval:

```bash
for _ in $(seq 1 50); do
    [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]] && break
    sleep 0.2
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-session-review.sh`
Expected: PASS, including pre-existing assertions.

- [ ] **Step 5: Commit**

```bash
git add scripts/session-review.sh tests/test-session-review.sh
git commit -m "fix(review): reviewer proposes on stdout, script persists (Claude Code path)"
```

---

