#!/usr/bin/env bash
# tests/test-script-paths.sh
#
# Task 7c: self-learning-health.sh, curator-run.sh, and index-session.sh must
# resolve the framework's OWN store (state, skills, logs, sessions db,
# backups, own script dir) through scripts/lib/config.sh / paths.py, never by
# recomputing ${HOME}/.claude internally.
#
# A source grep cannot be the primary assertion here: index-session.sh
# legitimately reads Claude Code's own transcript directory
# (~/.claude/projects) and self-learning-health.sh legitimately reads Claude
# Code's own settings.json (~/.claude/settings.json) — neither of those is
# the framework's store, and a grep cannot distinguish them from an
# illegitimate hardcoded store path. So this test asserts BEHAVIOR under a
# redirected AGENT_LEARNING_HOME (with nothing seeded under ~/.claude except
# the two legitimate Claude-Code-owned artifacts), and uses narrow source
# assertions only to pin exactly those two legitimate exceptions so a future
# edit that reintroduces a hardcoded store path is still caught.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }
# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
STORE="${TMP_HOME}/store"

# --- Minimal, controlled PATH (same rationale as test-install-paths.sh): the
# three scripts under test shell out to mkdir, jq, sqlite3, python3, tar, du,
# grep, sed, date, find, etc. Resolve each explicitly rather than trusting
# /usr/bin:/bin is sufficient on this machine (pyenv shims, Homebrew, ...). ---
_dirs=""
for _tool in mkdir cp chmod sed sqlite3 python3 jq dirname basename date \
             grep tar du cut head stat find cat mv rm printf touch mktemp; do
    _tool_path="$(command -v "$_tool" 2>/dev/null || true)"
    if [[ -z "$_tool_path" ]]; then
        echo "FAIL: test setup is wrong — '$_tool' is not resolvable on this machine"
        FAILURES=$((FAILURES+1))
        continue
    fi
    _tool_dir="$(dirname "$_tool_path")"
    case ":${_dirs}:" in
        *":${_tool_dir}:"*) ;;
        *) _dirs="${_dirs:+${_dirs}:}${_tool_dir}" ;;
    esac
done
if [[ -n "${PYENV_ROOT:-}" ]]; then
    _dirs="${_dirs}:${PYENV_ROOT}/libexec:${PYENV_ROOT}/bin"
fi
MINIMAL_PATH="${_dirs}:/usr/bin:/bin"
for _tool in python3 jq sqlite3; do
    if ! PATH="$MINIMAL_PATH" command -v "$_tool" >/dev/null 2>&1; then
        echo "FAIL: test setup is wrong — $_tool is not resolvable on MINIMAL_PATH"
        FAILURES=$((FAILURES+1))
    fi
done
if [[ "$FAILURES" -gt 0 ]]; then
    echo "Aborting: test harness cannot resolve required tools; not a real red result." >&2
    exit 1
fi

run_env() {
    env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} "$@"
}

# Resolve the store paths the exact same way config.sh/paths.py will, so the
# rest of this test asserts against ground truth rather than a guess.
RESOLVED_STATE="$(run_env python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get state)"
RESOLVED_SKILLS="$(run_env python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get skills)"
RESOLVED_DB="$(run_env python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get sessions_db)"
RESOLVED_LOGS="$(run_env python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get logs)"
RESOLVED_HOME="$(run_env python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get home)"

# Fix round E: compared with sl_check_same_path, not plain string equality
# -- RESOLVED_STATE/SKILLS/DB above crossed a python3.exe subprocess
# boundary (subject to MSYS auto-conversion on Git Bash) while
# "${STORE}/..." never did.
sl_check_same_path "resolved state under store" "${STORE}/state" "$RESOLVED_STATE"
sl_check_same_path "resolved skills under store" "${STORE}/learned-skills" "$RESOLVED_SKILLS"
sl_check_same_path "resolved sessions db under store" "${STORE}/sessions/search.db" "$RESOLVED_DB"

