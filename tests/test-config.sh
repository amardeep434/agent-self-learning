#!/usr/bin/env bash
# tests/test-config.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

# Defaults (point SL_CONFIG_FILE at the repo config)
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="${SCRIPT_DIR}/config/self-learning.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_ENABLED|\$SL_COACH_EXPORT_ENABLED\"")
check "both coach flags default false" "false|false" "$OUT"

# Env override wins
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="${SCRIPT_DIR}/config/self-learning.conf" SL_COACH_RULES_ENABLED=true \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_ENABLED\"")
check "env override wins" "true" "$OUT"

# Missing config file is non-fatal, defaults apply.
#
# Fix round E: compared with sl_check_same_path (canonicalized), not plain
# string equality -- $HOME crossing into the python3.exe subprocess
# config.sh shells out to is subject to the same MSYS auto-conversion as
# any other env value (see tests/lib/path-compare.sh), so on Git Bash the
# resolved $OUT can be a differently-spelled but identical directory to the
# bash-literal "$HOME/.local/share/agent-learning" this test used to compare
# against verbatim.
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
sl_check_same_path "missing file falls back to defaults" "$HOME/.local/share/agent-learning" "$OUT"

# Neutral defaults: no ~/.claude anywhere
OUT=$(env -i HOME="$HOME" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
case "$OUT" in
    *.claude*) echo "FAIL: SL_HOME still points into .claude ($OUT)"; FAILURES=$((FAILURES+1)) ;;
    *agent-learning*) echo "PASS: SL_HOME is vendor-neutral" ;;
    *) echo "FAIL: unexpected SL_HOME ($OUT)"; FAILURES=$((FAILURES+1)) ;;
esac

