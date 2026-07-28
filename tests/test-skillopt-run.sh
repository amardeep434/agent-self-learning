#!/usr/bin/env bash
# tests/test-skillopt-run.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SL_CONFIG_FILE="/nonexistent"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# Fake SkillOpt checkout whose run-sleep.sh just echoes its args
mkdir -p "$TMP/skillopt/plugins" "$TMP/skillopt/skillopt_sleep"
cat > "$TMP/skillopt/plugins/run-sleep.sh" <<'EOF'
#!/usr/bin/env bash
echo "RUNSLEEP:$*"
EOF
chmod +x "$TMP/skillopt/plugins/run-sleep.sh"

# A directory that exists but is NOT a repo root (the "off by one directory"
# mistake: pointing at plugins/ instead of the root).
mkdir -p "$TMP/not-a-repo"

# Fake installed `skillopt-sleep` CLI, in a bin dir we add to PATH ONLY for the
# cases that are about the pip route.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/skillopt-sleep" <<'EOF'
#!/usr/bin/env bash
echo "PIPCLI:$*"
EOF
chmod +x "$TMP/bin/skillopt-sleep"

# PATH scrubbing. The wrapper now falls back to whatever `skillopt-sleep` is on
# PATH, so every "nothing installed" assertion below becomes a statement about
# the DEVELOPER'S machine unless PATH is controlled. Measured: with a real
# skillopt-sleep installed, two of these cases flip from "explains" to "ran the
# user's real Sleep engine". CLEAN_PATH keeps only the standard system dirs
# (bash/command still resolve) and deliberately excludes $TMP/bin; CLI_PATH is
# CLEAN_PATH plus the fake CLI. Neither ever contains a real installation.
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
CLI_PATH="$TMP/bin:$CLEAN_PATH"

# Guard the guard: if a real skillopt-sleep is reachable from CLEAN_PATH the
# scrub is not doing its job, and the "nothing installed" cases below would be
# silently testing something else. Fail loudly rather than pass vacuously.
if PATH="$CLEAN_PATH" command -v skillopt-sleep >/dev/null 2>&1; then
    echo "FAIL: CLEAN_PATH still resolves skillopt-sleep -- the PATH scrub is ineffective"
    exit 1
fi

# $1 = PATH to run under; rest = wrapper args.
run_with_path() { local p="$1"; shift; PATH="$p" bash "${SCRIPT_DIR}/scripts/skillopt-run.sh" "$@" 2>"$TMP/err"; }
run() { run_with_path "$CLEAN_PATH" "$@"; }

# 1) Disabled by default: no-op, exit 0, nothing passed through
OUT=$(SL_SKILLOPT_ENABLED=false run status || echo "EXIT$?")
check "disabled is no-op" "" "$OUT"
check "disabled notes reason" "yes" "$(grep -q 'disabled' "$TMP/err" && echo yes || echo no)"

# 1b) A non-"true" value must be quoted back accurately, not reported as false.
OUT=$(SL_SKILLOPT_ENABLED=1 run status || echo "EXIT$?")
check "disabled-by-other-value is no-op" "" "$OUT"
check "disabled names the actual value" "yes" "$(grep -q "SL_SKILLOPT_ENABLED='1'" "$TMP/err" && echo yes || echo no)"
check "disabled does not claim 'false'" "no" "$(grep -q "SL_SKILLOPT_ENABLED=false" "$TMP/err" && echo yes || echo no)"

# 2) Enabled, nothing installed at all: graceful stderr, exit 0
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="" run status || echo "EXIT$?")
check "enabled+nothing-installed exit 0" "" "$OUT"
check "enabled+nothing-installed names unset repo" "yes" "$(grep -q 'SL_SKILLOPT_REPO is unset' "$TMP/err" && echo yes || echo no)"
check "enabled+nothing-installed names missing CLI" "yes" "$(grep -q "no 'skillopt-sleep' on PATH" "$TMP/err" && echo yes || echo no)"
check "enabled+nothing-installed suggests pip" "yes" "$(grep -q 'pip install skillopt' "$TMP/err" && echo yes || echo no)"

# 3) Enabled + repo: cheap verb passes through
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" run harvest --since 1d)
check "harvest passes through" "RUNSLEEP:harvest --since 1d" "$OUT"

# 4) 'run' blocked unless confirmed
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" SL_SKILLOPT_RUN_CONFIRMED=false run run || echo "EXIT$?")
check "run blocked without confirm" "" "$OUT"
check "run block explains gate" "yes" "$(grep -q 'SL_SKILLOPT_RUN_CONFIRMED' "$TMP/err" && echo yes || echo no)"

