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
MAX_MEMORY_ENTRIES = 4

ALLOWED_MEMORY_FILES = frozenset({"MEMORY.md", "USER.md"})
ALLOWED_MODES = frozenset({"replace", "append"})
SKILL_NAME_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")

_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)

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

    # Try fenced block first
    match = _FENCE_RE.search(text)
    if match:
        try:
            return json.loads(match.group(1))
        except (json.JSONDecodeError, RecursionError, ValueError, TypeError):
            pass  # Fall through to bare scan

    # Fall back to bare JSON
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end <= start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except (json.JSONDecodeError, RecursionError, ValueError, TypeError):
        return None
