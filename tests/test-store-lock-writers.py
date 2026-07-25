#!/usr/bin/env python3
"""Regression suite for fix-p8: the OTHER writers of the store must take the
same lock persist-proposal.py takes.

THE DEFECT THIS PINS
--------------------
fix-p7 serialised persist-proposal.py. It did not touch `skill-lifecycle.py`,
which performs the identical read-modify-write over the SAME `.usage.json`
(load_usage -> decide transitions -> shutil.move skill directories ->
save_usage), nor `curator-run.sh`, which takes the pre-run backup that all of
that destruction is supposed to be recoverable from.

Measured against the pre-fix code with the barrier harness below
(24 persist writers + 1 lifecycle pass over 1500 records, Linux, 3 runs):

    lifecycle transitions LOST: 1500 of 1500, every run, lifecycle exit 0

i.e. an entire curator sweep silently discarded by concurrent reviews, with
nothing anywhere reporting a failure. Post-fix: 0 of 1500. The reverse
direction (a review's records discarded by the sweep's stale snapshot) is
the same bug seen from the other side and is asserted here too.

WHY THE PRE-FIX FAILURE IS RELIABLE, NOT LUCK
---------------------------------------------
Same two properties as tests/test-persist-concurrency.py: a real barrier
(every child blocks in stdin.read() until released together) and a widened
span (the seeded `.usage.json` is large enough that loading, deciding and
rewriting it takes real time). Neither depends on timing luck.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "scripts" / "persist-proposal.py"
LIFECYCLE = ROOT / "scripts" / "skill-lifecycle.py"
CURATOR = ROOT / "scripts" / "curator-run.sh"
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import store_lock  # noqa: E402

# Concurrency and seed size. SEED_RECORDS is the knob that widens the
# lifecycle's read-modify-write span; at 1200 the pre-fix loss is total and
# the whole run still costs ~2s, far inside run-all.sh's 120s per-suite
# timeout.
N_PROCS = int(os.environ.get("SL_CONCURRENCY_TEST_N", "16"))
SEED_RECORDS = int(os.environ.get("SL_LIFECYCLE_TEST_SEED", "1200"))
BARRIER_SETTLE = 1.0

# Runs the real script only after stdin closes, so a script that does not
# itself read stdin (skill-lifecycle.py) can join the same barrier as the
# ones that do.
_BARRIER_SHIM = ("import sys, subprocess; sys.stdin.read(); "
                 "sys.exit(subprocess.call([sys.executable] + sys.argv[1:]))")


def _clean_env(store: Path, **extra) -> dict:
    env = dict(os.environ, AGENT_LEARNING_HOME=str(store))
    for leaked in ("SL_LOG_DIR", "SL_STATE_DIR", "SL_SKILLS_DIR", "SL_MEMORY_DIR",
                   "CLAUDE_LEARNED_SKILLS_DIR"):
        env.pop(leaked, None)
    env["SL_CONFIG_FILE"] = "/nonexistent/x.conf"
    env.update(extra)
    return env


def _seed_usage(skills: Path, count: int, age_days: int = 40) -> None:
    """`count` agent-created records old enough to go stale (30d) but not to
    be archived (90d), so the lifecycle pass mutates every one of them
    without moving any directories."""
    skills.mkdir(parents=True, exist_ok=True)
    old = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                        time.gmtime(time.time() - age_days * 86400))
    seed = {"seed-%05d" % i: {"created_by": "agent", "created_at": old,
                              "state": "active", "pinned": False,
                              "use_count": 3, "last_used_at": old}
            for i in range(count)}
    (skills / ".usage.json").write_text(json.dumps(seed, indent=2), encoding="utf-8")


class TestLifecycleVsPersist(unittest.TestCase):
    def test_neither_writer_silently_discards_the_other(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "store"
            skills = store / "learned-skills"
            _seed_usage(skills, SEED_RECORDS)
            env = _clean_env(store)

            writers = [subprocess.Popen([sys.executable, str(WRITER)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=env)
                       for _ in range(N_PROCS)]
            life = subprocess.Popen([sys.executable, "-c", _BARRIER_SHIM, str(LIFECYCLE)],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, env=env)
            try:
                time.sleep(BARRIER_SETTLE)
                for i, proc in enumerate(writers):
                    payload = {"version": 1, "memory": [],
                               "skills": [{"name": "new-%04d" % i,
                                           "content": "# new %04d\n" % i}]}
                    proc.stdin.write("```json\n" + json.dumps(payload) + "\n```\n")
                for proc in writers:
                    proc.stdin.close()
                life.stdin.close()

                failures = []
                for proc in writers + [life]:
                    proc.stdout.read()
                    err = proc.stderr.read()
                    proc.stdout.close()
                    proc.stderr.close()
                    proc.wait()
                    if proc.returncode != 0:
                        failures.append((proc.returncode, err[:200]))
            finally:
                for proc in writers + [life]:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()

            self.assertEqual(failures, [], f"a writer failed: {failures}")
            usage = json.loads((skills / ".usage.json").read_text(encoding="utf-8"))

            lost_records = [i for i in range(N_PROCS) if ("new-%04d" % i) not in usage]
            lost_transitions = [i for i in range(SEED_RECORDS)
                                if usage.get("seed-%05d" % i, {}).get("state") != "stale"]
            self.assertEqual(
                lost_records, [],
                f"{len(lost_records)} of {N_PROCS} persisted skill records were LOST -- "
                "skill-lifecycle.py wrote back a snapshot taken before they existed")
            self.assertEqual(
                lost_transitions, [],
                f"{len(lost_transitions)} of {SEED_RECORDS} lifecycle transitions were "
                "LOST while skill-lifecycle.py exited 0 -- an entire curator sweep "
                "silently discarded by concurrent reviews")
            for i in range(N_PROCS):
                self.assertTrue((skills / ("new-%04d" % i) / "SKILL.md").is_file(),
                                f"new-{i:04d}/SKILL.md missing")
            strays = [p.name for p in skills.rglob("*")
                      if p.name.startswith(".persist-tmp-") or p.name.endswith(".json.tmp")]
            self.assertEqual(strays, [], f"stray temp files left behind: {strays}")
        print(f"[concurrency] lifecycle vs persist: {N_PROCS} writers + 1 lifecycle pass "
              f"over {SEED_RECORDS} records, lost transitions = 0, lost records = 0")


class TestLifecycleSnapshotIsTakenUnderTheLock(unittest.TestCase):
    """The half-fix guard, with the interleaving FORCED rather than raced.

    A lock around `save_usage()` alone looks correct and is not: the
    snapshot it writes back was read before the lock was taken, so anything
    another writer committed in between is silently discarded. That is
    exactly the mutation fix-p7 already proved inadequate for
    persist-proposal.py's `_plan`, and a plain concurrency race only catches
    it when the timing happens to cooperate (measured: 1 run in 3).

    So this test does not race. It stands in for a persist writer by taking
    the real lock itself, starting the lifecycle underneath it, committing a
    record while still holding it, and only then releasing:

        test: acquire lock
        test: start skill-lifecycle.py        <- must block BEFORE reading
        test: commit "sentinel" to .usage.json
        test: release lock
        lifecycle: proceeds

    If the lifecycle's snapshot is taken under the lock, it necessarily sees
    "sentinel" and preserves it. If the snapshot was taken before the lock,
    "sentinel" is destroyed. No timing luck either way.
    """

    def test_a_record_committed_under_the_lock_is_never_discarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "store"
            skills = store / "learned-skills"
            _seed_usage(skills, 40)
            usage_file = skills / ".usage.json"
            env = _clean_env(store, SL_PERSIST_LOCK_TIMEOUT="30")

            held = store_lock.StoreLock(store / "state", timeout=10.0)
            held.acquire()
            life = None
            try:
                life = subprocess.Popen([sys.executable, str(LIFECYCLE)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, env=env)
                time.sleep(1.5)  # ample time to start and (wrongly) read early
                self.assertIsNone(life.poll(),
                                  "skill-lifecycle.py finished while the store lock was "
                                  "held by another writer -- it never waited at all")
                # Exactly what a persist commits while holding the lock.
                current = json.loads(usage_file.read_text(encoding="utf-8"))
                current["sentinel"] = {"created_by": "agent", "state": "active",
                                       "pinned": False, "use_count": 0,
                                       "last_patched_at": "2026-07-25T00:00:00Z"}
                usage_file.write_text(json.dumps(current, indent=2), encoding="utf-8")
            finally:
                held.release()
            out, err = life.communicate(timeout=90)
            self.assertEqual(life.returncode, 0, f"lifecycle failed: {err[-300:]}")

            final = json.loads(usage_file.read_text(encoding="utf-8"))
            self.assertIn(
                "sentinel", final,
                "a record committed while the store lock was held was DESTROYED by "
                "skill-lifecycle.py -- its snapshot was taken outside the lock, so "
                "locking only the write is a half-fix")
            self.assertEqual(final["seed-00000"]["state"], "stale",
                             "the lifecycle's own transitions were not applied")
        print("[concurrency] forced interleaving: record committed under the lock "
              "survived a concurrent lifecycle pass")


class TestLifecycleLockFailureIsLoud(unittest.TestCase):
    def test_timeout_exits_nonzero_logs_and_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "store"
            skills = store / "learned-skills"
            _seed_usage(skills, 5)
            before = (skills / ".usage.json").read_text(encoding="utf-8")

            held = store_lock.StoreLock(store / "state", timeout=5.0)
            held.acquire()
            try:
                env = _clean_env(store, SL_PERSIST_LOCK_TIMEOUT="0.5")
                started = time.monotonic()
                proc = subprocess.run([sys.executable, str(LIFECYCLE)],
                                      capture_output=True, text=True, env=env)
                elapsed = time.monotonic() - started
            finally:
                held.release()

            self.assertNotEqual(proc.returncode, 0,
                                "a lock timeout must not report success")
            self.assertEqual(proc.returncode, 3,
                             "lock failure must be distinguishable from corrupt-usage (2)")
            self.assertLess(elapsed, 30.0, "the wait must be bounded")
            log = store / "logs" / "persist-failures.log"
            self.assertTrue(log.is_file(), "a lock timeout must reach persist-failures.log")
            self.assertIn("skill-lifecycle: lock timeout", log.read_text(encoding="utf-8"))
            self.assertEqual((skills / ".usage.json").read_text(encoding="utf-8"), before,
                             "a timed-out lifecycle pass must change nothing")
        print(f"[concurrency] lifecycle timeout: exit 3 + persist-failures.log, "
              f"bounded at {elapsed:.2f}s")


def _bash_available() -> bool:
    """Functional probe -- run bash, don't assume it from the platform name."""
    try:
        return subprocess.run(["bash", "-c", "exit 0"],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


BASH_AVAILABLE = _bash_available()


class TestCuratorTakesTheLock(unittest.TestCase):
    """curator-run.sh is destructive (it archives and deletes skills), so
    every run here is fully sandboxed: its own HOME, its own
    AGENT_LEARNING_HOME, no config file, idle gate disabled."""

    def setUp(self):
        if not BASH_AVAILABLE:
            self.skipTest("bash not runnable here (probed, not assumed)")

    def _sandbox(self, tmp: Path) -> "tuple[Path, dict]":
        store = tmp / "store"
        skills = store / "learned-skills"
        _seed_usage(skills, 3)
        (skills / "seed-00000").mkdir(parents=True, exist_ok=True)
        (skills / "seed-00000" / "SKILL.md").write_text("# x\n", encoding="utf-8")
        env = _clean_env(store, HOME=str(tmp), CLAUDE_CURATOR_IDLE_GATE="0")
        return store, env

    def test_curator_completes_and_applies_transitions_without_deadlocking(self):
        """The curator takes the lock for its backup and skill-lifecycle.py
        takes the same lock in a child process. If the curator held its lock
        across that call they would deadlock against each other -- the run
        would stall for the full acquire timeout and apply nothing. This is
        the guard for that."""
        with tempfile.TemporaryDirectory() as tmp:
            store, env = self._sandbox(Path(tmp))
            started = time.monotonic()
            proc = subprocess.run(["bash", str(CURATOR)], capture_output=True,
                                  text=True, env=env, timeout=90)
            elapsed = time.monotonic() - started
            self.assertEqual(proc.returncode, 0, f"curator failed: {proc.stderr[-500:]}")
            self.assertLess(elapsed, 20.0,
                            "curator took long enough to suggest it blocked on its own lock")
            usage = json.loads((store / "learned-skills" / ".usage.json")
                               .read_text(encoding="utf-8"))
            self.assertEqual(usage["seed-00000"]["state"], "stale",
                             "lifecycle transitions were not applied by the curator run")
            self.assertTrue(any((store / "backups" / "curator").glob("*.tar.gz")),
                            "no pre-run backup was created")
        print(f"[concurrency] curator run completed in {elapsed:.2f}s, no self-deadlock")

    def test_curator_aborts_loudly_when_the_lock_is_held(self):
        """With the lock held elsewhere the curator must NOT proceed to
        destructive transitions with an unverified backup -- it must abort,
        non-zero, and the failure must reach persist-failures.log."""
        with tempfile.TemporaryDirectory() as tmp:
            store, env = self._sandbox(Path(tmp))
            env["SL_PERSIST_LOCK_TIMEOUT"] = "0.5"
            before = (store / "learned-skills" / ".usage.json").read_text(encoding="utf-8")
            held = store_lock.StoreLock(store / "state", timeout=5.0)
            held.acquire()
            try:
                proc = subprocess.run(["bash", str(CURATOR)], capture_output=True,
                                      text=True, env=env, timeout=90)
            finally:
                held.release()
            self.assertNotEqual(proc.returncode, 0,
                                "curator must not report success when it could not lock")
            self.assertIn("ABORTING", proc.stderr)
            log = store / "logs" / "persist-failures.log"
            self.assertTrue(log.is_file(),
                            "the curator's lock failure must reach persist-failures.log")
            self.assertIn("store-lock", log.read_text(encoding="utf-8"))
            self.assertEqual((store / "learned-skills" / ".usage.json")
                             .read_text(encoding="utf-8"), before,
                             "an aborted curator run must change nothing")
        print("[concurrency] curator abort path: non-zero + persist-failures.log, "
              "no transitions applied")


class TestWritersAgreeOnTheLockFile(unittest.TestCase):
    def test_single_definition_of_the_lock_location(self):
        """A lock only serialises processes that pick the SAME path. Pin that
        the resolver honours SL_STATE_DIR (what config.sh exports for bash)
        and otherwise agrees with paths.py -- if these ever diverge, every
        test above would still pass while the writers silently stopped
        excluding each other."""
        import paths
        env = {"AGENT_LEARNING_HOME": "/tmp/hnp-lockdir-probe"}
        self.assertEqual(store_lock.default_lock_dir(env),
                         paths.resolve_all(env)["state"])
        env2 = dict(env, SL_STATE_DIR="/tmp/hnp-elsewhere")
        self.assertEqual(store_lock.default_lock_dir(env2), Path("/tmp/hnp-elsewhere"))

    def test_bash_front_end_uses_the_same_lock(self):
        if not BASH_AVAILABLE:
            self.skipTest("bash not runnable here (probed, not assumed)")
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            script = (f'set -euo pipefail\n'
                      f'source "{ROOT}/scripts/lib/store-lock.sh"\n'
                      f'SL_STATE_DIR="{state}" sl_with_store_lock true\n')
            proc = subprocess.run(["bash", "-c", script], capture_output=True,
                                  text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr[-400:])

            # Held from Python -> the bash front end must time out, loudly.
            held = store_lock.StoreLock(state, timeout=5.0)
            held.acquire()
            try:
                script2 = (f'source "{ROOT}/scripts/lib/store-lock.sh"\n'
                           f'SL_STATE_DIR="{state}" SL_PERSIST_LOCK_TIMEOUT=0.5 '
                           f'SL_LOG_DIR="{tmp}/logs" sl_with_store_lock true\n')
                proc2 = subprocess.run(["bash", "-c", script2], capture_output=True,
                                       text=True, timeout=60)
            finally:
                held.release()
            self.assertEqual(proc2.returncode, 75,
                             "bash front end must surface a lock timeout as EX_TEMPFAIL")
            failures = Path(tmp) / "logs" / "persist-failures.log"
            self.assertTrue(failures.is_file())
            self.assertIn("store-lock", failures.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
