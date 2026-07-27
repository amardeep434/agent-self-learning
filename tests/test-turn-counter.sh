#!/usr/bin/env bash
# tests/test-turn-counter.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_HOME="$TMP" SL_STATE_DIR="$TMP/state" SL_CONFIG_FILE="/nonexistent"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

payload() { echo "{\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"hook_event_name\":\"PostToolUse\"}"; }

# 1) First call creates counter with session id from stdin
payload sess-A | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "session id recorded from stdin" "sess-A" "$(jq -r .session_id "$TMP/state/turn_counter.json")"
check "one tool call counted" "1" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 2) Same session increments
payload sess-A | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "increment within session" "2" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 3) New session resets
payload sess-B | bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "session boundary resets counter" "1" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"
check "new session id recorded" "sess-B" "$(jq -r .session_id "$TMP/state/turn_counter.json")"

# 4) Recursion guard: no state change when SL_REVIEW_ACTIVE is set
BEFORE=$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")
payload sess-B | SL_REVIEW_ACTIVE=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
check "recursion guard skips counting" "$BEFORE" "$(jq -r .total_turns_this_session "$TMP/state/turn_counter.json")"

# 5) Cooldown gate wiring, end-to-end, with a non-empty last_review_at.
#
# Fix round 1 (reviewer finding): tests/test-config.sh now covers
# sl_iso_to_epoch in isolation, but the reviewer also asked for a test that
# exercises a CALLER gate — this one is turn-counter.sh's "no re-trigger
# within 60s of last_review_at" cooldown (scripts/turn-counter.sh line
# ~146). A helper can be individually correct and still be wired up wrong
# (or not wired up at all); this proves the wiring, not just the helper.
#
# A recent last_review_at (a few seconds ago) must suppress the signal even
# though the skill-review threshold is met. If sl_iso_to_epoch regressed to
# always return 0 (the reviewer's mutation), every last_review_at would look
# ~56 years old and this assertion would flip from PASS to FAIL.
RECENT=$(date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
cat > "$TMP/state/turn_counter.json" <<EOF
{
  "session_id": "sess-cooldown",
  "memory_turns": 0,
  "skill_iterations": 0,
  "last_review_at": "${RECENT}",
  "session_started_at": "${RECENT}",
  "total_turns_this_session": 5
}
EOF
rm -f "$TMP/state/review_signal.json"
payload sess-cooldown | SL_SKILL_REVIEW_INTERVAL=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
if [[ -f "$TMP/state/review_signal.json" ]]; then
    echo "FAIL: cooldown gate did not suppress the signal despite last_review_at being ${RECENT} (a few seconds ago)"
    FAILURES=$((FAILURES+1))
else
    echo "PASS: cooldown gate suppresses the signal within 60s of a real last_review_at"
fi

# 6) Same gate, opposite direction: a genuinely stale last_review_at must
# allow the signal to fire again. Without this half, a broken gate that
# ALWAYS suppresses (e.g. an inverted comparison) would slip through case 5.
STALE="2020-01-01T00:00:00Z"
cat > "$TMP/state/turn_counter.json" <<EOF
{
  "session_id": "sess-cooldown",
  "memory_turns": 0,
  "skill_iterations": 0,
  "last_review_at": "${STALE}",
  "session_started_at": "${STALE}",
  "total_turns_this_session": 5
}
EOF
rm -f "$TMP/state/review_signal.json"
payload sess-cooldown | SL_SKILL_REVIEW_INTERVAL=1 bash "${SCRIPT_DIR}/scripts/turn-counter.sh"
if [[ -f "$TMP/state/review_signal.json" ]]; then
    echo "PASS: cooldown gate allows the signal once last_review_at is genuinely stale"
else
    echo "FAIL: cooldown gate incorrectly suppressed the signal for a stale last_review_at (${STALE})"
    FAILURES=$((FAILURES+1))
fi

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All turn-counter tests passed."
