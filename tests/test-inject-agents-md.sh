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

# 6) A memory file larger than the injection budget must be injected IN FULL,
#    and must announce itself in persist-failures.log.
#
#    This used to be `read_text(...)[:2200]`. Measured 2026-07-30 against the
#    real store, that slice injected 10% of a 20752-byte MEMORY.md and dropped
#    89% mid-entry -- no ellipsis, no log line, nothing doctor.sh could see.
#    The tail is where the NEWEST lessons live in an append-ordered file, so
#    the silent half of that bug destroyed exactly the content most worth
#    delivering.
#
#    Hermes uses the same 2200 as a WRITE-side budget that refuses the write
#    and demands consolidation (tools/memory_tool.py:165, rejection :426-437);
#    its read path never truncates. We cannot copy that number to our write
#    path -- MEMORY.md is already 9x over it, so it would reject every future
#    append -- and persist-proposal.py already bounds accumulated growth
#    loudly at MAX_MEMORY_FILE_BYTES. So the read path carries no cap at all,
#    and the budget becomes a loud advisory instead of a silent knife.
BIG_HOME=$(mktemp -d)
BIG_STORE="${BIG_HOME}/store"
mkdir -p "${BIG_STORE}/memory" "${BIG_STORE}/logs"
{
    echo "- FIRST-LINE-SENTINEL oldest lesson"
    for i in $(seq 1 400); do
        echo "- filler lesson ${i} with enough text to push this file past any small budget"
    done
    echo "- LAST-LINE-SENTINEL newest lesson"
} > "${BIG_STORE}/memory/MEMORY.md"
BIG_BYTES=$(wc -c < "${BIG_STORE}/memory/MEMORY.md")

env -i HOME="$BIG_HOME" AGENT_LEARNING_HOME="$BIG_STORE" PATH="$PATH" \
    SL_MEMORY_INJECT_BUDGET=2200 \
    python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "${BIG_HOME}/AGENTS.md"

check "oversized memory: oldest line survives" "yes" \
    "$(grep -q 'FIRST-LINE-SENTINEL' "${BIG_HOME}/AGENTS.md" && echo yes || echo no)"
check "oversized memory: NEWEST line survives (the silent-drop bug)" "yes" \
    "$(grep -q 'LAST-LINE-SENTINEL' "${BIG_HOME}/AGENTS.md" && echo yes || echo no)"

# Byte comparison, not "did grep find something" -- this project's own rule.
# The block carries headings around the memory, so it must be AT LEAST the
# size of the source file; equality would mean something was dropped.
BLOCK_BYTES=$(wc -c < "${BIG_HOME}/AGENTS.md")
check "oversized memory: nothing dropped (block >= source bytes)" "yes" \
    "$([[ "$BLOCK_BYTES" -ge "$BIG_BYTES" ]] && echo yes || echo no)"

# Loud, not silent: over-budget must be named in persist-failures.log.
BIG_LOG="${BIG_STORE}/logs/persist-failures.log"
check "oversized memory: logged a named reason" "yes" \
    "$([[ -s "$BIG_LOG" ]] && grep -qi 'consolidat' "$BIG_LOG" && echo yes || echo no)"
check "oversized memory: reason states the measured size" "yes" \
    "$(grep -q "$BIG_BYTES" "$BIG_LOG" && echo yes || echo no)"

# And a file UNDER budget must stay quiet -- an advisory that always fires is
# noise, and doctor.sh distinguishes an absent log from an empty one.
SMALL_HOME=$(mktemp -d)
SMALL_STORE="${SMALL_HOME}/store"
mkdir -p "${SMALL_STORE}/memory" "${SMALL_STORE}/logs"
echo "- one short lesson" > "${SMALL_STORE}/memory/MEMORY.md"
env -i HOME="$SMALL_HOME" AGENT_LEARNING_HOME="$SMALL_STORE" PATH="$PATH" \
    SL_MEMORY_INJECT_BUDGET=2200 \
    python3 "${SCRIPT_DIR}/scripts/inject-agents-md.py" "${SMALL_HOME}/AGENTS.md"
check "under-budget memory: no advisory logged" "no" \
    "$([[ -s "${SMALL_STORE}/logs/persist-failures.log" ]] && echo yes || echo no)"
rm -rf "$BIG_HOME" "$SMALL_HOME"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All inject-agents-md tests passed."
