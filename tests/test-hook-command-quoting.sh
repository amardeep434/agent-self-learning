#!/usr/bin/env bash
# tests/test-hook-command-quoting.sh
#
# The EXECUTION-time twin of tests/test-hook-template-render.sh.
#
# That suite proves the rendered hook file NAMES the right path. This one
# proves the harness can still RUN it, which is a different claim: every hook
# command in every template is a shell command string (measured against each
# harness's own reference -- see the doc quotes below), so the rendered path
# is re-tokenized by a shell at fire time. An unquoted path containing a
# space splits into two words there, and the hook installs perfectly, reports
# success, and then fails on every single invocation:
#
#   $ sh -c "bash /tmp/My Store/scripts/turn-counter.sh"
#   bash: /tmp/My: No such file or directory      (exit 127)
#
# Measured, before the fix, on all five command values across the three
# templates -- INCLUDING Copilot CLI's `powershell` one, whose `\"` looks
# like protection but is PowerShell's own quoting and is consumed there; see
# sl_hook_powershell_inner in tests/lib/hook-command.sh.
#
# This is the same root cause as the install-time defect fixed in e7163b6 (a
# store path with a space), on the other half of the system: that one broke
# install.sh's "is this hook ours?" comparison, this one breaks the hook.
#
# Why single quotes and not the double quotes the `powershell` value already
# used. Measured here, executing `bash <form>` for a store path built from
# each character:
#
#   path contains   bare        "double"                 'single'
#   ------------- ----------- ------------------------ ----------
#   space           broken      RUNS                     RUNS
#   $              broken      broken (expands)          RUNS
#   `              broken      broken (SUBSTITUTES)      RUNS
#   '              broken      RUNS                      broken
#
# Single quotes strictly dominate double quotes except for an apostrophe:
# they fix everything double quotes fix, plus `$` and backtick, which double
# quotes leave broken in this project's signature direction -- silently, as
# some other path, and for a backtick by running the contents as a command.
# The one case single quotes lose, an apostrophe in the store path, fails as
# a loud shell syntax error at fire time rather than as a plausible wrong
# path. That is the direction this project consistently chooses to be wrong
# in, so: single quotes, at the shell level, in all three templates.
#
# Harness reference, on whether these fields are shell-parsed at all -- if
# any were argv-split with no shell, quoting would BREAK it, so each was
# confirmed against its own docs before the quotes went in:
#
#   Claude Code (code.claude.com/docs/en/hooks), shell form, which is what
#   these templates use because they carry no `args` key:
#     "The `command` string is passed to a shell: `sh -c` on macOS and
#      Linux, Git Bash on Windows [...] The shell tokenizes the string"
#     "In shell form, wrap each placeholder in double quotes."
#   VS Code (code.visualstudio.com/docs/copilot/customization/hooks):
#     "Hooks enable you to execute custom shell commands", `command` is
#     "The shell command to execute". It has no `args` field.
#   Copilot CLI (docs.github.com/en/copilot/reference/hooks-reference):
#     "Command hooks run shell scripts", `bash` is "Shell command for Unix"
#     and `powershell` is "Shell command for Windows". No `args` field.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAILURES=$((FAILURES+1)); fi; }

# shellcheck source=tests/lib/hook-command.sh
source "${SCRIPT_DIR}/tests/lib/hook-command.sh"