# Explicit override wins over platform default.
#
# Fix round D, blocker (b) / fix round E: on Git Bash / MSYS2, /tmp is
# itself remapped to %TEMP% by the MSYS runtime, so 'AGENT_LEARNING_HOME=/tmp/al'
# and the path python.exe resolves for it can be the SAME directory on disk
# while being spelled completely differently as strings ('/tmp/al/memory'
# vs. 'C:/Users/RUNNER~1/AppData/Local/Temp/al/memory', or -- after paths.py's
# MSYS-form fix -- '/c/Users/.../Temp/al/memory'). A plain string `==`
# assertion is therefore not portable even once paths.py is doing the right
# thing. sl_check_same_path (tests/lib/path-compare.sh) handles this the
# same way every other suite now does, instead of a one-off inline `-ef`
# block (which is what round D shipped here, the thing round E generalizes).
OUT=$(env -i HOME="$HOME" PATH="$PATH" AGENT_LEARNING_HOME="/tmp/al" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_MEMORY_DIR\"")
sl_check_same_path "AGENT_LEARNING_HOME drives SL_MEMORY_DIR" "/tmp/al/memory" "$OUT"

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
# Not `ln -s`: symlink creation can silently fail or require elevated
# privileges on Windows (no admin / no Developer Mode), which would abort
# this script under `set -e` with a confusing, environment-dependent error
# far from the real assertion.
#
# Not `cp` either, as of fix round D, blocker (b): round A used `cp` here
# specifically to dodge the `ln -s` privilege problem above, but on Git
# Bash/MSYS2 that trade turned out to (unconfirmed, but the strongest
# hypothesis for a `tests/test-config.sh exit 127` CI failure that survived
# round A's other Windows fixes) make things WORSE. Copying bash.exe/
# dirname.exe into an isolated, otherwise-empty directory separates the
# binary from the msys-2.0.dll (and friends) the Windows loader resolves
# relative to the EXECUTABLE'S OWN DIRECTORY -- not via PATH. With the DLL
# missing from that directory, the loader fails and the shell reports exit
# 127 ("command not found"), which is indistinguishable from "tool truly
# absent" without inspecting the failure directly on a Windows box (this
# repo cannot; there is no Windows CI evidence yet confirming this diagnosis
# the way blocker (b)'s AGENT_LEARNING_HOME finding was CI-confirmed).
#
# A forwarder script has no DLL dependency of its own -- it is a text file
# whose shebang execs the ORIGINAL absolute path, right next to its real
# siblings, every time. Identical behavior on POSIX and Git Bash. `command
# -v python3` still correctly reports "not found" for the no-python3 tests
# below, since no forwarder is ever created for python3.
#
# CONFIRMED by fix round E: CI run 30155575042 shows this fix worked --
# `tests/test-config.sh` no longer exits 127 on windows-latest; it now
# fails (or passes) on an ordinary assertion. The forwarder-script writer
# now lives once in tests/lib/path-compare.sh as sl_forwarder, used here and
# by every other suite with the same restricted-PATH need (fix round D
# applied this fix only in this file; round E generalizes it, since
# test-doctor-no-python.sh and test-health-no-python.sh turned out to still
# have the pre-fix `cp`-based version).
_sl_no_python_dir=$(mktemp -d)
sl_forwarder "$(command -v dirname)" "$_sl_no_python_dir/dirname"
sl_forwarder "$(command -v bash)" "$_sl_no_python_dir/bash"
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
#
# fix-p6 (flaky, not a platform bug -- macOS CI run 30166469526, 3.13 cell):
# this used to sample BEFORE_EPOCH via a SEPARATE `date -u +%s` call AFTER
# already capturing WRITTEN via its own `date -u +%Y-%m-%dT%H:%M:%SZ` call,
# with zero slack on either bound ([$BEFORE_EPOCH, $AFTER_EPOCH] both able
# to equal the same single second). Two consequences, both real: (1)
# BEFORE_EPOCH could itself be sampled a second AFTER the instant WRITTEN
# captured, if the wall clock ticked over between those two separate `date`
# process spawns -- so the lower bound could already exclude the correct,
# actually-round-tripped epoch, exactly what happened in CI ("wrote
# '...:29Z', expected an epoch in [...270, ...270], got '...269'" -- 269 is
# CORRECT, the window was built one second late); (2) even without that
# ordering bug, a window of width zero has no slack for the clock ticking
# during the `sl_iso_to_epoch` subprocess call itself. Fixed by sampling
# BEFORE_EPOCH first, ahead of WRITTEN, and padding both bounds by a full
# second -- the property under test is "the round-trip preserves the
# instant," not "the test and the producer observed the identical second."
BEFORE_EPOCH=$(($(date -u +%s) - 1))
WRITTEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_iso_to_epoch '$WRITTEN'")
AFTER_EPOCH=$(($(date -u +%s) + 1))
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
sl_forwarder "$(command -v dirname)" "$_sl_no_python_dir2/dirname"
sl_forwarder "$(command -v bash)" "$_sl_no_python_dir2/bash"
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
#
# Fix round E: this HOME is a bare literal ("/tmp/sl-coach-rules-home") that
# never gets mkdir'd -- it doesn't need to exist for config.sh to resolve a
# string from it, but it DOES cross into the python3.exe subprocess
# config.sh shells out to (as the HOME env var), which is exactly the
# boundary MSYS auto-converts on Git Bash. sl_check_same_path's
# canonicalization fallback (tests/lib/path-compare.sh) handles a
# nonexistent path exactly like an existing one for this purpose.
OUT=$(env -i HOME="/tmp/sl-coach-rules-home" PATH="$PATH" SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_COACH_RULES_DIR\"")
sl_check_same_path "I5: SL_COACH_RULES_DIR matches install.sh's actual coach-rules destination" \
    "/tmp/sl-coach-rules-home/.local/share/agent-learning/scripts/coach-rules" "$OUT"

# --- M13: sl_check_hook_fresh() used an unanchored `grep -qF` for the
# "fresh" check, so a hook pointing at "<script>.bak" (or any other filename
# that merely starts with the resolved scripts_dir/script_name string) read
# as fresh -- the boundary check only looked for the substring, never for
# where it ended. A hook genuinely pointing at the resolved script must
# still read fresh; the fix must only reject the CONTINUATION case, not
# break the real one.
_sl_hookfresh_conf=$(mktemp)
echo '{"command":"bash /store/scripts/turn-counter.sh.bak"}' > "$_sl_hookfresh_conf"
OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_check_hook_fresh '$_sl_hookfresh_conf' 'turn-counter.sh' '/store/scripts'")
check "M13: a hook pointing at <script>.bak is NOT reported fresh" "stale" "$OUT"
rm -f "$_sl_hookfresh_conf"

