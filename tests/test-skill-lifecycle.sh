#!/usr/bin/env bash
# tests/test-skill-lifecycle.sh
#
# C2: skill-lifecycle.py hardcoded ~/.claude/learned-skills and only read
# the Claude-branded CLAUDE_LEARNED_SKILLS_DIR, never SL_SKILLS_DIR -- the
# variable curator-run.sh actually exports (via lib/config.sh) before
# invoking it with no arguments. On a correct vendor-neutral install this
# made lifecycle transitions silently never run (exit 0, "Nothing to do.").
# On an upgraded machine with both a legacy ~/.claude/learned-skills and a
# new vendor-neutral store, it would run destructive shutil.move/rmtree
# against the WRONG (legacy) directory. These tests pin the fixed
# resolution order: SL_SKILLS_DIR > CLAUDE_LEARNED_SKILLS_DIR > paths.py.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A skill whose last activity is far enough in the past (> 90 days before
# "today") to trigger an ARCHIVE transition -- the destructive operation
# that must land in the right directory.
write_fixture() {
    local dir="$1"
    mkdir -p "${dir}/old-skill"
    cat > "${dir}/old-skill/SKILL.md" <<'EOF'
---
name: old-skill
description: fixture
---
body
EOF
    cat > "${dir}/.usage.json" <<'EOF'
{
  "old-skill": {
    "created_by": "agent",
    "state": "active",
    "pinned": false,
    "use_count": 5,
    "last_used_at": "2020-01-01T00:00:00Z"
  }
}
EOF
}

# --- 1) SL_SKILLS_DIR set, CLAUDE_LEARNED_SKILLS_DIR unset: transitions
#        actually run against the vendor-neutral store, with no ~/.claude
#        anywhere on disk (a correct fresh install). ---
NEW_STORE="${TMP}/new-store/learned-skills"
mkdir -p "$NEW_STORE"
write_fixture "$NEW_STORE"

OUT=$(env -i HOME="${TMP}/no-claude-home" PATH="$PATH" SL_SKILLS_DIR="$NEW_STORE" \
    python3 "${SCRIPT_DIR}/scripts/skill-lifecycle.py" 2>&1) || true
check "SL_SKILLS_DIR: transitions actually ran (not 'Nothing to do')" "no" \
    "$(printf '%s' "$OUT" | grep -qi 'nothing to do' && echo yes || echo no)"
check "SL_SKILLS_DIR: old-skill archived under the resolved store" "yes" \
    "$([[ -d "${NEW_STORE}/.archive/old-skill" ]] && echo yes || echo no)"
check "SL_SKILLS_DIR: no ~/.claude was ever created" "no" \
    "$([[ -e "${TMP}/no-claude-home/.claude" ]] && echo yes || echo no)"

# --- 2) CLAUDE_LEARNED_SKILLS_DIR alone (SL_SKILLS_DIR unset): deprecated
#        alias still works, for one release, with a stderr deprecation
#        notice. ---
LEGACY_ALIAS_STORE="${TMP}/legacy-alias-store"
mkdir -p "$LEGACY_ALIAS_STORE"
write_fixture "$LEGACY_ALIAS_STORE"

OUT=$(env -i HOME="${TMP}/no-claude-home2" PATH="$PATH" CLAUDE_LEARNED_SKILLS_DIR="$LEGACY_ALIAS_STORE" \
    python3 "${SCRIPT_DIR}/scripts/skill-lifecycle.py" 2>&1) || true
check "CLAUDE_LEARNED_SKILLS_DIR alone: old-skill archived" "yes" \
    "$([[ -d "${LEGACY_ALIAS_STORE}/.archive/old-skill" ]] && echo yes || echo no)"
check "CLAUDE_LEARNED_SKILLS_DIR alone: deprecation notice printed" "yes" \
    "$(printf '%s' "$OUT" | grep -q 'deprecated' && echo yes || echo no)"

