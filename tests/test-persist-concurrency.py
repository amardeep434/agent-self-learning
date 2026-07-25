#!/usr/bin/env python3
"""Regression suite for the concurrent-append data-loss defect (fix P7).

THE DEFECT THIS PINS
--------------------
persist-proposal.py's append path did read-existing -> concatenate -> stage
-> rename with no cross-process lock spanning that cycle. Two hooks firing
near-simultaneously each read the same MEMORY.md, each appended their own
entry, and each renamed their own copy over the other's. One append was
destroyed; BOTH processes exited 0 and printed a success JSON. The same
span exists inside "replace"-mode skill writes, because `.usage.json` is
read, merged, and rewritten there -- so this was never append-only.

Measured against the pre-fix code with the barrier below (N=100, Linux):
  append : 98 of 100 entries lost
  skills : 95-98 of 100 `.usage.json` records lost, while all 100
           SKILL.md files were written -- skills present on disk with no
           telemetry record at all.
Post-fix: 0 of 100 lost, repeatedly.

WHY THIS TEST IS NOT A COIN FLIP
--------------------------------
A concurrency test that only sometimes overlaps is worthless: it would pass
against the broken code by luck. Two things make the pre-fix failure
near-certain here rather than probabilistic:

  1. A real barrier. Every child process is spawned first and blocks in
     `sys.stdin.read()`; only once all of them are up is any payload
     written. They therefore all enter the read-modify-write span inside
     the same few milliseconds, instead of being staggered by ~40ms of
     interpreter startup each.
  2. A widened window. The store is pre-seeded with a large MEMORY.md and
     each proposal carries a padded body, so every process spends real time
     reading, concatenating and writing hundreds of KB while holding
     nothing.

Both are properties of the harness, not of timing luck. The counts are
printed so a reader can see the coverage actually exercised.
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
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import store_lock  # noqa: E402

# Concurrency of each round. Deliberately modest so the whole suite stays
# far inside tests/run-all.sh's 120s per-suite timeout on the slowest CI
# runner, while still being several times larger than the 2-3 processes a
# real double-hook-fire produces. Overridable for manual deeper runs.
N_PROCS = int(os.environ.get("SL_CONCURRENCY_TEST_N", "24"))
ROUNDS = int(os.environ.get("SL_CONCURRENCY_TEST_ROUNDS", "2"))

# Seed + padding sizes, kept well under persist-proposal's
# MAX_MEMORY_FILE_BYTES (1 MiB) even after N appends:
#   200 KiB seed + 24 * ~2 KiB = ~250 KiB.
SEED_BYTES = 200 * 1024
PAD_BYTES = 2 * 1024

# Seconds to let every spawned child reach its blocking stdin.read() before
# the barrier is released. Generous for a loaded Windows runner; a child
# that is still starting up merely joins the contention late, which can
# only ever make the pre-fix failure less likely, never make a post-fix
# pass wrong.
BARRIER_SETTLE = 1.0


def _payload_memory(i: int) -> str:
    body = "ENTRY-%04d %s\n" % (i, "x" * PAD_BYTES)
    obj = {"version": 1, "skills": [],
           "memory": [{"file": "MEMORY.md", "mode": "append", "content": body}]}
    return "```json\n" + json.dumps(obj) + "\n```\n"


def _payload_skill(i: int) -> str:
    obj = {"version": 1, "memory": [],
           "skills": [{"name": "conc-skill-%04d" % i, "content": "# conc %04d\n" % i}]}
    return "```json\n" + json.dumps(obj) + "\n```\n"


def _run_barrier(store: Path, payloads: "list[str]", env_extra: "dict | None" = None):
    """Spawn one writer per payload, hold them all at stdin, release together.

    Returns [(returncode, stdout, stderr)] in payload order.
    """
    env = dict(os.environ, AGENT_LEARNING_HOME=str(store))
    env.pop("SL_LOG_DIR", None)
    if env_extra:
        env.update(env_extra)
    procs = [subprocess.Popen([sys.executable, str(WRITER)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, env=env)
             for _ in payloads]
    try:
        time.sleep(BARRIER_SETTLE)
        for proc, payload in zip(procs, payloads):
            proc.stdin.write(payload)
        for proc in procs:
            proc.stdin.close()
        results = []
        for proc in procs:
            out, err = proc.stdout.read(), proc.stderr.read()
            proc.stdout.close()
            proc.stderr.close()
            proc.wait()
            results.append((proc.returncode, out, err))
        return results
    finally:
        for proc in procs:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


def _stray_files(store: Path) -> "list[str]":
    """Any lock file or leftover staging file inside the *content*
    directories. Those are enumerated by consumers (inject-agents-md.py,
    curator-run.sh, skill-lifecycle.py), so anything the writer leaves there
    is read as content. The lock file itself belongs in state/, never here.
    """
    strays = []
    for sub in ("memory", "learned-skills"):
        base = store / sub
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            name = path.name.lower()
            if name.startswith(".persist-tmp-") or "lock" in name:
                strays.append(str(path.relative_to(store)))
    return sorted(strays)


class TestConcurrentAppend(unittest.TestCase):
    def test_no_append_is_lost_under_contention(self):
        total_lost = 0
        for round_no in range(ROUNDS):
            with tempfile.TemporaryDirectory() as tmp:
                store = Path(tmp) / "store"
                memory = store / "memory"
                memory.mkdir(parents=True)
                # Pre-seed: makes every read-modify-write span real work,
                # which is what turns "sometimes overlaps" into "always
                # overlaps" for the pre-fix code.
                (memory / "MEMORY.md").write_text("SEED\n" + "s" * SEED_BYTES + "\n",
                                                  encoding="utf-8")
                results = _run_barrier(store, [_payload_memory(i) for i in range(N_PROCS)])

                text = (memory / "MEMORY.md").read_text(encoding="utf-8")
                missing = [i for i in range(N_PROCS) if ("ENTRY-%04d" % i) not in text]
                total_lost += len(missing)
                bad = [(rc, err[:200]) for rc, _out, err in results if rc != 0]
                self.assertEqual(bad, [], f"round {round_no}: writers failed: {bad}")
                self.assertIn("SEED", text, f"round {round_no}: pre-existing content destroyed")
                self.assertEqual(
                    missing, [],
                    f"round {round_no}: {len(missing)} of {N_PROCS} concurrent appends were "
                    f"LOST while every writer exited 0 -- the append read-modify-write span "
                    f"is not serialised across processes")
                self.assertEqual(_stray_files(store), [],
                                 f"round {round_no}: stray lock/temp files left in the store")
        print(f"[concurrency] append: {ROUNDS} rounds x {N_PROCS} processes, "
              f"lost entries = {total_lost}")


class TestConcurrentSkillUsage(unittest.TestCase):
    def test_no_usage_record_is_lost_under_contention(self):
        """`.usage.json` is read-merged-rewritten inside a *replace*-mode
        skill write. Pre-fix this lost 95-98 of 100 telemetry records while
        writing every SKILL.md -- skills that exist on disk but that
        skill-lifecycle.py has no record for."""
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "store"
            results = _run_barrier(store, [_payload_skill(i) for i in range(N_PROCS)])
            bad = [(rc, err[:200]) for rc, _out, err in results if rc != 0]
            self.assertEqual(bad, [], f"writers failed: {bad}")

            skills_dir = store / "learned-skills"
            usage = json.loads((skills_dir / ".usage.json").read_text(encoding="utf-8"))
            missing_files = [i for i in range(N_PROCS)
                             if not (skills_dir / ("conc-skill-%04d" % i) / "SKILL.md").is_file()]
            missing_records = [i for i in range(N_PROCS)
                               if ("conc-skill-%04d" % i) not in usage]
            self.assertEqual(missing_files, [], "skill content files were lost")
            self.assertEqual(
                missing_records, [],
                f"{len(missing_records)} of {N_PROCS} .usage.json records were LOST while "
                f"every writer exited 0 -- the usage read-merge-write span is not serialised")
            self.assertEqual(_stray_files(store), [], "stray lock/temp files left in the store")
        print(f"[concurrency] skills/.usage.json: 1 round x {N_PROCS} processes, "
              f"lost records = {len(missing_records)}")


class TestLockTimeoutFailsLoudly(unittest.TestCase):
    """A bounded wait that expires must fail LOUDLY: non-zero exit plus a
    line in persist-failures.log (which doctor.sh surfaces). Silently
    giving up and reporting success would be another instance of the exact
    pattern this project exists to eliminate."""

    def test_timeout_exits_nonzero_and_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "store"
            state = store / "state"
            held = store_lock.StoreLock(state, timeout=5.0)
            held.acquire()
            try:
                env = dict(os.environ, AGENT_LEARNING_HOME=str(store),
                           SL_PERSIST_LOCK_TIMEOUT="0.5")
                env.pop("SL_LOG_DIR", None)
                started = time.monotonic()
                proc = subprocess.run([sys.executable, str(WRITER)],
                                      input=_payload_memory(1), capture_output=True,
                                      text=True, env=env)
                elapsed = time.monotonic() - started
            finally:
                held.release()

            self.assertNotEqual(proc.returncode, 0,
                                "a lock timeout must not report success")
            self.assertIn("timed out", proc.stderr.lower())
            self.assertLess(elapsed, 30.0,
                            "the wait must be bounded, not block a hook indefinitely")

            log = store / "logs" / "persist-failures.log"
            self.assertTrue(log.is_file(),
                            "a lock timeout must be recorded in persist-failures.log")
            self.assertIn("lock timeout", log.read_text(encoding="utf-8"))

            # Nothing must have been half-written, and no lock file may be
            # left inside the content directories.
            self.assertFalse((store / "memory" / "MEMORY.md").exists(),
                             "a timed-out write must write nothing at all")
            self.assertEqual(_stray_files(store), [])
        print("[concurrency] timeout path: non-zero exit + persist-failures.log line, "
              f"bounded at {elapsed:.2f}s")


class TestStoreLockBackends(unittest.TestCase):
    def test_backend_selected_by_functional_probe(self):
        self.assertIn(store_lock.BACKEND, ("flock", "msvcrt", "exclusive"))
        print(f"[capability probe] store_lock backend={store_lock.BACKEND} "
              f"releases_on_crash={store_lock.BACKEND_RELEASES_ON_CRASH}")

    def test_selected_backend_is_mutually_exclusive(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            first = store_lock.StoreLock(state, timeout=0.2)
            first.acquire()
            try:
                with self.assertRaises(store_lock.LockTimeout):
                    store_lock.StoreLock(state, timeout=0.2).acquire()
            finally:
                first.release()
            # Released: the next acquirer gets it immediately.
            second = store_lock.StoreLock(state, timeout=0.2)
            second.acquire()
            second.release()

    def test_exclusive_fallback_backend_is_mutually_exclusive(self):
        """The O_CREAT|O_EXCL fallback is what runs where neither kernel
        primitive probes true, so it is exercised explicitly on every
        platform rather than only on the platforms that happen to need it."""
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            first = store_lock.StoreLock(state, timeout=0.2, backend="exclusive")
            first.acquire()
            self.assertTrue((state / store_lock.LOCK_FILENAME).is_file())
            try:
                with self.assertRaises(store_lock.LockTimeout):
                    store_lock.StoreLock(state, timeout=0.2, backend="exclusive").acquire()
            finally:
                first.release()
            self.assertFalse((state / store_lock.LOCK_FILENAME).exists(),
                             "the exclusive backend must remove its lock file on release")

    def test_exclusive_fallback_breaks_a_stale_lock(self):
        """A crashed holder must not wedge the store forever. The kernel
        backends get this for free (the OS drops the lock when the process
        dies); the exclusive fallback has to break an over-age lock itself."""
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            state.mkdir(parents=True)
            stale = state / store_lock.LOCK_FILENAME
            stale.write_text("99999999 0\n", encoding="utf-8")
            old = time.time() - (store_lock.STALE_SECONDS + 60)
            os.utime(stale, (old, old))

            lock = store_lock.StoreLock(state, timeout=2.0, backend="exclusive")
            lock.acquire()  # must not raise: the stale lock is broken
            lock.release()

    def test_fresh_lock_is_not_broken_as_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            state.mkdir(parents=True)
            (state / store_lock.LOCK_FILENAME).write_text("1 0\n", encoding="utf-8")
            with self.assertRaises(store_lock.LockTimeout):
                store_lock.StoreLock(state, timeout=0.2, backend="exclusive").acquire()

    def test_kernel_backend_releases_when_holder_process_dies(self):
        """SIGKILL a process holding the lock; the next acquirer must get it.

        Skipped where the selected backend has no crash-release guarantee
        (the exclusive fallback), which is stated rather than silently
        passed -- that backend's answer to a dead holder is STALE_SECONDS,
        covered by test_exclusive_fallback_breaks_a_stale_lock above.
        """
        if not store_lock.BACKEND_RELEASES_ON_CRASH:
            self.skipTest(f"backend {store_lock.BACKEND} has no crash-release guarantee")
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            code = (
                "import sys, time\n"
                f"sys.path.insert(0, {str(ROOT / 'scripts' / 'lib')!r})\n"
                "import store_lock\n"
                f"lock = store_lock.StoreLock({str(state)!r}, timeout=5.0)\n"
                "lock.acquire()\n"
                "print('held', flush=True)\n"
                "time.sleep(60)\n"
            )
            holder = subprocess.Popen([sys.executable, "-c", code],
                                      stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(holder.stdout.readline().strip(), "held")
                with self.assertRaises(store_lock.LockTimeout):
                    store_lock.StoreLock(state, timeout=0.3).acquire()
                holder.kill()
                holder.wait()
            finally:
                if holder.poll() is None:
                    holder.kill()
                    holder.wait()
                holder.stdout.close()
            # The OS dropped the dead holder's lock: this must now succeed.
            survivor = store_lock.StoreLock(state, timeout=5.0)
            survivor.acquire()
            survivor.release()


if __name__ == "__main__":
    unittest.main()
