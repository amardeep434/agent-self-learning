#!/usr/bin/env bash
# tests/test-session-review.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
# Item 3 (deferred minor): this file allocates additional temp dirs further
# down (TMP_HOME/FAKE_BIN, TMP6) that used to be cleaned only via an explicit
# `rm -rf` on the success path -- an early `exit 1` leaked them. One EXIT
# trap covering every temp dir this script ever creates, referencing the
# later variables via ${VAR:-} so it's safe to register before they're set
# (the trap body is expanded when EXIT fires, not when trap is registered).
# fix-p6: sl_rm_rf_retry, not a bare `rm -rf`, on this trap -- defense in
# depth alongside sl_wait_for_review_complete used below (see
# tests/lib/wait-for-review.sh for why both layers exist).
trap 'sl_rm_rf_retry "$TMP"; sl_rm_rf_retry "${TMP_HOME:-}"; sl_rm_rf_retry "${FAKE_BIN:-}"; sl_rm_rf_retry "${TMP6:-}"; sl_rm_rf_retry "${TMP8:-}"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE="/nonexistent"
export SL_COACH_SIGNALS_FILE="$TMP/state/coach-signals.json"
mkdir -p "$TMP/state" "$TMP/bin"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/wait-for-review.sh
source "${SCRIPT_DIR}/tests/lib/wait-for-review.sh"

# Fake `claude` binary that records its argv and env
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_CLAUDE_LOG}"
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" FAKE_CLAUDE_LOG="$TMP/claude-calls.log"

# Counter above the min-turns gate
echo '{"session_id":"s1","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' > "$TMP/state/turn_counter.json"


# fix-p7 (audit follow-up): every case below that drives a review for real
# used to wait a bare fixed sleep before asserting on what the DETACHED
# pipeline produced. An earlier round retrofitted the marker wait
# (tests/lib/wait-for-review.sh) onto the cases that then tore the tree
# down, and judged these "wide margin". Re-judged here and that call was
# wrong: 0.3s does not cover `nohup bash -c` plus a bash shim on a loaded
# windows-latest runner -- this repo's own fix round E documents Windows
# process-spawn overhead as a real, measured cost, and a flaky
# zero-tolerance assertion in tests/test-config.sh already turned this
# branch's CI red once. The positive assertions could false-FAIL; worse,
# the negative one ("spawns nothing") could false-PASS vacuously against a
# log that was empty only because nothing had started yet. All of them are
# now gated on the pipeline's own completion marker, which is unconditional
# and the last statement it runs, so the retrofit is mechanical after all.

# 1) Review spawns with recursion guard set
sl_clear_review_marker "$SL_LOG_DIR"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "claude was invoked" "yes" "$([[ -s "$FAKE_CLAUDE_LOG" ]] && echo yes || echo no)"
check "guard env set for reviewer" "1" "$(grep -m1 '^GUARD:' "$FAKE_CLAUDE_LOG" | cut -d: -f2)"