echo '{"command":"bash /store/scripts/turn-counter.sh"}' > "$_sl_hookfresh_conf"
OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_check_hook_fresh '$_sl_hookfresh_conf' 'turn-counter.sh' '/store/scripts'")
check "M13: an exact hook match still reports fresh" "fresh" "$OUT"
rm -f "$_sl_hookfresh_conf"

echo '{"command":"bash /store/scripts/turn-counter.sh --verbose"}' > "$_sl_hookfresh_conf"
OUT=$(bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; sl_check_hook_fresh '$_sl_hookfresh_conf' 'turn-counter.sh' '/store/scripts'")
check "M13: a hook match followed by a flag (space boundary) still reports fresh" "fresh" "$OUT"
rm -f "$_sl_hookfresh_conf"

# --- The bash fallback must mirror paths.py's Windows branch --------------
#
# When no interpreter can be resolved, config.sh falls back to a bash-side
# mirror of paths.py's override chain. That mirror had no LOCALAPPDATA branch,
# with a comment asserting python3 was a hard dependency on Windows so the
# case could not arise -- exactly backwards: a real Windows box is precisely
# where resolution fails, and there paths.py resolves
# %LOCALAPPDATA%\agent-learning while the fallback resolved
# $HOME/.local/share/agent-learning. Two stores, silently.
#
# Simulated by the two values that only co-exist on Git Bash (LOCALAPPDATA +
# MSYSTEM), on a PATH from which no Python can be resolved.
_sl_nopy_dir="$(mktemp -d)"
for _tool in bash sh grep sed cat printf date mkdir rm mktemp dirname basename; do
    _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
    [[ -n "$_tool_path" ]] && sl_forwarder "$_tool_path" "${_sl_nopy_dir}/${_tool}"
done
_sl_fallback_home_dir="$(mktemp -d)"
# A real directory, not a literal C:/... string: config.sh's degraded-report
# path mkdir's a logs dir under whatever this resolves to, and a bare "C:"
# would be created relative to the CWD on a POSIX box.
_sl_localappdata_dir="$(mktemp -d)"

OUT=$(env -i HOME="$_sl_fallback_home_dir" PATH="$_sl_nopy_dir" \
    LOCALAPPDATA="$_sl_localappdata_dir" MSYSTEM=MINGW64 \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
check "no-python fallback mirrors paths.py's LOCALAPPDATA branch on Windows" \
    "${_sl_localappdata_dir}/agent-learning" "$OUT"

# ...and must NOT take that branch where paths.py would not: paths.py branches
# on sys.platform, so a LOCALAPPDATA leaked into a Linux environment (WSLENV,
# Wine) must not move the store there or the two resolvers disagree again.
OUT=$(env -i HOME="$_sl_fallback_home_dir" PATH="$_sl_nopy_dir" \
    LOCALAPPDATA="$_sl_localappdata_dir" \
    SL_CONFIG_FILE="/nonexistent/x.conf" \
    bash -c "source '${SCRIPT_DIR}/scripts/lib/config.sh'; echo \"\$SL_HOME\"")
check "LOCALAPPDATA without an MSYS marker does NOT move the store" \
    "${_sl_fallback_home_dir}/.local/share/agent-learning" "$OUT"

# The same degradation must be LOUD (hard rule 2): the old code discarded both
# the exit status and the stderr of the paths.py spawn with 2>/dev/null.
check "an unresolvable interpreter is named in persist-failures.log" "yes" \
    "$(grep -q 'python3_unresolvable' \
        "${_sl_localappdata_dir}/agent-learning/logs/persist-failures.log" \
        2>/dev/null && echo yes || echo no)"
rm -rf "$_sl_nopy_dir" "$_sl_fallback_home_dir" "$_sl_localappdata_dir"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All config tests passed."
