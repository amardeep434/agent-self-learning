#!/usr/bin/env bash
# scripts/lib/skill-layout.sh
#
# Bash-side access to the single skill-directory-layout definition in
# lib/skill_layout.py (SKILL.md filename, .usage.json filename, .archive
# dirname). Same pattern lib/config.sh already uses for lib/paths.py: shell
# out once, read KEY=VALUE lines, assign bash variables. Never re-type the
# literals here -- that duplication (values re-stated independently in
# persist-proposal.py, skill-lifecycle.py, inject-agents-md.py,
# curator-run.sh, and self-learning-health.sh) is exactly what caused a
# Critical on this branch once already (see lib/skill_layout.py's docstring).
#
# Deliberately NOT sourced from lib/config.sh: config.sh is sourced by
# turn-counter.sh, which runs on every single tool-call hook invocation
# inside a <100ms budget that already spends ~22-25ms on one `paths.py`
# spawn. Adding a second subprocess spawn there for values turn-counter.sh
# never uses would regress the one genuinely hot path in this project. This
# file is sourced only by curator-run.sh and self-learning-health.sh, both
# of which run at most a few times a day (curator: 7-day gate; health: an
# on-demand diagnostic) -- one extra spawn per invocation of either is a
# rounding error there, and each sources this file exactly once, not per
# skill in a loop.
#
# Sets: SL_SKILL_MD_FILENAME, SL_USAGE_FILENAME, SL_ARCHIVE_DIRNAME
# Falls back to the same literals lib/skill_layout.py defines if python3 is
# unavailable, so a box missing python3 degrades gracefully instead of
# leaving these variables unset (never silently empty -- the class of bug
# this whole layer exists to prevent).

_sl_skill_layout_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One resolver for the interpreter (scripts/lib/python-resolve.sh):
# `python3` is a name real Windows Python installs never provide.
# Sourced here, not assumed from config.sh, because this file is also
# sourced directly (by its own suite, and by scripts that predate
# config.sh in their own load order). Re-resolution is free once
# SL_PYTHON is exported.
# shellcheck source=scripts/lib/python-resolve.sh
source "${_sl_skill_layout_lib_dir}/python-resolve.sh"
sl_resolve_python || true
_sl_skill_layout_py="${_sl_skill_layout_lib_dir}/skill_layout.py"

SL_SKILL_MD_FILENAME="SKILL.md"
SL_USAGE_FILENAME=".usage.json"
SL_ARCHIVE_DIRNAME=".archive"

if [[ -f "$_sl_skill_layout_py" ]]; then
    while IFS='=' read -r _sl_sk_key _sl_sk_val; do
        _sl_sk_val="${_sl_sk_val%$'\r'}"
        case "$_sl_sk_key" in
            skill_md_filename) SL_SKILL_MD_FILENAME="$_sl_sk_val" ;;
            usage_filename)    SL_USAGE_FILENAME="$_sl_sk_val" ;;
            archive_dirname)   SL_ARCHIVE_DIRNAME="$_sl_sk_val" ;;
        esac
    done < <("${SL_PYTHON}" "$_sl_skill_layout_py" all 2>/dev/null)
fi

export SL_SKILL_MD_FILENAME SL_USAGE_FILENAME SL_ARCHIVE_DIRNAME
