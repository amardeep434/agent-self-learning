#!/usr/bin/env bash
# tests/test-hook-template-render.sh
#
# The teeth of the hook-template render path: substituting __SL_SCRIPTS_DIR__
# must be a LITERAL replacement, for every template and at every site.
#
# install.sh used to render with `sed "s|__SL_SCRIPTS_DIR__|${SL_SCRIPTS}|g"`,
# interpolating the store path unescaped into sed's own expression language.
# Measured end-to-end through install.sh, all three sed replacement
# metacharacters mis-render a perfectly ordinary store location:
#
#   &  -> "the matched text": /home/u/R&D/store became
#         /home/u/R__SL_SCRIPTS_DIR__D/store. Exit 0, valid JSON, dead hook.
#   \  -> escape introducer: /home/u/c\d/store became /home/u/cd/store, and
#         GNU sed's \U extension turns a Windows C:\Users\... into C:SERS...
#   |  -> the delimiter itself: sed aborts with "unknown option to 's'", and
#         under install.sh's `set -euo pipefail` the install stops half-done.
#
# The first two are this project's signature defect -- a hook registered with
# a success message, pointing at a path that does not exist, which never fires
# and never says so. These assertions are written against BEHAVIOUR (the
# rendered path names the real scripts dir) rather than against the rendering
# mechanism, so they stay meaningful if the implementation changes again.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# shellcheck source=tests/lib/path-compare.sh
source "${SCRIPT_DIR}/tests/lib/path-compare.sh"

RENDERER="${SCRIPT_DIR}/scripts/lib/render-template.py"
PATHS_PY="${SCRIPT_DIR}/scripts/lib/paths.py"
TEMPLATES=(settings-hooks.json copilot-hooks.json vscode-hooks.json)

# Every metacharacter in one string, so a fix that handles only the one a
# reviewer happened to flag cannot pass this file.
NASTY='/home/u/R&D/a|b/c\d/store/scripts'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. The renderer itself: literal, for every template ---

check "renderer exists" "yes" "$([[ -f "$RENDERER" ]] && echo yes || echo no)"

for tpl in "${TEMPLATES[@]}"; do
    src="${SCRIPT_DIR}/config/${tpl}"
    out="$(printf '%s' "$NASTY" | python3 "$RENDERER" "$src")"
    check "render ${tpl}: no unsubstituted placeholder" "0" \
        "$(printf '%s' "$out" | grep -c '__SL_SCRIPTS_DIR__' || true)"
    # A backslash in the path is only correct if it is JSON-escaped, so the
    # rendered TEXT deliberately does not contain $NASTY verbatim. Every
    # assertion below therefore reads the DECODED value out of the JSON --
    # which is what the harness actually executes, and the only level at
    # which "the hook names the real path" is a meaningful claim.
    check "render ${tpl}: still parses as JSON" "yes" \
        "$(printf '%s' "$out" | jq -e . >/dev/null 2>&1 && echo yes || echo no)"
    # A path is only correct if EVERY command in it is correct -- the old sed
    # corrupted all of them identically, so checking one would have caught it,
    # but checking all of them is what makes a partial fix visible.
    cmds="$(printf '%s' "$out" | jq -r '[.hooks[][] | .. | objects | (.bash // .command // empty)] | .[]' 2>/dev/null || true)"
    check "render ${tpl}: rendered at least one hook command" "yes" \
        "$([[ -n "$cmds" ]] && echo yes || echo no)"
    check "render ${tpl}: every hook command names the literal scripts dir" "0" \
        "$(printf '%s\n' "$cmds" | grep -cv -F "$NASTY" || true)"
done