# --- 3) Both set: SL_SKILLS_DIR wins, and the legacy directory named by
#        CLAUDE_LEARNED_SKILLS_DIR is left completely untouched -- this is
#        the exact "destructive against the wrong directory" scenario from
#        the finding: an upgraded machine with both a stale legacy store
#        and a real new one. ---
WINNER_STORE="${TMP}/winner-store"
LOSER_STORE="${TMP}/loser-store"
mkdir -p "$WINNER_STORE" "$LOSER_STORE"
write_fixture "$WINNER_STORE"
write_fixture "$LOSER_STORE"

env -i HOME="${TMP}/no-claude-home3" PATH="$PATH" \
    SL_SKILLS_DIR="$WINNER_STORE" CLAUDE_LEARNED_SKILLS_DIR="$LOSER_STORE" \
    python3 "${SCRIPT_DIR}/scripts/skill-lifecycle.py" >/dev/null 2>&1 || true
check "both set: SL_SKILLS_DIR (winner) processed" "yes" \
    "$([[ -d "${WINNER_STORE}/.archive/old-skill" ]] && echo yes || echo no)"
check "both set: CLAUDE_LEARNED_SKILLS_DIR (loser) left untouched" "yes" \
    "$([[ -d "${LOSER_STORE}/old-skill" && ! -d "${LOSER_STORE}/.archive/old-skill" ]] && echo yes || echo no)"

# --- 4) Neither set: falls back to paths.py's resolver (AGENT_LEARNING_HOME
#        override here), and -- this is the destructive-upgrade regression
#        from the finding -- a populated ~/.claude/learned-skills sitting
#        right there on disk must be left completely alone. ---
FALLBACK_HOME="${TMP}/fallback-home"
FALLBACK_STORE="${FALLBACK_HOME}/store"
mkdir -p "${FALLBACK_HOME}/.claude/learned-skills"
write_fixture "${FALLBACK_HOME}/.claude/learned-skills"
mkdir -p "${FALLBACK_STORE}/learned-skills"
write_fixture "${FALLBACK_STORE}/learned-skills"

env -i HOME="$FALLBACK_HOME" PATH="$PATH" AGENT_LEARNING_HOME="$FALLBACK_STORE" \
    python3 "${SCRIPT_DIR}/scripts/skill-lifecycle.py" >/dev/null 2>&1 || true
check "no env vars: paths.py fallback processed the resolved store" "yes" \
    "$([[ -d "${FALLBACK_STORE}/learned-skills/.archive/old-skill" ]] && echo yes || echo no)"
check "no env vars: legacy ~/.claude/learned-skills left untouched (no destructive wrong-dir write)" "yes" \
    "$([[ -d "${FALLBACK_HOME}/.claude/learned-skills/old-skill" && ! -d "${FALLBACK_HOME}/.claude/learned-skills/.archive/old-skill" ]] && echo yes || echo no)"

# --- 5) Corrupt .usage.json: must refuse (non-zero exit), never silently
#        report "No .usage.json found. Nothing to do." for a file that
#        DOES exist -- that message is only true when the file is absent.
#        This is the "also in scope" fix: skill-lifecycle.py's policy for a
#        present-but-corrupt .usage.json must agree with
#        persist-proposal.py's (refuse, don't silently treat as empty). ---
CORRUPT_STORE="${TMP}/corrupt-store"
mkdir -p "$CORRUPT_STORE"
echo '{not valid json' > "${CORRUPT_STORE}/.usage.json"

CORRUPT_STATUS=0
CORRUPT_OUT=$(env -i HOME="${TMP}/no-claude-home4" PATH="$PATH" SL_SKILLS_DIR="$CORRUPT_STORE" \
    python3 "${SCRIPT_DIR}/scripts/skill-lifecycle.py" 2>&1) || CORRUPT_STATUS=$?
check "corrupt .usage.json: exits non-zero (refuses, does not silently no-op)" "yes" \
    "$([[ "$CORRUPT_STATUS" -ne 0 ]] && echo yes || echo no)"
check "corrupt .usage.json: does NOT report 'Nothing to do' for a file that exists" "no" \
    "$(printf '%s' "$CORRUPT_OUT" | grep -qi 'nothing to do' && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All skill-lifecycle tests passed."