# --- Seed a healthy install purely under STORE. Deliberately create NOTHING
# under ${TMP_HOME}/.claude except the two legitimate Claude-Code-owned
# artifacts (settings.json, projects/) later in this file, so a script that
# still hardcodes ~/.claude for its OWN store would find nothing there and
# visibly fail or silently no-op — exactly the bug this task fixes. ---
mkdir -p "$RESOLVED_STATE" "$RESOLVED_SKILLS" "$(dirname "$RESOLVED_DB")" \
         "${RESOLVED_LOGS}/reviews" "${RESOLVED_LOGS}/curator"
echo '{}' > "${RESOLVED_SKILLS}/.usage.json"

## ============================================================
## self-learning-health.sh
## ============================================================

HEALTH_STATUS=0
HEALTH_OUT="$(run_env bash "${SCRIPT_DIR}/scripts/self-learning-health.sh" 2>&1)" || HEALTH_STATUS=$?

# Vacuity guard: assert on the SPECIFIC resolved store path being reported
# present, not merely on exit code — a script that exits 0 while printing
# FAIL for the store (or one that resolves a different, empty directory and
# reports it "healthy" for the wrong reason) must not pass this.
check "health reports resolved state dir present" "yes" \
    "$(printf '%s' "$HEALTH_OUT" | grep -qF "[PASS] ${RESOLVED_STATE} exists" && echo yes || echo no)"
check "health reports resolved skills dir present" "yes" \
    "$(printf '%s' "$HEALTH_OUT" | grep -qF "[PASS] ${RESOLVED_SKILLS} exists" && echo yes || echo no)"
check "health does not report resolved state dir missing" "0" \
    "$(printf '%s' "$HEALTH_OUT" | grep -cF "${RESOLVED_STATE} missing" || true)"
check "health does not report resolved skills dir missing" "0" \
    "$(printf '%s' "$HEALTH_OUT" | grep -cF "${RESOLVED_SKILLS} missing" || true)"

# The behavioral crux from the review write-up: a freshly-installed,
# correctly-seeded store must be reported HEALTHY (exit 0), not failed for
# every check because the script went looking in ~/.claude instead.
check "health exits 0 (HEALTHY) with store seeded and no ~/.claude store present" "0" "$HEALTH_STATUS"
check "health prints overall HEALTHY status" "yes" \
    "$(printf '%s' "$HEALTH_OUT" | grep -q "^Status: HEALTHY$" && echo yes || echo no)"

# The three framework directories must never be reported via a hardcoded
# ${HOME}/.claude path — that would mean the script resolved the wrong
# location even if it happened to also check the right one.
check "health output never cites state dir under ~/.claude" "0" \
    "$(printf '%s' "$HEALTH_OUT" | grep -c "${TMP_HOME}/.claude/state" || true)"
check "health output never cites skills dir under ~/.claude" "0" \
    "$(printf '%s' "$HEALTH_OUT" | grep -c "${TMP_HOME}/.claude/learned-skills" || true)"
check "health output never cites sessions db under ~/.claude" "0" \
    "$(printf '%s' "$HEALTH_OUT" | grep -c "${TMP_HOME}/.claude/sessions" || true)"

# The Claude-Code-settings.json check is legitimate but must be clearly
# labelled Claude-Code-specific, and its absence (normal on a Copilot-only
# machine) must be a WARN, never a FAIL — a spurious FAIL here would be
# exactly the false-negative UX bug called out in the review.
check "hook registration section is labelled Claude-Code-specific" "yes" \
    "$(printf '%s' "$HEALTH_OUT" | grep -q "Hook Registration (Claude Code)" && echo yes || echo no)"
SETTINGS_LINE="$(printf '%s\n' "$HEALTH_OUT" | grep "settings.json not found" || true)"
check "missing settings.json line exists" "yes" "$([[ -n "$SETTINGS_LINE" ]] && echo yes || echo no)"
check "missing settings.json reported as WARN" "yes" \
    "$(printf '%s' "$SETTINGS_LINE" | grep -q '\[WARN\]' && echo yes || echo no)"
check "missing settings.json never reported as FAIL" "0" \
    "$(printf '%s' "$SETTINGS_LINE" | grep -c '\[FAIL\]' || true)"

