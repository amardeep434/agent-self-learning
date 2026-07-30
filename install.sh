#!/usr/bin/env bash
#
# One-command installer for the agent-self-learning system.
#
# Creates directories, copies scripts, initializes the SQLite database,
# and prints instructions for registering hooks with each harness.
#
# Usage:
#   bash install.sh              # Install everything
#   bash install.sh --dry-run    # Preview what would be done
#   bash install.sh --uninstall  # Remove installed files (delegates to uninstall.sh)
#
# Prerequisites:
#   - jq, python3 must be installed
#   - sqlite3 (the CLI) is optional: fix-p6 moved session-search schema
#     init off the CLI and onto python3's own bundled sqlite3 module (which
#     macOS's system CLI often lacks FTS5 support for, unlike Python's), so
#     nothing in this script shells out to the `sqlite3` binary anymore.
#     Only self-learning-health.sh's diagnostic DB check still uses it,
#     already gracefully degrading (a warning, not a failure) if absent.
#
# Install locations are resolved by scripts/lib/paths.py (vendor-neutral;
# never inside ~/.claude by default). Claude Code and GitHub Copilot CLI are
# adapters on top of that shared store, never a dependency of it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --uninstall)
            if [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]; then
                exec bash "${SCRIPT_DIR}/uninstall.sh"
            else
                echo "Error: uninstall.sh not found" >&2
                exit 1
            fi
            ;;
        --help|-h)
            echo "Usage: bash install.sh [--dry-run | --uninstall]"
            echo ""
            echo "  --dry-run    Preview what would be done without making changes"
            echo "  --uninstall  Remove installed files (delegates to uninstall.sh)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# --- Helpers ---

do_mkdir() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] mkdir -p $1"
    else
        mkdir -p "$1"
        echo "  Created: $1"
    fi
}

do_copy() {
    local src="$1"
    local dst="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] cp $src -> $dst"
    else
        cp "$src" "$dst"
        echo "  Copied:  $(basename "$src") -> $dst"
    fi
}

do_chmod() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] chmod +x $1"
    else
        chmod +x "$1"
    fi
}

# --- Preflight checks ---

echo "=== agent-self-learning Installer ==="
echo ""

MISSING_DEPS=()
for cmd in jq python3; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "Error: Missing required dependencies: ${MISSING_DEPS[*]}" >&2
    echo "Install them before running this script." >&2
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN MODE -- no changes will be made]"
    echo ""
fi

# --- Resolve every install path exactly once, through paths.py ---
#
# Global constraint: paths are computed in exactly one place
# (scripts/lib/paths.py). Bash obtains paths by calling it, once, here — never
# by recomputing them or calling paths.py in a loop.

PATHS_PY="${SCRIPT_DIR}/scripts/lib/paths.py"
if [[ ! -f "$PATHS_PY" ]]; then
    echo "Error: ${PATHS_PY} not found" >&2
    exit 1
fi

SL_HOME="" SL_STATE="" SL_SKILLS="" SL_MEMORY="" SL_LOGS="" \
SL_SESSIONS_DB="" SL_CONFIG_FILE="" SL_SCRIPTS=""
while IFS='=' read -r _sl_key _sl_val; do
    # Fix round E, defence in depth: see scripts/lib/config.sh's identical
    # strip for the full rationale -- paths.py's stdout is now forced to
    # LF-only, making this a no-op in practice, but `read` never strips a
    # \r that isn't the record terminator itself, so this stays as a cheap
    # second layer against a stray one corrupting every resolved path.
    _sl_val="${_sl_val%$'\r'}"
    case "$_sl_key" in
        home)        SL_HOME="$_sl_val" ;;
        state)       SL_STATE="$_sl_val" ;;
        skills)      SL_SKILLS="$_sl_val" ;;
        memory)      SL_MEMORY="$_sl_val" ;;
        logs)        SL_LOGS="$_sl_val" ;;
        sessions_db) SL_SESSIONS_DB="$_sl_val" ;;
        config_file) SL_CONFIG_FILE="$_sl_val" ;;
        scripts)     SL_SCRIPTS="$_sl_val" ;;
    esac
