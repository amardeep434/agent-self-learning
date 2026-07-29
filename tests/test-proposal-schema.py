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
        # Each chunk is exactly MAX_SKILL_BYTES, so together they exceed total cap
        chunk = "x" * ps.MAX_SKILL_BYTES
        self._bad(lambda p: p.__setitem__(
            "skills", [{"name": f"s{i}", "content": chunk} for i in range(9)]))

    def test_non_dict(self):
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal([1, 2, 3])

    def test_extract_returns_none_when_absent(self):
        self.assertIsNone(ps.extract_proposal("no json here at all"))


class TestSecurityCritical1TrailingNewline(unittest.TestCase):
    """CRITICAL 1: skill-name regex accepts trailing newline"""
    def _reject_name(self, name):
        p = good()
        p["skills"][0]["name"] = name
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_skill_name_trailing_newline(self):
        self._reject_name("evil\n")

    def test_skill_name_embedded_newline(self):
        self._reject_name("a\nb")

    def test_skill_name_only_newline(self):
        self._reject_name("\n")

    def test_skill_name_trailing_carriage_return(self):
        self._reject_name("a\r")


class TestSecurityCritical2RecursionError(unittest.TestCase):
    """CRITICAL 2: RecursionError escapes extract_proposal"""
    def test_deeply_nested_input_is_never_a_usable_proposal(self):
        """Deep nesting must not crash, and must never yield a valid proposal.

        This used to assert `is None`, which encoded a CPython implementation
        detail rather than the security property. Through 3.13 `json.loads`
        raised RecursionError on this input and extract_proposal caught it; in
        3.14 the parser is no longer recursive, so the same payload parses in
        ~0.02s and a dict comes back. MEASURED on 3.14.6: the old assertion
        failed while nothing about the system's safety had changed.

        What actually matters, and what is asserted here: the call does not
        raise, and whatever it returns is rejected by validate_proposal. That
        holds on every version, and is strictly stronger than `is None` --
        a parser that returned None for the wrong reason would have passed the
        old test.
        """
        nested = '{"a":' + '['*100000 + ']'*100000 + '}'
        result = ps.extract_proposal(nested)   # must not raise
        if result is not None:
            with self.assertRaises(Exception):
                ps.validate_proposal(result)

    def test_oversized_input_returns_none(self):
        # Input exceeding MAX_INPUT_BYTES should return None before regex
        oversized = 'x' * (ps.MAX_INPUT_BYTES + 1)
        result = ps.extract_proposal(oversized)
        self.assertIsNone(result)


class TestSecurityCritical2Fallback(unittest.TestCase):
    """CRITICAL 2: Fenced garbage falls back to bare scan"""
    def test_fenced_garbage_then_valid_bare_json(self):
        # Fenced candidate fails to parse, should fall back to bare JSON
        text = 'chatter\n```json\ngarbage\n```\n{"version": 1}'
        result = ps.extract_proposal(text)
        self.assertEqual(result, {"version": 1})


class TestImportant3UnhashableTypes(unittest.TestCase):
    """IMPORTANT 3: unhashable values raise TypeError, not ValidationError"""
    def test_unhashable_file_raises_validation_error(self):
        p = good()
        p["memory"][0]["file"] = []
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_unhashable_mode_raises_validation_error(self):
        p = good()
        p["memory"][0]["mode"] = {}
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)


class TestImportant4MemoryCaps(unittest.TestCase):
    """IMPORTANT 4: cap on memory entries and duplicate detection"""
    def test_too_many_memory_entries(self):
        p = good()
        p["memory"] = [
            {"file": "MEMORY.md", "mode": "replace", "content": "a"},
            {"file": "USER.md", "mode": "replace", "content": "b"},
            {"file": "MEMORY.md", "mode": "append", "content": "c"},
            {"file": "USER.md", "mode": "append", "content": "d"},
            {"file": "MEMORY.md", "mode": "replace", "content": "e"},
        ]
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_duplicate_memory_files(self):
        p = good()
        p["memory"] = [
            {"file": "MEMORY.md", "mode": "replace", "content": "a"},
            {"file": "MEMORY.md", "mode": "append", "content": "b"},
        ]
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_duplicate_skill_names(self):
        p = good()
        p["skills"] = [
            {"name": "my-skill", "content": "a"},
            {"name": "my-skill", "content": "b"},
        ]
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)


