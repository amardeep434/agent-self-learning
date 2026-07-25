#!/usr/bin/env bash
# tests/test-config.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Defaults (point SL_CONFIG_FILE at the repo config)
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="${SCRIPT_DIR}/config/self-learning.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_ENABLED|\$SL_COACH_EXPORT_ENABLED\"")
check "both coach flags default false" "false|false" "$OUT"

# Env override wins
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="${SCRIPT_DIR}/config/self-learning.conf" SL_COACH_RULES_ENABLED=true \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_ENABLED\"")
check "env override wins" "true" "$OUT"

# Missing config file is non-fatal, defaults apply
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
check "missing file falls back to defaults" "$HOME/.local/share/agent-learning" "$OUT"

# Neutral defaults: no ~/.claude anywhere
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
case "$OUT" in
    *.claude*) echo "FAIL: SL_HOME still points into .claude ($OUT)"; FAILURES=$((FAILURES+1)) ;;
    *agent-learning*) echo "PASS: SL_HOME is vendor-neutral" ;;
    *) echo "FAIL: unexpected SL_HOME ($OUT)"; FAILURES=$((FAILURES+1)) ;;
esac

# Explicit override wins over platform default
OUT=$(env -i HOME="$HOME" PATH="$PATH" AGENT_LEARNING_HOME="/tmp/al" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_MEMORY_DIR\"")
check "AGENT_LEARNING_HOME drives SL_MEMORY_DIR" "/tmp/al/memory" "$OUT"

# New review flag defaults on
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED defaults true" "true" "$OUT"

# Legacy variable still honored for one release
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "legacy CLAUDE_REVIEW_ENABLED honored" "false" "$OUT"

# New variable beats legacy when both set
OUT=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_REVIEW_ENABLED=false SL_REVIEW_ENABLED=true SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_REVIEW_ENABLED\"")
check "SL_REVIEW_ENABLED beats legacy" "true" "$OUT"

# SL_CONFIG_FILE default comes from paths.py's config_file key, not ~/.claude
OUT=$(env -i HOME="$HOME" PATH="$PATH" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_CONFIG_FILE\"")
case "$OUT" in
    *.claude*) echo "FAIL: default SL_CONFIG_FILE still points into .claude ($OUT)"; FAILURES=$((FAILURES+1)) ;;
    *agent-learning*) echo "PASS: default SL_CONFIG_FILE is vendor-neutral" ;;
    *) echo "FAIL: unexpected default SL_CONFIG_FILE ($OUT)"; FAILURES=$((FAILURES+1)) ;;
esac

# Pre-set SL_CONFIG_FILE still wins over the paths.py default
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_CONFIG_FILE\"")
check "pre-set SL_CONFIG_FILE overrides paths.py default" "/nonexistent/x.conf" "$OUT"

# All six path variables get a working, vendor-neutral literal fallback when
# python3/paths.py is entirely unavailable (e.g. not on PATH). A minimal PATH
# is built containing only the external commands config.sh itself needs
# (dirname, bash -- `env` re-resolves argv[0] against the PATH it is itself
# given, so bash must be reachable there too) so python3 cannot be found,
# without relying on any GNU-only tool.
#
# `cp`, not `ln -s`: symlink creation can silently fail or require elevated
# privileges on Windows (no admin / no Developer Mode), which would abort
# this script under `set -e` with a confusing, environment-dependent error
# far from the real assertion. `cp` needs no special privilege on any
# platform and preserves the source basename (incl. a `.exe` suffix, so
# Windows' implicit PATHEXT-style resolution still finds it).
_sl_link_or_copy() {
    local src="$1" dst="$2"
    cp "$src" "$dst"
}
_sl_no_python_dir=$(mktemp -d)
_sl_link_or_copy "$(command -v dirname)" "$_sl_no_python_dir/dirname"
_sl_link_or_copy "$(command -v bash)" "$_sl_no_python_dir/bash"
OUT=$(env -i HOME="$HOME" PATH="$_sl_no_python_dir" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME|\$SL_STATE_DIR|\$SL_SKILLS_DIR|\$SL_MEMORY_DIR|\$SL_LOG_DIR|\$SL_SEARCH_DB\"")
rm -rf "$_sl_no_python_dir"
_sl_no_python_ok=true
IFS='|' read -r _h _st _sk _me _lo _se <<< "$OUT"
for _val in "$_h" "$_st" "$_sk" "$_me" "$_lo" "$_se"; do
    case "$_val" in
        "") _sl_no_python_ok=false ;;
        *.claude*) _sl_no_python_ok=false ;;
    esac
done
if [[ "$_sl_no_python_ok" == "true" ]]; then
    echo "PASS: all six paths are non-empty and vendor-neutral with no python3 ($OUT)"
