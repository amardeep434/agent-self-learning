import importlib.util
import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "persist-proposal.py"


def _load_writer_module():
    """Import persist-proposal.py directly (hyphenated filename, no import)."""
    spec = importlib.util.spec_from_file_location("persist_proposal", WRITER)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ROOT / "scripts" / "lib"))
    spec.loader.exec_module(module)
    return module


def run(stdin_text, home, extra_args=()):
    env = dict(os.environ, AGENT_LEARNING_HOME=str(home))
    return subprocess.run([sys.executable, str(WRITER), *extra_args],
                          input=stdin_text, capture_output=True, text=True, env=env)


# ---------------------------------------------------------------------------
# Capability probes, not platform-name assumptions.
#
# These tests used to skip on `sys.platform.startswith("win")` on the theory
# that symlink/hardlink creation requires elevated privilege on Windows.
# That's often true for a plain user session, but GitHub Actions'
# windows-latest runner frequently runs as (or equivalent to) an
# administrator, and Developer Mode can also unlock unprivileged symlink
# creation -- so the platform name alone does not tell you whether the
# attack surface these tests exercise is actually reachable on a given
# runner. Measuring it directly (the same discipline already used in
# tests/test-path-compare-lib.sh's `[[ -L ]]` probe after `ln -s`, and
# tests/test-doctor.sh's real write attempt after `chmod 500`) means: if
# windows-latest CAN create symlinks, these security tests actually run
# there instead of silently reporting green while testing nothing.
# ---------------------------------------------------------------------------

def _can_symlink():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d) / "target"
        target.write_text("x")
        link = Path(d) / "link"
        try:
            link.symlink_to(target)
        except OSError:
            return False
        return True


def _can_hardlink():
    with tempfile.TemporaryDirectory() as d:
        target = Path(d) / "target"
        target.write_text("x")
        link = Path(d) / "link"
        try:
            os.link(target, link)
        except OSError:
            return False
        return True


CAN_SYMLINK = _can_symlink()
CAN_HARDLINK = _can_hardlink()
# os.O_NOFOLLOW is a genuinely POSIX-only primitive (absent from the os
# module's namespace entirely on native Windows) -- this one *is* a
# structural platform fact, not something to probe by attempting an action,
# so checking for the attribute is the correct probe for it.
HAS_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0) != 0

# DIR_FD_SUPPORTED (fix-p3-toctou): the same real functional probe
# persist-proposal.py itself uses to decide whether it can run the
# dir_fd-anchored writer (_write_all_fd) or must fall back to the weaker,
# disclosed-residual path-based one (_write_all_path). Imported from the
# module under test rather than reimplemented here, since a second,
# independent implementation of "is dir_fd usable" could silently drift
# from the one that actually gates production behaviour.
_writer_for_probe = _load_writer_module()
DIR_FD_SUPPORTED = _writer_for_probe.DIR_FD_SUPPORTED

print(f"[capability probe] symlink creation: {'AVAILABLE' if CAN_SYMLINK else 'UNAVAILABLE (probed, not platform-assumed)'}",
      file=sys.stderr)
print(f"[capability probe] hardlink creation: {'AVAILABLE' if CAN_HARDLINK else 'UNAVAILABLE (probed, not platform-assumed)'}",
      file=sys.stderr)
print(f"[capability probe] O_NOFOLLOW: {'AVAILABLE' if HAS_O_NOFOLLOW else 'UNAVAILABLE (POSIX-only primitive)'}",
      file=sys.stderr)
print(f"[capability probe] dir_fd (functional): {'AVAILABLE' if DIR_FD_SUPPORTED else 'UNAVAILABLE (e.g. native Windows)'}",
      file=sys.stderr)


