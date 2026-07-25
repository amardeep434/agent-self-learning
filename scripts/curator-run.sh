#!/usr/bin/env bash
#
# Curator: periodic skill library maintenance.
# Triggered by cron, systemd timer, or Claude Code routine.
#
# Responsibilities:
# 1. Check idle gate (user must be idle 2+ hours)
# 2. Check last-run gate (7-day minimum interval)
# 3. Create backup of learned-skills directory
# 4. Run deterministic lifecycle transitions (via skill-lifecycle.py)
# 5. Optionally prepare inventory for LLM consolidation pass
# 6. Write a Markdown report to logs/curator/
#
# Usage:
#   bash curator-run.sh                       # Full run with all gates
#   CLAUDE_CURATOR_IDLE_GATE=0 bash curator-run.sh  # Skip idle gate
#   CLAUDE_CURATOR_LLM_PASS=true bash curator-run.sh # Enable LLM pass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/config.sh"

SKILLS_DIR="$SL_SKILLS_DIR"
ARCHIVE_DIR="${SKILLS_DIR}/.archive"
# No "backups" key in paths.py (out of scope for this task); derive it under
# the resolved home the same way install.sh does, so the installer and this
# consumer never disagree about where backups live.
BACKUP_DIR="${SL_HOME}/backups/curator"
LOG_DIR="${SL_LOG_DIR}/curator"
REPORT_FILE="${LOG_DIR}/$(date +%Y-%m-%d)-curator-report.md"
IDLE_GATE_HOURS="${CLAUDE_CURATOR_IDLE_GATE:-2}"
LLM_PASS="${CLAUDE_CURATOR_LLM_PASS:-false}"
STATE_DIR="$SL_STATE_DIR"

mkdir -p "$ARCHIVE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$STATE_DIR"

# --- Idle gate check ---
# The curator should only run when the user is not actively in a session.

LAST_SESSION_FILE="${STATE_DIR}/last-session-end"
if [[ -f "$LAST_SESSION_FILE" ]]; then
    LAST_SESSION_TS=$(cat "$LAST_SESSION_FILE")
    LAST_SESSION_EPOCH=$(date -d "$LAST_SESSION_TS" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    IDLE_SECONDS=$((NOW_EPOCH - LAST_SESSION_EPOCH))
    IDLE_HOURS=$((IDLE_SECONDS / 3600))

    if [[ "$IDLE_HOURS" -lt "$IDLE_GATE_HOURS" ]]; then
        echo "[CURATOR] Idle gate not met: ${IDLE_HOURS}h < ${IDLE_GATE_HOURS}h required" >&2
        exit 0
    fi
fi

# --- Last run check (7-day interval) ---

LAST_RUN_FILE="${STATE_DIR}/curator-last-run"
if [[ -f "$LAST_RUN_FILE" ]]; then
    LAST_RUN_TS=$(cat "$LAST_RUN_FILE")
    LAST_RUN_EPOCH=$(date -d "$LAST_RUN_TS" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DAYS_SINCE=$(( (NOW_EPOCH - LAST_RUN_EPOCH) / 86400 ))

    if [[ "$DAYS_SINCE" -lt 7 ]]; then
        echo "[CURATOR] Too soon: ${DAYS_SINCE} days since last run (7 required)" >&2
        exit 0
    fi
fi

echo "[CURATOR] Starting curator run at $(date -Iseconds)"

# --- Pre-run backup ---
# Always back up before any destructive operations.

BACKUP_FILE="${BACKUP_DIR}/skills-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
if [[ -d "$SKILLS_DIR" ]]; then
    tar -czf "$BACKUP_FILE" -C "$(dirname "$SKILLS_DIR")" "$(basename "$SKILLS_DIR")" 2>/dev/null || true
    echo "[CURATOR] Backup created: $BACKUP_FILE"
else
    echo "[CURATOR] Skills directory not found, skipping backup"
fi

# --- Initialize report ---

cat > "$REPORT_FILE" << EOF
# Curator Report: $(date +%Y-%m-%d)

**Run started:** $(date -Iseconds)
**Skills directory:** $SKILLS_DIR
**Backup:** $BACKUP_FILE
**LLM consolidation:** $LLM_PASS

## Inventory

EOF

# --- Count skills by state ---

TOTAL_ACTIVE=0
TOTAL_STALE=0
TOTAL_ARCHIVED=0
TOTAL_PINNED=0

USAGE_FILE="${SKILLS_DIR}/.usage.json"
if [[ -f "$USAGE_FILE" ]]; then
    for SKILL_NAME in $(jq -r 'keys[]' "$USAGE_FILE" 2>/dev/null); do
        state=$(jq -r --arg n "$SKILL_NAME" '.[$n].state // "active"' "$USAGE_FILE" 2>/dev/null || echo "active")
        pinned=$(jq -r --arg n "$SKILL_NAME" '.[$n].pinned // false' "$USAGE_FILE" 2>/dev/null || echo "false")

        case "$state" in
            active)   TOTAL_ACTIVE=$((TOTAL_ACTIVE + 1)) ;;
            stale)    TOTAL_STALE=$((TOTAL_STALE + 1)) ;;
            archived) TOTAL_ARCHIVED=$((TOTAL_ARCHIVED + 1)) ;;
        esac
        if [[ "$pinned" == "true" ]]; then
            TOTAL_PINNED=$((TOTAL_PINNED + 1))
        fi
    done
