#!/usr/bin/env bash
# tests/test-copilot-absent.sh
# The mirror image of tests/test-claude-absent.sh, and the reason it exists:
# "peers" only holds if the guard runs BOTH ways. That file proves the Copilot
# review path needs no `claude`; this one proves the Claude Code path (and, by
# the shared code it runs, the VS Code path's persistence half) needs no
# `copilot` binary and no ~/.copilot directory.
#
# NOT re-covered here: reviewer SELECTION on the VS Code path when copilot is
# absent -- tests/test-vscode-session-review.sh:110-129 already drives that
# with fake CLIs (SL_VSCODE_REVIEWER auto-detect falling back to claude).
# Duplicating it would drift.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/wait-for-review.sh
source "${SCRIPT_DIR}/tests/lib/wait-for-review.sh"

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
trap 'sl_rm_rf_retry "$TMP_HOME"; sl_rm_rf_retry "$FAKE_BIN"' EXIT

STORE="${TMP_HOME}/store"
mkdir -p "${STORE}/state" "${STORE}/logs"

# A PATH containing claude and the system basics, but deliberately no `copilot`.
cat > "${FAKE_BIN}/claude" <<'FAKE'
#!/usr/bin/env bash
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "no-copilot-needed"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/claude"

# python3 and jq must actually resolve on this machine via the minimal PATH;
# don't assume /usr/bin has them (e.g. pyenv-shimmed setups). Never add a
# directory that also contains `copilot`.
_sys_path_dirs="/usr/bin:/bin"
for _tool in python3 jq; do
    if ! PATH="${FAKE_BIN}:${_sys_path_dirs}" command -v "$_tool" >/dev/null 2>&1; then
        _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
        if [[ -n "$_tool_path" ]]; then
            _tool_dir="$(dirname "$_tool_path")"
            if PATH="$_tool_dir" command -v copilot >/dev/null 2>&1; then
                echo "FAIL: test setup is wrong — $_tool_dir also exposes copilot"; FAILURES=$((FAILURES+1))
            else
                _sys_path_dirs="${_tool_dir}:${_sys_path_dirs}"
            fi
        fi
    fi
done
MINIMAL_PATH="${FAKE_BIN}:${_sys_path_dirs}"

for _tool in python3 jq; do
    if ! PATH="$MINIMAL_PATH" command -v "$_tool" >/dev/null 2>&1; then
        echo "FAIL: test setup is wrong — $_tool is not resolvable on MINIMAL_PATH"; FAILURES=$((FAILURES+1))
    fi
done

if PATH="$MINIMAL_PATH" command -v copilot >/dev/null 2>&1; then
    echo "FAIL: test setup is wrong — copilot is reachable"; FAILURES=$((FAILURES+1))
else
    echo "PASS: copilot is absent from PATH"
fi

# A real Claude Code transcript shape (type/message.role), so the review runs
# with genuine session content rather than an empty digest.
TRANSCRIPT="${TMP_HOME}/transcript.jsonl"
{
    printf '{"type":"user","message":{"role":"user","content":"how do I run the suite"},"timestamp":"2026-01-01T00:00:00Z"}\n'
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"index this transcript"}]},"timestamp":"2026-01-01T00:00:01Z"}\n'
} > "$TRANSCRIPT"

# Above the min-turns gate, or session-review.sh exits silently and this suite
# would pass vacuously.
printf '{"session_id":"s-nocopilot","total_turns_this_session":9,"memory_turns":0,"skill_iterations":0}\n' \
    > "${STORE}/state/turn_counter.json"

# --- 1) End-of-session review on the Claude path, copilot absent ---
#
# Byte counts before/after, not "does the file exist": CLAUDE.md's hard rule --
# an empty command output is not evidence of absence, and a pre-existing file
# is not evidence of a write.
MEM_BEFORE=0
[[ -f "${STORE}/memory/MEMORY.md" ]] && MEM_BEFORE=$(wc -c < "${STORE}/memory/MEMORY.md")

sl_clear_review_marker "${STORE}/logs"
printf '{"session_id":"s-nocopilot","hook_event_name":"Stop","transcript_path":"%s"}\n' "$TRANSCRIPT" \
    | env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
        AGENT_LEARNING_HOME="$STORE" \
        SL_CONFIG_FILE="/nonexistent/x.conf" \
        bash "${SCRIPT_DIR}/scripts/session-review.sh" >/dev/null 2>&1 || true

sl_wait_for_review_complete "${STORE}/logs" || true
sl_assert_review_marker_or_abort "${STORE}/logs"

MEM_AFTER=0
[[ -f "${STORE}/memory/MEMORY.md" ]] && MEM_AFTER=$(wc -c < "${STORE}/memory/MEMORY.md")
check "review persisted with copilot absent (memory grew)" "yes" \
    "$([[ "$MEM_AFTER" -gt "$MEM_BEFORE" ]] && echo yes || echo no)"