# Now the flip side: WITH ~/.claude/settings.json present (Claude Code IS
# installed), the check must still correctly detect registered hooks there —
# proving this is a real, working check and not merely disabled.
#
# The hook commands below MUST point at the actual resolved scripts dir
# (${STORE}/scripts), not a placeholder path: self-learning-health.sh now
# shares sl_check_hook_fresh() with scripts/doctor.sh (Task 9 fix round 1),
# which verifies the hook command points at the currently-resolved scripts
# directory, not merely that the script's name appears somewhere in the
# file. A placeholder path here would (correctly) read as STALE.
# Fix round E: RESOLVED_SCRIPTS used to be a bash-literal "${STORE}/scripts"
# concatenation, compared textually (via sl_check_hook_fresh) against what
# self-learning-health.sh independently resolves via python3 -- resolve it
# through the same tool instead so the fixture cannot be spelled
# differently from what the product will compute.
RESOLVED_SCRIPTS="$(run_env python3 "${SCRIPT_DIR}/scripts/lib/paths.py" get scripts)"
mkdir -p "${TMP_HOME}/.claude"
cat > "${TMP_HOME}/.claude/settings.json" <<EOF
{"hooks":{"PostToolUse":[{"hooks":[{"command":"bash ${RESOLVED_SCRIPTS}/turn-counter.sh"}]}],
"Stop":[{"hooks":[{"command":"bash ${RESOLVED_SCRIPTS}/session-review.sh"}]},
        {"hooks":[{"command":"bash ${RESOLVED_SCRIPTS}/index-session.sh"}]}]}}
EOF
HEALTH_OUT2="$(run_env bash "${SCRIPT_DIR}/scripts/self-learning-health.sh" 2>&1)" || true
check "with settings.json present, turn-counter hook detected" "yes" \
    "$(printf '%s' "$HEALTH_OUT2" | grep -qF "[PASS] PostToolUse turn-counter hook registered" && echo yes || echo no)"

## ============================================================
## curator-run.sh
## ============================================================

CURATOR_OUT="$(run_env bash "${SCRIPT_DIR}/scripts/curator-run.sh" 2>&1)" || true

check "curator created backup dir under store (matches install.sh's SL_HOME/backups/curator)" "yes" \
    "$([[ -d "${STORE}/backups/curator" ]] && echo yes || echo no)"
check "curator did NOT create a backup dir under ~/.claude" "no" \
    "$([[ -d "${TMP_HOME}/.claude/backups" ]] && echo yes || echo no)"

REPORT_FILE="${RESOLVED_LOGS}/curator/$(date +%Y-%m-%d)-curator-report.md"
check "curator report written under resolved store logs" "yes" \
    "$([[ -f "$REPORT_FILE" ]] && echo yes || echo no)"
if [[ -f "$REPORT_FILE" ]]; then
    check "curator report cites the resolved (store) skills dir" "yes" \
        "$(grep -qF "$RESOLVED_SKILLS" "$REPORT_FILE" && echo yes || echo no)"
    check "curator report never cites a skills dir under ~/.claude" "0" \
        "$(grep -c "${TMP_HOME}/.claude/learned-skills" "$REPORT_FILE" || true)"
fi
check "curator output never mentions ~/.claude" "0" \
    "$(printf '%s' "$CURATOR_OUT" | grep -c '\.claude' || true)"

## ============================================================
## index-session.sh
## ============================================================
#
# SESSIONS_DIR (${HOME}/.claude/projects) is Claude Code's own transcript
# source and must be left exactly as-is — only DB_PATH (the framework's own
# search index) must move under the resolved store. Build a minimal
# "installed" layout (index-session.sh needs session-search-schema.sql as a
# sibling, which install.sh copies from schema/ at install time but which
# does not live next to the script in the source tree) so this exercises the
# real end-to-end behavior rather than a schema-missing no-op.