done < <(python3 "$PATHS_PY" all)

if [[ -z "$SL_HOME" || -z "$SL_SCRIPTS" ]]; then
    echo "Error: could not resolve install paths via ${PATHS_PY}" >&2
    exit 1
fi

# --- The ONE hook-template render, used by all five sites below ---
#
# Every hook template carries `__SL_SCRIPTS_DIR__` where $SL_SCRIPTS belongs,
# and this file renders that in five places: writing the Copilot hook file,
# comparing against the on-disk one to decide "up to date", printing the
# ACTION REQUIRED block, and rendering the VS Code and Claude Code JSON.
# README.md documents a sixth for users rendering by hand.
#
# That used to be five copies of
# `sed "s|__SL_SCRIPTS_DIR__|${SL_SCRIPTS}|g"`, which interpolates the store
# path UNESCAPED into sed's expression language. Measured end to end through
# this script: a store under `/home/u/R&D/...` rendered
# `/home/u/R__SL_SCRIPTS_DIR__D/...` and exited 0; `c\d` rendered as `cd` and
# exited 0; `a|b` closed sed's own delimiter and aborted the install
# half-done. The first two are the signature defect this project exists to
# eliminate -- a hook file that is valid JSON, names a path that does not
# exist, and is reported as installed.
#
# lib/render-template.py is a literal (metacharacter-free) replacement and
# carries the full rationale. One definition, not five, so a sixth site
# cannot drift: see tests/test-hook-template-render.sh.
RENDER_TEMPLATE_PY="${SCRIPT_DIR}/scripts/lib/render-template.py"
if [[ ! -f "$RENDER_TEMPLATE_PY" ]]; then
    echo "Error: ${RENDER_TEMPLATE_PY} not found" >&2
    exit 1
fi

# $SL_SCRIPTS goes in on STDIN, never as an argument. python3 is a NATIVE
# Windows binary under Git Bash (sed was an MSYS one), so MSYS auto-converts
# POSIX-looking argv values crossing into it: passing it as argv rewrote
# `/c/Users/.../scripts` to `C:/Users/.../scripts` in the rendered hook file.
# Both name the same directory, but sl_check_hook_fresh() in lib/config.sh
# compares that command TEXTUALLY against the resolved scripts dir, so the
# changed spelling makes a correctly-installed hook look stale forever.
# Caught by windows-latest CI, on tests/test-install-paths.sh. An env var
# would be converted too; see render-template.py for why the per-process
# suppression switches are not an option either.
render_hook_template() {
    printf '%s' "$SL_SCRIPTS" | python3 "$RENDER_TEMPLATE_PY" "$1"
}

# The inverse: strip whatever install location a rendered hook file names back
# to the template's placeholder, so Step 4b can tell "ours, installed
# elsewhere" from "ours, edited". See lib/normalize-hook-path.py for why this
# is a scan and not a sed character class, and tests/test-copilot-hook-normalize.sh
# for the cases that pinned it. Only the file path crosses into python3 here;
# the script name is a bare basename, so MSYS has nothing to convert.
NORMALIZE_HOOK_PY="${SCRIPT_DIR}/scripts/lib/normalize-hook-path.py"
if [[ ! -f "$NORMALIZE_HOOK_PY" ]]; then
    echo "Error: ${NORMALIZE_HOOK_PY} not found" >&2
    exit 1
fi
# "$@", not "$1" "$2": the stale branch below calls this with a leading
# --print-path to ask the same scan for the directory it would have rewritten,
# rather than matching the path a second time with an expression of its own.
normalize_hook_path() {
    python3 "$NORMALIZE_HOOK_PY" "$@"
}

echo "Install target (resolved by paths.py): ${SL_HOME}"
echo ""

