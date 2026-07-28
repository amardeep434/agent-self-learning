#!/usr/bin/env bash
# tests/test-vscode-hooks-json.sh
#
# Static guard on config/vscode-hooks.json, the VS Code Copilot Chat
# hook-registration template. Modelled on tests/test-claude-hooks-json.sh,
# because VS Code parses Claude Code's hook format -- the same nested
# event -> matcher-group -> hooks[] schema, the same `command`, the same
# `timeout` in SECONDS. It is NOT Copilot CLI's shape (`bash`/`powershell`/
# `timeoutSec`), and a file in the wrong one of those two shapes parses as
# JSON and registers nothing, which is the worst possible failure here.
#
# Two things asserted that the Claude counterpart does not, both consequences
# of measurements in docs/superpowers/vscode-adapter-spike.md:
#
#   - a PostToolUse turn-counter hook must be present. VS Code's `Stop` fires
#     PER TURN (3 prompts -> 3 Stops), so the turn gate is the only thing
#     between this adapter and one paid model call per user turn, and
#     turn-counter.sh is what advances the counter it reads.
#   - index-session.sh must NOT be present. It indexes Claude Code's own
#     ~/.claude/projects transcript directory, which has nothing to do with a
#     VS Code session; registering it here would run a Claude-specific
#     indexer on every VS Code turn.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

HOOK="${SCRIPT_DIR}/config/vscode-hooks.json"

check "template exists" "yes" "$([[ -f "$HOOK" ]] && echo yes || echo no)"
check "template parses as JSON" "yes" "$(jq -e . "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"

