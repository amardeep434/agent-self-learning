#!/usr/bin/env bash
# tests/test-vscode-hooks-json.sh
#
# Static guard on config/vscode-hooks.json, the VS Code Copilot Chat
# hook-registration template. VS Code's documented schema for hook FILES
# (`.github/hooks/*.json` and every `chat.hookFilesLocations` entry) is the
# FLAT shape: event -> [ {type, command, timeout} ] -- no matcher wrapper,
# no nested hooks[] array. The nested Claude Code schema is parsed ONLY from
# the `.claude/settings.json` locations.
#
# MEASURED 2026-08-04 on a real Windows machine: this template shipped in the
# nested schema, and VS Code silently ignored it from both a custom
# hookFilesLocations entry and the default workspace `.github/hooks/`
# location -- zero errors in the extension's debug log, zero hook fires,
# while the identical command hand-piped into bash worked. The adapter
# spike's "VS Code parses Claude's nested schema" observation was made via
# the ~/.claude/settings.json route, which is a different parser path.
# A file in the wrong shape parses as JSON and registers NOTHING, which is
# the worst possible failure here -- hence this suite pins the flat shape.
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

# shellcheck source=tests/lib/hook-command.sh
source "${SCRIPT_DIR}/tests/lib/hook-command.sh"

HOOK="${SCRIPT_DIR}/config/vscode-hooks.json"

check "template exists" "yes" "$([[ -f "$HOOK" ]] && echo yes || echo no)"
check "template parses as JSON" "yes" "$(jq -e . "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"

# --- The FLAT schema (VS Code's documented shape for hook files). The nested
# Claude matcher/hooks[] shape parses as JSON and is silently ignored at
# these locations -- measured, see header.
check "PostToolUse entries sit directly under the event (flat schema)" "yes" \
    "$(jq -e '.hooks.PostToolUse[0].type == "command"' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "Stop entries sit directly under the event (flat schema)" "yes" \
    "$(jq -e '.hooks.Stop[0].type == "command"' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "no nested matcher/hooks[] wrapper anywhere (the Claude schema)" "0" \
    "$(jq '[.hooks[][] | select(has("matcher") or has("hooks"))] | length' "$HOOK")"

# --- NOT Copilot CLI's shape. These keys belong to ~/.copilot/hooks/, and a
# template carrying them here would register nothing in VS Code while looking
# plausible to a reader who knows the other adapter.
check "no Copilot-CLI 'bash' key" "0" "$(grep -c '"bash"' "$HOOK" || true)"
check "no Copilot-CLI 'powershell' key" "0" "$(grep -c '"powershell"' "$HOOK" || true)"
check "no Copilot-CLI 'timeoutSec' key" "0" "$(grep -c 'timeoutSec' "$HOOK" || true)"

ENTRY_COUNT="$(jq '[.hooks[][]] | length' "$HOOK")"
# Not a hardcoded count -- see the same change in test-claude-hooks-json.sh.
# This said "2" until the SessionStart hook made it 3.
check "at least one hook entry exists" "yes" \
    "$([[ "$ENTRY_COUNT" -ge 1 ]] && echo yes || echo no)"
check "SessionStart is registered (the learned-context read-back)" "yes" \
    "$(jq -e '.hooks.SessionStart[0].command | test("session-start-context")' "$HOOK" >/dev/null 2>&1 && echo yes || echo no)"
check "every entry has type=command" "$ENTRY_COUNT" \
    "$(jq '[.hooks[][] | select(.type == "command")] | length' "$HOOK")"

# --- The timeout unit: SECONDS, not milliseconds.
check "every timeout is a plausible number of SECONDS (1..600)" "$ENTRY_COUNT" \
    "$(jq '[.hooks[][] | select(.timeout >= 1 and .timeout <= 600)] | length' "$HOOK")"

# --- The script path must be the vendor-neutral store, resolved at install
# time -- never a hardcoded ~/.claude path (defect A1's ruling).
check "no hardcoded ~/.claude script path" "0" \
    "$(jq -r '.hooks[][].command' "$HOOK" | grep -c '\.claude' || true)"
check "every command carries the scripts-dir placeholder" "$ENTRY_COUNT" \
    "$(jq -r '.hooks[][].command' "$HOOK" | grep -c '__SL_SCRIPTS_DIR__' || true)"

# --- The per-turn Stop consequence: the turn gate must actually be wired.
check "PostToolUse registers turn-counter.sh (the per-turn Stop gate)" "yes" \
    "$(jq -r '.hooks.PostToolUse[].command' "$HOOK" | grep -q 'turn-counter\.sh' && echo yes || echo no)"
check "Stop registers vscode-session-review.sh" "yes" \
    "$(jq -r '.hooks.Stop[].command' "$HOOK" | grep -q 'vscode-session-review\.sh' && echo yes || echo no)"

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
    # Tokenize, then drop the placeholder directory: the command now
    # shell-quotes its path, so the old literal prefix strip
    # (`${cmd#bash __SL_SCRIPTS_DIR__/}`) no longer matched at all and
    # left the whole command in $script_path.
    script_path="$(sl_hook_script_path "$cmd")"
    script_path="${script_path#__SL_SCRIPTS_DIR__/}"
    if [[ -f "${SCRIPT_DIR}/scripts/${script_path}" ]]; then
        echo "PASS: template names a real script: ${script_path}"
    else
        echo "FAIL: template names a real script: ${script_path}"
        FAILURES=$((FAILURES+1))
        echo "  [diag] probed: ${SCRIPT_DIR}/scripts/${script_path}" >&2
        printf '  [diag] script_path bytes: ' >&2
        printf '%s' "$script_path" | od -c | head -2 >&2
    fi
done < <(jq -r '.hooks[][].command' "$HOOK")

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
