#!/usr/bin/env bash
# tests/test-session-review.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE="/nonexistent"
export SL_COACH_SIGNALS_FILE="$TMP/state/coach-signals.json"
mkdir -p "$TMP/state" "$TMP/bin"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Fake `claude` binary that records its argv and env
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_CLAUDE_LOG}"
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" FAKE_CLAUDE_LOG="$TMP/claude-calls.log"

# Counter above the min-turns gate
echo '{"session_id":"s1","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' > "$TMP/state/turn_counter.json"

# 1) Review spawns with recursion guard set
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
sleep 0.3
check "claude was invoked" "yes" "$([[ -s "$FAKE_CLAUDE_LOG" ]] && echo yes || echo no)"
check "guard env set for reviewer" "1" "$(grep -m1 '^GUARD:' "$FAKE_CLAUDE_LOG" | cut -d: -f2)"

# 2) Recursion guard on entry: guarded call spawns nothing
: > "$FAKE_CLAUDE_LOG"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/session-review.sh"
sleep 0.3
check "guarded entry spawns nothing" "no" "$([[ -s "$FAKE_CLAUDE_LOG" ]] && echo yes || echo no)"

# 3) Coach signals appear in the prompt when signals exist.
# The signal is planted BOTH as a pre-built signals file (valid before Task 12
# wires coach-signals.py into this script) AND as a Route B export fixture with
# SL_COACH_EXPORT_ENABLED=true (valid after Task 12, when coach-signals.py
# regenerates the signals file from the export before the prompt is built).
echo '{"session_id":"s1","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' > "$TMP/state/turn_counter.json"
echo '{"generated_at":"2099-01-01T00:00:00Z","signals":[{"id":"mega-sessions","severity":"high","suggestion":"Break large tasks into focused conversations."}]}' > "$SL_COACH_SIGNALS_FILE"
export SL_COACH_EXPORT_ENABLED=true SL_COACH_EXPORT_PATH="$TMP/export.json"
echo '{"antiPatterns":{"totalOccurrences":1,"topPatterns":[{"id":"mega-sessions","name":"Mega Sessions","severity":"high","group":"session-hygiene","occurrences":1,"description":"d","suggestion":"Break large tasks into focused conversations."}]}}' > "$SL_COACH_EXPORT_PATH"
: > "$FAKE_CLAUDE_LOG"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
unset SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH
sleep 0.3
check "coach signal id reaches prompt" "yes" "$(grep -q 'mega-sessions' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"

# 4) settings-hooks.json uses the valid nested schema
SCHEMA_OK=$(jq -e '.hooks.PostToolUse[0].hooks[0].type == "command" and (.hooks.Stop | length) >= 1' \
    "${SCRIPT_DIR}/config/settings-hooks.json" >/dev/null && echo yes || echo no)
check "settings-hooks.json nested schema" "yes" "$SCHEMA_OK"
ROLLING=$(grep -c 'rolling-transcript' "${SCRIPT_DIR}/config/settings-hooks.json" || true)
check "no reference to nonexistent rolling-transcript.sh" "0" "$ROLLING"

# 5) Reviewer output is persisted by the writer, not by the agent.
TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
ARGV_LOG="${TMP_HOME}/claude-argv.log"
cat > "${FAKE_BIN}/claude" <<'FAKE'
#!/usr/bin/env bash
# Record our own argv so the test can assert the turn cap was passed, then
# ignore all arguments; emit a valid proposal on stdout and write nothing.
echo "$*" >> "${FAKE_CLAUDE_ARGV_LOG}"
cat <<'JSON'
```json
{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "persisted-by-writer"}]}
```
JSON
FAKE
chmod +x "${FAKE_BIN}/claude"

# The script exits early unless a turn counter above the min-turns gate
# already exists, so seed one under the resolved state dir before invoking.
mkdir -p "${TMP_HOME}/store/state"
echo '{"session_id":"s5","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "${TMP_HOME}/store/state/turn_counter.json"

env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    FAKE_CLAUDE_ARGV_LOG="${ARGV_LOG}" \
    bash "${SCRIPT_DIR}/scripts/session-review.sh" </dev/null >/dev/null 2>&1 || true

for _ in $(seq 1 50); do
    [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]] && break
    sleep 0.2
done

# Turn cap must reach the backgrounded reviewer: an unbounded background
# model loop is exactly the cost regression this framework exists to avoid.
# Default SL_REVIEW_MAX_TURNS (no config file, no env override here) is 16.
check "spawn passes turn cap" "yes" \
    "$(grep -q -- '--max-turns 16' "${ARGV_LOG}" 2>/dev/null && echo yes || echo no)"
check "spawn passes plain-text output format" "yes" \
    "$(grep -q -- '--output-format text' "${ARGV_LOG}" 2>/dev/null && echo yes || echo no)"

if [[ -f "${TMP_HOME}/store/memory/MEMORY.md" ]]; then
    check "reviewer proposal persisted" "persisted-by-writer" "$(cat "${TMP_HOME}/store/memory/MEMORY.md")"
else
    echo "FAIL: MEMORY.md was not written by the writer"; FAILURES=$((FAILURES+1))
fi
rm -rf "$TMP_HOME" "$FAKE_BIN"

# I8: the prompt used to state a dot-inclusive skill-name charset
# (^[a-z0-9][a-z0-9._-]*$) that contradicted proposal_schema.py's actual
# regex, stated a few lines later in the same prompt (self-contradictory).
# Pin that the prompt states the schema regex once, and never states the
# stale dot-inclusive form anywhere.
check "prompt states the real schema regex" "yes" \
    "$(grep -qF '[A-Za-z0-9][A-Za-z0-9_-]{0,63}' "${SCRIPT_DIR}/scripts/session-review.sh" && echo yes || echo no)"
check "prompt no longer states the dot-inclusive contradiction" "no" \
    "$(grep -qE '\[a-z0-9\]\[a-z0-9\._-\]' "${SCRIPT_DIR}/scripts/session-review.sh" && echo yes || echo no)"
check "prompt no longer instructs the model to write .usage.json itself" "no" \
    "$(grep -qi 'set created_by.*\.usage\.json' "${SCRIPT_DIR}/scripts/session-review.sh" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All session-review tests passed."