# 1b) Global Constraint 5: the reviewer must not be GRANTED file-write tools.
# The Copilot path has enforced this mechanically since Task 6 (its argv
# assertion is in tests/test-review-cli-flags.sh); this path enforced it by
# prompt text alone until the final closeout round, which is not the same
# thing -- a poisoned transcript can argue with a prompt, it cannot argue
# with a deny rule. These assert the real argv the hook builds, recorded by
# the fake `claude` shim above.
#
# The deny assertion is the load-bearing one: --allowedTools only
# auto-approves, whereas a deny rule wins over anything the host's
# settings.json may have allowed globally.
#
# Grepped over the whole log, not over a single `^ARGS:` line: the review
# prompt is multi-line, so `echo "ARGS:$*"` in the shim spans many lines and
# the flags land well after the first one. An earlier draft of this check
# used `grep -m1 '^ARGS:'` and failed against a correct implementation --
# recorded here because that is precisely the false-negative shape this
# suite exists to avoid.
check "reviewer argv denies the file-write tools" "yes" \
    "$(grep -q -- '--disallowedTools Write,Edit,NotebookEdit' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "reviewer argv still permits the read tools it needs" "yes" \
    "$(grep -q -- '--allowedTools Read,Glob,Grep' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"

# 2) Recursion guard on entry: guarded call spawns nothing
: > "$FAKE_CLAUDE_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/session-review.sh"
# Negative assertion: watch for the marker for a bounded window and require
# that it never arrives, rather than sampling an empty log once (which would
# also "pass" against a guard that is broken but merely slow).
check "no review pipeline was spawned at all" "yes" \
    "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
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
sl_clear_review_marker "$SL_LOG_DIR"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
unset SL_COACH_EXPORT_ENABLED SL_COACH_EXPORT_PATH
sl_wait_for_review_complete "$SL_LOG_DIR" || true
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

# fix-p6: wait for the detached pipeline's own completion marker (see
# tests/lib/wait-for-review.sh), not only for MEMORY.md to appear.
sl_clear_review_marker "${TMP_HOME}/store/logs"
env -i HOME="$TMP_HOME" PATH="${FAKE_BIN}:${PATH}" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    FAKE_CLAUDE_ARGV_LOG="${ARGV_LOG}" \
    bash "${SCRIPT_DIR}/scripts/session-review.sh" </dev/null >/dev/null 2>&1 || true

sl_wait_for_review_complete "${TMP_HOME}/store/logs" || true

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

# 6) P0b fix: a real Stop-hook payload's transcript_path + a seeded Claude
# Code transcript JSONL actually reaches the reviewer's prompt. Same
# argv-recording shim technique as case 1, but now the payload carries a
# real transcript_path pointing at a fixture built from the REAL Claude
# Code schema (verified against ~/.claude/projects/*/*.jsonl -- see
# scripts/lib/transcript.py's module docstring and
# tests/test-transcript.py's fixtures).
TMP6="$(mktemp -d)"
echo '{"session_id":"s6","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "$TMP/state/turn_counter.json"
TRANSCRIPT_FILE="${TMP6}/transcript.jsonl"
cat > "$TRANSCRIPT_FILE" <<'EOF'
{"parentUuid":null,"isSidechain":false,"type":"system","uuid":"u0","timestamp":"2026-07-25T12:00:00.000Z","sessionId":"s6","subtype":"stop_hook_summary"}
{"parentUuid":"u0","isSidechain":false,"type":"user","uuid":"u1","timestamp":"2026-07-25T12:00:01.000Z","sessionId":"s6","message":{"role":"user","content":"UNIQUE_MARKER_USER_TURN_CASE6"}}
{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"u2","timestamp":"2026-07-25T12:00:02.000Z","sessionId":"s6","message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal, must not reach the prompt"},{"type":"text","text":"UNIQUE_MARKER_ASSISTANT_TURN_CASE6"}]}}
{"parentUuid":"u2","isSidechain":false,"type":"user","uuid":"u3","timestamp":"2026-07-25T12:00:03.000Z","sessionId":"s6","message":{"role":"user","content":"Continue from where you left off."},"isMeta":true}
EOF
: > "$FAKE_CLAUDE_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
echo "{\"session_id\":\"s6\",\"hook_event_name\":\"Stop\",\"transcript_path\":\"${TRANSCRIPT_FILE}\"}" \
    | bash "${SCRIPT_DIR}/scripts/session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "transcript user turn reached the prompt" "yes" \
    "$(grep -q 'UNIQUE_MARKER_USER_TURN_CASE6' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "transcript assistant text reached the prompt" "yes" \
    "$(grep -q 'UNIQUE_MARKER_ASSISTANT_TURN_CASE6' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "thinking block did NOT reach the prompt" "no" \
    "$(grep -q 'internal, must not reach the prompt' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "isMeta turn did NOT reach the prompt" "no" \
    "$(grep -q 'Continue from where you left off' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "transcript section framed as untrusted data" "yes" \
    "$(grep -q 'untrusted conversation data' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"

# 7) Missing transcript_path is logged visibly to persist-failures.log,
# never a silent empty review.
echo '{"session_id":"s1","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "$TMP/state/turn_counter.json"
rm -f "${TMP}/logs/persist-failures.log"
: > "$FAKE_CLAUDE_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
echo '{"session_id":"s1","hook_event_name":"Stop"}' | bash "${SCRIPT_DIR}/scripts/session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "missing transcript_path logged to persist-failures.log" "yes" \
    "$([[ -f "${TMP}/logs/persist-failures.log" ]] && grep -q 'session-review: transcript unavailable' "${TMP}/logs/persist-failures.log" && echo yes || echo no)"

# 8) THE TRAP. VS Code's default `chat.hookFilesLocations` includes
# `~/.claude/settings.json` -- the exact file install.sh tells users to merge
# these hooks into -- so VS Code Copilot Chat runs THIS script with a VS Code
# transcript_path. The payloads are indistinguishable (same field names, same
# "Stop" event name), so the transcript file's own content is the only
# discriminator, and `Stop` fires PER TURN in VS Code rather than per session.
#
# MEASURED before the fix, against this exact fixture: summarize_claude_events
# extracted 0 messages, so the digest was empty, one "no user/assistant text
# content" line went to persist-failures.log, and the reviewer was spawned
# anyway -- a paid model call that could not learn anything, once per VS Code
# turn, plus a log line per turn that pushes doctor.sh permanently UNHEALTHY.
#
# Both halves are asserted: the digest must be REAL, and the failure log must
# stay clean. Asserting only the first would still allow a per-turn log line.
TMP8="$(mktemp -d)"
echo '{"session_id":"s8","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "$TMP/state/turn_counter.json"
VSCODE_TRANSCRIPT="${TMP8}/vscode.jsonl"
cat > "$VSCODE_TRANSCRIPT" <<'EOF'
{"type":"session.start","data":{"sessionId":"vs8","producer":"copilot-chat","copilotVersion":"0.58.0","vscodeVersion":"1.130.0"},"id":"e0","parentId":null,"timestamp":"2026-07-28T10:00:00.000Z"}
{"type":"user.message","data":{"content":"UNIQUE_MARKER_VSCODE_ON_CLAUDE_PATH","attachments":[]},"id":"e1","parentId":"e0","timestamp":"2026-07-28T10:00:01.000Z"}
{"type":"assistant.turn_start","data":{"turnId":"0"},"id":"e2","parentId":"e1","timestamp":"2026-07-28T10:00:02.000Z"}
{"type":"assistant.message","data":{"messageId":"m1","content":"UNIQUE_MARKER_VSCODE_REPLY","toolRequests":[]},"id":"e3","parentId":"e2","timestamp":"2026-07-28T10:00:03.000Z"}
{"type":"assistant.turn_end","data":{"turnId":"0"},"id":"e4","parentId":"e3","timestamp":"2026-07-28T10:00:04.000Z"}
EOF
rm -f "${TMP}/logs/persist-failures.log"
: > "$FAKE_CLAUDE_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
echo "{\"session_id\":\"vs8\",\"hook_event_name\":\"Stop\",\"cwd\":\"/tmp/ws\",\"timestamp\":1785000000000,\"stop_hook_active\":false,\"transcript_path\":\"${VSCODE_TRANSCRIPT}\"}" \
    | bash "${SCRIPT_DIR}/scripts/session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "VS Code user turn reaches the prompt on the Claude path" "yes" \
    "$(grep -q 'UNIQUE_MARKER_VSCODE_ON_CLAUDE_PATH' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "VS Code assistant turn reaches the prompt on the Claude path" "yes" \
    "$(grep -q 'UNIQUE_MARKER_VSCODE_REPLY' "$FAKE_CLAUDE_LOG" && echo yes || echo no)"
check "a VS Code transcript writes NO persist-failures.log line" "yes" \
    "$([[ ! -s "${TMP}/logs/persist-failures.log" ]] && echo yes || echo no)"
sl_rm_rf_retry "$TMP8"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All session-review tests passed."
