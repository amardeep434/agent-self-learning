#!/usr/bin/env python3
"""The contract between the reviewer agent and the writer.

The reviewer agent emits one JSON object on stdout and writes no files. This
module is the security boundary for that object: everything is allow-listed,
size-capped, and rejected wholesale on any violation. A prompt-injected
session must not be able to steer a write outside the store, and a partially
valid proposal must never be partially applied.
"""
from __future__ import annotations

import json
import re

SCHEMA_VERSION = 1

MAX_MEMORY_BYTES = 64 * 1024
MAX_SKILL_BYTES = 32 * 1024
MAX_SKILLS = 10
MAX_TOTAL_BYTES = 256 * 1024
MAX_INPUT_BYTES = 4 * MAX_TOTAL_BYTES

ALLOWED_MEMORY_FILES = frozenset({"MEMORY.md", "USER.md"})

# Derived, not a hand-written 4. Entries are allow-listed by exact filename AND
# checked for duplicates below, so more entries than there are legal filenames
# is unreachable by construction -- the old literal 4 advertised a headroom of
# two entries that no valid proposal could ever occupy, and its error message
# ("at most 4 memory entries per proposal") actively contradicted the real
# limit. Deriving it keeps the two facts from drifting if a third memory file
# is ever allow-listed.
MAX_MEMORY_ENTRIES = len(ALLOWED_MEMORY_FILES)
ALLOWED_MODES = frozenset({"replace", "append"})
SKILL_NAME_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")

# Memory is ONE flat file per name (ALLOWED_MEMORY_FILES). There is no
# per-entry file anywhere in this project, so a memory entry that reads
# `- [Some lesson](some-lesson.md) -- ...` is referring to a file that does
# not and will not exist. Measured on the real store: 15 of 52 MEMORY.md
# lines carried such a link, and of the 15 targets not one existed --
# `msys-path-boundary.md` and `probe-key-name-before-claiming-defect.md`
# among them. The nearest real thing on disk is a SKILL directory
# (`learned-skills/<name>/SKILL.md`), which is not what these spell either.
#
# Rejected in the schema, not merely discouraged in the prompt, for the same
# reason the one-entry-per-file rule is: this file is the contract, the
# OUTPUT CONTRACT now states the rule to the reviewer in the same words, and
# a rule stated only in a prompt is a suggestion. A dangling link is worse
# than noise in a bounded file -- it invites the next agent to go read
# something that is not there.
#
# Deliberately narrow: only an inline markdown link whose target ends in
# `.md` (with optional anchor/query), which is the exact shape observed.
# Prose that merely names a file ("see paths.py") is untouched, and skill
# content is untouched -- SKILL.md files are real and may legitimately
# cross-reference.
# The whole markdown link, with the visible text captured so it can be kept.
# Narrow on purpose: only ".md" targets. Prose that merely names a file
# ("see CLAUDE.md"), http(s) links, and every skill body are untouched.
MEMORY_FILE_LINK_RE = re.compile(
    r"\[([^\]\n]*)\]\(\s*[^)\s]+\.md(?:[#?][^)]*)?\s*\)")
# An orphaned target with no "[text]" before it. Stripped separately so the
# first substitution can never leave a dangling "](...)" behind.
_MEMORY_ORPHAN_LINK_RE = re.compile(r"\]\(\s*[^)\s]+\.md(?:[#?][^)]*)?\s*\)")


def strip_memory_file_links(content: str) -> str:
    """Reduce "[Text](lesson.md)" to "Text" in a memory entry.

    Memory is ONE flat file, so a markdown file link always points at
    something that does not exist. The reviewer keeps emitting the form
    anyway -- it is mimicking the real learned-skills/<name>/SKILL.md layout,
    flattened -- and rejecting the proposal for it cost a whole paid review on
    2026-07-29 (persist-failures.log: "'](capture-exit-code-separately.md)'
    points at a file that does not exist").

    Stripping rather than refusing is safe HERE specifically because nothing is
    lost: the visible text carries the lesson, and the target carried no
    information at all. That is normalisation, not a judgement about content --
    the reason this is allowed to be silent while the duplicate-line check is
    still a loud refusal, which discards something a reader might have wanted.
    """
    return _MEMORY_ORPHAN_LINK_RE.sub("", MEMORY_FILE_LINK_RE.sub(r"\1", content))

