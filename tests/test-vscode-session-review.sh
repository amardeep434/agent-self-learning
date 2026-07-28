#!/usr/bin/env bash
# tests/test-vscode-session-review.sh
#
# The VS Code Copilot Chat adapter's hook script, driven end to end with
# fake reviewer CLIs. Modelled on tests/test-copilot-session-review.sh and
# tests/test-session-review.sh.
#
# EVERY launch of the detached review pipeline in this file is paired with
# sl_wait_for_review_complete or sl_expect_no_review_spawned --
# tests/test-review-launch-lint.py enforces that, and the failure it prevents
# (a negative assertion passing vacuously against a log that is empty only
# because the spawn has not happened yet) is exactly the shape of assertion
# this file is full of.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'sl_rm_rf_retry "$TMP"; sl_rm_rf_retry "${TMP7:-}"; sl_rm_rf_retry "${FAKE_BIN7:-}"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE="/nonexistent"
export SL_COACH_SIGNALS_FILE="$TMP/state/coach-signals.json"
mkdir -p "$TMP/state" "$TMP/bin"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/wait-for-review.sh
source "${SCRIPT_DIR}/tests/lib/wait-for-review.sh"

# The script under test is spelled out in full at every launch site below,
# never through this variable. tests/test-review-launch-lint.py matches the
# literal `bash .../vscode-session-review.sh` text; a launch written through
# a variable is invisible to it, so every launch site in this suite would go
# unchecked while the lint still reported success -- "green while testing
# nothing", the exact failure the lint exists to prevent. (Measured: with the
# variable form the lint saw 0 of this file's launches and still passed.)
# REVIEW is used only for source-text greps, never to launch anything.
REVIEW="${SCRIPT_DIR}/scripts/vscode-session-review.sh"

# Fake reviewer CLIs. `copilot` is the auto-detect winner, `claude` the
# fallback; both record their own argv and the recursion-guard env so every
# assertion below is about what was really invoked.
cat > "$TMP/bin/copilot" <<'EOF'
#!/usr/bin/env bash
{ echo "WHO:copilot"; echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_REVIEWER_LOG}"
printf '{"version": 1}\n'
EOF
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "WHO:claude"; echo "ARGS:$*"; echo "GUARD:${SL_REVIEW_ACTIVE:-unset}"; } >> "${FAKE_REVIEWER_LOG}"
printf '{"version": 1}\n'
EOF
chmod +x "$TMP/bin/copilot" "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" FAKE_REVIEWER_LOG="$TMP/reviewer-calls.log"

