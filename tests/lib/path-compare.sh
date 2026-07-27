#!/usr/bin/env bash
# tests/lib/path-compare.sh
#
# Fix round E. Round D's Windows fixes (MSYS-form CLI output, forwarder
# scripts instead of copied binaries) got CI from 4/6 cells green to
# 4/6 -- ubuntu and macOS, both Python versions. The remaining two
# (windows-latest) failed 13 of 27 suites, and the failures shared one
# shape: a test compares a bash-spelled path (usually built by hand from a
# `mktemp -d` result, e.g. "${TMP_HOME}/store/memory") against a path the
# PRODUCT resolved via a native python3.exe subprocess (e.g. `$SL_MEMORY_DIR`,
# sourced from config.sh, which shells out to paths.py). On Git Bash/MSYS2
# those can be the SAME real directory (MSYS remaps /tmp <-> %TEMP%) while
# being spelled completely differently as strings, because MSYS
# auto-converts POSIX-looking argv/env values crossing into a native
# (non-MSYS) executable. `-ef`/string-equality alone cannot tell they match.
#
# Round D applied this fix to exactly one assertion in test-config.sh. This
# file is the "do it once, share it everywhere" version: the same lesson
# that produced the 3.9 isotime regression (nine near-identical copies is
# the next divergence waiting to happen) applies here too.
#
# Two independent mechanisms, used for two different situations:
#
#  (1) sl_canon_path / sl_same_path -- comparing two ALREADY-COMPUTED path
#      STRINGS (whether or not either names something that exists on disk
#      yet). Canonicalizes via Python's os.path.realpath, which does not
#      require existence. Passing the string as argv to a native python3.exe
#      from bash triggers the SAME MSYS auto-conversion a real product
#      subprocess call would have applied to it, so two differently-spelled
#      strings naming the same directory converge to the same canonical
#      output on any platform -- including a purely bash-built path that
#      never itself crossed a process boundary before being canonicalized
#      here.
#
#  (2) sl_resolve_path / sl_legacy_home -- when the "expected" value should
#      be DERIVED, not merely compared: instead of guessing what a resolved
#      path will look like and then reconciling spellings after the fact,
#      call the exact same resolver the product calls (paths.py's `get`
#      subcommand, or paths.legacy_home()), under the identical env, so the
#      "expected" string is byte-identical to what the product will emit --
#      on any platform, without needing to canonicalize anything. This is
#      what fixture-building code should use (e.g. writing a hooks.json
#      fixture that must textually match what self-learning-health.sh will
#      independently resolve): a bash-literal fixture path force sl_same_path
#      cannot help with, since sl_check_hook_fresh() in lib/config.sh does a
#      textual grep match, not a filesystem-identity check.
#
# Plus one unrelated-but-adjacent helper:
#
#  (3) sl_forwarder -- writes a forwarder script instead of `cp`-ing a
#      binary, for building a restricted PATH. See fix round D blocker (b)
#      part 3 / fix round E: a copied binary loses the DLL siblings
#      (msys-2.0.dll et al.) the Windows loader resolves relative to the
#      executable's OWN directory, which a bare `cp` breaks.
#
# Sourced by, never copied into, every shell suite that needs any of this.

# Resolved once, at source time, relative to this file's own location --
# tests/lib/path-compare.sh -> ../../scripts/lib/paths.py -- so every
# function below shares the ONE path resolver rather than recomputing or
# reimplementing its logic, matching this project's own global constraint
# ("paths are computed in exactly one place").
_SL_PATH_COMPARE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SL_PATHS_PY="${_SL_PATH_COMPARE_LIB_DIR}/../../scripts/lib/paths.py"