# 5) 'run' allowed when confirmed
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" SL_SKILLOPT_RUN_CONFIRMED=true run run)
check "run passes when confirmed" "RUNSLEEP:run" "$OUT"

# --- The pip route (upstream's own fallback) --------------------------------

# 6) No checkout, but `skillopt-sleep` on PATH: the wrapper must USE it. Before
#    this, a `pip install skillopt` user got a silent exit 0 and nothing else.
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="" run_with_path "$CLI_PATH" harvest --since 1d)
check "pip CLI used when no checkout" "PIPCLI:harvest --since 1d" "$OUT"

# 7) The confirm gate must apply to the pip route too, not just the checkout.
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="" SL_SKILLOPT_RUN_CONFIRMED=false run_with_path "$CLI_PATH" run || echo "EXIT$?")
check "pip CLI run blocked without confirm" "" "$OUT"
check "pip CLI run block explains gate" "yes" "$(grep -q 'SL_SKILLOPT_RUN_CONFIRMED' "$TMP/err" && echo yes || echo no)"
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="" SL_SKILLOPT_RUN_CONFIRMED=true run_with_path "$CLI_PATH" run)
check "pip CLI run passes when confirmed" "PIPCLI:run" "$OUT"

# 8) Upstream's precedence: a checkout OUTRANKS the installed CLI, because a
#    clone of main can be ahead of the published package.
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/skillopt" run_with_path "$CLI_PATH" status)
check "checkout outranks pip CLI" "RUNSLEEP:status" "$OUT"

# --- Each misconfiguration must be distinguishable and name its value -------

# 9) A path that does not exist at all.
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/ghost" run status || echo "EXIT$?")
check "nonexistent repo exit 0" "" "$OUT"
check "nonexistent repo names the path" "yes" "$(grep -qF "SL_SKILLOPT_REPO='$TMP/ghost' does not exist" "$TMP/err" && echo yes || echo no)"

# 10) A real directory that is not a repo root (off by one directory).
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/not-a-repo" run status || echo "EXIT$?")
check "wrong-dir repo exit 0" "" "$OUT"
check "wrong-dir repo names the path" "yes" "$(grep -qF "SL_SKILLOPT_REPO='$TMP/not-a-repo' has no plugins/run-sleep.sh" "$TMP/err" && echo yes || echo no)"
check "wrong-dir repo names the file it looked for" "yes" "$(grep -qF "$TMP/not-a-repo/plugins/run-sleep.sh" "$TMP/err" && echo yes || echo no)"

# 11) A path that exists but is a FILE, not a directory.
: > "$TMP/repo-is-a-file"
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/repo-is-a-file" run status || echo "EXIT$?")
check "file-as-repo names the path" "yes" "$(grep -qF "SL_SKILLOPT_REPO='$TMP/repo-is-a-file' is not a directory" "$TMP/err" && echo yes || echo no)"

# 12) The three misconfigurations must not share one byte-identical message --
#     that was the original defect, and comparing them is the only way to keep
#     a future edit from collapsing them back together.
E_UNSET=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="" run status 2>/dev/null; cat "$TMP/err")
E_GHOST=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/ghost" run status 2>/dev/null; cat "$TMP/err")
E_WRONG=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/not-a-repo" run status 2>/dev/null; cat "$TMP/err")
check "unset vs nonexistent differ" "differ" "$([[ "$E_UNSET" != "$E_GHOST" ]] && echo differ || echo same)"
check "nonexistent vs wrong-dir differ" "differ" "$([[ "$E_GHOST" != "$E_WRONG" ]] && echo differ || echo same)"
check "unset vs wrong-dir differ" "differ" "$([[ "$E_UNSET" != "$E_WRONG" ]] && echo differ || echo same)"

# 13) A bad SL_SKILLOPT_REPO must not veto a working pip install: warn about the
#     checkout, then still run. Silently skipping would be the original defect.
OUT=$(SL_SKILLOPT_ENABLED=true SL_SKILLOPT_REPO="$TMP/ghost" run_with_path "$CLI_PATH" status)
check "bad repo falls back to pip CLI" "PIPCLI:status" "$OUT"
check "bad repo still warns while falling back" "yes" "$(grep -qF "SL_SKILLOPT_REPO='$TMP/ghost' does not exist" "$TMP/err" && echo yes || echo no)"

if [[ "$FAILURES" -gt 0 ]]; then exit 1; fi
echo "All skillopt-run tests passed."