RENDERER="${SCRIPT_DIR}/scripts/lib/render-template.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- The store paths under test ---
#
# TWO of them, deliberately. A SPACE is the case this fix is about, it is the
# one every filesystem here can represent, and it is the one real users hit
# (`C:\Users\First Last\AppData\Local\...`), so it gets a store of its own
# and is never skipped. Mixing it into a store that also contains a backtick
# would hide it: a backtick makes the shell fail while still PARSING the
# command, before word splitting is ever reached, so a suite that only tested
# the combined path would go green on a fix that addressed neither.
#
# The second store carries `$` and backtick, the two characters that decided
# single quotes over double. Both are legal on NTFS and on POSIX filesystems,
# but "legal" is a platform assumption, so each is probed and any this
# filesystem cannot round trip is announced with its reason.
_component_survives() {
    local probe rc=0
    probe="$(mktemp -d)"
    mkdir -p "${probe}/${1}" 2>/dev/null || { rm -rf "$probe"; return 1; }
    [[ "$(ls -A "$probe" 2>/dev/null)" == "$1" ]] || { rm -rf "$probe"; return 1; }
    printf 'x' > "${probe}/${1}/probe" 2>/dev/null || { rm -rf "$probe"; return 1; }
    python3 -c 'import sys; open(sys.argv[1], "rb").read()' \
        "${probe}/${1}/probe" >/dev/null 2>&1 || rc=1
    rm -rf "$probe"
    return "$rc"
}

# Every script any of the three templates can name, in a given scripts dir.
# Each announces itself, so "the right script ran" is an observation and not
# an inference from an exit status -- `bash /tmp/My Store/...` also exits
# non-zero when the path is merely absent, and this suite must tell those
# apart.
_populate_scripts_dir() {
    local dir="$1" s
    mkdir -p "$dir"
    # Every script any template's hook command names. session-start-context is
    # a bash wrapper around session-start-context.py for exactly this reason:
    # this harness, sl_hook_script_path, and lib/normalize-hook-path.py all
    # assume the one `bash '<dir>/<name>.sh'` command shape, and the MSYS argv
    # boundary has broken this project four times already. One shape.
    for s in turn-counter session-review index-session \
             copilot-session-review vscode-session-review \
             session-start-context; do
        printf '#!/usr/bin/env bash\nprintf "RAN:%s:argc=%%d\\n" "$#"\n' "$s" \
            > "${dir}/${s}.sh"
        chmod +x "${dir}/${s}.sh"
    done
}

SPACE_SCRIPTS="${TMP}/My Store/scripts"
_populate_scripts_dir "$SPACE_SCRIPTS"

NASTY_COMPONENT=""
for _part in 'a$b' 'a`b'; do
    if _component_survives "$_part"; then
        NASTY_COMPONENT="${NASTY_COMPONENT:+${NASTY_COMPONENT} }${_part}"
    else
        echo "SKIP-DETAIL: store path component '${_part}' — this filesystem"
        echo "             could not create it and read it back. Excluded from"
        echo "             the metacharacter store below; the space store above"
        echo "             is mandatory and still runs on every platform."
    fi
done

# The scripts dir every assertion below renders against. Reassigned once, for
# the metacharacter pass in section 4.
SCRIPTS_DIR="$SPACE_SCRIPTS"

render() { printf '%s' "$SCRIPTS_DIR" | python3 "$RENDERER" "${SCRIPT_DIR}/config/$1"; }

# --- 1. Execute every rendered command, exactly as stored ---
#
# `sh -c` because that is what Claude Code documents for macOS and Linux, and
# because it is the strictest of the shells in play: a form that survives
# dash survives bash. The assertion is on the script's OWN output, plus
# argc=0 -- a hook whose path split into two words would either not run at
# all or run something with a stray argument.
assert_runs() {
    local label="$1" cmd="$2" expect_script="$3" out status=0
    out="$(sh -c "$cmd" </dev/null 2>&1)" || status=$?
    check "${label}: exits 0" "0" "$status"
    check "${label}: ran ${expect_script} with no split-off arguments" \
        "RAN:${expect_script}:argc=0" "$out"
}

# The path the command names must also be recoverable and real -- the same
# claim the sibling suites make, now through a tokenizer instead of a
# prefix strip.
assert_names_real_script() {
    local label="$1" cmd="$2" expect_script="$3" path
    path="$(sl_hook_script_path "$cmd" || true)"
    check "${label}: command tokenizes to an existing file" "yes" \
        "$([[ -n "$path" && -f "$path" ]] && echo yes || echo no)"
    check "${label}: command tokenizes to the installed script" \
        "${SCRIPTS_DIR}/${expect_script}.sh" "$path"
}