_FENCE = "```"
# Deferred minor (Item 3): bounds how many fenced code-block candidates
# extract_proposal() will scan looking for a valid proposal JSON payload.
# Fail-closed by construction: raising or lowering this number can only
# change whether a VALID proposal is found (a legitimate one buried past the
# 10th fence in reviewer chatter would be missed), never let an INVALID or
# adversarial payload be accepted -- every candidate this loop yields still
# goes through the same validate_proposal() checks as candidate #1. There is
# no value of this constant that turns a rejection into an acceptance.
_MAX_FENCE_CANDIDATES = 10

_WINDOWS_RESERVED = frozenset(
    {"CON", "PRN", "AUX", "NUL"}
    | {f"COM{i}" for i in range(10)}
    | {f"LPT{i}" for i in range(10)}
)


class ValidationError(Exception):
    pass


def _need(cond: bool, msg: str) -> None:
    if not cond:
        raise ValidationError(msg)


def _size(text: str) -> int:
    return len(text.encode("utf-8"))


def _fenced_candidates(text: str):
    """Yield candidate JSON strings from fenced blocks, without backtracking.

    A regex such as ```(?:json)?\\s*(\\{.*?\\})\\s*``` under DOTALL retries from
    every fence opener when there is no valid closer: 872 KB of adversarial
    reviewer output cost 26 seconds. str.find scanning is linear and cannot be
    driven into that behaviour.
    """
    pos = 0
    yielded = 0
    while yielded < _MAX_FENCE_CANDIDATES:
        start = text.find(_FENCE, pos)
        if start == -1:
            return
        line_end = text.find("\n", start + len(_FENCE))
        if line_end == -1:
            return
        end = text.find(_FENCE, line_end + 1)
        if end == -1:
            return
        yield text[line_end + 1:end].strip()
        yielded += 1
        pos = end + len(_FENCE)


