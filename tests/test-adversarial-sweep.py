#!/usr/bin/env python3
"""Codified adversarial sweep against the reviewer-proposal trust boundary.

scripts/persist-proposal.py + scripts/lib/proposal_schema.py turn
model-generated JSON into filesystem writes. A reviewer once ran a large
ad-hoc adversarial sweep against them and reported zero surviving issues --
but that sweep was never checked in, and persist-proposal.py has since been
touched at least three times (a symlink read-oracle hoist, the shared
`isotime` import, and the P0/P0b transcript work). This file makes the sweep
a permanent, CI-enforced regression suite instead of a memory of a passing
audit.

Design rules this file follows throughout:

  - A skipped attack must be loud. Every capability this suite depends on
    (symlink creation, hardlink creation, O_NOFOLLOW, enforced read-only
    permissions, case-insensitive filesystem behaviour) is *measured*, never
    assumed from `sys.platform`, and every skip prints why to stderr in
    addition to unittest's own skip bookkeeping. Silent skips are this
    project's single most-repeated defect class.
  - Every attack attempted calls attack(name) exactly once, so the actual
    count run in a given CI job is reported and checked against a floor
    (MIN_ATTACK_COUNT below) at the end of the run. A suite that quietly
    stops attacking is worse than no suite.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "persist-proposal.py"
LIB = ROOT / "scripts" / "lib"

sys.path.insert(0, str(LIB))
import proposal_schema as ps  # noqa: E402


def _load_writer_module():
    """Import persist-proposal.py directly (hyphenated filename, no import)."""
    spec = importlib.util.spec_from_file_location("persist_proposal_sweep", WRITER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WRITER_MOD = _load_writer_module()


def run(stdin_text, home, extra_args=()):
    env = dict(os.environ, AGENT_LEARNING_HOME=str(home))
    return subprocess.run([sys.executable, str(WRITER), *extra_args],
                          input=stdin_text, capture_output=True, text=True, env=env)


# ---------------------------------------------------------------------------
# Capability probes. Measured once at import time, never inferred from the
# platform name -- see tests/test-persist-proposal.py for the same
# discipline applied to that file's pre-existing symlink/hardlink tests.
# ---------------------------------------------------------------------------

def _probe(fn):
    try:
        return bool(fn())
    except Exception:
        return False


def _probe_symlink():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d) / "t"
        target.write_text("x")
        (Path(d) / "l").symlink_to(target)
        return True


def _probe_hardlink():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d) / "t"
        target.write_text("x")
        os.link(target, Path(d) / "l")
        return True


def _probe_readonly_enforced():
    """False when chmod 500 does not actually block a write here (e.g. root)."""
    with tempfile.TemporaryDirectory() as d:
        sub = Path(d) / "sub"
        sub.mkdir()
        os.chmod(sub, 0o500)
        try:
            (sub / "x").write_text("x")
            return False
        except OSError:
            return True
        finally:
            os.chmod(sub, 0o700)


def _probe_case_insensitive_fs():
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "CaseProbe").write_text("x")
        return (Path(d) / "caseprobe").exists()


CAN_SYMLINK = _probe(_probe_symlink)
CAN_HARDLINK = _probe(_probe_hardlink)
HAS_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0) != 0
READONLY_ENFORCED = _probe(_probe_readonly_enforced)
CASE_INSENSITIVE_FS = _probe(_probe_case_insensitive_fs)
IS_WINDOWS = os.name == "nt"

for _name, _val, _extra in (
    ("symlink creation", CAN_SYMLINK, ""),
    ("hardlink creation", CAN_HARDLINK, ""),
    ("O_NOFOLLOW", HAS_O_NOFOLLOW, " (POSIX-only primitive)"),
    ("chmod read-only enforcement", READONLY_ENFORCED, " (false usually means running as root)"),
    ("case-insensitive filesystem", CASE_INSENSITIVE_FS, ""),
):
    print(f"[capability probe] {_name}: {'AVAILABLE' if _val else 'UNAVAILABLE'}{_extra if not _val else ''}",
          file=sys.stderr)


# ---------------------------------------------------------------------------
# Attack accounting. Every attack attempted (not just every test method --
# a single subTest loop over N malicious strings counts N attacks) calls
# attack() exactly once. Reported and floor-checked at the very end.
# ---------------------------------------------------------------------------

ATTACK_COUNT = 0
SKIPPED_ATTACKS = []
FINDINGS = []

# Set well below the true inventory (29 schema + 5 resource + 23 filesystem +
# 8 confinement + 1 TOCTOU = 66) so that legitimate platform-driven skips
# (no symlink privilege, no chmod enforcement, ...) can never by themselves
# push a real CI run under the floor, while a suite that quietly stopped
# attacking (e.g. an import failure that skipped every class) still trips it.
MIN_ATTACK_COUNT = 55


def attack(name):
    global ATTACK_COUNT
    ATTACK_COUNT += 1


def loud_skip(name, reason):
    SKIPPED_ATTACKS.append((name, reason))
    print(f"[SKIPPED ATTACK] {name}: {reason}", file=sys.stderr)


def finding(text):
    FINDINGS.append(text)
    print(f"[FINDING] {text}", file=sys.stderr)


# ===========================================================================
# Schema layer: ~29 malicious names, must be rejected both as a skill name
# and as a memory `file` value.
# ===========================================================================

MALICIOUS_NAMES = [
    "../evil",
    "a/../../evil",
    "/etc/passwd",
    "..\\evil",
    "C:\\Windows\\x",
    ".",
    "..",
    ".usage.json",
    ".hidden",
    "CON",
    "con",
    "COM1",
    "nul",
    "alpha:stream",       # NTFS alternate data stream syntax
    "alpha\x00evil",      # embedded NUL
    "alpha\nevil",        # embedded newline
    "alpha\revil",        # embedded CR
    "alpha\x1bevil",      # embedded ESC control char
    "\u0430lpha",         # Cyrillic \u0430 homoglyph of 'a'
    "cafe\u0301",         # NFD combining acute accent
    "\uff41lpha",         # fullwidth 'a' (U+FF41)
    "alpha\u202evil",     # RTL override
    "al pha",             # embedded space
    "alpha ",             # trailing space
    "alpha.",             # trailing dot
    "",                   # empty
    "a" * 65,             # over the 64-char cap
    "~",
    "..%2fevil",          # URL-encoded traversal (not decoded, but must still fail)
]
assert len(MALICIOUS_NAMES) == 29, len(MALICIOUS_NAMES)


class TestSchemaLayerSweep(unittest.TestCase):
    def test_all_malicious_names_rejected_as_skill_name(self):
        for name in MALICIOUS_NAMES:
            with self.subTest(name=repr(name)):
                attack(f"schema:skill-name:{name!r}")
                p = {"version": 1, "skills": [{"name": name, "content": "x"}]}
                with self.assertRaises(ps.ValidationError, msg=f"skill name {name!r} was accepted"):
                    ps.validate_proposal(p)

    def test_all_malicious_names_rejected_as_memory_file(self):
        for name in MALICIOUS_NAMES:
            with self.subTest(name=repr(name)):
                attack(f"schema:memory-file:{name!r}")
                p = {"version": 1, "memory": [{"file": name, "mode": "replace", "content": "x"}]}
                with self.assertRaises(ps.ValidationError, msg=f"memory file {name!r} was accepted"):
                    ps.validate_proposal(p)


# ===========================================================================
# Resource exhaustion.
# ===========================================================================

class TestResourceExhaustion(unittest.TestCase):
    TIME_BOUND = 5.0  # generous vs. the ~1ms actual cost, to survive a loaded CI runner

    def _timed_none(self, label, payload):
        attack(f"resource:{label}")
        start = time.monotonic()
        result = ps.extract_proposal(payload)
        elapsed = time.monotonic() - start
        self.assertIsNone(result, f"{label}: expected None, took {elapsed:.4f}s")
        self.assertLess(elapsed, self.TIME_BOUND, f"{label}: took {elapsed:.4f}s -- possible ReDoS/complexity regression")

    def _timed_not_a_proposal(self, label, payload):
        """For WELL-FORMED payloads that are merely hostile in shape.

        `_timed_none` is right for malformed or oversized input, which is
        rejected before parsing and still returns None on every version. It is
        wrong for valid-but-deeply-nested JSON: through 3.13 that raised
        RecursionError inside json.loads (hence None), but 3.14's parser is not
        recursive, so it parses and returns a dict. MEASURED on 3.14.6 -- the
        400kb bracket bomb and the oversized payload still return None; only
        this one changed.

        The invariant is unchanged and is what this asserts: bounded time, no
        exception escaping, and the result never validating as a proposal.
        """
        attack(f"resource:{label}")
        start = time.monotonic()
        result = ps.extract_proposal(payload)
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, self.TIME_BOUND,
                        f"{label}: took {elapsed:.4f}s -- possible ReDoS/complexity regression")
        if result is not None:
            with self.assertRaises(Exception):
                ps.validate_proposal(result)

    def test_400kb_bracket_bomb(self):
        payload = "[" * 200_000 + "]" * 200_000
        self.assertGreaterEqual(len(payload.encode()), 390_000)
        self._timed_none("400kb-bracket-bomb", payload)

    def test_100k_deep_nested_object(self):
        payload = '{"a":' * 100_000 + "1" + "}" * 100_000
        self._timed_not_a_proposal("100k-deep-nesting", payload)

    def test_100k_fence_openers(self):
        payload = "```json\n{" * 100_000
        self._timed_none("100k-fence-openers", payload)

    def test_unterminated_fence(self):
        payload = "```json\n" + ("x" * 500_000)
        self._timed_none("unterminated-fence", payload)

    def test_redos_pin_872kb_many_openers(self):
        """Pins the fixed quadratic-backtracking regression: a prior regex
        took 26.1s on this exact 872KB shape; the linear str.find scan that
        replaced it measured 0.00078s. The bound here is generous enough not
        to flake on a loaded CI runner while still catching a real
        regression back toward exponential/quadratic behaviour."""
        payload = ("```json\n{" + "a" * 100) * 8000
        self.assertGreater(len(payload.encode()), 850_000)
        self._timed_none("redos-pin-872kb", payload)


# ===========================================================================
# Filesystem layer: ~22-23 attacks against the real writer subprocess.
# ===========================================================================

class TestFilesystemLayerSweep(unittest.TestCase):

    def test_symlinked_skill_dir_escapes(self):
        if not CAN_SYMLINK:
            loud_skip("fs:symlinked-skill-dir", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:symlinked-skill-dir")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "learned-skills").mkdir(parents=True)
            outside = Path(d) / "outside"
            outside.mkdir()
            (home / "learned-skills" / "evil").symlink_to(outside, target_is_directory=True)
            payload = json.dumps({"version": 1, "skills": [{"name": "evil", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(list(outside.iterdir()), [])

    def test_symlinked_skills_dir_root_escapes(self):
        if not CAN_SYMLINK:
            loud_skip("fs:symlinked-skills-root", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:symlinked-skills-root")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            home.mkdir()
            outside = Path(d) / "outside_skills"
            outside.mkdir()
            (home / "learned-skills").symlink_to(outside, target_is_directory=True)
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(list(outside.iterdir()), [])

    def test_symlinked_skills_dir_redirect_inside_store_still_refused(self):
        """A symlink at the skills_dir position is refused outright even
        when it points somewhere else *inside* the store: _reject_if_symlink
        treats any symlink at a store-directory position as suspicious
        regardless of destination, not just destinations outside the
        store."""
        if not CAN_SYMLINK:
            loud_skip("fs:symlinked-skills-dir-inside-store", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:symlinked-skills-dir-inside-store")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            home.mkdir()
            real_dir = home / "real-skills"
            real_dir.mkdir()
            (home / "learned-skills").symlink_to(real_dir, target_is_directory=True)
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(list(real_dir.iterdir()), [])

    def test_symlinked_memory_dir_escapes(self):
        if not CAN_SYMLINK:
            loud_skip("fs:symlinked-memory-dir", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:symlinked-memory-dir")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            home.mkdir()
            outside = Path(d) / "outside_mem"
            outside.mkdir()
            (home / "memory").symlink_to(outside, target_is_directory=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(list(outside.iterdir()), [])

    def test_symlinked_skill_md_points_at_canary(self):
        if not CAN_SYMLINK:
            loud_skip("fs:symlinked-skill-md-canary", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:symlinked-skill-md-canary")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            skill_dir = home / "learned-skills" / "alpha"
            skill_dir.mkdir(parents=True)
            canary = Path(d) / "canary.txt"
            canary.write_text("SECRET")
            (skill_dir / "SKILL.md").symlink_to(canary)
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(canary.read_text(), "SECRET")

    def test_hardlinked_skill_md(self):
        """Skill content always writes in 'replace' mode via stage-then-
        os.replace(): unlike append mode there is no explicit hardlink
        check on this path, but os.replace() only ever repoints the
        directory entry -- it never writes through the old inode -- so the
        *other* hardlink (the canary) must survive untouched regardless."""
        if not CAN_HARDLINK:
            loud_skip("fs:hardlinked-skill-md", "hardlink creation probed and unavailable")
            self.skipTest("hardlink creation probed and unavailable")
        attack("fs:hardlinked-skill-md")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            skill_dir = home / "learned-skills" / "alpha"
            skill_dir.mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("SECRET")
            os.link(outside, skill_dir / "SKILL.md")
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(outside.read_text(), "SECRET")
            self.assertNotIn("Traceback", r.stderr)

    def test_symlinked_usage_json_refused(self):
        if not CAN_SYMLINK:
            loud_skip("fs:symlinked-usage-json", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:symlinked-usage-json")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            outside = Path(d) / "outside_usage.json"
            outside.write_text("SECRET")
            (skills_dir / ".usage.json").symlink_to(outside)
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(outside.read_text(), "SECRET")

    def test_hardlinked_usage_json_refused(self):
        if not CAN_HARDLINK:
            loud_skip("fs:hardlinked-usage-json", "hardlink creation probed and unavailable")
            self.skipTest("hardlink creation probed and unavailable")
        attack("fs:hardlinked-usage-json")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            outside = Path(d) / "outside_usage.json"
            outside.write_text("SECRET")
            os.link(outside, skills_dir / ".usage.json")
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(outside.read_text(), "SECRET")

    def test_skill_name_collides_with_preexisting_regular_file(self):
        attack("fs:skill-name-collides-with-file")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            (skills_dir / "alpha").write_text("not a directory")
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertNotIn("Traceback", r.stderr)
            self.assertEqual((skills_dir / "alpha").read_text(), "not a directory")

    def test_skill_md_preexists_as_directory(self):
        attack("fs:skill-md-preexists-as-directory")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "learned-skills" / "alpha" / "SKILL.md").mkdir(parents=True)
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertNotIn("Traceback", r.stderr)

    def test_dangling_symlink_at_skill_name(self):
        if not CAN_SYMLINK:
            loud_skip("fs:dangling-symlink-at-skill-name", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:dangling-symlink-at-skill-name")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            nonexistent = Path(d) / "does_not_exist"
            (skills_dir / "alpha").symlink_to(nonexistent, target_is_directory=True)
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertFalse(nonexistent.exists())

    def test_legacy_flat_skill_file_preserved(self):
        attack("fs:legacy-flat-skill-file-preserved")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            (skills_dir / "alpha.md").write_text("LEGACY CONTENT")
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "# New"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((skills_dir / "alpha.md").read_text(), "LEGACY CONTENT")
            self.assertEqual((skills_dir / "alpha" / "SKILL.md").read_text(), "# New")

    def test_readonly_skills_dir_refused(self):
        if not READONLY_ENFORCED:
            loud_skip("fs:readonly-skills-dir", "chmod read-only probed and not enforced on this runner (likely root)")
            self.skipTest("chmod read-only probed and not enforced on this runner")
        attack("fs:readonly-skills-dir")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            os.chmod(skills_dir, 0o500)
            try:
                payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
                r = run(payload, home)
                self.assertEqual(r.returncode, 2, r.stderr)
            finally:
                os.chmod(skills_dir, 0o700)

    def test_readonly_store_root_refused(self):
        if not READONLY_ENFORCED:
            loud_skip("fs:readonly-store-root", "chmod read-only probed and not enforced on this runner (likely root)")
            self.skipTest("chmod read-only probed and not enforced on this runner")
        attack("fs:readonly-store-root")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            home.mkdir()
            os.chmod(home, 0o500)
            try:
                payload = json.dumps({"version": 1,
                                      "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}]})
                r = run(payload, home)
                self.assertEqual(r.returncode, 2, r.stderr)
            finally:
                os.chmod(home, 0o700)

    def test_corrupt_usage_json_refused(self):
        attack("fs:corrupt-usage-json")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            (skills_dir / ".usage.json").write_text("{not valid json")
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertNotIn("Traceback", r.stderr)
            self.assertEqual((skills_dir / ".usage.json").read_text(), "{not valid json")

    def test_usage_json_array_refused(self):
        attack("fs:usage-json-array")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            (skills_dir / ".usage.json").write_text("[1, 2, 3]")
            payload = json.dumps({"version": 1, "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual((skills_dir / ".usage.json").read_text(), "[1, 2, 3]")

    def test_nul_in_content_rejected_end_to_end(self):
        attack("fs:nul-in-content-end-to-end")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "a\x00b"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1, r.stderr)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_all_or_nothing_valid_memory_plus_symlinked_skill_dir(self):
        if not CAN_SYMLINK:
            loud_skip("fs:all-or-nothing-symlinked-skill", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("fs:all-or-nothing-symlinked-skill")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            outside = Path(d) / "outside"
            outside.mkdir()
            (skills_dir / "evil").symlink_to(outside, target_is_directory=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "valid"}],
                                  "skills": [{"name": "evil", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())
            self.assertEqual(list(outside.iterdir()), [])

    def test_all_or_nothing_valid_memory_plus_bad_skill_name(self):
        attack("fs:all-or-nothing-bad-skill-name")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "valid"}],
                                  "skills": [{"name": "../evil", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1, r.stderr)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_all_or_nothing_valid_memory_plus_corrupt_usage_json(self):
        attack("fs:all-or-nothing-corrupt-usage-json")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            (skills_dir / ".usage.json").write_text("not json")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "valid"}],
                                  "skills": [{"name": "alpha", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())
            self.assertEqual((skills_dir / ".usage.json").read_text(), "not json")

    def test_no_tmp_leftovers_after_failure(self):
        attack("fs:no-tmp-leftovers-after-failure")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "learned-skills" / "beta" / "SKILL.md").mkdir(parents=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}],
                                  "skills": [{"name": "beta", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            leftovers = list(home.rglob(".persist-tmp-*"))
            self.assertEqual(leftovers, [], f"leftover temp files: {leftovers}")

    def test_case_collision_alpha_ALPHA(self):
        """'alpha' + 'ALPHA' in one proposal must be REFUSED, on every runner.

        History, because this case is the reason the assertion is worded the
        way it is: this used to `finding(...)` and pass. On macOS and
        Windows CI (both probing `case-insensitive filesystem: AVAILABLE`)
        the two names produced two independent `.usage.json` records over a
        single folded directory entry, so one skill's content was destroyed
        -- and the sweep printed that fact into a green matrix rather than
        failing on it.

        `proposal_schema.validate_proposal` now rejects names that collide
        under casefold, and it does so WITHOUT consulting the filesystem.
        That makes this assertion platform-independent, which is a strict
        improvement over the old shape: the rejection is now proven on all
        six matrix cells instead of only on the two that could reproduce the
        collision. The CASE_INSENSITIVE_FS probe stays, but only to record
        which filesystem the run observed -- it no longer gates the check.
        """
        attack("fs:case-collision-alpha-ALPHA")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1, "skills": [
                {"name": "alpha", "content": "# lower"},
                {"name": "ALPHA", "content": "# upper"},
            ]})
            r = run(payload, home)
            self.assertNotIn("Traceback", r.stderr)
            # Exit 1 is validation refusal (where this is caught). Exit 2
            # would be the writer's cross-review guard. Exit 0 is a FAILURE
            # anywhere: on a case-insensitive filesystem it is the
            # content-destroying outcome, and on a case-sensitive one it
            # means a store that would be corrupt the moment it were synced
            # to macOS was written anyway.
            self.assertIn(r.returncode, (1, 2), r.stderr)
            self.assertRegex(r.stderr, r"case-fold")
            # A refusal must not half-apply.
            self.assertFalse((home / "learned-skills" / ".usage.json").exists(),
                             "a refused proposal must leave no .usage.json behind")
            self.assertFalse((home / "learned-skills" / "alpha").exists(),
                             "a refused proposal must write no skill directory")

    def test_case_variant_of_an_existing_skill_never_destroys_it(self):
        """The ACROSS-review half: 'alpha' persisted, then 'ALPHA' proposed.

        The schema check above cannot see this -- it only holds the proposal
        in hand. persist-proposal's `_assert_no_case_fold_collision` covers
        it by observing whether the path resolves onto a differently-cased
        real directory entry, so the behaviour legitimately differs by
        filesystem and both outcomes are asserted rather than one being
        skipped:

        * case-sensitive: two distinct skills, both survive intact;
        * case-insensitive: the second proposal is refused, exit 2, and the
          first skill's content is untouched.

        The outcome ruled out everywhere is 'accepted, and alpha's content
        is gone'.
        """
        attack("fs:case-collision-across-reviews")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            first = run(json.dumps({"version": 1, "skills": [
                {"name": "alpha", "content": "# lower"}]}), home)
            self.assertEqual(first.returncode, 0, first.stderr)
            r = run(json.dumps({"version": 1, "skills": [
                {"name": "ALPHA", "content": "# upper"}]}), home)
            self.assertNotIn("Traceback", r.stderr)
            skills = home / "learned-skills"
            if CASE_INSENSITIVE_FS:
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("case-folds onto existing skill", r.stderr)
                self.assertEqual(sorted(json.loads((skills / ".usage.json").read_text())),
                                 ["alpha"])
            else:
                loud_skip("fs:case-collision-across-reviews (refusal path)",
                          "probed filesystem is case-sensitive here, so 'ALPHA' "
                          "resolves to no existing entry and is correctly accepted "
                          "as a distinct skill; only the macOS/Windows cells can "
                          "exercise the refusal")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual((skills / "ALPHA" / "SKILL.md").read_text(), "# upper")
            # Asserted on BOTH branches: alpha survives either way.
            self.assertEqual((skills / "alpha" / "SKILL.md").read_text(), "# lower")

    def test_written_files_are_mode_0600(self):
        if IS_WINDOWS:
            loud_skip("fs:mode-0600-on-success",
                       "POSIX permission bits are not meaningful on Windows/NTFS ACLs")
            self.skipTest("POSIX mode bits not meaningful on Windows")
        attack("fs:mode-0600-on-success")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}],
                                  "skills": [{"name": "alpha", "content": "y"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            for p in (home / "memory" / "MEMORY.md",
                      home / "learned-skills" / "alpha" / "SKILL.md",
                      home / "learned-skills" / ".usage.json"):
                mode = stat.S_IMODE(p.stat().st_mode)
                self.assertEqual(mode, 0o600, f"{p} has mode {oct(mode)}")


# ===========================================================================
# Confinement backstop: bypass proposal_schema entirely, call _plan/_write_all
# directly with raw attacker-controlled names.
# ===========================================================================

RAW_BACKSTOP_NAMES = ["../../evil", "/tmp/evilpwn", "..", ".", "", "..\\evil", ".usage.json", "\x00evil"]
assert len(RAW_BACKSTOP_NAMES) == 8


class TestConfinementBackstop(unittest.TestCase):
    def test_confinement_backstop_sweep(self):
        for raw_name in RAW_BACKSTOP_NAMES:
            with self.subTest(name=repr(raw_name)):
                attack(f"confinement:{raw_name!r}")
                with tempfile.TemporaryDirectory() as d:
                    home = Path(d) / "store"
                    home.mkdir()
                    skills_dir = home / "learned-skills"
                    proposal = {"version": 1, "memory": [], "skills": [{"name": raw_name, "content": "pwned"}]}
                    try:
                        planned = WRITER_MOD._plan(proposal, home / "memory", skills_dir)
                        WRITER_MOD._write_all(planned)
                    except (WRITER_MOD.PersistError, OSError, ValueError):
                        pass  # refused -- correct
                    else:
                        self.fail(f"raw name {raw_name!r} was NOT refused by _plan/_write_all")
                    escaped = [p for p in Path(d).iterdir() if p != home]
                    self.assertEqual(escaped, [], f"raw name {raw_name!r}: paths escaped the store: {escaped}")


# ===========================================================================
# TOCTOU: race a thread swapping <name> between a real directory and a
# symlink pointing outside, while _plan/_write_all runs.
# ===========================================================================

class TestTOCTOU(unittest.TestCase):
    ITERATIONS = 40  # matches the prior ad-hoc sweep's iteration count

    # HISTORY: persist-proposal.py's docstrings used to acknowledge a
    # narrow, deliberately-unclosed race between the last confinement/
    # symlink check on stage_dir and the mkstemp() call that actually
    # resolved it again by path. Two independent measurements of that race
    # (a prior codified run of exactly this test reporting ~10%, and a
    # from-scratch reproduction at 18.3% / 11 of 60) superseded a much
    # older, wrong "0 escapes in 40 iterations" claim -- see the correction
    # appended to
    # .superpowers/sdd/2026-07-25-harness-neutral-persistence/progress.md
    # and fix-p3-toctou-report.md for the full record, including the
    # determination that the leaked material was real file content
    # (SKILL.md / staged .persist-tmp-* files carrying actual proposal
    # content), never just empty directories.
    #
    # FIX: persist-proposal.py now does the entire write -- every directory
    # in the chain below the trusted store root, the target stat, the
    # staged-file create, and the final rename -- through dir_fd-anchored
    # syscalls (O_NOFOLLOW open/mkdir/stat/replace/unlink relative to an
    # already-open directory fd) whenever DIR_FD_SUPPORTED is true (a real
    # functional probe, not a platform-name check or a bare
    # os.supports_dir_fd lookup -- see persist-proposal.py's
    # _probe_dir_fd_support docstring for why the latter alone is not
    # trustworthy here). That closes the exact re-resolution race this test
    # exercises: measured at 0/300 escapes in a standalone harness at higher
    # iteration counts than this suite runs by default (see
    # fix-p3-toctou-report.md), so this test now asserts zero tolerance
    # wherever dir_fd is actually available.
    #
    # RESIDUAL: dir_fd has no equivalent on native Windows (`os.mkdir(...,
    # dir_fd=...)` etc. raise NotImplementedError there; DIR_FD_SUPPORTED's
    # functional probe correctly reports False there). On such a platform
    # this test measures and reports the rate without failing the suite
    # over an already-known, already-disclosed, currently-unfixable-with-
    # the-stdlib gap -- a hard failure there would not be honest about
    # what's actually achievable without a Windows-native primitive this
    # project doesn't have.
    ESCAPE_RATE_CEILING = 0.5  # only used on the no-dir_fd (report-only) branch

    # FLAKE ANALYSIS (final closeout round). Its sibling in
    # tests/test-persist-proposal.py asserted that a race MUST manifest
    # within N iterations and false-failed on an idle runner; that shape has
    # been removed there in favour of a forced interleaving. This test was
    # re-examined for the same defect and does NOT have it, in either
    # branch, so it is deliberately left racing:
    #
    #  * dir_fd supported: asserts `escapes == 0`. That is the safe
    #    direction -- a race NOT occurring. Contention only ever gives the
    #    attacker more chances, so an idle runner cannot manufacture a
    #    failure here; only a real regression can. Deterministic in
    #    practice.
    #  * dir_fd unsupported (native Windows only): asserts
    #    `rate <= ESCAPE_RATE_CEILING`. This is a probabilistic UPPER bound,
    #    not a must-occur assertion, and the margin is enormous -- the
    #    measured rate is ~10-18% against a 50% ceiling over 40 iterations,
    #    so a false failure needs a deviation that would itself be the
    #    story. It also fails in the informative direction: it fires only on
    #    a total confinement collapse, which is worth a red build. Zero
    #    escapes passes it, so an idle runner is fine here too.
    #
    # The `finding(...)` call on that branch is report-only by design: the
    # residual it names is known, disclosed, and not fixable stdlib-only.

    def test_toctou_symlink_swap_race(self):
        if not CAN_SYMLINK:
            loud_skip("toctou:symlink-swap-race", "symlink creation probed and unavailable")
            self.skipTest("symlink creation probed and unavailable")
        attack("toctou:symlink-swap-race")
        escapes = 0
        for _ in range(self.ITERATIONS):
            with tempfile.TemporaryDirectory() as d:
                home = Path(d) / "store"
                skills_dir = home / "learned-skills"
                skills_dir.mkdir(parents=True)
                outside = Path(d) / "outside"
                outside.mkdir()
                skill_dir = skills_dir / "alpha"
                skill_dir.mkdir()

                stop = threading.Event()

                def swap():
                    while not stop.is_set():
                        try:
                            if skill_dir.is_symlink():
                                skill_dir.unlink()
                                skill_dir.mkdir()
                            elif skill_dir.exists():
                                shutil.rmtree(skill_dir)
                                skill_dir.symlink_to(outside, target_is_directory=True)
                        except OSError:
                            pass  # lost the race this tick -- fine, keep spinning

                racer = threading.Thread(target=swap, daemon=True)
                racer.start()
                try:
                    proposal = {"version": 1, "memory": [], "skills": [{"name": "alpha", "content": "pwned"}]}
                    planned = WRITER_MOD._plan(proposal, home / "memory", skills_dir)
                    WRITER_MOD._write_all(planned)
                except Exception:
                    pass
                finally:
                    stop.set()
                    racer.join(timeout=1)

                if list(outside.iterdir()):
                    escapes += 1

        rate = escapes / self.ITERATIONS
        dir_fd = WRITER_MOD.DIR_FD_SUPPORTED
        print(f"[TOCTOU] dir_fd={'supported' if dir_fd else 'UNSUPPORTED (fallback path)'} "
              f"{escapes}/{self.ITERATIONS} ({rate:.0%}) iterations escaped the store "
              "under active symlink-swap contention", file=sys.stderr)

        if not dir_fd:
            if escapes:
                finding(
                    f"TOCTOU: {escapes}/{self.ITERATIONS} ({rate:.0%}) symlink-swap-race iterations "
                    "wrote content outside the store on a platform without dir_fd support -- the "
                    "known, disclosed residual of the path-based fallback writer (see "
                    "_write_all_path's docstring and fix-p3-toctou-report.md). Not fixable with the "
                    "stdlib alone on this platform.")
            self.assertLessEqual(
                rate, self.ESCAPE_RATE_CEILING,
                f"{escapes}/{self.ITERATIONS} ({rate:.0%}) exceeds the sanity ceiling of "
                f"{self.ESCAPE_RATE_CEILING:.0%} -- this looks like a total confinement "
                "collapse, not the known narrow residual.")
            return

        # dir_fd IS supported here: zero tolerance. Any escape at all is a
        # regression in the fix this test exists to hold the line on.
        self.assertEqual(
            escapes, 0,
            f"{escapes}/{self.ITERATIONS} ({rate:.0%}) escaped the store with dir_fd support "
            "available -- the TOCTOU fix has regressed. See fix-p3-toctou-report.md for the "
            "design this is supposed to guarantee.")


if __name__ == "__main__":
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=1)
    result = runner.run(suite)

    print()
    print(f"--- Adversarial sweep summary ---")
    print(f"Attacks executed: {ATTACK_COUNT} (floor: {MIN_ATTACK_COUNT})")
    if SKIPPED_ATTACKS:
        print(f"Attacks loudly skipped ({len(SKIPPED_ATTACKS)}):")
        for name, reason in SKIPPED_ATTACKS:
            print(f"  - {name}: {reason}")
    if FINDINGS:
        print(f"Findings recorded ({len(FINDINGS)}): see fix-p1-p2-report.md")

    ok = result.wasSuccessful()
    if ATTACK_COUNT < MIN_ATTACK_COUNT:
        print(f"FAIL: only {ATTACK_COUNT} attacks executed, below the floor of {MIN_ATTACK_COUNT}. "
              "A suite that silently stopped attacking is worse than none.")
        ok = False

    sys.exit(0 if ok else 1)