# Legacy-install detection (design decision 4): preserve-and-notify, never
# migrate. This only reads ~/.claude to decide whether to print a note; it
# never writes to or moves anything under it.
# fix-p6: the lib directory used to be baked into the -c source string as
# a bash-interpolated literal (`sys.path.insert(0, '${SCRIPT_DIR}/...')`).
# Git Bash only auto-translates POSIX-style paths to Windows form when they
# appear as their own argv token passed to a native executable, not when
# baked into the middle of a quoted -c string -- passed as sys.argv[1]
# instead, the same safe pattern doctor.sh's own legacy-home probe and
# tests/lib/path-compare.sh's sl_legacy_home already use.
LEGACY_HOME="$(python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import paths
found = paths.legacy_home()
print(found or '')
" "${SCRIPT_DIR}/scripts/lib" 2>/dev/null || true)"

if [[ -n "$LEGACY_HOME" ]]; then
    echo "NOTE: a legacy install was found at ${LEGACY_HOME}."
    echo "      It is left untouched and will keep working as-is."
    echo "      This install writes to the vendor-neutral store above instead;"
    echo "      the two are independent until you migrate deliberately."
    echo ""
fi

# --- Step 1: Create directories ---

echo "Step 1: Creating directories..."

DIRS=(
    "$SL_STATE"
    "$SL_SKILLS"
    "${SL_SKILLS}/.archive"
    "$(dirname "$SL_SESSIONS_DB")"
    "${SL_LOGS}/reviews"
    "${SL_LOGS}/curator"
    "${SL_HOME}/backups/curator"
    "$SL_SCRIPTS"
    "${SL_SCRIPTS}/prompts"
    "$SL_MEMORY"
)

for dir in "${DIRS[@]}"; do
    do_mkdir "$dir"
done

echo ""

# --- Step 2: Copy scripts ---

echo "Step 2: Copying scripts..."

SCRIPTS=(
    "turn-counter.sh"
    "session-review.sh"
    "index-session.sh"
    "index-session.py"
    "scan-threats.py"
    "skill-lifecycle.py"
    "curator-run.sh"
    "self-learning-health.sh"
    "copilot-session-review.sh"
    "vscode-session-review.sh"
    "inject-agents-md.py"
    "session-start-context.py"
    "session-start-context.sh"
    "coach-rules-eval.py"
    "coach-export-read.py"
    "coach-signals.py"
    "skillopt-run.sh"
    "persist-proposal.py"
    "doctor.sh"
)

DEST_DIR="$SL_SCRIPTS"

for script in "${SCRIPTS[@]}"; do
    src="${SCRIPT_DIR}/scripts/${script}"
    if [[ -f "$src" ]]; then
        do_copy "$src" "${DEST_DIR}/${script}"
        do_chmod "${DEST_DIR}/${script}"
    else
        # M14: this used to print a [WARN] and continue, exiting 0 -- a
        # missing script (potentially the writer itself, or something it
        # imports) became a warning buried in a long log plus a successful
        # exit. A script named in this file's own SCRIPTS array that is
        # missing from the source tree means the install is broken; report
        # that as fatal, not cosmetic.
        echo "  [FAIL] Script not found: $src" >&2
        echo "Error: install.sh's SCRIPTS array names '${script}', but it does not exist" >&2
        echo "at ${src}. This install is incomplete; refusing to continue." >&2
        exit 1
    fi
done

echo ""
echo "Step 2b: Copying shared libraries..."
do_mkdir "${DEST_DIR}/lib"
for lib in "${SCRIPT_DIR}/scripts/lib/"*.sh; do
    if [[ -f "$lib" ]]; then
        do_copy "$lib" "${DEST_DIR}/lib/$(basename "$lib")"
    fi
done
# Python libraries too (e.g. paths.py, proposal_schema.py) — a loop, not a
# hand-listed file, so a future library is never silently dropped the way
# proposal_schema.py originally was: persist-proposal.py (in SCRIPTS above)
# imports it from its own installed directory's lib/, and a missing import
# fails the whole persistence pipeline on a real install with no error
# surfaced above the hook layer — exactly the defect this project exists to
# eliminate.
for lib in "${SCRIPT_DIR}/scripts/lib/"*.py; do
    if [[ -f "$lib" ]]; then
        do_copy "$lib" "${DEST_DIR}/lib/$(basename "$lib")"
    fi
