#!/usr/bin/env bash
# tests/test-inject-agents-md.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_MEMORY_DIR="$TMP/memory" SL_SKILLS_DIR="$TMP/skills"
mkdir -p "$SL_MEMORY_DIR" "$SL_SKILLS_DIR/my-skill"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

echo "- User prefers pytest over unittest" > "$SL_MEMORY_DIR/MEMORY.md"
printf -- '---\nname: my-skill\ndescription: Does a useful thing.\n---\nBody\n' > "$SL_SKILLS_DIR/my-skill/SKILL.md"

TARGET="$TMP/AGENTS.md"
printf '# My Project\n\nHand-written intro.\n' > "$TARGET"

# 1) First run appends a managed block, preserves existing content
python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "$TARGET"
check "existing content preserved" "yes" "$(grep -q 'Hand-written intro.' "$TARGET" && echo yes || echo no)"
check "memory line injected" "yes" "$(grep -q 'prefers pytest' "$TARGET" && echo yes || echo no)"
check "skill listed" "yes" "$(grep -q 'my-skill' "$TARGET" && echo yes || echo no)"
check "begin marker present" "1" "$(grep -c 'BEGIN self-learning:managed' "$TARGET")"

# 2) Second run is idempotent (exactly one block, no duplication)
python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "$TARGET"
check "idempotent single block" "1" "$(grep -c 'BEGIN self-learning:managed' "$TARGET")"

# 3) Updated memory replaces block content
echo "- New fact only" > "$SL_MEMORY_DIR/MEMORY.md"
python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "$TARGET"
check "stale memory removed" "no" "$(grep -q 'prefers pytest' "$TARGET" && echo yes || echo no)"
check "new memory present" "yes" "$(grep -q 'New fact only' "$TARGET" && echo yes || echo no)"

# 4) Missing target file is created
python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "$TMP/fresh/AGENTS.md"
check "creates missing target" "yes" "$([[ -f "$TMP/fresh/AGENTS.md" ]] && echo yes || echo no)"

# 5) C2-shaped fallback: with SL_MEMORY_DIR/SL_SKILLS_DIR unset, this must
#    consult lib/paths.py (AGENT_LEARNING_HOME here) rather than a
#    hardcoded ~/.claude/... literal, which would be wrong-location on any
#    install that isn't Claude Code.
FALLBACK_HOME=$(mktemp -d)
FALLBACK_STORE="${FALLBACK_HOME}/store"
mkdir -p "${FALLBACK_STORE}/learned-skills/fallback-skill" "${FALLBACK_STORE}/memory"
printf -- '---\nname: fallback-skill\ndescription: Reached via paths.py, not a hardcoded default.\n---\nBody\n' \
    > "${FALLBACK_STORE}/learned-skills/fallback-skill/SKILL.md"
echo "- fallback memory line" > "${FALLBACK_STORE}/memory/MEMORY.md"
env -i HOME="$FALLBACK_HOME" AGENT_LEARNING_HOME="$FALLBACK_STORE" PATH="$PATH" \
    python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "${FALLBACK_HOME}/AGENTS.md"
FALLBACK_BLOCK="$(cat "${FALLBACK_HOME}/AGENTS.md" 2>/dev/null || echo MISSING)"
check "fallback resolves via paths.py: skill found" "yes" "$([[ "$FALLBACK_BLOCK" == *"fallback-skill"* ]] && echo yes || echo no)"
check "fallback resolves via paths.py: memory found" "yes" "$([[ "$FALLBACK_BLOCK" == *"fallback memory line"* ]] && echo yes || echo no)"
check "fallback never created ~/.claude" "no" "$([[ -e "${FALLBACK_HOME}/.claude" ]] && echo yes || echo no)"
rm -rf "$FALLBACK_HOME"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All inject-agents-md tests passed."