IDX_SCRIPTS="$(mktemp -d)"
mkdir -p "${IDX_SCRIPTS}/lib"
cp "${SCRIPT_DIR}/scripts/index-session.sh" "${SCRIPT_DIR}/scripts/index-session.py" "$IDX_SCRIPTS/"
cp "${SCRIPT_DIR}/scripts/lib/config.sh" "${SCRIPT_DIR}/scripts/lib/paths.py" \
   "${SCRIPT_DIR}/scripts/lib/isotime.py" "${SCRIPT_DIR}/scripts/lib/list-transcripts.py" \
   "${SCRIPT_DIR}/scripts/lib/session_db.py" "${IDX_SCRIPTS}/lib/"
cp "${SCRIPT_DIR}/schema/session-search-schema.sql" \
   "${SCRIPT_DIR}/schema/session-search-fts5.sql" "$IDX_SCRIPTS/"
chmod +x "${IDX_SCRIPTS}/index-session.sh"

mkdir -p "${TMP_HOME}/.claude/projects/demo-project"

run_idx() {
    env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} bash "${IDX_SCRIPTS}/index-session.sh"
}

# First run: only creates/initializes the DB (nothing newer than the
# just-created DB file yet). This mirrors real first-run behavior.
run_idx >/dev/null 2>&1 || true

check "index-session created the DB under the resolved store" "yes" \
    "$([[ -f "$RESOLVED_DB" ]] && echo yes || echo no)"
check "index-session did NOT create a DB under ~/.claude" "no" \
    "$([[ -e "${TMP_HOME}/.claude/sessions" ]] && echo yes || echo no)"

# Now add a session transcript newer than the DB and re-run; it must be
# found via the untouched, legitimate SESSIONS_DIR and indexed into the
# resolved (store) DB — proving both halves of the distinction at once.
sleep 1.2
cat > "${TMP_HOME}/.claude/projects/demo-project/sess-abc123.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hello from a real Claude Code session"},"timestamp":"2026-01-01T00:00:00Z"}
EOF

IDX_OUT="$(run_idx 2>&1)" || true

check "index-session indexed the session found via ~/.claude/projects" "1" \
    "$(run_env sqlite3 "$RESOLVED_DB" "SELECT count(*) FROM sessions WHERE session_id='sess-abc123'" 2>/dev/null || echo ERROR)"

rm -rf "$IDX_SCRIPTS"

## ============================================================
## Narrow source assertions — ONLY for the specific, individually-named
## legitimate exceptions.
## A grep cannot be the primary assertion (see file header), but pinning
## exactly these known-legitimate lines means a future edit that
## reintroduces a hardcoded FRAMEWORK path elsewhere is still caught, because
## any such addition would push these counts above the pinned total.
## ============================================================

check "curator-run.sh has zero ~/.claude references (no legitimate exception exists there)" "0" \
    "$(grep -c '\.claude' "${SCRIPT_DIR}/scripts/curator-run.sh" || true)"
check "index-session.sh has exactly one ~/.claude reference (SESSIONS_DIR, the legitimate source)" "1" \
    "$(grep -c '\${HOME}/\.claude' "${SCRIPT_DIR}/scripts/index-session.sh" || true)"
check "index-session.sh's lone ~/.claude reference is the SESSIONS_DIR line" "yes" \
    "$(grep -qF 'SESSIONS_DIR="${HOME}/.claude/projects"' "${SCRIPT_DIR}/scripts/index-session.sh" && echo yes || echo no)"
check "self-learning-health.sh has exactly one \${HOME}/.claude reference (SETTINGS_FILE, the legitimate source)" "1" \
    "$(grep -c '\${HOME}/\.claude' "${SCRIPT_DIR}/scripts/self-learning-health.sh" || true)"
check "self-learning-health.sh's lone \${HOME}/.claude reference is the SETTINGS_FILE line" "yes" \
    "$(grep -qF 'SETTINGS_FILE="${HOME}/.claude/settings.json"' "${SCRIPT_DIR}/scripts/self-learning-health.sh" && echo yes || echo no)"