class TestCaseFoldSkillCollision(unittest.TestCase):
    """Two skill names in ONE proposal that fold to the same directory entry.

    Reported as an unfixed finding by tests/test-adversarial-sweep.py on
    macOS and Windows CI: 'alpha' and 'ALPHA' produced two independent
    .usage.json records over a single directory, so one skill's content was
    destroyed. Rejected at the schema layer, which needs no filesystem at
    all -- so unlike the sweep's probe these assertions are meaningful on
    every runner, including case-sensitive Linux.
    """

    def _rejects(self, a, b):
        p = good()
        p["skills"] = [{"name": a, "content": "x"}, {"name": b, "content": "y"}]
        with self.assertRaises(ps.ValidationError) as ctx:
            ps.validate_proposal(p)
        # The message must name the problem, not just fail: this rejection
        # reaches a human only through persist-failures.log.
        self.assertIn("case-folded", str(ctx.exception))

    def test_alpha_and_upper_alpha_rejected(self):
        self._rejects("alpha", "ALPHA")

    def test_mixed_case_variants_rejected(self):
        self._rejects("My-Skill", "my-skill")

    def test_single_character_case_variant_rejected(self):
        self._rejects("a", "A")

    def test_distinct_names_still_accepted(self):
        p = good()
        p["skills"] = [{"name": "alpha", "content": "x"}, {"name": "beta", "content": "y"}]
        out = ps.validate_proposal(p)
        self.assertEqual([s["name"] for s in out["skills"]], ["alpha", "beta"])

    def test_exact_casing_is_preserved_not_normalised(self):
        """Rejection must not become silent lowercasing of a legal name."""
        p = good()
        p["skills"] = [{"name": "MySkill", "content": "x"}]
        out = ps.validate_proposal(p)
        self.assertEqual(out["skills"][0]["name"], "MySkill")


class TestImportant5WindowsReserved(unittest.TestCase):
    """IMPORTANT 5: Windows reserved device names validate"""
    def test_windows_reserved_con(self):
        p = good()
        p["skills"][0]["name"] = "CON"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_windows_reserved_nul_lowercase(self):
        p = good()
        p["skills"][0]["name"] = "nul"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_windows_reserved_com1(self):
        p = good()
        p["skills"][0]["name"] = "COM1"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_windows_reserved_lpt9(self):
        p = good()
        p["skills"][0]["name"] = "LPT9"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)


class TestMinor6VersionType(unittest.TestCase):
    """MINOR 6: True and 1.0 pass the version check"""
    def test_version_true_rejected(self):
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal({"version": True})

    def test_version_float_rejected(self):
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal({"version": 1.0})


class TestMinor8NulBytes(unittest.TestCase):
    """MINOR 8: NUL bytes in content"""
    def test_nul_byte_in_memory_content_rejected(self):
        p = good()
        p["memory"][0]["content"] = "hello\x00world"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_nul_byte_in_skill_content_rejected(self):
        p = good()
        p["skills"][0]["content"] = "# Skill\x00"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)


class TestTypeChecks(unittest.TestCase):
    """Ensure all type checks are enforced"""
    def test_memory_not_a_list(self):
        p = good()
        p["memory"] = "not a list"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_skills_not_a_list(self):
        p = good()
        p["skills"] = "not a list"
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_memory_entry_not_a_dict(self):
        p = good()
        p["memory"] = ["not a dict"]
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_skill_entry_not_a_dict(self):
        p = good()
        p["skills"] = ["not a dict"]
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_memory_content_not_a_string(self):
        p = good()
        p["memory"][0]["content"] = 123
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_skill_content_not_a_string(self):
        p = good()
        p["skills"][0]["content"] = 123
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)


class TestByteCounting(unittest.TestCase):
    """Ensure byte counting (not char counting) is used"""
    def test_multibyte_counted_as_bytes(self):
        # "é" is 2 bytes in UTF-8, so this should exceed the byte limit
        p = good()
        p["memory"][0]["content"] = "é" * (ps.MAX_MEMORY_BYTES // 2 + 1)
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)

    def test_skill_byte_cap(self):
        # One skill exceeding the per-skill byte cap
        p = good()
        p["skills"][0]["content"] = "x" * (ps.MAX_SKILL_BYTES + 1)
        with self.assertRaises(ps.ValidationError):
            ps.validate_proposal(p)