# A shape-accurate VS Code transcript. Types and key shapes taken from the
# real files under ~/.config/Code/User/workspaceStorage/<ws>/
# GitHub.copilot-chat/transcripts/ (2026-07-28, VS Code 1.130.0 /
# GitHub.copilot-chat 0.58.0); content is placeholders only.
VSCODE_TRANSCRIPT="$TMP/vscode-transcript.jsonl"
cat > "$VSCODE_TRANSCRIPT" <<'EOF'
{"type":"session.start","data":{"sessionId":"vs1","producer":"copilot-chat","copilotVersion":"0.58.0","vscodeVersion":"1.130.0"},"id":"e0","parentId":null,"timestamp":"2026-07-28T10:00:00.000Z"}
{"type":"user.message","data":{"content":"UNIQUE_MARKER_VSCODE_USER","attachments":[]},"id":"e1","parentId":"e0","timestamp":"2026-07-28T10:00:01.000Z"}
{"type":"assistant.turn_start","data":{"turnId":"0"},"id":"e2","parentId":"e1","timestamp":"2026-07-28T10:00:02.000Z"}
{"type":"tool.execution_start","data":{"toolCallId":"t1","toolName":"read_file","arguments":{}},"id":"e3","parentId":"e2","timestamp":"2026-07-28T10:00:03.000Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"t1","success":true},"id":"e4","parentId":"e3","timestamp":"2026-07-28T10:00:04.000Z"}
{"type":"assistant.message","data":{"messageId":"m1","content":"UNIQUE_MARKER_VSCODE_ASSISTANT","toolRequests":[]},"id":"e5","parentId":"e4","timestamp":"2026-07-28T10:00:05.000Z"}
{"type":"assistant.turn_end","data":{"turnId":"0"},"id":"e6","parentId":"e5","timestamp":"2026-07-28T10:00:06.000Z"}
EOF

# The real payload shape, from the spike's 9 recorded VS Code Stop payloads:
# JSON on stdin, Claude Code's field names, plus `timestamp` and
# `stop_hook_active`.
vscode_stop_payload() {
    printf '{"session_id":"vs1","hook_event_name":"Stop","cwd":"/tmp/ws","timestamp":%s,"stop_hook_active":false,"transcript_path":"%s"}' \
        "1785000000000" "$1"
}

seed_counter() {  # $1 = total_turns_this_session
    printf '{"session_id":"vs1","total_turns_this_session":%s,"memory_turns":0,"skill_iterations":0}\n' \
        "$1" > "$TMP/state/turn_counter.json"
}

# --- 1) The happy path: a VS Code transcript reaches the reviewer's prompt.
seed_counter 9
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$VSCODE_TRANSCRIPT" | bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "a reviewer was invoked" "yes" "$([[ -s "$FAKE_REVIEWER_LOG" ]] && echo yes || echo no)"
# The completion marker itself, asserted rather than merely waited on. Every
# `sl_wait_for_review_complete` call in the suites ends in `|| true`, and
# every `sl_expect_no_review_spawned` is satisfied by a marker that never
# arrives -- so deleting the marker from the shared launcher produces ZERO
# failures across the whole suite (measured: 0 in this file, 0 in
# tests/test-session-review.sh). That is a guard nothing was guarding. This
# is the one assertion that fails if the marker stops being written, which
# matters because the marker is what stops teardown racing a live writer.
check "the detached pipeline wrote its completion marker" "yes" \
    "$([[ -f "${SL_LOG_DIR}/.review-complete" ]] && echo yes || echo no)"
check "recursion guard set for the reviewer" "1" \
    "$(grep -m1 '^GUARD:' "$FAKE_REVIEWER_LOG" | cut -d: -f2)"
check "VS Code user turn reached the prompt" "yes" \
    "$(grep -q 'UNIQUE_MARKER_VSCODE_USER' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
check "VS Code assistant turn reached the prompt" "yes" \
    "$(grep -q 'UNIQUE_MARKER_VSCODE_ASSISTANT' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
check "transcript section framed as untrusted data" "yes" \
    "$(grep -q 'untrusted conversation data' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
check "the shared OUTPUT CONTRACT is in the prompt" "yes" \
    "$(grep -q 'OUTPUT CONTRACT' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
# A correctly parsed transcript must leave persist-failures.log alone. Stop
# fires PER TURN here, so one spurious line is one line per turn -- which is
# how doctor.sh ends up permanently UNHEALTHY on a healthy store.
check "no persist-failures.log line on the happy path" "yes" \
    "$([[ ! -s "${SL_LOG_DIR}/persist-failures.log" ]] && echo yes || echo no)"

# --- 2) Reviewer selection: copilot preferred, claude as fallback.
check "copilot is the auto-detected reviewer when both are present" "copilot" \
    "$(grep -m1 '^WHO:' "$FAKE_REVIEWER_LOG" | cut -d: -f2)"
check "copilot reviewer gets no write tool" "no" \
    "$(grep -m1 '^ARGS:' "$FAKE_REVIEWER_LOG" | grep -q -- '--allow-tool write' && echo yes || echo no)"
check "copilot reviewer runs headless read-only" "yes" \
    "$(grep -m1 '^ARGS:' "$FAKE_REVIEWER_LOG" | grep -q -- '-s --allow-tool read' && echo yes || echo no)"

seed_counter 9
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$VSCODE_TRANSCRIPT" | SL_VSCODE_REVIEWER=claude bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "SL_VSCODE_REVIEWER=claude selects claude" "claude" \
    "$(grep -m1 '^WHO:' "$FAKE_REVIEWER_LOG" | cut -d: -f2)"
check "claude reviewer is denied the file-write tools" "yes" \
    "$(grep -q -- '--disallowedTools Write,Edit,NotebookEdit' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
check "claude reviewer keeps the read tools it needs" "yes" \
    "$(grep -q -- '--allowedTools Read,Glob,Grep' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
check "claude reviewer is bounded by the turn cap" "yes" \
    "$(grep -q -- '--max-turns 16' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"

# A hostile value must never reach argv, and must be reported, not swallowed.
seed_counter 9
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
SELECT_ERR="$(vscode_stop_payload "$VSCODE_TRANSCRIPT" \
    | SL_VSCODE_REVIEWER='claude; rm -rf /' bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh" 2>&1 >/dev/null)"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "reviewer still ran (so the assertion below is not vacuous)" "yes" \
    "$([[ -s "$FAKE_REVIEWER_LOG" ]] && echo yes || echo no)"
check "hostile SL_VSCODE_REVIEWER falls back to auto-detect" "copilot" \
    "$(grep -m1 '^WHO:' "$FAKE_REVIEWER_LOG" | cut -d: -f2)"
check "hostile SL_VSCODE_REVIEWER reported on stderr" "yes" \
    "$(printf '%s' "$SELECT_ERR" | grep -q 'SL_VSCODE_REVIEWER' && echo yes || echo no)"