## ============================================================
## I11: repo-wide guard over ALL of scripts/**, not just the three files
## above. Python scripts were never in scope before this -- exactly how C2
## (skill-lifecycle.py hardcoding ~/.claude/learned-skills) and the
## inject-agents-md.py fallback both survived to the final review despite
## this exact test file existing. Every legitimate hit is named and
## justified individually, in the style of test-install-paths.sh's
## INSTALL_EXEMPTIONS -- an un-exempted new hit anywhere under scripts/
## fails this test, forcing a conscious decision instead of a silent
## reintroduction.
##
## Two patterns, one per language. Fix round D, blocker (c): the ORIGINAL
## patterns here (bash: literal `${HOME}/.claude`; python: literal `".claude"`
## in double quotes) were mutation-tested against six representative
## real-world-shaped injections and MISSED THREE of them, including one that
## is VERBATIM the pre-fix C2 line (`os.path.expanduser("~/.claude/...")`,
## `git show f11a870:scripts/skill-lifecycle.py` line 37) -- a guard that
## would not have caught the bug it exists for is not a guard. Widened to:
##   python: \.claude           -- ANY literal ".claude" path segment,
##           single- or double-quoted, bare or inside expanduser/join/etc.
##           Prose false positives (there is a lot of it, by design -- this
##           whole file's premise is documenting why code must not go there)
##           are handled the same way a real legitimate hit is: named and
##           justified in PY_CLAUDE_EXEMPTIONS below, not filtered out by a
##           narrower regex that can also filter out a real bug.
##   bash:   \$\{?HOME\}?/\.claude   (braced OR unbraced $HOME/.claude) PLUS
##           a bare ~/.claude on any line that is not ENTIRELY a comment
##           (so `# see ~/.claude for details` is not flagged, but
##           `BAD=~/.claude/x` -- real code, no leading #      -- is).
##
## No associative arrays or namerefs (bash 3.2 on stock macOS lacks both) --
## "path|reason" pairs in plain indexed arrays, same convention as
## test-install-paths.sh's INSTALL_EXEMPTIONS.
## ============================================================

BASH_CLAUDE_EXEMPTIONS=(
    "scripts/index-session.sh|SESSIONS_DIR: Claude Code's own transcript source (~/.claude/projects), read-only, never the framework's own store"
    "scripts/self-learning-health.sh|SETTINGS_FILE: Claude Code's own hook-registration file (~/.claude/settings.json), read-only diagnostic input; remaining hits are prose (warning/help text) describing that same legitimate reference, not additional store paths"
    "scripts/doctor.sh|CLAUDE_SETTINGS: same as self-learning-health.sh's SETTINGS_FILE -- Claude Code's own hook-registration file, read-only, gated behind 'command -v claude'; remaining hits are prose (the file's own no-~/.claude rule statement, legacy-store detection messages) describing that rule and the read-only legacy_home() detection below, not additional store paths"
    "scripts/lib/config.sh|prose only (two comments stating the vendor-neutral-defaults rule itself: 'may not point inside ~/.claude', 'never reintroducing ~/.claude'); no code path in this file constructs a ~/.claude path"
)
PY_CLAUDE_EXEMPTIONS=(
    "scripts/lib/paths.py|legacy_home(): DETECT ONLY the pre-neutral ~/.claude store so doctor.sh can tell the user it exists and how to migrate; never read from or written to as the framework's own store. Remaining hits are prose (module/function docstrings stating the same never-default-into-~/.claude rule)"
    "scripts/coach-signals.py|prose only (a docstring describing a fallback that must NOT default into ~/.claude); no code path in this file constructs a ~/.claude path"
    "scripts/inject-agents-md.py|prose only (comments describing why this file must not hardcode ~/.claude and does not have one); no code path in this file constructs a ~/.claude path"
    "scripts/skill-lifecycle.py|prose only (docstring for _default_skills_dir describing the pre-fix C2 bug this function replaced, entirely in the past tense); the function itself resolves via SL_SKILLS_DIR/CLAUDE_LEARNED_SKILLS_DIR/paths.py, never a literal ~/.claude"
    "scripts/lib/telemetry.py|_claude_projects_root(): resolves Claude Code's OWN transcript directory (~/.claude/projects) as a READ-ONLY telemetry source for the Coach rules, exactly the same category as index-session.sh's SESSIONS_DIR. It is never the framework's own store: nothing here writes, and the framework's own paths still come from lib/paths.py. Harness neutrality is preserved by construction -- the Copilot source is resolved and read entirely independently (see _copilot_event_files/_copilot_store_db), and a missing Claude directory yields an empty list rather than an error, so the Copilot-only path never touches this function's result. tests/test-claude-absent.sh remains the regression guard"
    "scripts/lib/transcript.py|P0b module docstring documents Claude Code's OWN transcript location (~/.claude/projects/<project-slug>/<sessionId>.jsonl) as background for build_claude_session_digest(); no code path in this file constructs that path itself -- session-review.sh hands transcript_path in directly from the Stop hook payload (same read-only, hook-supplied category as index-session.sh's SESSIONS_DIR), and this module never resolves it, defaults into it, or writes to it"
)