# The script a command is SUPPOSED to run, read off the command text without
# tokenizing it -- sl_hook_script_path is itself under test here, so the
# expected value must not come from it. Stripping every quote makes this
# work identically before and after the fix.
_expected_script_name() {
    local bare
    bare="$(printf '%s' "$1" | tr -d "\"'")"
    bare="$(basename "$bare")"
    printf '%s' "${bare%.sh}"
}

# One full pass over all three templates, rendered against $SCRIPTS_DIR.
# A function and not straight-line code because section 4 runs it a second
# time against a store carrying `$` and a backtick; two copies is how the
# second store would end up asserting less than the first.
execution_pass() {
    local prefix="$1" tpl rendered cmd name seen copilot copilot_bash copilot_ps ps_inner ps_out ps_status
    # `slug` is the label with glob metacharacters removed, and it is what goes
    # into FILENAMES. The label itself keeps its brackets for readability in
    # the check text.
    #
    # MEASURED: with the label used directly, every jq read of a rendered file
    # failed on both windows-latest cells with "Could not open file
    # /tmp/.../[space]-settings-hooks.json: No such file or directory" (run
    # 30386807304), while jq read MSYS paths perfectly well elsewhere in the
    # same run. `[...]` is a glob range, and MSYS's argv path conversion for
    # native binaries does not recognise such a token as a path, so native jq
    # received an unconverted MSYS path it cannot open. Do not put glob
    # metacharacters in filenames.
    local slug="${prefix//[^A-Za-z0-9]/}"

    # Claude Code (nested schema) and VS Code (FLAT schema -- its documented
    # hook-file shape; see tests/test-vscode-hooks-json.sh's header for the
    # 2026-08-04 Windows measurement). Same `.command` string either way,
    # different depth.
    local jq_filter
    for tpl in settings-hooks vscode-hooks; do
        case "$tpl" in
            (settings-hooks) jq_filter='.hooks[][].hooks[].command' ;;
            (*)              jq_filter='.hooks[][].command' ;;
        esac
        rendered="${TMP}/${slug}-${tpl}.json"
        render "${tpl}.json" > "$rendered"
        check "${prefix} ${tpl}: rendered output parses as JSON" "yes" \
            "$(jq -e . "$rendered" >/dev/null 2>&1 && echo yes || echo no)"
        seen=0
        while IFS= read -r cmd; do
            cmd="${cmd%$'\r'}"
            [[ -n "$cmd" ]] || continue
            seen=$((seen+1))
            name="$(_expected_script_name "$cmd")"
            assert_runs "${prefix} ${tpl}/${name}" "$cmd" "$name"
            assert_names_real_script "${prefix} ${tpl}/${name}" "$cmd" "$name"
        done < <(jq -r "$jq_filter" "$rendered")
        check "${prefix} ${tpl}: at least one command was exercised" "yes" \
            "$([[ "$seen" -gt 0 ]] && echo yes || echo no)"
    done

    # Copilot CLI: the `bash` field, same shell, different schema.
    copilot="${TMP}/${slug}-copilot-hooks.json"
    render copilot-hooks.json > "$copilot"
    check "${prefix} copilot-hooks: rendered output parses as JSON" "yes" \
        "$(jq -e . "$copilot" >/dev/null 2>&1 && echo yes || echo no)"
    copilot_bash="$(jq -r '.hooks.sessionEnd[0].bash' "$copilot")"
    copilot_bash="${copilot_bash%$'\r'}"
    assert_runs "${prefix} copilot-hooks/bash" "$copilot_bash" copilot-session-review
    assert_names_real_script "${prefix} copilot-hooks/bash" "$copilot_bash" copilot-session-review

    # --- Copilot CLI's `powershell` field, across the PowerShell boundary ---
    #
    # No CI cell in this project can execute PowerShell against a Git Bash of
    # its own (docs/verification-log.md records the same limitation for this
    # value), so this models the ONE thing about that boundary that is not in
    # doubt: PowerShell consumes the outer double quotes and hands `bash -lc`
    # the text between them as a single argument, which bash then parses as
    # shell input. The quoting that has to survive is therefore whatever is
    # INSIDE them -- and that inner string is a plain shell command this suite
    # can run for real. It is also why the `\"` the template already carried
    # protected nothing: those quotes never reached bash.
    copilot_ps="$(jq -r '.hooks.sessionEnd[0].powershell' "$copilot")"
    copilot_ps="${copilot_ps%$'\r'}"
    ps_inner="$(sl_hook_powershell_inner "$copilot_ps")"
    check "${prefix} copilot-hooks/powershell: has the documented 'bash -lc \"...\"' shape" "yes" \
        "$([[ -n "$ps_inner" ]] && echo yes || echo no)"
    if [[ -n "$ps_inner" ]]; then
        # `bash -c` for real, with the inner string as ONE argv element --
        # byte for byte what PowerShell would pass. --noprofile/--norc, so a
        # developer's own ~/.bash_profile errors cannot land in $ps_out and
        # fail the output assertion for the wrong reason; `-l` is dropped for
        # the same reason and is not what is under test here.
        ps_out=""; ps_status=0
        ps_out="$(bash --noprofile --norc -c "$ps_inner" </dev/null 2>&1)" || ps_status=$?
        check "${prefix} copilot-hooks/powershell: inner command exits 0" "0" "$ps_status"
        check "${prefix} copilot-hooks/powershell: inner command ran the review script" \
            "RAN:copilot-session-review:argc=0" "$ps_out"
        assert_names_real_script "${prefix} copilot-hooks/powershell" "$copilot_ps" \
            copilot-session-review
    fi
}