if [[ -f "${STORE}/memory/MEMORY.md" ]]; then
    check "persisted content came from the reviewer" "yes" \
        "$(grep -q 'no-copilot-needed' "${STORE}/memory/MEMORY.md" && echo yes || echo no)"
fi

# --- 2) Session start: context injection + skill mirroring ---
START_OUT="$(printf '{"session_id":"s-nocopilot","hook_event_name":"SessionStart"}\n' \
    | env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
        AGENT_LEARNING_HOME="$STORE" \
        SL_CONFIG_FILE="/nonexistent/x.conf" \
        bash "${SCRIPT_DIR}/scripts/session-start-context.sh" 2>/dev/null || true)"
check "session-start-context emitted exactly one JSON object" "yes" \
    "$(printf '%s' "$START_OUT" | PATH="$MINIMAL_PATH" python3 -c 'import json,sys; json.loads(sys.stdin.read()); print("yes")' 2>/dev/null || echo no)"

# The mirror runs detached; give it a bounded window to do whatever it is
# going to do BEFORE asserting it never created ~/.copilot.
for _i in $(seq 1 10); do
    [[ -e "${TMP_HOME}/.copilot" ]] && break
    sleep 0.2
done

# --- 3) Session indexing (Claude adapter; must not need copilot either) ---
#
# index-session.sh resolves its schema next to itself, i.e. in the INSTALLED
# layout, so it is staged the same way tests/test-index-session-first-run.sh
# stages it (running it straight from the checkout finds no schema file and
# exits 0 -- a vacuous pass).
IDX_SCRIPTS="${TMP_HOME}/idx-scripts"
mkdir -p "${IDX_SCRIPTS}/lib"
cp "${SCRIPT_DIR}/scripts/index-session.sh" "${SCRIPT_DIR}/scripts/index-session.py" "$IDX_SCRIPTS/"
cp "${SCRIPT_DIR}/scripts/lib/config.sh" "${SCRIPT_DIR}/scripts/lib/paths.py" \
   "${SCRIPT_DIR}/scripts/lib/python-resolve.sh" \
   "${SCRIPT_DIR}/scripts/lib/isotime.py" "${SCRIPT_DIR}/scripts/lib/list-transcripts.py" \
   "${SCRIPT_DIR}/scripts/lib/session_db.py" "${IDX_SCRIPTS}/lib/"
cp "${SCRIPT_DIR}/schema/session-search-schema.sql" \
   "${SCRIPT_DIR}/schema/session-search-fts5.sql" "$IDX_SCRIPTS/"

# A transcript where the Claude adapter looks for one.
mkdir -p "${TMP_HOME}/.claude/projects/proj"
cp "$TRANSCRIPT" "${TMP_HOME}/.claude/projects/proj/s-nocopilot.jsonl"

env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
    AGENT_LEARNING_HOME="$STORE" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${IDX_SCRIPTS}/index-session.sh" </dev/null >/dev/null 2>&1 || true
check "index-session.sh created the search db without copilot" "yes" \
    "$([[ -f "${STORE}/sessions/search.db" ]] && echo yes || echo no)"
check "the session was indexed without copilot" "yes" \
    "$(PATH="$MINIMAL_PATH" python3 "${IDX_SCRIPTS}/lib/session_db.py" search "${STORE}/sessions/search.db" transcript 2>/dev/null | grep -q 's-nocopilot' && echo yes || echo no)"

# --- 4) Nothing may have been created under ~/.copilot ---
if [[ -e "${TMP_HOME}/.copilot" ]]; then
    echo "FAIL: the Claude path created ${TMP_HOME}/.copilot"; FAILURES=$((FAILURES+1))
else
    echo "PASS: no ~/.copilot created"
fi

# --- 5) No failure line may name copilot as a hard requirement ---
FAIL_LOG="${STORE}/logs/persist-failures.log"
if [[ -f "$FAIL_LOG" ]]; then
    _copilot_failures="$(grep -ci 'copilot' "$FAIL_LOG" || true)"
    check "no persist-failures line blames a missing copilot" "0" "$_copilot_failures"
    if [[ "$_copilot_failures" != "0" ]]; then
        echo "--- persist-failures.log ---"; cat "$FAIL_LOG"
    fi
else
    echo "PASS: no persist-failures.log written at all"
fi

# The shipped Claude hook config template must never hardcode ~/.copilot --
# same shape as test-claude-absent.sh's assertion about copilot-hooks.json.
_hook_template_copilot_count="$(grep -c '\.copilot' "${SCRIPT_DIR}/config/settings-hooks.json" || true)"
check "shipped settings-hooks.json template contains no ~/.copilot" "0" "$_hook_template_copilot_count"

[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All copilot-absent tests passed."
