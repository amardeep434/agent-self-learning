#!/usr/bin/env bash
# tests/test-uninstall.sh — sandboxed via HOME override.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Simulate an installed state
mkdir -p "$HOME/.claude/scripts/self-learning/lib" "$HOME/.claude/state/self-learning" \
         "$HOME/.claude/logs/reviews" "$HOME/.claude/memory" "$HOME/.claude/learned-skills/s1" \
         "$HOME/.claude/sessions" "$HOME/.copilot/hooks"
touch "$HOME/.claude/scripts/self-learning/turn-counter.sh" \
      "$HOME/.claude/self-learning.conf" \
      "$HOME/.copilot/hooks/self-learning.json" \
      "$HOME/.claude/memory/MEMORY.md" \
      "$HOME/.claude/learned-skills/s1/SKILL.md" \
      "$HOME/.claude/sessions/search.db"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"model":"opus","hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/scripts/self-learning/turn-counter.sh","timeout":3}]},{"matcher":"","hooks":[{"type":"command","command":"echo user-own-hook","timeout":3}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/scripts/self-learning/session-review.sh","timeout":15}]}]}}
EOF

# 1) --keep-data removes install but preserves learned data
bash "${SCRIPT_DIR}/uninstall.sh" --keep-data --yes
check "scripts removed" "no" "$([[ -d "$HOME/.claude/scripts/self-learning" ]] && echo yes || echo no)"
check "conf removed" "no" "$([[ -f "$HOME/.claude/self-learning.conf" ]] && echo yes || echo no)"
check "copilot hook removed" "no" "$([[ -f "$HOME/.copilot/hooks/self-learning.json" ]] && echo yes || echo no)"
check "state removed" "no" "$([[ -d "$HOME/.claude/state/self-learning" ]] && echo yes || echo no)"
check "memory preserved with --keep-data" "yes" "$([[ -f "$HOME/.claude/memory/MEMORY.md" ]] && echo yes || echo no)"
check "skills preserved with --keep-data" "yes" "$([[ -d "$HOME/.claude/learned-skills" ]] && echo yes || echo no)"
check "settings self-learning hooks stripped" "0" "$(grep -c self-learning "$HOME/.claude/settings.json" || true)"
check "unrelated user hook survives" "1" "$(grep -c user-own-hook "$HOME/.claude/settings.json")"
check "settings still valid json" "yes" "$(jq . "$HOME/.claude/settings.json" >/dev/null && echo yes)"
check "settings backup exists" "yes" "$(ls "$HOME/.claude/"settings.json.pre-uninstall-* >/dev/null 2>&1 && echo yes || echo no)"

# 2) Full uninstall also removes data
mkdir -p "$HOME/.claude/scripts/self-learning"
bash "${SCRIPT_DIR}/uninstall.sh" --yes
check "memory removed on full uninstall" "no" "$([[ -f "$HOME/.claude/memory/MEMORY.md" ]] && echo yes || echo no)"
check "skills removed on full uninstall" "no" "$([[ -d "$HOME/.claude/learned-skills" ]] && echo yes || echo no)"
check "search db removed on full uninstall" "no" "$([[ -f "$HOME/.claude/sessions/search.db" ]] && echo yes || echo no)"

# 3) Both legacy (~/.claude) and resolved (vendor-neutral store) locations are
# cleaned in a single run — a user may have installed before and after the
# harness-neutral-persistence change (design decision 5).
export AGENT_LEARNING_HOME="${HOME}/store"
mkdir -p "${HOME}/.claude/scripts/self-learning" "${HOME}/.claude/state/self-learning" \
         "${HOME}/.claude/logs/reviews" "${HOME}/.claude/logs/curator" \
         "${HOME}/.claude/memory" "${HOME}/.claude/learned-skills/s1" "${HOME}/.claude/sessions" \
         "${AGENT_LEARNING_HOME}/scripts" "${AGENT_LEARNING_HOME}/state" \
         "${AGENT_LEARNING_HOME}/logs/reviews" "${AGENT_LEARNING_HOME}/logs/curator" \
         "${AGENT_LEARNING_HOME}/memory" "${AGENT_LEARNING_HOME}/learned-skills/s1" \
         "${AGENT_LEARNING_HOME}/sessions" "${HOME}/.copilot/hooks"
touch "${HOME}/.claude/scripts/self-learning/turn-counter.sh" \
      "${HOME}/.claude/self-learning.conf" \
      "${HOME}/.copilot/hooks/self-learning.json" \
      "${HOME}/.claude/memory/MEMORY.md" \
      "${HOME}/.claude/learned-skills/s1/SKILL.md" \
      "${HOME}/.claude/sessions/search.db" \
      "${AGENT_LEARNING_HOME}/scripts/turn-counter.sh" \
      "${AGENT_LEARNING_HOME}/self-learning.conf" \
      "${AGENT_LEARNING_HOME}/memory/MEMORY.md" \
      "${AGENT_LEARNING_HOME}/learned-skills/s1/SKILL.md" \
      "${AGENT_LEARNING_HOME}/sessions/search.db"

bash "${SCRIPT_DIR}/uninstall.sh" --yes
check "legacy scripts removed" "no" "$([[ -d "$HOME/.claude/scripts/self-learning" ]] && echo yes || echo no)"
check "legacy memory removed" "no" "$([[ -f "$HOME/.claude/memory/MEMORY.md" ]] && echo yes || echo no)"
check "resolved scripts removed" "no" "$([[ -d "${AGENT_LEARNING_HOME}/scripts" ]] && echo yes || echo no)"
check "resolved state removed" "no" "$([[ -d "${AGENT_LEARNING_HOME}/state" ]] && echo yes || echo no)"
check "resolved memory removed" "no" "$([[ -f "${AGENT_LEARNING_HOME}/memory/MEMORY.md" ]] && echo yes || echo no)"
check "resolved skills removed" "no" "$([[ -d "${AGENT_LEARNING_HOME}/learned-skills" ]] && echo yes || echo no)"
check "resolved search db removed" "no" "$([[ -f "${AGENT_LEARNING_HOME}/sessions/search.db" ]] && echo yes || echo no)"
unset AGENT_LEARNING_HOME

# 4) A1 follow-on: hooks registered with the CURRENT, correct commands must be
# stripped too. Every case above feeds the pre-Task-7b shape
# (~/.claude/scripts/self-learning/...), whose path happens to contain the
# literal string "self-learning" that uninstall.sh used to match on. A hook
# registered the way install.sh now tells users to register it reads
# `bash <store>/scripts/turn-counter.sh` and contains no such substring, so the
# stripper skipped it in silence and reported success. The rendered
# settings-hooks.json is checked here for the same reason: it names paths that
# no longer exist after an uninstall.
export AGENT_LEARNING_HOME="${HOME}/store2"
mkdir -p "${AGENT_LEARNING_HOME}/scripts" "${HOME}/.claude"
SL_SCRIPTS_NOW="${AGENT_LEARNING_HOME}/scripts"
touch "${SL_SCRIPTS_NOW}/turn-counter.sh"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"bash '"${SL_SCRIPTS_NOW}"'/turn-counter.sh","timeout":3}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash '"${SL_SCRIPTS_NOW}"'/session-review.sh","timeout":15},{"type":"command","command":"bash '"${SL_SCRIPTS_NOW}"'/index-session.sh","timeout":10}]},{"matcher":"","hooks":[{"type":"command","command":"echo user-own-hook","timeout":3}]}]}}' \
    > "${HOME}/.claude/settings.json"
printf '%s\n' '{"hooks":{}}' > "${AGENT_LEARNING_HOME}/settings-hooks.json"

bash "${SCRIPT_DIR}/uninstall.sh" --yes

check "store-path turn-counter hook stripped" "0" \
    "$(grep -c 'turn-counter' "${HOME}/.claude/settings.json" || true)"
check "store-path session-review hook stripped" "0" \
    "$(grep -c 'session-review' "${HOME}/.claude/settings.json" || true)"
check "store-path index-session hook stripped" "0" \
    "$(grep -c 'index-session' "${HOME}/.claude/settings.json" || true)"
check "unrelated user hook still survives" "1" \
    "$(grep -c user-own-hook "${HOME}/.claude/settings.json")"
check "settings still valid json after store-path strip" "yes" \
    "$(jq . "${HOME}/.claude/settings.json" >/dev/null && echo yes)"
check "rendered settings-hooks.json removed" "no" \
    "$([[ -f "${AGENT_LEARNING_HOME}/settings-hooks.json" ]] && echo yes || echo no)"
unset AGENT_LEARNING_HOME

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All uninstall tests passed."