done

echo ""

# --- Step 3: Copy prompts (if present) ---

echo "Step 3: Copying prompt templates..."

PROMPTS_SRC="${SCRIPT_DIR}/prompts"
PROMPTS_DST="${DEST_DIR}/prompts"

if [[ -d "$PROMPTS_SRC" ]]; then
    PROMPT_COUNT=0
    for prompt_file in "${PROMPTS_SRC}"/*.md; do
        if [[ -f "$prompt_file" ]]; then
            do_copy "$prompt_file" "${PROMPTS_DST}/$(basename "$prompt_file")"
            PROMPT_COUNT=$((PROMPT_COUNT + 1))
        fi
    done
    if [[ "$PROMPT_COUNT" -eq 0 ]]; then
        echo "  No prompt templates found in ${PROMPTS_SRC}/"
    fi
else
    echo "  No prompts/ directory found (optional)"
fi

echo ""

# --- Step 3b: Copy vendored Coach rules (if present) ---

echo "Step 3b: Copying vendored Coach rules..."

COACH_RULES_SRC="${SCRIPT_DIR}/vendor/coach-rules"
COACH_RULES_DST="${DEST_DIR}/coach-rules"

if [[ -d "$COACH_RULES_SRC" ]]; then
    do_mkdir "$COACH_RULES_DST"
    COACH_RULE_COUNT=0
    for rule_file in "${COACH_RULES_SRC}"/*.md; do
        if [[ -f "$rule_file" ]]; then
            do_copy "$rule_file" "${COACH_RULES_DST}/$(basename "$rule_file")"
            COACH_RULE_COUNT=$((COACH_RULE_COUNT + 1))
        fi
    done
    if [[ "$COACH_RULE_COUNT" -eq 0 ]]; then
        echo "  No Coach rule files found in ${COACH_RULES_SRC}/"
    fi
else
    echo "  No vendor/coach-rules/ directory found (optional)"
fi

echo ""

# --- Step 4: Copy config (if present) ---

echo "Step 4: Copying configuration..."

CONFIG_SRC="${SCRIPT_DIR}/config/self-learning.conf"
CONFIG_DST="$SL_CONFIG_FILE"

if [[ -f "$CONFIG_SRC" ]]; then
    if [[ -f "$CONFIG_DST" ]]; then
        echo "  Config already exists at $CONFIG_DST -- skipping (will not overwrite)"
    else
        do_copy "$CONFIG_SRC" "$CONFIG_DST"
    fi
else
    echo "  No config/self-learning.conf found (optional)"
fi

echo ""
echo "Step 4b: Copilot CLI adapter (optional)..."
if [[ -d "${HOME}/.copilot" ]]; then
    do_mkdir "${HOME}/.copilot/hooks"
    COPILOT_HOOK_SRC="${SCRIPT_DIR}/config/copilot-hooks.json"
    COPILOT_HOOK_DST="${HOME}/.copilot/hooks/self-learning.json"
    # An existing hook file used to be skipped outright with "Already exists
    # ... (skipping)". That made upgrading a SILENT NO-OP: anyone who had
    # installed before the vendor-neutral store landed kept a hook pointing at
    # the old ~/.claude/scripts/self-learning/... path, re-ran install.sh, was
    # told it succeeded, and got no learning at all. Observed for real on the
    # reporter's machine, where the file had to be re-rendered by hand.
    #
    # Three distinct states now, because "leave it alone" and "overwrite it"
    # are both wrong as a blanket rule:
    #
    #   up to date   -- byte-identical to what we would render: say so, touch
    #                   nothing.
    #   ours, stale  -- canonicalizing the file (every path in front of one of
    #                   OUR script names back to the template placeholder, then
    #                   our own shell quoting off that placeholder) reproduces
    #                   the canonicalized template, so the only things that
    #                   differ are the install location and the quoting shape
    #                   WE ship. Nothing of the user's is in there to lose:
    #                   re-render, and print the before/after paths.
    #   ours, edited -- references our script but does not canonicalize to the
    #                   template, i.e. someone changed a timeout or added a
    #                   hook. Re-render (an upgrade that leaves a broken path
    #                   in place is the defect being fixed) but keep a
    #                   timestamped .bak alongside and say where it went.
    #   not ours     -- never mentions our script. Do NOT overwrite someone
    #                   else's hook file; warn loudly, twice (here and in the
    #                   final summary), with the exact content to merge.
    # Rendered to a temporary file and moved into place, never straight into
    # $COPILOT_HOOK_DST: a redirect truncates the destination BEFORE the
    # renderer runs, so a render that fails left a zero-byte hook file behind
    # -- and the "up to date" comparison below then matched empty against
    # empty and reported it as current on every subsequent install. Observed
    # while writing tests/test-hook-template-render.sh, with the `a|b` store
    # path that made sed exit non-zero.
    _render_copilot_hook() {
        local tmp="${COPILOT_HOOK_DST}.tmp.$$"
        render_hook_template "$COPILOT_HOOK_SRC" > "$tmp"
        mv "$tmp" "$COPILOT_HOOK_DST"
    }
    # Replace any absolute path immediately preceding one of our script names
    # with the template's placeholder. This used to be a sed character class,
    # `[^" ]*`, which excludes the space -- so a store under `.../My Store/`
    # normalized to `/home/u/My __SL_SCRIPTS_DIR__/...`, never equalled the
    # template, and relocating such a store took the "had local modifications"
    # branch below: a spurious .bak and a false claim the user had edited the
    # file, on a path where the space-free equivalent correctly reported
    # "was stale". Widening the class cannot fix it -- `[^"]*` eats the `bash`
    # interpreter out of the bash value, `bash [^"]*` misses the powershell
    # value entirely -- because the boundary is "where does the path begin",
    # not a character. lib/normalize-hook-path.py scans for it.
    #
    # ...and then strip the shell quoting from around that placeholder, on BOTH
    # sides of the comparison, because the template's own shape changes between
    # releases: 58098f7 single-quoted the rendered path so a store path with a
    # space still runs. Comparing the normalized file against the template's raw
    # bytes made every pre-58098f7 install differ by exactly those quotes and
    # take the "had local modifications" branch -- measured on a real upgrade,
    # with the .bak and the instruction to re-apply edits that were never made.
    # --canonical forgives OUR quoting of OUR path and nothing else, so a
    # changed timeout, an added key or a user's own wrapper still classifies as
    # edited and still keeps its backup.
    _canonical_copilot_hook() {
        normalize_hook_path --canonical "$1" copilot-session-review.sh session-start-context.sh
    }

    if [[ ! -f "$COPILOT_HOOK_DST" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY RUN] render ${COPILOT_HOOK_SRC} -> ${COPILOT_HOOK_DST} (__SL_SCRIPTS_DIR__ -> ${SL_SCRIPTS})"
        else
            _render_copilot_hook
            echo "  Rendered: copilot-hooks.json -> $COPILOT_HOOK_DST"
        fi
    elif [[ "$(render_hook_template "$COPILOT_HOOK_SRC")" == "$(cat "$COPILOT_HOOK_DST")" ]]; then
        echo "  Up to date: $COPILOT_HOOK_DST (already points at ${SL_SCRIPTS})"
    elif [[ "$(_canonical_copilot_hook "$COPILOT_HOOK_DST")" == "$(_canonical_copilot_hook "$COPILOT_HOOK_SRC")" ]]; then
        # Same scan that decided this file was ours, asked for the directory
        # instead of the rewrite. This used to be a sed expression of its own
        # -- a second hand-rolled answer to "where does the path begin" -- and
        # it broke the moment the hook command gained shell quoting around the
        # path: the trailing `.sh"` stopped matching `.sh'"`, so this branch
        # printed `<unknown>` while still reporting success. See
        # lib/normalize-hook-path.py's find_paths().
        OLD_HOOK_PATH="$(normalize_hook_path --print-path "$COPILOT_HOOK_DST" copilot-session-review.sh session-start-context.sh | head -n 1)"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY RUN] re-render STALE hook ${COPILOT_HOOK_DST}: ${OLD_HOOK_PATH:-<unknown>} -> ${SL_SCRIPTS}"
        else
            _render_copilot_hook
            echo "  UPDATED (was stale): $COPILOT_HOOK_DST"
            echo "    hook now runs ${SL_SCRIPTS}/copilot-session-review.sh"
            if [[ "$OLD_HOOK_PATH" == "$SL_SCRIPTS" ]]; then
                # Same directory, so the file was stale in the OTHER dimension:
                # the template's command shape changed under it. Saying
                # "previously <the identical path>" would read as a no-op edit.
                echo "    (same location; the hook command's quoting was updated)"
            else
                echo "    (previously ${OLD_HOOK_PATH:-<unknown>}/copilot-session-review.sh)"
            fi
        fi
    elif grep -q 'copilot-session-review\.sh' "$COPILOT_HOOK_DST"; then
        COPILOT_HOOK_BAK="${COPILOT_HOOK_DST}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "[DRY RUN] back up locally-modified ${COPILOT_HOOK_DST} -> ${COPILOT_HOOK_BAK}, then re-render"
        else
            cp "$COPILOT_HOOK_DST" "$COPILOT_HOOK_BAK"
            _render_copilot_hook
            echo "  UPDATED (had local modifications): $COPILOT_HOOK_DST"
            echo "    previous version saved to: $COPILOT_HOOK_BAK"
            echo "    re-apply any customizations from that file by hand."
        fi
    else
        COPILOT_HOOK_CONFLICT="$COPILOT_HOOK_DST"
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !!! NOT INSTALLED: $COPILOT_HOOK_DST already exists and is NOT ours"
        echo "  !!! (it does not reference copilot-session-review.sh). Refusing to"
        echo "  !!! overwrite someone else's hook file. Copilot CLI sessions will"
        echo "  !!! NOT be reviewed until you merge this in by hand:"
        echo "  !!!"
        render_hook_template "$COPILOT_HOOK_SRC" | sed 's/^/  !!!   /'
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
else
    echo "  ~/.copilot not found — Copilot CLI not installed; skipping (re-run install.sh after installing it)"
fi

echo ""
echo "Step 4c: VS Code Copilot Chat adapter (optional)..."

# Rendered and written into the store, then printed -- exactly like the
# Claude Code template in Step 7, and for the same reason: there is no file
# this installer may safely write to register a VS Code hook. VS Code's hook
# sources come from the `chat.hookFilesLocations` SETTING, and editing a
# user's settings.json by hand from an installer is not something this
# project does. So: render it, put it somewhere permanent, and print the one
# setting the user has to add.
VSCODE_HOOK_SRC="${SCRIPT_DIR}/config/vscode-hooks.json"
VSCODE_HOOK_DST="${SL_HOME}/vscode-hooks.json"

if [[ ! -f "$VSCODE_HOOK_SRC" ]]; then
    # Loud, not silent -- same rule as the Claude template below: printing
    # nothing here would read as "no VS Code step needed".
    echo "  ACTION REQUIRED -- cannot render the VS Code hook JSON:"
    echo "    missing template ${VSCODE_HOOK_SRC}"
    echo "    VS Code Copilot Chat sessions will NOT be reviewed."
else
    VSCODE_HOOK_JSON="$(render_hook_template "$VSCODE_HOOK_SRC")"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] render ${VSCODE_HOOK_SRC} -> ${VSCODE_HOOK_DST} (__SL_SCRIPTS_DIR__ -> ${SL_SCRIPTS})"
    else
        printf '%s\n' "$VSCODE_HOOK_JSON" > "$VSCODE_HOOK_DST"
        chmod 644 "$VSCODE_HOOK_DST"
        echo "  Rendered: vscode-hooks.json -> $VSCODE_HOOK_DST"
    fi
    echo ""
    echo "  To review VS Code Copilot Chat sessions, add this to VS Code's"
    echo "  settings.json (Preferences: Open User Settings (JSON)):"
    echo ""
    echo "      \"chat.hookFilesLocations\": {"
    echo "        \"${VSCODE_HOOK_DST}\": true"
    echo "      }"
    echo ""
    echo "  NOTE: VS Code ALSO reads ~/.claude/settings.json as a hook source by"
    echo "  default, so once you complete the Claude Code step below, VS Code will"
    echo "  run session-review.sh too. That is handled -- the review scripts detect"
    echo "  which transcript format they were handed and parse it correctly -- but"
    echo "  registering BOTH means two reviews per VS Code turn. Pick one:"
    echo "    * Claude Code hooks only (nothing more to do; VS Code reuses them), or"
    echo "    * this file, plus \"~/.claude/settings.json\": false in the same setting."
fi

echo ""

# --- Step 5: Copy and initialize SQLite schema ---

echo "Step 5: Initializing session search database..."

SCHEMA_SRC="${SCRIPT_DIR}/schema/session-search-schema.sql"
SCHEMA_DST="${DEST_DIR}/session-search-schema.sql"
FTS5_SCHEMA_SRC="${SCRIPT_DIR}/schema/session-search-fts5.sql"
FTS5_SCHEMA_DST="${DEST_DIR}/session-search-fts5.sql"
DB_PATH="$SL_SESSIONS_DB"

if [[ -f "$SCHEMA_SRC" ]]; then
    do_copy "$SCHEMA_SRC" "$SCHEMA_DST"
    [[ -f "$FTS5_SCHEMA_SRC" ]] && do_copy "$FTS5_SCHEMA_SRC" "$FTS5_SCHEMA_DST"

    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ ! -f "$DB_PATH" ]]; then
            # fix-p6 (macOS CI): this used to be `sqlite3 "$DB_PATH" <
            # "$SCHEMA_DST"` via the `sqlite3` CLI, which failed silently
            # on macOS -- its bundled CLI commonly lacks FTS5, and its
            # batch mode does not reliably surface a non-zero exit for a
            # mid-script error. session_db.py applies the same schema via
            # Python's own sqlite3 module (raises immediately on a real
            # failure) and gates the FTS5-only part behind a functional
            # probe -- see scripts/lib/session_db.py's module docstring.
            if ! SCHEMA_RESULT=$(python3 "${DEST_DIR}/lib/session_db.py" \
                    ensure-schema "$DB_PATH" "$SCHEMA_DST" "$FTS5_SCHEMA_DST" 2>&1); then
                echo "  FATAL: failed to initialize session search database ($DB_PATH): $SCHEMA_RESULT" >&2
                exit 1
            fi
            if [[ "$SCHEMA_RESULT" == no-fts5:* ]]; then
                echo "  WARNING: ${SCHEMA_RESULT#no-fts5:} -- full-text search degraded to substring (LIKE) matching."
            fi
            echo "  Initialized: $DB_PATH"
        else
            echo "  Database already exists: $DB_PATH (skipping)"
        fi
    else
        echo "[DRY RUN] python3 ${DEST_DIR}/lib/session_db.py ensure-schema $DB_PATH $SCHEMA_DST $FTS5_SCHEMA_DST"
    fi
else
    echo "  No schema/session-search-schema.sql found"
    echo "  Database will be initialized on first use by index-session.sh"
fi

echo ""

# --- Step 6: Initialize .usage.json (if missing) ---

echo "Step 6: Initializing learned skills tracker..."

USAGE_FILE="${SL_SKILLS}/.usage.json"
if [[ ! -f "$USAGE_FILE" ]]; then
    if [[ "$DRY_RUN" != "true" ]]; then
        echo '{}' > "$USAGE_FILE"
        echo "  Created: $USAGE_FILE"
    else
        echo "[DRY RUN] echo '{}' > $USAGE_FILE"
    fi
else
    echo "  Already exists: $USAGE_FILE (skipping)"
fi

echo ""

# --- Step 7: Print hook registration instructions ---

echo "========================================"
echo "  Installation complete!"
echo "========================================"
echo ""
echo "NEXT STEP (Claude Code only): Register hooks in ~/.claude/settings.json"
echo "This is Claude Code's own config directory (not this project's store)."
echo ""

# The JSON below is RENDERED from config/settings-hooks.json, never hand-rolled
# here. A hand-rolled second copy is what produced the A1 defect: this block
# printed the flat {matcher, command, timeout} schema that Claude Code silently
# ignores, with millisecond timeouts in a field Claude Code reads as seconds,
# while the template it was supposed to mirror was correct in both respects.
# Pasting it registered nothing, and a hook that was never registered is
# indistinguishable from a working one until sessions quietly stop being
# reviewed. One definition, substituted -- exactly like copilot-hooks.json.
CLAUDE_HOOK_SRC="${SCRIPT_DIR}/config/settings-hooks.json"
CLAUDE_HOOK_DST="${SL_HOME}/settings-hooks.json"

if [[ ! -f "$CLAUDE_HOOK_SRC" ]]; then
    # Loud, not silent: without the template there is nothing correct to print,
    # and printing nothing would read as "no Claude Code step needed".
    echo "ACTION REQUIRED -- cannot render the Claude Code hook JSON:"
    echo "  missing template ${CLAUDE_HOOK_SRC}"
    echo "  Claude Code hooks are NOT registered; sessions will not be reviewed."
else
    CLAUDE_HOOK_JSON="$(render_hook_template "$CLAUDE_HOOK_SRC")"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] render ${CLAUDE_HOOK_SRC} -> ${CLAUDE_HOOK_DST} (__SL_SCRIPTS_DIR__ -> ${SL_SCRIPTS})"
    else
        printf '%s\n' "$CLAUDE_HOOK_JSON" > "$CLAUDE_HOOK_DST"
        chmod 644 "$CLAUDE_HOOK_DST"
    fi
    echo "Merge the following into your settings.json (also written to"
    echo "${CLAUDE_HOOK_DST}, so you do not need this checkout to copy it):"
    echo ""
    printf '%s\n' "$CLAUDE_HOOK_JSON"
fi
echo ""
echo "Optional: Add weekly curator cron job:"
echo "  0 3 * * 0 bash ${SL_SCRIPTS}/curator-run.sh >> ${SL_LOGS}/curator/cron.log 2>&1"
echo ""
echo "Verify installation:"
echo "  bash ${SL_SCRIPTS}/self-learning-health.sh"
echo ""
echo "Diagnose state at any time (resolved paths, writability, detected"
echo "harnesses, legacy store, and any silent persistence failures):"
echo "  bash ${SL_SCRIPTS}/doctor.sh"
echo ""
if [[ -d "${HOME}/.copilot" ]]; then
    if [[ -n "${COPILOT_HOOK_CONFLICT:-}" ]]; then
        # Repeated here on purpose: Step 4b's output scrolls past on a normal
        # install, and a hook that was never registered is indistinguishable
        # from a working one until sessions quietly stop being reviewed --
        # the exact silent-failure class this project exists to eliminate.
        echo "ACTION REQUIRED -- GitHub Copilot CLI hooks were NOT installed:"
        echo "  ${COPILOT_HOOK_CONFLICT} exists and is not ours; see Step 4b above"
        echo "  for the JSON to merge. Until then, Copilot sessions are not reviewed."
    else
        echo "GitHub Copilot CLI: hooks were installed to ~/.copilot/hooks/self-learning.json"
    fi
    echo ""
fi