# --- 3) Recursion guard on entry.
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$VSCODE_TRANSCRIPT" | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
check "no review pipeline was spawned at all" "yes" \
    "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
check "guarded entry spawns nothing" "no" "$([[ -s "$FAKE_REVIEWER_LOG" ]] && echo yes || echo no)"

# --- 4) The turn gate. `Stop` fires PER TURN in VS Code (measured: 3 prompts
# -> 3 Stops), so without this gate every user turn is a paid model call.
seed_counter 2
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$VSCODE_TRANSCRIPT" | bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
check "below the turn gate, nothing is spawned" "yes" \
    "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
check "below the turn gate, no reviewer ran" "no" \
    "$([[ -s "$FAKE_REVIEWER_LOG" ]] && echo yes || echo no)"

# The gate must RE-ARM after a review, or the next per-turn Stop fires again
# immediately and the gate is decorative. session-review.sh can leave the
# total standing because Claude's Stop is per session; this one cannot.
seed_counter 9
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$VSCODE_TRANSCRIPT" | bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "total_turns_this_session is reset after a review" "0" \
    "$(jq -r '.total_turns_this_session' "$TMP/state/turn_counter.json")"
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$VSCODE_TRANSCRIPT" | bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
check "the very next per-turn Stop does NOT spawn another review" "yes" \
    "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
check "the very next per-turn Stop invoked no reviewer" "no" \
    "$([[ -s "$FAKE_REVIEWER_LOG" ]] && echo yes || echo no)"

# --- 5) No digest, no spend. Unlike session-review.sh (Claude's Stop is once
# per session), an unreadable transcript here must NOT spawn a paid review --
# it would recur on every turn. It must still be LOUD.
seed_counter 9
rm -f "${SL_LOG_DIR}/persist-failures.log"
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "/nonexistent/vscode-transcript.jsonl" | bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
check "missing transcript spawns nothing" "yes" \
    "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
check "missing transcript burns no model call" "no" \
    "$([[ -s "$FAKE_REVIEWER_LOG" ]] && echo yes || echo no)"
check "missing transcript is logged loudly, not swallowed" "yes" \
    "$(grep -q 'vscode-session-review: transcript unavailable' "${SL_LOG_DIR}/persist-failures.log" 2>/dev/null && echo yes || echo no)"

# --- 6) Format auto-detection on THIS script too. The registration paths
# overlap (VS Code reads ~/.claude/settings.json by default), so a Claude
# transcript can reach this script. It must be parsed as what it is.
CLAUDE_TRANSCRIPT="$TMP/claude-transcript.jsonl"
cat > "$CLAUDE_TRANSCRIPT" <<'EOF'
{"parentUuid":null,"isSidechain":false,"type":"user","uuid":"u1","timestamp":"2026-07-28T10:00:01.000Z","message":{"role":"user","content":"UNIQUE_MARKER_CLAUDE_ON_VSCODE_PATH"}}
{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"u2","timestamp":"2026-07-28T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"UNIQUE_MARKER_CLAUDE_REPLY"}]}}
EOF
seed_counter 9
rm -f "${SL_LOG_DIR}/persist-failures.log"
: > "$FAKE_REVIEWER_LOG"
sl_clear_review_marker "$SL_LOG_DIR"
vscode_stop_payload "$CLAUDE_TRANSCRIPT" | bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh"
sl_wait_for_review_complete "$SL_LOG_DIR" || true
check "a Claude transcript on this path is parsed, not discarded" "yes" \
    "$(grep -q 'UNIQUE_MARKER_CLAUDE_ON_VSCODE_PATH' "$FAKE_REVIEWER_LOG" && echo yes || echo no)"
check "cross-format parse writes no failure line" "yes" \
    "$([[ ! -s "${SL_LOG_DIR}/persist-failures.log" ]] && echo yes || echo no)"

# --- 7) End to end: the reviewer's proposal is persisted by the WRITER, into
# a resolved store, with no reviewer write tool anywhere in the loop.
TMP7="$(mktemp -d)"; FAKE_BIN7="$(mktemp -d)"
cat > "${FAKE_BIN7}/copilot" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "write" ]]; then
        echo "FAIL_MARKER: write tool was requested" >&2
        exit 3
    fi
done
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "vscode-persisted"}]}\n'
FAKE
chmod +x "${FAKE_BIN7}/copilot"
mkdir -p "${TMP7}/store/state"
echo '{"session_id":"vs7","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}' \
    > "${TMP7}/store/state/turn_counter.json"
cp "$VSCODE_TRANSCRIPT" "${TMP7}/t.jsonl"

sl_clear_review_marker "${TMP7}/store/logs"
vscode_stop_payload "${TMP7}/t.jsonl" \
    | env -i HOME="$TMP7" PATH="${FAKE_BIN7}:${PATH}" \
        AGENT_LEARNING_HOME="${TMP7}/store" SL_CONFIG_FILE="/nonexistent/x.conf" \
        bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh" >/dev/null 2>&1 || true