else
    echo "FAIL: paths broke with no python3 on PATH ($OUT)"
    FAILURES=$((FAILURES+1))
fi

# --- sl_iso_to_epoch: direct unit coverage -------------------------------
# Fix round 1 (reviewer finding): the reviewer replaced sl_iso_to_epoch's
# body with `echo 0; return 0` and tests/test-turn-counter.sh still passed —
# proving nothing exercised this function directly. Epoch 0 makes every
# timestamp look infinitely stale, which is silent and directional (the
# curator would archive skills it should keep). These assertions exist to
# make that mutation fail loudly. See "mutation testing" note in
# task-8-report.md for the before/after proof.
#
# Expected epochs below are computed independently of sl_iso_to_epoch (via
# `date -u -d '2024-06-15T12:34:56Z' +%s` and cross-checked with Python's
# datetime.timestamp()) and hardcoded, so a bug in the function under test
# cannot also corrupt the expected value.

OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56Z'")
check "sl_iso_to_epoch: Z suffix" "1718454896" "$OUT"

OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56+00:00'")
check "sl_iso_to_epoch: explicit +00:00 offset" "1718454896" "$OUT"

OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T18:04:56+05:30'")
check "sl_iso_to_epoch: non-UTC +05:30 offset" "1718454896" "$OUT"

OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56.500Z'")
check "sl_iso_to_epoch: fractional seconds" "1718454896" "$OUT"