# --- 2. Byte-identical output for an ordinary path ---
#
# install.sh Step 4b decides "up to date" by comparing a fresh render against
# the file already on disk, and tests/test-install-paths.sh asserts on the
# rendered artifact. A render that is correct but differs by so much as a
# trailing newline would make every re-install look stale forever. So: for a
# path with no metacharacters, the renderer must agree with `sed` exactly --
# including the template's final bytes, which `$(cat)` would have eaten.
ORDINARY='/home/u/store/scripts'
for tpl in "${TEMPLATES[@]}"; do
    src="${SCRIPT_DIR}/config/${tpl}"
    printf '%s' "$ORDINARY" | python3 "$RENDERER" "$src" > "${TMP}/new-${tpl}"
    sed "s|__SL_SCRIPTS_DIR__|${ORDINARY}|g" "$src" > "${TMP}/old-${tpl}"
    check "render ${tpl}: byte-identical to sed for an ordinary path" "yes" \
        "$(cmp -s "${TMP}/new-${tpl}" "${TMP}/old-${tpl}" && echo yes || echo no)"
done

# --- 3. Loud failures, never a plausible-looking file ---
#
# Each of these would otherwise render a well-formed hook file naming a path
# that cannot exist -- the failure mode this whole file is about.
set +e
printf '%s' "" | python3 "$RENDERER" "${SCRIPT_DIR}/config/settings-hooks.json" >/dev/null 2>&1
check "renderer rejects an empty scripts dir" "3" "$?"
printf '%s' "$ORDINARY" | python3 "$RENDERER" "${TMP}/does-not-exist.json" >/dev/null 2>&1
check "renderer rejects a missing template" "3" "$?"
printf '{"hooks":{}}\n' > "${TMP}/no-placeholder.json"
printf '%s' "$ORDINARY" | python3 "$RENDERER" "${TMP}/no-placeholder.json" >/dev/null 2>&1
check "renderer rejects a template with no placeholder" "3" "$?"
# The scripts dir must arrive on STDIN. Passing it as argv is what made
# windows-latest red: python3 is a native Windows binary under Git Bash, so
# MSYS rewrote /c/Users/... to C:/Users/... on the way in, silently changing
# the path spelling written into the hook file. Refusing a second argument
# means that form cannot quietly come back -- it fails the install instead.
python3 "$RENDERER" "${SCRIPT_DIR}/config/settings-hooks.json" "$ORDINARY" </dev/null >/dev/null 2>&1
check "renderer refuses the argv form MSYS would path-convert" "2" "$?"
set -e

# --- 4. install.sh, for real, into a store whose path carries all three ---
#
# The unit assertions above prove the renderer is literal; only a real install
# proves install.sh actually USES it at every one of its five sites. Which
# characters a store path can actually contain is platform-dependent, so the
# path is assembled from the components this filesystem demonstrably supports
# -- and every excluded one is named, with its reason, never skipped silently.
#
# The probe must confirm the directory it created IS the directory it asked
# for, not merely that mkdir returned 0. First version of this file checked
# only the exit status plus `[[ -d ]]`, and on windows-latest that passed
# while lying: MSYS treats `\` as a SEPARATOR, so `mkdir -p 'c\d'` silently
# created `c/d` -- two components -- and the `[[ -d 'c\d' ]]` test then went
# through the same translation and agreed. The suite ran against a store that
# was not where it thought, and failed. Listing the parent is what makes the
# substitution visible.
_component_survives() {
    local probe created rc=0
    probe="$(mktemp -d)"
    if ! mkdir -p "${probe}/${1}" 2>/dev/null; then
        rm -rf "$probe"
        return 1
    fi
    # Exactly one entry, named exactly what we asked for. If `\` was eaten as
    # a separator this reports the leading component instead.
    created="$(ls -A "$probe" 2>/dev/null)"
    if [[ "$created" != "$1" ]]; then
        rm -rf "$probe"
        return 1
    fi
    # ...and then prove a NATIVE binary can actually USE it. An MSYS-side
    # check cannot certify a path native tools will later have to open: `|`
    # is reserved in NTFS, yet MSYS's mkdir/ls/[[ -d ]] all accept it and
    # agree with each other, while jq and python3 fail with `Invalid
    # argument`. That is precisely how windows CI ended up running the whole
    # end-to-end install against a store no native tool could read.
    # python3 and jq are both native under Git Bash and are the two binaries
    # this suite actually uses to read rendered hook files -- so exercise
    # both, rather than hardcoding NTFS's reserved-character list (which
    # would be a platform assumption, not a measurement).
    if ! printf '%s' '{"probe":1}' > "${probe}/${1}/probe.json" 2>/dev/null; then
        rm -rf "$probe"
        return 1
    fi
    python3 -c 'import sys; open(sys.argv[1], "rb").read()' \
        "${probe}/${1}/probe.json" >/dev/null 2>&1 || rc=1
    if [[ "$rc" -eq 0 ]]; then
        jq -e . "${probe}/${1}/probe.json" >/dev/null 2>&1 || rc=1
    fi
    rm -rf "$probe"
    return "$rc"
}