sl_wait_for_review_complete "${TMP7}/store/logs" || true

for _ in $(seq 1 50); do
    [[ -f "${TMP7}/store/memory/MEMORY.md" ]] && break
    sleep 0.2
done
if [[ -f "${TMP7}/store/memory/MEMORY.md" ]]; then
    check "vscode proposal persisted by the writer" "vscode-persisted" \
        "$(cat "${TMP7}/store/memory/MEMORY.md")"
else
    echo "FAIL: VS Code path did not persist"; FAILURES=$((FAILURES+1))
fi

# --- 8) No reviewer CLI on PATH: must be loud, never a silent exit 0. This
# project's signature defect is a component that exits 0 having done nothing,
# and `if command -v X; then ... fi` with no else branch is that defect in
# shell form.
seed_counter 9
rm -f "${SL_LOG_DIR}/persist-failures.log"
sl_clear_review_marker "$SL_LOG_DIR"
# A PATH carrying every tool this script legitimately needs and NEITHER
# reviewer CLI. Built from the DIRECTORIES of the resolved tools, the same
# technique tests/test-script-paths.sh uses, rather than from symlinks to
# each binary: a symlinked `python3` breaks outright when python3 is a
# pyenv/asdf shim (the shim re-execs and needs its own directory on PATH),
# and this case would then "pass" with an empty log for entirely the wrong
# reason -- a missing interpreter, not a missing reviewer.
NO_REVIEWER_PATH=""
for tool in bash jq python3 date mkdir rm mv cat grep sed cut head dirname \
            basename nohup sleep env; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$tp" ]]; then
        echo "FAIL: test setup is wrong -- '$tool' is not resolvable on this machine"
        FAILURES=$((FAILURES+1))
        continue
    fi
    td="$(dirname "$tp")"
    case ":${NO_REVIEWER_PATH}:" in
        *":${td}:"*) ;;
        *) NO_REVIEWER_PATH="${NO_REVIEWER_PATH:+${NO_REVIEWER_PATH}:}${td}" ;;
    esac
done

# PROBE, not an assumption: on a machine where copilot or claude happens to
# live in one of those same directories this construction cannot express
# "no reviewer available", so skip with the reason printed rather than run an
# assertion whose premise is false. Same discipline as the platform-gated
# skips elsewhere in this suite -- the limitation is verified, not guessed.
if PATH="$NO_REVIEWER_PATH" command -v copilot >/dev/null 2>&1 \
   || PATH="$NO_REVIEWER_PATH" command -v claude >/dev/null 2>&1; then
    echo "SKIP: no-reviewer case -- a reviewer CLI shares a directory with the"
    echo "      base tools on this machine (PATH=${NO_REVIEWER_PATH}), so a"
    echo "      reviewer-free PATH cannot be constructed this way."
else
    vscode_stop_payload "$VSCODE_TRANSCRIPT" \
        | env PATH="$NO_REVIEWER_PATH" SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" \
            SL_LOG_DIR="$TMP/logs" SL_CONFIG_FILE=/nonexistent \
            SL_COACH_SIGNALS_FILE="$SL_COACH_SIGNALS_FILE" \
            bash "${SCRIPT_DIR}/scripts/vscode-session-review.sh" >/dev/null 2>&1 || true
    check "no reviewer on PATH spawns nothing" "yes" \
        "$(sl_expect_no_review_spawned "$SL_LOG_DIR" && echo yes || echo no)"
    check "no reviewer on PATH is reported to persist-failures.log" "yes" \
        "$(grep -q 'vscode-session-review: no reviewer CLI on PATH' "${SL_LOG_DIR}/persist-failures.log" 2>/dev/null && echo yes || echo no)"
fi

# --- 9) Registration template shape (the detail asserted exhaustively in
# tests/test-vscode-hooks-json.sh; pinned here so this suite fails too if the
# script and its registration stop naming each other).
check "hook template registers this script" "yes" \
    "$(jq -r '.hooks.Stop[].hooks[].command' "${SCRIPT_DIR}/config/vscode-hooks.json" \
        | grep -q 'vscode-session-review\.sh' && echo yes || echo no)"

# --- 10) The prompt must state the schema the writer actually enforces (I8).
check "prompt states the real schema regex" "yes" \
    "$(grep -qF '[A-Za-z0-9][A-Za-z0-9_-]{0,63}' "$REVIEW" && echo yes || echo no)"
check "prompt does not state the dot-inclusive contradiction" "no" \
    "$(grep -qE '\[a-z0-9\]\[a-z0-9\._-\]' "$REVIEW" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All vscode-session-review tests passed."