bash_claude_exempt_reason() {
    local name="$1" entry
    for entry in "${BASH_CLAUDE_EXEMPTIONS[@]}"; do
        case "$entry" in
            "${name}|"*) printf '%s' "${entry#*|}"; return 0 ;;
        esac
    done
    return 1
}
py_claude_exempt_reason() {
    local name="$1" entry
    for entry in "${PY_CLAUDE_EXEMPTIONS[@]}"; do
        case "$entry" in
            "${name}|"*) printf '%s' "${entry#*|}"; return 0 ;;
        esac
    done
    return 1
}

for f in $(find "${SCRIPT_DIR}/scripts" -name '*.sh' | sort); do
    rel="scripts/$(printf '%s' "$f" | sed "s|^${SCRIPT_DIR}/scripts/||")"
    home_count="$(grep -cE '\$\{?HOME\}?/\.claude' "$f" || true)"
    # Bare-tilde form used as a real path expression somewhere in this
    # file's CODE, not merely in a comment. Excludes only lines that are
    # ENTIRELY a comment (first non-whitespace char is '#'); a bare-tilde
    # hit on a real code line is a hit regardless of any trailing comment.
    tilde_count="$(grep -vE '^[[:space:]]*#' "$f" | grep -cE '~/\.claude' || true)"
    count=$((home_count + tilde_count))
    if [[ "$count" -eq 0 ]]; then
        echo "PASS: $rel has no \${HOME}/.claude or bare ~/.claude code reference"
    elif reason="$(bash_claude_exempt_reason "$rel")"; then
        echo "PASS: $rel has a \${HOME}/.claude or ~/.claude reference, exempted ($reason)"
    else
        echo "FAIL: $rel has an un-exempted \${HOME}/.claude or ~/.claude reference -- add it to BASH_CLAUDE_EXEMPTIONS in this test with a reason, or fix it"
        FAILURES=$((FAILURES+1))
    fi
done

for f in $(find "${SCRIPT_DIR}/scripts" -name '*.py' -not -path '*/__pycache__/*' | sort); do
    rel="scripts/$(printf '%s' "$f" | sed "s|^${SCRIPT_DIR}/scripts/||")"
    count="$(grep -c '\.claude' "$f" || true)"
    if [[ "$count" -eq 0 ]]; then
        echo "PASS: $rel has no \".claude\" reference"
    elif reason="$(py_claude_exempt_reason "$rel")"; then
        echo "PASS: $rel has a \".claude\" reference, exempted ($reason)"
    else
        echo "FAIL: $rel has an un-exempted \".claude\" reference -- add it to PY_CLAUDE_EXEMPTIONS in this test with a reason, or fix it"
        FAILURES=$((FAILURES+1))
    fi
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "--- self-learning-health.sh output (seeded store, no ~/.claude) ---"
    printf '%s\n' "$HEALTH_OUT"
    echo "--- curator-run.sh output ---"
    printf '%s\n' "$CURATOR_OUT"
    echo "--- index-session.sh output (second run) ---"
    printf '%s\n' "${IDX_OUT:-}"
    exit 1
fi
echo "All script-paths tests passed."