# Timezone independence: the input always carries explicit UTC/offset info,
# so the interpreter's local TZ must never leak into the result. TZ is
# pinned explicitly (not just inherited from the CI runner's default) so a
# future regression that drops -u or assumes local time fails HERE instead
# of only in whichever TZ a given CI runner happens to use.
OUT=$(TZ="America/New_York" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56Z'")
check "sl_iso_to_epoch: TZ=America/New_York does not shift the result" "1718454896" "$OUT"

OUT=$(TZ="Asia/Kolkata" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56Z'")
check "sl_iso_to_epoch: TZ=Asia/Kolkata does not shift the result" "1718454896" "$OUT"

OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch ''")
check "sl_iso_to_epoch: empty input returns the documented sentinel" "0" "$OUT"

OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch 'not-a-real-timestamp'")
check "sl_iso_to_epoch: garbage input returns the documented sentinel" "0" "$OUT"

# The sentinel must be reached deliberately for empty/garbage input, not by
# every input silently collapsing to it. A timestamp one second after the
# Unix epoch must NOT come back as the same "0" as the failure sentinel.
OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '1970-01-01T00:00:01Z'")
check "sl_iso_to_epoch: real epoch-adjacent timestamp is distinguishable from the sentinel" "1" "$OUT"

# Round-trip against the repo's own writer format (date -u
# +%Y-%m-%dT%H:%M:%SZ — what session-review.sh, curator-run.sh, and
# turn-counter.sh all use to persist timestamps) so producer and consumer
# stay pinned together instead of drifting apart independently.
WRITTEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BEFORE_EPOCH=$(date -u +%s)
OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '$WRITTEN'")
AFTER_EPOCH=$(date -u +%s)
if [[ "$OUT" =~ ^[0-9]+$ && "$OUT" -ge "$BEFORE_EPOCH" && "$OUT" -le "$AFTER_EPOCH" ]]; then
    echo "PASS: sl_iso_to_epoch round-trips the repo's own writer format ($WRITTEN -> $OUT)"
else
    echo "FAIL: sl_iso_to_epoch round-trip mismatch: wrote '$WRITTEN', expected an epoch in [$BEFORE_EPOCH, $AFTER_EPOCH], got '$OUT'"
    FAILURES=$((FAILURES+1))
fi

# --- I7: force BOTH the GNU and BSD `date` strategies to fail (a fake
# `date` binary that always exits 1, ahead of the real one on PATH) so these
# assertions exercise the python3 fallback specifically, regardless of which
# `date` flavor the host machine actually has. This is what makes the fix
# verifiable on Linux even though the bug it targets is macOS-only: Linux's
# real GNU `date -d` is lenient enough to mask a python3-fallback
# regression entirely (it never gets a chance to run), which is exactly how
# this bug shipped in the first place.
_sl_fake_date_dir=$(mktemp -d)
cat > "$_sl_fake_date_dir/date" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$_sl_fake_date_dir/date"

OUT=$(PATH="${_sl_fake_date_dir}:${PATH}" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56+00:00'")
check "I7 python3-fallback: explicit +00:00 offset" "1718454896" "$OUT"

OUT=$(PATH="${_sl_fake_date_dir}:${PATH}" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T18:04:56+05:30'")
check "I7 python3-fallback: non-UTC +05:30 offset" "1718454896" "$OUT"

OUT=$(PATH="${_sl_fake_date_dir}:${PATH}" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56.500Z'")
check "I7 python3-fallback: fractional seconds" "1718454896" "$OUT"

OUT=$(PATH="${_sl_fake_date_dir}:${PATH}" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T12:34:56Z'")
check "I7 python3-fallback: Z suffix" "1718454896" "$OUT"

# Deferred minor 7: a NEGATIVE non-UTC offset must not be silently flipped
# to positive. "-05:30" means local = UTC + 5:30, so 07:04:56-05:30 is the
# same UTC instant (12:34:56Z / 1718454896) as 18:04:56+05:30 above -- if
# the sign were dropped or flipped, this would come back equal to the
# WRONG one of those two, or to some other value entirely, never
# 1718454896 by coincidence.
OUT=$(PATH="${_sl_fake_date_dir}:${PATH}" bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '2024-06-15T07:04:56-05:30'")
check "I7 python3-fallback (deferred minor 7): negative -05:30 offset is not flipped positive" "1718454896" "$OUT"

rm -rf "$_sl_fake_date_dir"

# --- I6: the python3-less fallback must honor the SAME override chain as
# paths.py (AGENT_LEARNING_HOME > XDG_DATA_HOME/agent-learning > $HOME
# default), not a bare ${HOME} literal that ignores overrides entirely.
# Commit 384a319 fixed "never silently go empty" by hardcoding
# ${HOME}/.local/share/agent-learning -- which itself silently ignores a
# caller's AGENT_LEARNING_HOME/XDG_DATA_HOME when python3 is unavailable.
_sl_no_python_dir2=$(mktemp -d)
_sl_link_or_copy "$(command -v dirname)" "$_sl_no_python_dir2/dirname"
_sl_link_or_copy "$(command -v bash)" "$_sl_no_python_dir2/bash"
OUT=$(env -i HOME="$HOME" PATH="$_sl_no_python_dir2" AGENT_LEARNING_HOME="/tmp/al-nopy" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME|\$SL_MEMORY_DIR\"")
check "I6: no python3, AGENT_LEARNING_HOME still drives SL_HOME" "/tmp/al-nopy|/tmp/al-nopy/memory" "$OUT"

OUT=$(env -i HOME="$HOME" PATH="$_sl_no_python_dir2" XDG_DATA_HOME="/tmp/xdg-nopy" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
check "I6: no python3, XDG_DATA_HOME still drives SL_HOME" "/tmp/xdg-nopy/agent-learning" "$OUT"
rm -rf "$_sl_no_python_dir2"

# --- Deferred minor 3: env must beat file for the five path variables that
# were missing from _sl_env_snapshot (SL_STATE_DIR, SL_SKILLS_DIR,
# SL_MEMORY_DIR, SL_LOG_DIR, SL_SEARCH_DB) -- previously a config file could
# silently override a caller's pre-set environment variable for these.
_sl_env_beats_file_conf=$(mktemp)
cat > "$_sl_env_beats_file_conf" <<'EOF'
SL_STATE_DIR=/from-file/state
SL_SKILLS_DIR=/from-file/skills
SL_MEMORY_DIR=/from-file/memory
SL_LOG_DIR=/from-file/logs
SL_SEARCH_DB=/from-file/search.db
EOF
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="$_sl_env_beats_file_conf" \
    SL_STATE_DIR="/from-env/state" SL_SKILLS_DIR="/from-env/skills" \
    SL_MEMORY_DIR="/from-env/memory" SL_LOG_DIR="/from-env/logs" \
    SL_SEARCH_DB="/from-env/search.db" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_STATE_DIR|\$SL_SKILLS_DIR|\$SL_MEMORY_DIR|\$SL_LOG_DIR|\$SL_SEARCH_DB\"")
check "deferred minor 3: env beats file for all five path vars" \
    "/from-env/state|/from-env/skills|/from-env/memory|/from-env/logs|/from-env/search.db" "$OUT"
rm -f "$_sl_env_beats_file_conf"

# --- I5: SL_COACH_RULES_DIR default must match where install.sh actually
# installs coach rules (${DEST_DIR}/coach-rules, DEST_DIR being paths.py's
# "scripts" key), not the pre-Task-7b .../scripts/self-learning/coach-rules
# path that no longer exists on a real install.
OUT=$(env -i HOME="/tmp/sl-coach-rules-home" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_DIR\"")
check "I5: SL_COACH_RULES_DIR matches install.sh's actual coach-rules destination" \
    "/tmp/sl-coach-rules-home/.local/share/agent-learning/scripts/coach-rules" "$OUT"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All config tests passed."