NASTY_PARTS=()
for _part in 'R&D' 'a|b' 'c\d'; do
    if _component_survives "$_part"; then
        NASTY_PARTS+=("$_part")
    else
        echo "SKIP-DETAIL: store path component '${_part}' — this platform"
        echo "             could not create it AND read it back with a native"
        echo "             python3/jq (expected on Windows, where '\\' is a"
        echo "             separator and '|' is reserved in NTFS: MSYS creates"
        echo "             it, native tools then fail with Invalid argument)."
        echo "             Excluded from the end-to-end store path below; the"
        echo "             renderer assertions above still exercised it as a"
        echo "             string, on every platform."
    fi
done
# `:-` is required, not defensive noise: under `set -u`, bash 3.2 (which
# macOS still ships, and macos-latest CI runs) treats `${arr[*]}` on an EMPTY
# array as an unbound variable and aborts the suite.
NASTY_DIR_NAME="$(IFS=/; printf '%s' "${NASTY_PARTS[*]:-}")"

if [[ -z "$NASTY_DIR_NAME" ]]; then
    echo "SKIP: end-to-end install into a metacharacter store — this"
    echo "      filesystem could not represent ANY of the three characters."
    echo "      The renderer assertions above still ran."
else
    echo "INFO: end-to-end store path component(s): ${NASTY_DIR_NAME}"
    TMP_HOME="${TMP}/home"
    STORE="${TMP_HOME}/${NASTY_DIR_NAME}/store"
    mkdir -p "${TMP_HOME}/.copilot"

    # Same minimal-PATH construction as tests/test-install-paths.sh: fail
    # loudly if a tool is unresolvable rather than fall back to a real PATH,
    # so a red result here can never be a harness artefact.
    _dirs=""
    for _tool in mkdir cp chmod sed grep cat sqlite3 python3 jq dirname basename date; do
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

    INSTALL_STATUS=0
    INSTALL_OUT="$(env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
        AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
        bash "${SCRIPT_DIR}/install.sh" </dev/null 2>&1)" || INSTALL_STATUS=$?
    check "install.sh into a metacharacter store exits 0" "0" "$INSTALL_STATUS"
    if [[ "$INSTALL_STATUS" -ne 0 ]]; then
        echo "--- install.sh output (last 15 lines) ---"
        printf '%s\n' "$INSTALL_OUT" | tail -n 15
        echo "-----------------------------------------"
    fi

    # DERIVED through the same resolver install.sh used, not hand-built from
    # $STORE. The assertions below are textual (`grep -F` against a rendered
    # hook command), and a bash-built "${STORE}/scripts" never crossed a
    # python3 subprocess boundary while the rendered value did -- on Git Bash
    # those spell the same directory as `/tmp/...` and `/c/Users/...`
    # respectively. Deriving it is what tests/lib/path-compare.sh calls the
    # fixture-building case: the expected string comes out byte-identical to
    # what the product will emit, on every platform.
    SCRIPTS_DIR="$(sl_resolve_path "$PATHS_PY" scripts \
        HOME="$TMP_HOME" PATH="$MINIMAL_PATH" AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"})"
    check "resolver produced a scripts dir for the metacharacter store" "yes" \
        "$([[ -n "$SCRIPTS_DIR" ]] && echo yes || echo no)"
    sl_check_same_path "derived scripts dir is the store's scripts dir" \
        "${STORE}/scripts" "$SCRIPTS_DIR"

    # The single assertion that matters: every path a rendered hook file names
    # must be a file this very install created. A mis-rendered path is still
    # valid JSON, so only checking the file on disk has teeth.
    assert_rendered_paths() {
        local label="$1" file="$2" filter="$3" missing=0 count=0 cmd script
        if [[ ! -f "$file" ]]; then
            echo "FAIL: ${label}: not written (${file})"
            FAILURES=$((FAILURES+1))
            return
        fi
        while IFS= read -r cmd; do
            # See tests/test-install-paths.sh for why the \r strip is here.
            cmd="${cmd%$'\r'}"
            script="${cmd#bash }"
            count=$((count+1))
            [[ -f "$script" ]] || { missing=$((missing+1)); echo "    missing: $script"; }
        done < <(jq -r "$filter" "$file")
        check "${label}: every rendered hook path exists on disk" "0" "$missing"
        check "${label}: rendered at least one hook command" "yes" \
            "$([[ "$count" -gt 0 ]] && echo yes || echo no)"
        # Decoded, not grepped raw: see the note in section 1.
        check "${label}: every hook command names the store scripts dir" "0" \
            "$(jq -r "$filter" "$file" | grep -cv -F "$SCRIPTS_DIR" || true)"
        check "${label}: no unsubstituted placeholder" "0" \
            "$(grep -c '__SL_SCRIPTS_DIR__' "$file" || true)"
    }

    # Site 1 (install.sh writes the Copilot hook file) and site 5 (the Claude
    # Code JSON written into the store).
    assert_rendered_paths "copilot hook" "${TMP_HOME}/.copilot/hooks/self-learning.json" \
        '.hooks.sessionEnd[].bash'
    assert_rendered_paths "claude hook" "${STORE}/settings-hooks.json" \
        '.hooks[][].hooks[].command'
    # Site 4 (VS Code JSON rendered into the store).
    assert_rendered_paths "vscode hook" "${STORE}/vscode-hooks.json" \
        '.hooks[][].hooks[].command'

    # Site 2: the "up to date" comparison. A render that disagrees with what
    # it just wrote makes every subsequent install re-render forever, and (for
    # a locally-edited file) spray .bak copies. Re-running the installer must
    # say "Up to date" -- that string is the observable proof the comparison
    # matched.
    RERUN_OUT="$(env -i HOME="$TMP_HOME" PATH="$MINIMAL_PATH" \
        AGENT_LEARNING_HOME="$STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
        bash "${SCRIPT_DIR}/install.sh" </dev/null 2>&1)" || true
    check "re-install recognises the copilot hook as up to date" "yes" \
        "$(printf '%s' "$RERUN_OUT" | grep -q 'Up to date' && echo yes || echo no)"
    check "re-install left no .bak copies" "0" \
        "$(find "${TMP_HOME}/.copilot/hooks" -name '*.bak-*' 2>/dev/null | wc -l | tr -d ' ')"
    # "Up to date" alone is not proof: a failed render used to truncate the
    # destination to zero bytes, after which the comparison matched empty
    # against empty and said "Up to date" forever. Re-assert the content.
    assert_rendered_paths "copilot hook after re-install" \
        "${TMP_HOME}/.copilot/hooks/self-learning.json" '.hooks.sessionEnd[].bash'
    check "re-install left no .tmp render residue" "0" \
        "$(find "${TMP_HOME}/.copilot/hooks" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"

    # Site 3: the ACTION REQUIRED block printed when the hook file is not
    # ours. It is the ONLY instructions a user in that state gets, so a
    # corrupted path there is as bad as a corrupted file -- and it is the site
    # a fix applied only where a file is written would miss.
    CONFLICT_HOME="${TMP}/conflict-home"
    mkdir -p "${CONFLICT_HOME}/.copilot/hooks"
    printf '{"version":1,"hooks":{"sessionEnd":[{"type":"command","bash":"echo someone-elses"}]}}\n' \
        > "${CONFLICT_HOME}/.copilot/hooks/self-learning.json"
    CONFLICT_STORE="${CONFLICT_HOME}/${NASTY_DIR_NAME}/store"
    CONFLICT_OUT="$(env -i HOME="$CONFLICT_HOME" PATH="$MINIMAL_PATH" \
        AGENT_LEARNING_HOME="$CONFLICT_STORE" \
        ${PYENV_ROOT:+PYENV_ROOT="$PYENV_ROOT"} \
        bash "${SCRIPT_DIR}/install.sh" </dev/null 2>&1)" || true
    check "ACTION REQUIRED block was printed" "yes" \
        "$(printf '%s' "$CONFLICT_OUT" | grep -q 'NOT INSTALLED' && echo yes || echo no)"
    # Scoped to the '!!!' -prefixed block, NOT the whole transcript: Step 2's
    # own "Copied: ... -> <store>/scripts/copilot-session-review.sh" lines
    # contain the correct path too, so an unscoped grep passed even while the
    # printed block itself was corrupt. Measured — that is exactly how this
    # assertion first passed against the buggy code.
    CONFLICT_BLOCK="$(printf '%s\n' "$CONFLICT_OUT" | grep '^  !!!   ' || true)"
    check "ACTION REQUIRED block has content" "yes" \
        "$([[ -n "$CONFLICT_BLOCK" ]] && echo yes || echo no)"
    CONFLICT_CMD="$(printf '%s\n' "$CONFLICT_BLOCK" | sed 's/^  !!!   //' \
        | jq -r '.hooks.sessionEnd[].bash' 2>/dev/null || true)"
    # Compared with the `bash ` prefix stripped, as the other suites do: an
    # expected value spelling it out in full reads as a detached-review launch
    # site to tests/test-review-launch-lint.py, which would then (correctly,
    # by its own rules) demand a wait for a process this test never starts.
    #
    # sl_check_same_path, not string equality: the printed command is a path
    # install.sh resolved through python3 (MSYS form, `/c/Users/...` on Git
    # Bash) while $CONFLICT_STORE was built by hand in bash (`/tmp/...`).
    # Those are the same directory spelled two ways -- comparing them as
    # strings failed on windows CI while the product was entirely correct.
    sl_check_same_path "ACTION REQUIRED block names the literal scripts dir" \
        "${CONFLICT_STORE}/scripts/copilot-session-review.sh" "${CONFLICT_CMD#bash }"
    check "ACTION REQUIRED block leaks no placeholder" "0" \
        "$(printf '%s' "$CONFLICT_BLOCK" | grep -c '__SL_SCRIPTS_DIR__' || true)"