fi

cat >> "$REPORT_FILE" << EOF
| State | Count |
|-------|-------|
| Active | $TOTAL_ACTIVE |
| Stale | $TOTAL_STALE |
| Archived | $TOTAL_ARCHIVED |
| Pinned | $TOTAL_PINNED |
| **Total** | **$((TOTAL_ACTIVE + TOTAL_STALE + TOTAL_ARCHIVED))** |

## Lifecycle Transitions

EOF

# --- Run deterministic transitions ---

echo "[CURATOR] Running deterministic lifecycle transitions..."
TRANSITION_LOG=""
if [[ -f "${SCRIPT_DIR}/skill-lifecycle.py" ]]; then
    TRANSITION_LOG=$(python3 "${SCRIPT_DIR}/skill-lifecycle.py" 2>&1) || true
else
    TRANSITION_LOG="[WARN] No skill-lifecycle script found"
fi

echo "$TRANSITION_LOG" >> "$REPORT_FILE"

if [[ -z "$TRANSITION_LOG" ]]; then
    echo "_No transitions this cycle._" >> "$REPORT_FILE"
fi

# --- LLM consolidation pass (opt-in) ---

if [[ "$LLM_PASS" == "true" ]]; then
    echo "" >> "$REPORT_FILE"
    echo "## LLM Consolidation Pass" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Build skill inventory for the LLM
    SKILL_INVENTORY=""
    if [[ -f "$USAGE_FILE" ]]; then
        for SKILL_NAME in $(jq -r 'keys[]' "$USAGE_FILE" 2>/dev/null); do
            state=$(jq -r --arg n "$SKILL_NAME" '.[$n].state // "active"' "$USAGE_FILE" 2>/dev/null || echo "active")
            use_count=$(jq -r --arg n "$SKILL_NAME" '.[$n].use_count // 0' "$USAGE_FILE" 2>/dev/null || echo "0")

            # Skip archived
            if [[ "$state" == "archived" ]]; then
                continue
            fi

            description=""
            SKILL_MD="${SKILLS_DIR}/${SKILL_NAME}/SKILL.md"
            if [[ -f "$SKILL_MD" ]]; then
                description=$(grep "^description:" "$SKILL_MD" 2>/dev/null | head -1 | sed 's/^description: *//')
            fi

            SKILL_INVENTORY+="- [${SKILL_NAME}] ($state, ${use_count} uses): $description"$'\n'
        done
    fi

    # Write inventory to temp file for manual LLM subagent invocation
    INVENTORY_FILE="${STATE_DIR}/curator-inventory.md"
    echo "$SKILL_INVENTORY" > "$INVENTORY_FILE"

    echo "[CURATOR] Skill inventory written to $INVENTORY_FILE"
    echo "[CURATOR] LLM consolidation requires manual trigger"
    echo "_LLM pass inventory prepared. Run consolidation subagent manually._" >> "$REPORT_FILE"
fi

# --- Finalize report ---

TRANSITION_COUNT=$(echo "$TRANSITION_LOG" | grep -cE "^\[(STALE|ARCHIVE|REACTIVATE)\]" 2>/dev/null || echo 0)
BACKUP_SIZE=$(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1 || echo "N/A")

cat >> "$REPORT_FILE" << EOF

## Summary

**Run completed:** $(date -Iseconds)
**Transitions applied:** $TRANSITION_COUNT
**Backup size:** $BACKUP_SIZE
EOF

# Update last-run timestamp
date -Iseconds > "$LAST_RUN_FILE"

echo "[CURATOR] Run complete. Report: $REPORT_FILE"
