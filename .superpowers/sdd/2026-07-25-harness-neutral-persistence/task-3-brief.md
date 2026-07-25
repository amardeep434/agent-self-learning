### Task 3: Proposal schema and validator

**Files:**
- Create: `scripts/lib/proposal_schema.py`
- Test: `tests/test-proposal-schema.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `SCHEMA_VERSION: int`, `MAX_MEMORY_BYTES: int`, `MAX_SKILL_BYTES: int`, `MAX_SKILLS: int`, `MAX_TOTAL_BYTES: int`, `ALLOWED_MEMORY_FILES: frozenset[str]`, `ValidationError(Exception)`, `validate_proposal(obj: dict) -> dict`, `extract_proposal(text: str) -> dict`.

**Why this exists:** inverting to "script persists" removes the path-allowlist failure, but it creates a new surface — a prompt-injected session could propose hostile content that a naive writer would dutifully write. The schema is the security boundary, so it is strict by construction: fixed filenames for memory, `[A-Za-z0-9_-]` skill names, hard byte caps, and total rejection rather than partial acceptance.

- [ ] **Step 1: Write the failing test**

```python
# tests/test-proposal-schema.py
import sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import proposal_schema as ps  # noqa: E402


def good():
    return {"version": 1,
            "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "hello"}],
            "skills": [{"name": "my-skill", "content": "# Skill"}]}


class TestValid(unittest.TestCase):
    def test_accepts_minimal(self):
        self.assertEqual(ps.validate_proposal({"version": 1}),
                         {"version": 1, "memory": [], "skills": []})

    def test_accepts_full(self):
        self.assertEqual(ps.validate_proposal(good())["skills"][0]["name"], "my-skill")

    def test_extracts_from_fenced_block(self):
        text = 'chatter\n```json\n{"version": 1}\n```\ntrailing'
        self.assertEqual(ps.extract_proposal(text), {"version": 1})

    def test_extracts_bare_json(self):
        self.assertEqual(ps.extract_proposal('  {"version": 1}  '), {"version": 1})


class TestRejects(unittest.TestCase):
    def _bad(self, mutate):
        p = good(); mutate(p)
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_wrong_version(self):
        self._bad(lambda p: p.__setitem__("version", 2))

    def test_unknown_memory_file(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "OTHER.md", "mode": "replace", "content": "x"}))

    def test_path_traversal_in_memory_file(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "../../etc/passwd", "mode": "replace", "content": "x"}))

    def test_absolute_path_in_memory_file(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "/etc/passwd", "mode": "replace", "content": "x"}))

    def test_skill_name_with_slash(self):
        self._bad(lambda p: p["skills"].__setitem__(0, {"name": "a/b", "content": "x"}))

    def test_skill_name_with_dotdot(self):
        self._bad(lambda p: p["skills"].__setitem__(0, {"name": "..", "content": "x"}))

    def test_skill_name_empty(self):
        self._bad(lambda p: p["skills"].__setitem__(0, {"name": "", "content": "x"}))

    def test_bad_mode(self):
        self._bad(lambda p: p["memory"].__setitem__(0, {"file": "MEMORY.md", "mode": "delete", "content": "x"}))

    def test_memory_too_large(self):
        self._bad(lambda p: p["memory"].__setitem__(
            0, {"file": "MEMORY.md", "mode": "replace", "content": "x" * (ps.MAX_MEMORY_BYTES + 1)}))

    def test_too_many_skills(self):
        self._bad(lambda p: p.__setitem__(
            "skills", [{"name": f"s{i}", "content": "x"} for i in range(ps.MAX_SKILLS + 1)]))

    def test_total_size_cap(self):
        chunk = "x" * (ps.MAX_SKILL_BYTES - 1)
        self._bad(lambda p: p.__setitem__(
            "skills", [{"name": f"s{i}", "content": chunk} for i in range(ps.MAX_SKILLS)]))

    def test_non_dict(self):
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal([1, 2, 3])

    def test_extract_returns_none_when_absent(self):
        self.assertIsNone(ps.extract_proposal("no json here at all"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test-proposal-schema.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'proposal_schema'`

- [ ] **Step 3: Write the implementation**

```python
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

ALLOWED_MEMORY_FILES = frozenset({"MEMORY.md", "USER.md"})
ALLOWED_MODES = frozenset({"replace", "append"})
SKILL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


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
    _need(obj.get("version") == SCHEMA_VERSION,
          f"version must be {SCHEMA_VERSION}, got {obj.get('version')!r}")

    memory_in = obj.get("memory", [])
    skills_in = obj.get("skills", [])
    _need(isinstance(memory_in, list), "memory must be a list")
    _need(isinstance(skills_in, list), "skills must be a list")
    _need(len(skills_in) <= MAX_SKILLS, f"at most {MAX_SKILLS} skills per proposal")

    total = 0
    memory_out = []
    for entry in memory_in:
        _need(isinstance(entry, dict), "memory entry must be an object")
        name = entry.get("file")
        mode = entry.get("mode", "replace")
        content = entry.get("content")
        # Exact-name allow-list: no join, no normalization, no traversal surface.
        _need(name in ALLOWED_MEMORY_FILES,
              f"memory file must be one of {sorted(ALLOWED_MEMORY_FILES)}, got {name!r}")
        _need(mode in ALLOWED_MODES, f"mode must be one of {sorted(ALLOWED_MODES)}")
        _need(isinstance(content, str), "memory content must be a string")
        _need(_size(content) <= MAX_MEMORY_BYTES,
              f"memory content exceeds {MAX_MEMORY_BYTES} bytes")
        total += _size(content)
        memory_out.append({"file": name, "mode": mode, "content": content})

    skills_out = []
    for entry in skills_in:
        _need(isinstance(entry, dict), "skill entry must be an object")
        name = entry.get("name")
        content = entry.get("content")
        _need(isinstance(name, str) and SKILL_NAME_RE.match(name),
              f"skill name must match {SKILL_NAME_RE.pattern}, got {name!r}")
        _need(isinstance(content, str), "skill content must be a string")
        _need(_size(content) <= MAX_SKILL_BYTES,
              f"skill content exceeds {MAX_SKILL_BYTES} bytes")
        total += _size(content)
        skills_out.append({"name": name, "content": content})

    _need(total <= MAX_TOTAL_BYTES, f"proposal exceeds {MAX_TOTAL_BYTES} bytes total")
    return {"version": SCHEMA_VERSION, "memory": memory_out, "skills": skills_out}


def extract_proposal(text: str) -> dict | None:
    """Pull the JSON object out of reviewer stdout.

    Agents wrap output in prose or fences no matter how firmly they are told
    not to, so accept a fenced block or a bare object. Returns None when no
    JSON object is present; callers treat that as 'nothing to persist', which
    is different from an invalid proposal (an error).
    """
    match = _FENCE_RE.search(text)
    candidate = match.group(1) if match else None
    if candidate is None:
        start = text.find("{")
        end = text.rfind("}")
        if start == -1 or end <= start:
            return None
        candidate = text[start:end + 1]
    try:
        return json.loads(candidate)
    except json.JSONDecodeError:
        return None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tests/test-proposal-schema.py`
Expected: PASS (18 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/proposal_schema.py tests/test-proposal-schema.py
git commit -m "feat(security): strict proposal schema with allow-lists and size caps"
```

---