def validate_proposal(obj: object) -> dict:
    _need(isinstance(obj, dict), "proposal must be a JSON object")
    assert isinstance(obj, dict)
    version = obj.get("version")
    _need(isinstance(version, int) and not isinstance(version, bool)
          and version == SCHEMA_VERSION,
          f"version must be {SCHEMA_VERSION}, got {version!r}")

    memory_in = obj.get("memory", [])
    skills_in = obj.get("skills", [])
    _need(isinstance(memory_in, list), "memory must be a list")
    _need(isinstance(skills_in, list), "skills must be a list")
    _need(len(memory_in) <= MAX_MEMORY_ENTRIES,
          f"at most {MAX_MEMORY_ENTRIES} memory entries per proposal")
    _need(len(skills_in) <= MAX_SKILLS, f"at most {MAX_SKILLS} skills per proposal")

    total = 0
    memory_out = []
    for entry in memory_in:
        _need(isinstance(entry, dict), "memory entry must be an object")
        name = entry.get("file")
        mode = entry.get("mode", "replace")
        content = entry.get("content")
        # Exact-name allow-list: no join, no normalization, no traversal surface.
        _need(isinstance(name, str) and name in ALLOWED_MEMORY_FILES,
              f"memory file must be one of {sorted(ALLOWED_MEMORY_FILES)}, got {name!r}")
        _need(isinstance(mode, str) and mode in ALLOWED_MODES,
              f"mode must be one of {sorted(ALLOWED_MODES)}")
        _need(isinstance(content, str), "memory content must be a string")
        _need("\x00" not in content, "content contains NUL byte")
        # Strip BEFORE the size check: stripping only shrinks, and the cap must
        # describe what actually gets stored, not what was proposed.
        content = strip_memory_file_links(content)
        _need(_size(content) <= MAX_MEMORY_BYTES,
              f"memory content exceeds {MAX_MEMORY_BYTES} bytes")
        total += _size(content)
        memory_out.append({"file": name, "mode": mode, "content": content})

    names = [e["file"] for e in memory_out]
    _need(len(names) == len(set(names)), "duplicate memory file entries")

    skills_out = []
    for entry in skills_in:
        _need(isinstance(entry, dict), "skill entry must be an object")
        name = entry.get("name")
        content = entry.get("content")
        _need(isinstance(name, str) and SKILL_NAME_RE.match(name),
              f"skill name must match {SKILL_NAME_RE.pattern}, got {name!r}")
        _need(name.upper() not in _WINDOWS_RESERVED,
              f"skill name is a reserved device name: {name!r}")
        _need(isinstance(content, str), "skill content must be a string")
        _need("\x00" not in content, "content contains NUL byte")
        _need(_size(content) <= MAX_SKILL_BYTES,
              f"skill content exceeds {MAX_SKILL_BYTES} bytes")
        total += _size(content)
        skills_out.append({"name": name, "content": content})

    names = [e["name"] for e in skills_out]
    _need(len(names) == len(set(names)), "duplicate skill names")
    # Case-fold collision WITHIN one proposal. The exact-string check above
    # does not see it, and on a case-insensitive filesystem (macOS, Windows
    # -- both probed live in tests/test-adversarial-sweep.py's CI runs)
    # "alpha" and "ALPHA" name two records in .usage.json but one directory
    # on disk, so one skill's content is silently destroyed by the other.
    #
    # Rejected unconditionally, not gated on a filesystem probe, because
    # this is ambiguous everywhere: a reviewer that emits two names
    # differing only in case in a single proposal has no coherent intent to
    # honour, and there is no filesystem on which accepting both is
    # obviously right. Rejecting here is also the safest of the available
    # behaviours -- nothing is written, so no existing store is touched or
    # rewritten. Re-writing the SAME skill is unaffected: that is the
    # identical string, already rejected by the line above and never a
    # legitimate thing to send twice in one proposal.
    #
    # casefold(), not lower(): lower() is not sufficient for full Unicode
    # case-insensitive matching. Names are ASCII-constrained by
    # SKILL_NAME_RE so the two agree here today, but the fold is the
    # correct operation and stays correct if that regex is ever widened.
    folded = [n.casefold() for n in names]
    _need(len(folded) == len(set(folded)),
          "skill names collide when case-folded (they would share one "
          "directory on a case-insensitive filesystem): "
          + repr(sorted(n for n in names if folded.count(n.casefold()) > 1)))

    _need(total <= MAX_TOTAL_BYTES, f"proposal exceeds {MAX_TOTAL_BYTES} bytes total")
    return {"version": SCHEMA_VERSION, "memory": memory_out, "skills": skills_out}


def extract_proposal(text: str) -> dict | None:
    """Pull the JSON object out of reviewer stdout.

    Agents wrap output in prose or fences no matter how firmly they are told
    not to, so accept a fenced block or a bare object. Returns None when no
    JSON object is present; callers treat that as 'nothing to persist', which
    is different from an invalid proposal (an error).
    """
    if not isinstance(text, str):
        return None
    if len(text.encode("utf-8", errors="ignore")) > MAX_INPUT_BYTES:
        return None

    # Try fenced blocks first (in order, linear-time scan prevents ReDoS)
    for candidate in _fenced_candidates(text):
        try:
            return json.loads(candidate)
        except (json.JSONDecodeError, RecursionError, ValueError, TypeError):
            pass  # Try next candidate

    # Fall back to bare JSON
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except (json.JSONDecodeError, RecursionError, ValueError, TypeError):
        return None
