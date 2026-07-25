#!/usr/bin/env bash
# tests/test-claude-absent.sh
# The Copilot path must work on a machine with no `claude` binary and no
# ~/.claude directory. This is the regression guard for harness independence:
# Copilot's own review loop must never depend on Claude Code being present.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/wait-for-review.sh
source "${SCRIPT_DIR}/tests/lib/wait-for-review.sh"

TMP_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
# Item 3 (deferred minor): the prior single `rm -rf` at the bottom of this
# file only ran on the success path -- an early `exit 1` (e.g. from `set -e`
# tripping on an unexpected command failure) leaked both temp dirs. A trap
# runs on every exit path, not just the fall-through one.
#
# fix-p6: sl_rm_rf_retry, not a bare `rm -rf` -- defense in depth alongside
# waiting for the detached pipeline below (tests/lib/wait-for-review.sh).
trap 'sl_rm_rf_retry "$TMP_HOME"; sl_rm_rf_retry "$FAKE_BIN"' EXIT

# A PATH containing copilot and the system basics, but deliberately no `claude`.
cat > "${FAKE_BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
printf '{"version": 1, "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "no-claude-needed"}]}\n'
FAKE
chmod +x "${FAKE_BIN}/copilot"

# python3 and jq must actually resolve on this machine via the minimal PATH;
# don't assume /usr/bin has them (e.g. pyenv-shimmed setups). Extend with
# whatever directories are needed, but never add a directory that also
# contains `claude`.
_sys_path_dirs="/usr/bin:/bin"
for _tool in python3 jq; do
    if ! PATH="${FAKE_BIN}:${_sys_path_dirs}" command -v "$_tool" >/dev/null 2>&1; then
        _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
        if [[ -n "$_tool_path" ]]; then
            _tool_dir="$(dirname "$_tool_path")"
            if PATH="$_tool_dir" command -v claude >/dev/null 2>&1; then
                echo "FAIL: test setup is wrong — $_tool_dir also exposes claude"; FAILURES=$((FAILURES+1))
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

if PATH="$MINIMAL_PATH" command -v claude >/dev/null 2>&1; then
    echo "FAIL: test setup is wrong — claude is reachable"; FAILURES=$((FAILURES+1))
else
    echo "PASS: claude is absent from PATH"
fi

# fix-p6: wait for the detached pipeline's own completion marker (see
# tests/lib/wait-for-review.sh), not only for the target file to appear --
# the marker signals every write this run makes is done, output file
# included, closing the same class of race that broke
# tests/test-e2e-skill-visibility.sh on macOS CI.
sl_clear_review_marker "${TMP_HOME}/store/logs"
env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
    AGENT_LEARNING_HOME="${TMP_HOME}/store" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash "${SCRIPT_DIR}/scripts/copilot-session-review.sh" </dev/null >/dev/null 2>&1 || true

# The review pipeline is spawned detached (nohup ... & + disown) by design —
# the sessionEnd hook must not block on it — so the file may not exist the
# instant the script returns. Poll with a bounded timeout instead of a bare
# sleep; the same idiom used in test-session-review.sh and
# test-copilot-session-review.sh.
sl_wait_for_review_complete "${TMP_HOME}/store/logs" || true

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

# The shipped Copilot hook config template must never hardcode ~/.claude — it
# is rendered at install time with the resolved, vendor-neutral scripts path.
# This closes the vacuity documented above: this file previously only
# exercised the script directly and never inspected what install.sh ships.
_hook_template_claude_count="$(grep -c '\.claude' "${SCRIPT_DIR}/config/copilot-hooks.json" || true)"
check "shipped copilot-hooks.json template contains no ~/.claude" "0" "$_hook_template_claude_count"

[[ "$FAILURES" -gt 0 ]] && exit 1
echo "All claude-absent tests passed."