# sl_canon_path <path>
# Canonicalizes an arbitrary path STRING for comparison.
#
# Fix round F: this used to be an inline `python3 -c 'import os, sys;
# print(os.path.realpath(sys.argv[1]))'` -- a SECOND, independent
# reimplementation of path rendering next to paths.py's own
# `_to_cli_string`, and it showed exactly the divergence that pattern
# always produces: on Git Bash/MSYS2 CI, this printed raw
# `os.path.realpath`'s native-flavour string (backslashes, e.g.
# 'C:\Users\...\real'), a THIRD path spelling alongside the plain
# '.as_posix()' form and the MSYS '/c/Users/...' cygdrive form the rest of
# this project's CLI output already uses consistently. Now shells out to
# paths.py's own `canon` subcommand, which combines the same
# os.path.realpath call with THIS module's `_to_cli_string` rendering --
# one implementation of "how a path is spelled for a bash consumer",
# shared, not reimplemented a second time in bash.
sl_canon_path() {
    python3 "$_SL_PATHS_PY" canon "$1" 2>/dev/null
}

# sl_same_path <a> <b>
# True if `a` and `b` name the same directory/file once canonicalized.
# Prefers `-ef` (same underlying inode) when both already exist on disk --
# a strictly stronger check than string comparison, and correct even for
# two DIFFERENT paths that happen to be hardlinked/symlinked together (which
# realpath-based comparison also handles, but -ef is the more direct,
# filesystem-native check when both sides exist). Falls back to
# sl_canon_path equality when either side does not yet exist (e.g.
# comparing a path the product WILL create against one this test built by
# hand before creating anything).
sl_same_path() {
    local a="$1" b="$2"
    if [[ -e "$a" && -e "$b" ]]; then
        [[ "$a" -ef "$b" ]]
        return
    fi
    local ca cb
    ca="$(sl_canon_path "$a")"
    cb="$(sl_canon_path "$b")"
    [[ -n "$ca" && "$ca" == "$cb" ]]
}

# sl_check_same_path <description> <expected> <actual>
# `check`-shaped wrapper around sl_same_path, for drop-in use alongside this
# project's existing `check "desc" "$expected" "$actual"` convention. Prints
# PASS/FAIL and increments the caller's FAILURES variable (must already be
# declared in the sourcing script, per this project's test convention).
sl_check_same_path() {
    local desc="$1" expected="$2" actual="$3"
    if sl_same_path "$expected" "$actual"; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc (expected a path equivalent to '$expected', got '$actual')"
        FAILURES=$((FAILURES + 1))
    fi
}

# sl_resolve_path <paths.py-path> <key> [ENV=VAL ...]
# Calls `python3 <paths.py-path> get <key>` under a caller-specified env
# (via `env -i`, so nothing but what is explicitly passed leaks in),
# mirroring exactly how scripts/lib/config.sh and scripts/doctor.sh resolve
# the same key. The returned string is directly comparable (with plain `==`
# or a substring `contains` check) to whatever the product prints, since it
# went through the identical subprocess/env/OS-path-conversion pipeline.
sl_resolve_path() {
    local paths_py="$1" key="$2"
    shift 2
    env -i "$@" python3 "$paths_py" get "$key" 2>/dev/null
}

# sl_legacy_home <scripts/lib-dir> [ENV=VAL ...]
# Mirrors doctor.sh's own inline `paths.legacy_home()` invocation exactly
# (same snippet), so a test's expected value for "legacy store found: X"
# always matches doctor.sh's actual output, byte for byte, on any platform.
sl_legacy_home() {
    local lib_dir="$1"
    shift
    env -i "$@" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import paths
h = paths.legacy_home()
print(h if h else "")
' "$lib_dir" 2>/dev/null
}

# sl_forwarder <src-absolute-path> <dst>
# Writes a tiny POSIX-shell forwarder script at `dst` that execs `src` by
# its original absolute path, then chmods it executable. Used to build a
# restricted PATH containing only specific tools without literally copying
# their binaries.
sl_forwarder() {
    local src="$1" dst="$2"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$src" > "$dst"
    chmod +x "$dst"
}