fi

# --- 5. Site 6: README's hand-render one-liner ---
#
# A user following the documented command must get the same bytes install.sh
# writes. Documenting a raw `sed` here would reintroduce the whole class for
# every reader with an '&' in their home directory, so assert the README
# routes through the shared renderer rather than spelling out a substitution
# of its own.
README="${SCRIPT_DIR}/README.md"
check "README documents the shared renderer" "yes" \
    "$(grep -q 'render-template.py' "$README" && echo yes || echo no)"

# --- 6. No site anywhere still interpolates a path into a sed expression ---
#
# The reason this fix was worth doing at all is that the rule lived in six
# places. This is the guard against a seventh appearing.
#
# Both greps match a COMMAND -- a line that begins with `sed` (or a pipe into
# one) and substitutes the placeholder -- not any mention of the old
# expression. install.sh and render-template.py both quote it verbatim while
# explaining what it did wrong, and a guard that forbade describing the bug
# would just get the explanation deleted.
_sed_command_uses_placeholder() {
    grep -cE '^[[:space:]]*(\||[A-Z_]+="?\$\()?[[:space:]]*sed[[:space:]]+.*s\|__SL_SCRIPTS_DIR__\|' "$1" || true
}
check "README documents no raw sed substitution command" "0" \
    "$(_sed_command_uses_placeholder "$README")"
check "install.sh has no sed-based placeholder substitution left" "0" \
    "$(_sed_command_uses_placeholder "${SCRIPT_DIR}/install.sh")"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All hook-template render checks passed."
    exit 0
fi
echo "${FAILURES} check(s) failed."
exit 1