class TestInputMutation(unittest.TestCase):
    """Ensure validate_proposal does not mutate input"""
    def test_validate_does_not_mutate_input(self):
        p = good()
        original = str(p)
        try:
            ps.validate_proposal(p)
        except ps.ValidationError:
            pass
        self.assertEqual(str(p), original)


class TestExtractEdgeCases(unittest.TestCase):
    """Additional extract_proposal tests"""
    def test_extract_non_string_returns_none(self):
        result = ps.extract_proposal(123)
        self.assertIsNone(result)

    def test_extract_multiple_json_objects(self):
        # Multiple JSON objects in text - should extract the valid one from bare scan
        text = '{"version": 1}\nsome text {"extra": "data"}'
        result = ps.extract_proposal(text)
        # find("{") gets first, rfind("}") gets last, so we get the full text
        # which is not valid JSON, so returns None - this is expected behavior
        self.assertIsNone(result)


class TestFencePerformance(unittest.TestCase):
    """Regression tests for ReDoS vulnerability in fence scanning"""

    def test_many_fence_openers_is_fast(self):
        """872 KB payload with many fence openers but no closers must complete quickly.

        Adversarial input: ("```json\n{" + "a"*100) * 8000 = 872 KB
        Previous regex took 26+ seconds due to catastrophic backtracking.
        Linear scanning should complete in milliseconds, well under 1.0 second.
        """
        import time
        payload = ("```json\n{" + "a"*100) * 8000
        start = time.monotonic()
        result = ps.extract_proposal(payload)
        elapsed = time.monotonic() - start

        self.assertIsNone(result, "Should return None, not hang")
        self.assertLess(elapsed, 1.0, f"Must complete in under 1.0 seconds, took {elapsed:.4f}s")

    def test_first_valid_fenced_block_wins(self):
        """When multiple fenced blocks exist, first valid JSON wins"""
        text = 'text\n```json\n{"version": 1}\n```\nmore\n```json\n{"version": 2}\n```'
        result = ps.extract_proposal(text)
        self.assertEqual(result, {"version": 1})

    def test_ordinary_fenced_block(self):
        """Prose, valid fenced JSON block, trailing prose: extracts correctly"""
        text = 'Some prose explaining things\n```json\n{"version": 1}\n```\nMore trailing text'
        result = ps.extract_proposal(text)
        self.assertEqual(result, {"version": 1})

    def test_fence_without_closer_falls_back_to_bare(self):
        """Opening fence with no closer falls back to bare JSON extraction"""
        text = '```json\n{"version": 1}\nno closing fence'
        result = ps.extract_proposal(text)
        # Falls back to bare JSON scan and finds the JSON object
        self.assertEqual(result, {"version": 1})

    def test_fenced_block_with_optional_language_tag(self):
        """Fence without json tag should still extract"""
        text = '```\n{"version": 1}\n```'
        result = ps.extract_proposal(text)
        self.assertEqual(result, {"version": 1})


class TestMemoryEntryLimitIsHonest(unittest.TestCase):
    """MAX_MEMORY_ENTRIES must not advertise headroom no valid proposal can use.

    Memory entries are allow-listed by exact filename AND de-duplicated, so the
    real ceiling is len(ALLOWED_MEMORY_FILES). The constant was a hand-written
    4, whose error message ("at most 4 memory entries per proposal") contradicted
    the limit actually enforced -- the same prompt-vs-schema contradiction that
    discarded a whole paid review on 2026-07-28 (see
    tests/test-review-failure-legibility.sh).
    """

    def test_limit_equals_number_of_allowed_files(self):
        self.assertEqual(ps.MAX_MEMORY_ENTRIES, len(ps.ALLOWED_MEMORY_FILES))

    def test_no_valid_proposal_can_exceed_the_limit(self):
        """Every entry count up to the limit is reachable; one more never is."""
        files = sorted(ps.ALLOWED_MEMORY_FILES)
        at_limit = {"version": 1,
                    "memory": [{"file": f, "mode": "append", "content": "x"}
                               for f in files]}
        # The largest proposal the allow-list permits must validate.
        self.assertEqual(len(ps.validate_proposal(at_limit)["memory"]),
                         ps.MAX_MEMORY_ENTRIES)
        # One more entry can only be a duplicate, so it must be rejected -- and
        # the count check must be what rejects it, so the message names the
        # limit rather than blaming a duplicate the reviewer could not avoid.
        over = {"version": 1,
                "memory": at_limit["memory"] + [{"file": files[0], "mode": "append",
                                                 "content": "x"}]}
        with self.assertRaises(ps.ValidationError) as ctx:
            ps.validate_proposal(over)
        self.assertIn(f"at most {ps.MAX_MEMORY_ENTRIES} memory entries", str(ctx.exception))