class TestWrites(unittest.TestCase):
    def test_writes_memory_and_skill(self):
        """C4: skills must land as <name>/SKILL.md (a directory), not a flat
        <name>.md file -- inject-agents-md.py, curator-run.sh, and
        skill-lifecycle.py all require a directory, so a flat file is
        syntactically written but invisible to every consumer."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "remembered"}],
                                  "skills": [{"name": "alpha", "content": "# Alpha"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "remembered")
            self.assertEqual((home / "learned-skills" / "alpha" / "SKILL.md").read_text(), "# Alpha")
            self.assertFalse((home / "learned-skills" / "alpha.md").exists())

    def test_writes_usage_json_entry_for_new_skill(self):
        """C4: nothing updated .usage.json either, so the lifecycle state
        machine could never see an agent-authored skill at all -- it only
        walks that file's keys."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "skills": [{"name": "alpha", "content": "# Alpha"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            usage = json.loads((home / "learned-skills" / ".usage.json").read_text())
            self.assertEqual(usage["alpha"]["created_by"], "agent")
            self.assertEqual(usage["alpha"]["state"], "active")
            self.assertFalse(usage["alpha"]["pinned"])
            self.assertEqual(usage["alpha"]["use_count"], 0)
            self.assertIn("created_at", usage["alpha"])
            self.assertIn("last_patched_at", usage["alpha"])

    def test_refresh_preserves_lifecycle_fields_but_bumps_last_patched_at(self):
        """Re-persisting an existing skill must not clobber a human's pin,
        the lifecycle state, or accumulated use_count -- only content and
        last_patched_at (the activity signal for 'content was patched')
        should change."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            (skills_dir / "alpha").mkdir()
            (skills_dir / "alpha" / "SKILL.md").write_text("# Old")
            (skills_dir / ".usage.json").write_text(json.dumps({
                "alpha": {"created_by": "agent", "created_at": "2020-01-01T00:00:00+00:00",
                          "state": "stale", "pinned": True, "use_count": 7}
            }))
            payload = json.dumps({"version": 1,
                                  "skills": [{"name": "alpha", "content": "# New"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((skills_dir / "alpha" / "SKILL.md").read_text(), "# New")
            usage = json.loads((skills_dir / ".usage.json").read_text())["alpha"]
            self.assertEqual(usage["created_at"], "2020-01-01T00:00:00+00:00")
            self.assertEqual(usage["state"], "stale")
            self.assertTrue(usage["pinned"])
            self.assertEqual(usage["use_count"], 7)
            self.assertNotEqual(usage.get("last_patched_at"), None)

    def test_usage_json_and_skill_content_write_atomically(self):
        """Both the SKILL.md and the .usage.json entry must land in the same
        staged-then-renamed transaction: a crash cannot leave one without
        the other. Simulated here by colliding a *second* skill's directory
        with a pre-existing file, which must abort the whole write -- so the
        first skill's SKILL.md and the merged .usage.json (which already
        includes the first skill) must both be absent afterward."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            skills_dir = home / "learned-skills"
            skills_dir.mkdir(parents=True)
            # "beta" pre-exists as a plain file, not a directory -- mkdir(name)
            # for the second skill will fail with FileExistsError.
            (skills_dir / "beta").write_text("not a directory")
            payload = json.dumps({"version": 1,
                                  "skills": [{"name": "alpha", "content": "# Alpha"},
                                             {"name": "beta", "content": "# Beta"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2, r.stderr)
            # The directory itself may be pre-created (mkdir is not a content
            # commit), but no file content may have landed: neither the
            # first skill's SKILL.md nor the merged .usage.json (which
            # already includes the first skill by the time staging fails on
            # the second) is committed.
            self.assertFalse((skills_dir / "alpha" / "SKILL.md").exists())
            self.assertFalse((skills_dir / ".usage.json").exists())

    def test_append_mode_appends(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory").mkdir(parents=True)
            (home / "memory" / "MEMORY.md").write_text("first\n")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "second\n"}]})
            self.assertEqual(run(payload, home).returncode, 0)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "first\nsecond\n")

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home, extra_args=("--dry-run",))
            self.assertEqual(r.returncode, 0)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_no_json_is_success_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            r = run("the model just chatted at us", home)
            self.assertEqual(r.returncode, 0)
            self.assertFalse((home / "memory").exists())