# The case this fix exists for, on every platform, in isolation.
execution_pass "[space]"

# --- 3. The quoting is in the TEMPLATES, not just in one rendered file ---
#
# Sections 1 and 2 would still pass if a future edit quoted only the template
# this suite happened to render first. Assert the form directly, per template
# and per command value, so dropping it anywhere is a named failure.
_unquoted_commands() {
    # A command value whose path is not wrapped in single quotes. Matches the
    # placeholder rather than a rendered path, so this reads the templates as
    # shipped.
    grep -cE "\"(bash|command|powershell)\": \"[^\"]*[^']__SL_SCRIPTS_DIR__" "$1" || true
}
for _tpl in settings-hooks copilot-hooks vscode-hooks; do
    check "${_tpl}.json: every hook command single-quotes its script path" "0" \
        "$(_unquoted_commands "${SCRIPT_DIR}/config/${_tpl}.json")"
done

# --- 4. The same pass, against a store carrying `$` and a backtick ---
#
# This is what makes the single-quote choice a tested decision rather than a
# preference. Double quotes pass every assertion in section 1 and fail here:
# `$` expands to some other path and a backtick RUNS its contents, both
# silently, both producing a hook that reports success while doing the wrong
# thing. Skipped, loudly, only where the filesystem cannot hold the
# characters.
if [[ -z "$NASTY_COMPONENT" ]]; then
    echo "SKIP: metacharacter store — this filesystem could not represent"
    echo "      either '\$' or a backtick in a directory name. The space"
    echo "      store in section 1 still ran."
else
    echo "INFO: metacharacter store path component: ${NASTY_COMPONENT}"
    SCRIPTS_DIR="${TMP}/My Store ${NASTY_COMPONENT}/scripts"
    _populate_scripts_dir "$SCRIPTS_DIR"
    execution_pass "[metachar]"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All hook-command quoting checks passed."
    exit 0
fi
echo "${FAILURES} check(s) failed."
exit 1