class TestMemoryEntriesAreSelfContained(unittest.TestCase):
    """Memory is ONE flat file, so a `[Title](title.md)` link is always dead.

    Measured on the user's real MEMORY.md: 15 of 52 lines carried one, and
    none of the 15 targets existed anywhere in the store. The OUTPUT CONTRACT
    (lib/review-common.sh) now states the rule; this is the enforcement half,
    exactly as the one-entry-per-file rule is stated there and enforced here.
    """

    def _entry(self, content):
        return {"version": 1,
                "memory": [{"file": "MEMORY.md", "mode": "append", "content": content}]}

    def test_dangling_md_link_is_stripped_and_the_lesson_kept(self):
        """Strip, do not refuse.

        Refusing cost a whole paid review on 2026-07-29 -- the live
        persist-failures.log carried "'](capture-exit-code-separately.md)'
        points at a file that does not exist" and the entire proposal, memory
        and skills alike, was discarded over one malformed line.

        Stripping is safe HERE because nothing is lost: the visible text
        carries the lesson and the target carried no information, since memory
        is one flat file. That is why this may be silent while the duplicate
        check remains a loud refusal -- a duplicate discards something a reader
        might have wanted, a dead link discards nothing.
        """
        out = ps.validate_proposal(self._entry(
            "- [Probe the real key name first](probe-key-name.md) - a guess is my bug.\n"))
        content = out["memory"][0]["content"]
        self.assertEqual(
            content, "- Probe the real key name first - a guess is my bug.\n")
        self.assertNotIn("probe-key-name.md", content)
        self.assertNotIn("](", content)

    def test_link_with_anchor_is_also_stripped(self):
        out = ps.validate_proposal(self._entry("- [x](docs/a.md#heading) - y\n"))
        self.assertEqual(out["memory"][0]["content"], "- x - y\n")

    def test_orphaned_target_leaves_no_dangling_bracket(self):
        """The strip runs in two passes so a target with no "[text]" before it
        cannot survive as "](...)" -- which would be a worse artefact than the
        link it replaced."""
        out = ps.validate_proposal(self._entry("- orphan ](stray.md) tail\n"))
        self.assertNotIn("](", out["memory"][0]["content"])
        self.assertIn("orphan", out["memory"][0]["content"])
        self.assertIn("tail", out["memory"][0]["content"])

    def test_prose_naming_a_file_is_untouched(self):
        """Deliberately narrow. Memory is FULL of legitimate filenames --
        `tests/run-all.sh`, `paths.py`, `see CLAUDE.md` -- and rejecting
        those would reject nearly every real entry."""
        for content in ("- see CLAUDE.md for the layout\n",
                        "- run tests/run-all.sh (53 suites) before pushing\n",
                        "- persist-proposal.py owns every write (not review-common.sh)\n"):
            with self.subTest(content=content):
                out = ps.validate_proposal(self._entry(content))
                self.assertEqual(out["memory"][0]["content"], content,
                                 "prose naming a file must survive byte-identical")

    def test_non_md_link_is_untouched(self):
        """A URL is a real, resolvable reference; only per-entry .md files
        are the invented convention."""
        content = "- see [the run](https://github.com/x/y/actions)\n"
        out = ps.validate_proposal(self._entry(content))
        self.assertEqual(out["memory"][0]["content"], content,
                         "a URL is resolvable; only .md targets are the invented convention")

    def test_skill_content_may_still_link(self):
        """Skills DO live in files (learned-skills/<name>/SKILL.md), so a
        cross-reference there is not dangling by construction."""
        ps.validate_proposal({"version": 1,
                              "skills": [{"name": "s", "content": "see [other](SKILL.md)"}]})


if __name__ == "__main__":
    unittest.main()