class TestRejects(unittest.TestCase):
    def test_dotted_skill_name_rejects_whole_proposal_including_valid_memory(self):
        """I8: the reviewer prompts used to state a dot-inclusive skill-name
        charset (^[a-z0-9][a-z0-9._-]*$) that contradicts proposal_schema's
        actual regex (no dots). A model that obeyed the (now-corrected)
        stated rule with a name like 'git.rebase' would get the entire
        proposal rejected -- and since validation is all-or-nothing, valid
        memory entries in the same proposal are discarded with it. This
        pins that exact scenario from the finding as a regression test,
        independent of which way the prompt-vs-schema mismatch gets fixed."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace",
                                              "content": "valid entry"}],
                                  "skills": [{"name": "git.rebase", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1, r.stderr)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())
            self.assertIn("git.rebase", r.stderr)

    def test_invalid_proposal_exits_1_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "../escape.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((Path(d).parent / "escape.md").exists())

    def test_partial_validity_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "ok"}],
                                  "skills": [{"name": "../evil", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())

    def test_symlinked_target_is_refused(self):
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("original")
            (home / "memory" / "MEMORY.md").symlink_to(outside)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "original")


class TestFixRound1Regressions(unittest.TestCase):
    """Regression coverage for findings from the round-1 adversarial review.

    Each of these reproduces a scenario found during manual adversarial
    testing (not part of the original 7); without the corresponding
    protection in persist-proposal.py, each of these fails.
    """

    def test_symlinked_root_directory_is_refused(self):
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            home.mkdir()
            outside_dir = Path(d) / "outside_dir"
            outside_dir.mkdir()
            (home / "memory").symlink_to(outside_dir, target_is_directory=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(list(outside_dir.iterdir()), [])

    def test_target_is_a_directory_is_refused_without_traceback(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory" / "MEMORY.md").mkdir(parents=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertNotIn("Traceback", r.stderr)

    def test_directory_collision_on_second_entry_leaves_first_uncommitted(self):
        """Post-C4-fix, a skill's target is <name>/SKILL.md; the collision
        that matters now is SKILL.md itself pre-existing as a directory
        inside an otherwise-normal skill directory."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "learned-skills" / "beta" / "SKILL.md").mkdir(parents=True)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "replace",
                                              "content": "should-not-persist"}],
                                  "skills": [{"name": "beta", "content": "# Beta"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertFalse((home / "memory" / "MEMORY.md").exists())
            self.assertFalse((home / "learned-skills" / ".usage.json").exists())

    def test_symlinked_skill_directory_is_refused(self):
        """New attack surface from C4: a skill name now maps to a
        *directory*, not a flat file. An attacker who can plant
        learned-skills/<name> as a symlink before the proposal runs must not
        be able to redirect the write anywhere outside the store."""
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "learned-skills").mkdir(parents=True)
            outside = Path(d) / "outside"
            outside.mkdir()
            (home / "learned-skills" / "evil").symlink_to(outside, target_is_directory=True)
            payload = json.dumps({"version": 1,
                                  "skills": [{"name": "evil", "content": "pwned"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(list(outside.iterdir()), [])

    def test_skill_name_cannot_collide_with_usage_json(self):
        """The schema's skill-name regex forbids a leading dot, but this is
        the filesystem-level backstop: a skill directory must never be able
        to land on the exact name of the shared metadata file."""
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            payload = json.dumps({"version": 1,
                                  "skills": [{"name": ".usage.json", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 1)  # rejected by proposal_schema's regex

    def test_append_through_symlinked_existing_file_is_refused(self):
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("original")
            (home / "memory" / "MEMORY.md").symlink_to(outside)
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "original")

    def test_append_through_hardlinked_existing_file_is_refused(self):
        if not CAN_HARDLINK:
            self.skipTest("hardlink creation probed and unavailable on this runner")
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / "store"
            (home / "memory").mkdir(parents=True)
            outside = Path(d) / "outside.md"
            outside.write_text("SECRET")
            os.link(outside, home / "memory" / "MEMORY.md")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(outside.read_text(), "SECRET")

    def test_append_on_non_utf8_existing_file_is_refused_without_traceback(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            (home / "memory").mkdir(parents=True)
            (home / "memory" / "MEMORY.md").write_bytes(b"\xff\xfe not valid utf-8")
            payload = json.dumps({"version": 1,
                                  "memory": [{"file": "MEMORY.md", "mode": "append", "content": "x"}]})
            r = run(payload, home)
            self.assertEqual(r.returncode, 2)
            self.assertNotIn("Traceback", r.stderr)


class TestInternalGuardsUnreachableThroughSchema(unittest.TestCase):
    """Direct unit tests for defence-in-depth checks the current schema makes
    unreachable through the public CLI.

    proposal_schema's exact allow-listed memory filenames and slash-free
    skill-name regex mean a subprocess call can never actually produce a
    `target` outside `root`, nor a filename containing a path separator --
    so `_assert_inside`'s parent-comparison branch and `_open_nofollow_fd`'s
    O_NOFOLLOW/ELOOP handling can't be exercised black-box. Call them
    directly so a regression in either is still caught, even though neither
    is adversarially reachable while proposal_schema's current guarantees
    hold.
    """

    def setUp(self):
        self.mod = _load_writer_module()

    def test_assert_inside_rejects_target_outside_root(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "root"
            root.mkdir()
            outside = Path(d) / "outside" / "file.md"
            outside.parent.mkdir()
            with self.assertRaises(self.mod.PersistError):
                self.mod._assert_inside(root, outside)

    def test_open_nofollow_fd_rejects_symlink(self):
        if not HAS_O_NOFOLLOW:
            self.skipTest("O_NOFOLLOW probed and unavailable (POSIX-only primitive)")
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner")
        with tempfile.TemporaryDirectory() as d:
            outside = Path(d) / "outside.md"
            outside.write_text("data")
            link = Path(d) / "link.md"
            link.symlink_to(outside)
            with self.assertRaises(self.mod.PersistError):
                self.mod._open_nofollow_fd(link, os.O_RDONLY)

    def test_read_existing_rejects_symlink_even_without_o_nofollow(self):
        """Isolates _read_existing's explicit is_symlink() pre-check from the
        redundant O_NOFOLLOW protection that also happens to catch a
        symlinked target on POSIX. We simulate the Windows case (no
        O_NOFOLLOW available) by monkeypatching it away, so this only passes
        if the explicit check -- the sole protection on that platform --
        is actually still there.
        """
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner "
                          "-- cannot construct the symlink this test needs")
        with tempfile.TemporaryDirectory() as d:
            outside = Path(d) / "outside.md"
            outside.write_text("data")
            link = Path(d) / "link.md"
            link.symlink_to(outside)
            original = getattr(self.mod.os, "O_NOFOLLOW", None)
            self.mod.os.O_NOFOLLOW = 0
            try:
                with self.assertRaises(self.mod.PersistError):
                    self.mod._read_existing(link)
            finally:
                if original is None:
                    del self.mod.os.O_NOFOLLOW
                else:
                    self.mod.os.O_NOFOLLOW = original

    def test_read_existing_rejects_invalid_utf8_as_persist_error(self):
        """Item 3 (deferred minor): _read_existing's own UnicodeDecodeError
        guard had no dedicated test -- it was only exercised incidentally via
        a broader `except ValueError` elsewhere in the module, so a
        regression here (e.g. the guard being deleted, or narrowed to catch
        something other than UnicodeDecodeError) could pass the existing
        suite while a real invalid-UTF-8 existing file went back to raising
        a raw UnicodeDecodeError instead of the documented PersistError.
        """
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / "MEMORY.md"
            # 0xFF is not valid anywhere in UTF-8 (not a valid lead byte, not
            # a valid continuation byte), so this is guaranteed to fail
            # decoding regardless of what otherwise-valid bytes surround it.
            target.write_bytes(b"some text \xff more text")
            with self.assertRaises(self.mod.PersistError) as ctx:
                self.mod._read_existing(target)
            self.assertIn("not valid UTF-8", str(ctx.exception))


class TestDirFdWritePath(unittest.TestCase):
    """fix-p3-toctou: exercises _write_all_fd directly (rather than only
    black-box through the CLI), and the dispatch/leak/mutation properties
    that make it safe to run on every hook invocation.
    """

    def setUp(self):
        self.mod = _load_writer_module()
        if not self.mod.DIR_FD_SUPPORTED:
            self.skipTest("dir_fd probed and unavailable on this runner (e.g. native Windows) "
                          "-- _write_all_fd is not the active code path there")

    def test_write_all_dispatches_to_fd_path_when_supported(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            proposal = {"version": 1,
                        "memory": [{"file": "MEMORY.md", "mode": "replace", "content": "x"}],
                        "skills": []}
            planned = self.mod._plan(proposal, home / "memory", home / "learned-skills")
            written, total = self.mod._write_all(planned)
            self.assertEqual((home / "memory" / "MEMORY.md").read_text(), "x")
            self.assertIn(str(home / "memory" / "MEMORY.md"), written)

    def test_no_fd_leak_across_many_successful_and_failed_writes(self):
        """Every fd opened by _write_all_fd must close on both the success
        and the failure path -- a leak here is a slow resource exhaustion
        bug in a script that runs on every review, not just an untidy
        detail. /proc/self/fd is the ground truth on Linux; skipped where
        unavailable (e.g. macOS, which has no /proc)."""
        if not Path("/proc/self/fd").is_dir():
            self.skipTest("/proc/self/fd unavailable on this platform")

        def fd_count():
            return len(os.listdir("/proc/self/fd"))

        before = fd_count()
        for i in range(50):
            with tempfile.TemporaryDirectory() as d:
                home = Path(d)
                proposal = {"version": 1,
                            "memory": [{"file": "MEMORY.md", "mode": "replace", "content": f"n{i}"}],
                            "skills": [{"name": f"skill{i}", "content": "# x"}]}
                planned = self.mod._plan(proposal, home / "memory", home / "learned-skills")
                self.mod._write_all(planned)
        self.assertEqual(fd_count(), before, "fd leak on the success path")

        for i in range(50):
            with tempfile.TemporaryDirectory() as d:
                home = Path(d)
                # SKILL.md pre-exists as a directory -- forces a failure
                # partway through staging.
                (home / "learned-skills" / "beta" / "SKILL.md").mkdir(parents=True)
                proposal = {"version": 1, "skills": [{"name": "beta", "content": "x"}]}
                try:
                    planned = self.mod._plan(proposal, home / "memory", home / "learned-skills")
                    self.mod._write_all(planned)
                except Exception:
                    pass
        self.assertEqual(fd_count(), before, "fd leak on the failure path")

    def test_mutation_forcing_path_based_writer_reproduces_the_race(self):
        """Mutation test: force DIR_FD_SUPPORTED False (simulating the
        pre-fix / no-dir_fd state) and confirm the race that
        tests/test-adversarial-sweep.py's TestTOCTOU holds at zero
        tolerance actually resurfaces -- i.e. that the zero-escape result
        with dir_fd enabled is because of the fix, not because the racer
        thread happens not to win often enough to matter regardless of
        which writer runs. Uses a smaller iteration count than the
        standalone race harness in fix-p3-toctou-report.md (this runs in
        the normal test suite budget); a handful of escapes out of a few
        dozen racy iterations is enough to demonstrate the mutation is
        killed without materially slowing the suite.
        """
        if not CAN_SYMLINK:
            self.skipTest("symlink creation probed and unavailable on this runner")
        import shutil
        import threading

        self.mod.DIR_FD_SUPPORTED = False
        try:
            escapes = 0
            iterations = 60
            for _ in range(iterations):
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
                                pass

                    racer = threading.Thread(target=swap, daemon=True)
                    racer.start()
                    try:
                        proposal = {"version": 1, "memory": [],
                                    "skills": [{"name": "alpha", "content": "pwned"}]}
                        planned = self.mod._plan(proposal, home / "memory", skills_dir)
                        self.mod._write_all(planned)
                    except Exception:
                        pass
                    finally:
                        stop.set()
                        racer.join(timeout=1)
                    if list(outside.iterdir()):
                        escapes += 1
        finally:
            self.mod.DIR_FD_SUPPORTED = True

        # A generous, non-flaky bar: the unfixed path-based writer measures
        # ~10-18% in independent runs (see fix-p3-toctou-report.md). Any
        # escape at all here is sufficient to prove the mutation is killed
        # (dir_fd-off behaves differently from dir_fd-on, which is 0/N).
        self.assertGreater(
            escapes, 0,
            f"expected the mutation (DIR_FD_SUPPORTED forced False) to reproduce at least one "
            f"escape in {iterations} racy iterations, got 0 -- either the race harness itself "
            "is broken, or _write_all_path is unexpectedly also race-free, either of which "
            "would mean this mutation test isn't actually testing anything.")


if __name__ == "__main__":
    unittest.main()