# --- The nested schema (Claude Code's, which VS Code parses). The flat
# {matcher, command, timeout} shape parses as JSON and is silently ignored.
check "PostToolUse uses the nested hooks[] schema" "yes" \
    "$(jq -e '.hooks.PostToolUse[0].hooks[0].type == "command"' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "Stop uses the nested hooks[] schema" "yes" \
    "$(jq -e '.hooks.Stop[0].hooks[0].type == "command"' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "no command sits directly on a matcher group (the flat schema)" "0" \
    "$(jq '[.hooks[][] | select(has("command"))] | length' "$HOOK")"

# --- NOT Copilot CLI's shape. These keys belong to ~/.copilot/hooks/, and a
# template carrying them here would register nothing in VS Code while looking
# plausible to a reader who knows the other adapter.
check "no Copilot-CLI 'bash' key" "0" "$(grep -c '"bash"' "$HOOK" || true)"
check "no Copilot-CLI 'powershell' key" "0" "$(grep -c '"powershell"' "$HOOK" || true)"
check "no Copilot-CLI 'timeoutSec' key" "0" "$(grep -c 'timeoutSec' "$HOOK" || true)"

ENTRY_COUNT="$(jq '[.hooks[][].hooks[]] | length' "$HOOK")"
check "two hook entries (turn-counter, vscode-session-review)" "2" "$ENTRY_COUNT"
check "every entry has type=command" "$ENTRY_COUNT" \
    "$(jq '[.hooks[][].hooks[] | select(.type == "command")] | length' "$HOOK")"

# --- The timeout unit: SECONDS, like Claude Code, not milliseconds.
check "every timeout is a plausible number of SECONDS (1..600)" "$ENTRY_COUNT" \
    "$(jq '[.hooks[][].hooks[] | select(.timeout >= 1 and .timeout <= 600)] | length' "$HOOK")"

# --- The script path must be the vendor-neutral store, resolved at install
# time -- never a hardcoded ~/.claude path (defect A1's ruling).
check "no hardcoded ~/.claude script path" "0" \
    "$(jq -r '.hooks[][].hooks[].command' "$HOOK" | grep -c '\.claude' || true)"
check "every command carries the scripts-dir placeholder" "$ENTRY_COUNT" \
    "$(jq -r '.hooks[][].hooks[].command' "$HOOK" | grep -c '__SL_SCRIPTS_DIR__' || true)"

# --- The per-turn Stop consequence: the turn gate must actually be wired.
check "PostToolUse registers turn-counter.sh (the per-turn Stop gate)" "yes" \
    "$(jq -r '.hooks.PostToolUse[].hooks[].command' "$HOOK" | grep -q 'turn-counter\.sh' && echo yes || echo no)"
check "Stop registers vscode-session-review.sh" "yes" \
    "$(jq -r '.hooks.Stop[].hooks[].command' "$HOOK" | grep -q 'vscode-session-review\.sh' && echo yes || echo no)"

# --- index-session.sh reads ~/.claude/projects; it is Claude-Code-specific
# and must not be registered for VS Code.
check "no Claude-specific index-session.sh hook" "0" \
    "$(grep -c 'index-session' "$HOOK" || true)"

# --- Every script named must exist in this repo, so a typo or a rename
# cannot leave the template naming a file nobody ships.
while IFS= read -r cmd; do
    # Strip a trailing CR from jq's output -- same strip, same measured
    # reason, as tests/test-claude-hooks-json.sh (windows-latest turns jq
    # string values into CRLF-terminated ones on the checks that build a
    # path from them).
    cmd="${cmd%$'\r'}"
    script_path="${cmd#bash __SL_SCRIPTS_DIR__/}"
    if [[ -f "${SCRIPT_DIR}/scripts/${script_path}" ]]; then
        echo "PASS: template names a real script: ${script_path}"
    else
        echo "FAIL: template names a real script: ${script_path}"
        FAILURES=$((FAILURES+1))
        echo "  [diag] probed: ${SCRIPT_DIR}/scripts/${script_path}" >&2
        printf '  [diag] script_path bytes: ' >&2
        printf '%s' "$script_path" | od -c | head -2 >&2
    fi
done < <(jq -r '.hooks[][].hooks[].command' "$HOOK")

# --- install.sh must actually render and place this template. A template no
# installer touches is a file that documents an intention, not a feature --
# and this project has shipped exactly that before (the hand-rolled hook
# block that drifted from the template it was meant to mirror, defect A1).
INSTALL="${SCRIPT_DIR}/install.sh"
check "install.sh reads config/vscode-hooks.json" "yes" \
    "$(grep -q 'config/vscode-hooks.json' "$INSTALL" && echo yes || echo no)"
# Asserts that the template is RENDERED, not how. This used to grep for the
# literal sed expression `__SL_SCRIPTS_DIR__|${SL_SCRIPTS}`, which pinned the
# very implementation that turned out to corrupt any store path containing
# `&`, `\` or `|`. tests/test-hook-template-render.sh owns the behaviour.
check "install.sh renders this template through the shared renderer" "yes" \
    "$(grep -q 'render_hook_template "$VSCODE_HOOK_SRC"' "$INSTALL" && echo yes || echo no)"
check "install.sh writes the rendered file into the store" "yes" \
    "$(grep -q 'VSCODE_HOOK_DST' "$INSTALL" && echo yes || echo no)"
check "install.sh tells the user which VS Code setting registers it" "yes" \
    "$(grep -q 'chat.hookFilesLocations' "$INSTALL" && echo yes || echo no)"
# THE TRAP, surfaced to the user rather than left as a surprise: VS Code
# reads ~/.claude/settings.json by default, so completing the Claude Code
# step also registers hooks in VS Code.
check "install.sh warns about the shared ~/.claude/settings.json hook source" "yes" \
    "$(grep -q 'VS Code ALSO reads ~/.claude/settings.json' "$INSTALL" && echo yes || echo no)"
# uninstall must not strand the rendered file, same rule the Claude template
# already follows.
check "uninstall.sh removes the rendered vscode-hooks.json" "yes" \
    "$(grep -q 'vscode-hooks.json' "${SCRIPT_DIR}/uninstall.sh" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All vscode-hooks-json tests passed."
