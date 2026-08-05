#!/usr/bin/env python3
"""Everything scripts/turn-counter.sh does once config.sh has resolved paths.

WHY THIS FILE EXISTS
--------------------
jq was the last RUNTIME dependency in this project, and it was needed in
exactly one place: this hook's state read. On Windows that meant telling
every user to `winget install jqlang.jq` for one JSON read, on the same hook
path that already spawns Python for path resolution.

The obvious move -- keep the bash and swap `jq` for `lib/jsonio.py` -- was
tried and REVERTED: it ADDED a Python spawn to a hook with a <100ms budget
and measured 97-129ms. The shape that works is consolidation, not
substitution: this module does the payload parse, the lock, the state read,
the counting, the thresholds and both writes in the ONE Python process the
hook was already going to pay for. Net spawns go DOWN (the jq call and the
lib/jsonio.py payload read both disappear into this one), which is why the
budget survives.

Every comment below that explains a decision is ported from the bash it
replaces, because the reasoning outlives the language: each one records a
defect that was measured on a real machine.

HOOK DISCIPLINE: exit 0 on every path. A PostToolUse hook that exits nonzero
is noise in the user's session, and the failure channel here is
persist-failures.log (the one file doctor.sh reads), never an exit code.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The ONE ISO parser in this project. skill-lifecycle.py once carried an
# independent third copy of this logic and it was missing both the "Z" swap
# (Python 3.9's fromisoformat rejects a trailing "Z", and every timestamp
# this project writes ends in "Z") and the naive-as-UTC guard. A fourth copy
# here to save an import would be exactly how that happened the first time.
from isotime import parse_iso  # noqa: E402

# Seconds between two reports of a CONTINUOUSLY degraded counter, and the
# minimum gap between two review signals. Both were bash constants; neither
# is configurable, so neither becomes a flag.
DEGRADED_REPORT_INTERVAL = 3600
REVIEW_COOLDOWN_SECONDS = 60
# Heuristic: one user-visible turn per 3 tool calls. A PostToolUse hook does
# not receive the user-message signal that would let us do better.
TURNS_PER_MEMORY_TURN = 3
LOCK_MAX_WAIT_SECONDS = 2.0
LOCK_POLL_SECONDS = 0.1


def now_utc_iso() -> str:
    """The exact format every producer in this project writes:
    `date -u +%Y-%m-%dT%H:%M:%SZ`. Kept byte-identical because sl_iso_to_epoch
    and lib/isotime.py both parse it, and doctor.sh reads it by eye."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_payload_session_id() -> str:
    """session_id from the hook payload on stdin, or "unknown".

    "unknown" is applied identically whether the field was absent, null,
    empty, or the whole payload was unparseable -- the same collapse
    lib/hook-input.sh applies, and the value the session-boundary check below
    deliberately refuses to treat as a new session.

    stdin is not read at all when it is a terminal: doctor.sh and humans run
    hook scripts directly from an interactive shell, where a blocking read
    waits forever for a Ctrl-D that normal usage never sends. This is
    lib/stdin-safe.sh's `[[ -t 0 ]]` guard, which checks the fd WITHOUT
    consuming anything.
    """
    if sys.stdin.isatty():
        return "unknown"
    try:
        raw = sys.stdin.read()
    except (OSError, UnicodeDecodeError):
        return "unknown"
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return "unknown"
    if not isinstance(obj, dict):
        return "unknown"
    value = obj.get("session_id")
    if not isinstance(value, str) or not value:
        return "unknown"
    return value


class Lock:
    """Atomic read-modify-write guard, mkdir-based.

    `mkdir` is atomic on POSIX AND on Windows (os.mkdir raises
    FileExistsError either way), which is why the bash used it rather than a
    lock file. Waits up to LOCK_MAX_WAIT_SECONDS, then treats the lock as
    stale, removes it and proceeds -- a hook that blocks forever behind a
    crashed sibling is worse than one that races.
    """

    def __init__(self, path: str):
        self.path = path

    def __enter__(self):
        waited = 0.0
        while True:
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                pass
            except OSError:
                # An unwritable state dir cannot be locked and cannot be
                # written either; the caller's own writes will fail and
                # report. Do not spin.
                return self
            if waited >= LOCK_MAX_WAIT_SECONDS:
                shutil.rmtree(self.path, ignore_errors=True)
                try:
                    os.mkdir(self.path)
                except OSError:
                    pass
                return self
            time.sleep(LOCK_POLL_SECONDS)
            waited += LOCK_POLL_SECONDS

    def __exit__(self, *exc):
        # Released on EVERY path including an exception -- the bash used
        # `trap release_lock EXIT` for the same reason.
        shutil.rmtree(self.path, ignore_errors=True)
        return False


def write_atomic(path: str, text: str) -> None:
    """Write via mkstemp + os.replace, mode 0600, LF-only.

    Atomic rename so a concurrent reader never sees a half-written counter
    (the bash wrote a .tmp and `mv`d it for the same reason). mkstemp creates
    at 0600 already; the explicit chmod covers the case where an existing
    target had looser permissions, since os.replace carries the SOURCE's mode.
    newline="\\n" because this file is JSON read back by both Python and bash
    on Windows, where the default translation would write \\r\\n.
    """
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tc-tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Degraded:
    """Throttled degraded-state reporting.

    Every other script in this project reports a broken precondition through
    sl_review_precondition_failed, which appends one line to
    persist-failures.log -- the one channel doctor.sh reads. This hook may NOT
    do that unconditionally: it runs on EVERY tool use, so an unthrottled call
    would append thousands of identical lines per session and turn doctor.sh's
    "N persistence failure(s) recorded" into unreadable noise. That destroys
    the diagnostic instead of using it.

    So the FORMATTING and DESTINATION stay shared (one message format across
    the project, one file for doctor.sh to read) and only the THROTTLE lives
    here, because only this script has the per-tool-use constraint. Reusing
    the "review NOT attempted -- <reason>" wording is deliberate too: a
    counter that cannot be read is exactly the reason no review will ever be
    attempted.

    The throttle is a marker file holding the epoch of the last report:

      * First entry into the degraded state always reports immediately -- the
        transition is the interesting event.
      * While it stays degraded, at most one line per
        DEGRADED_REPORT_INTERVAL. A machine broken for a day leaves ~24
        lines, not ~50,000; still loud enough that a human running doctor.sh
        cannot miss it, and it keeps accruing rather than being a single line
        that scrolls into history.
      * Recovery deletes the marker (`clear`), so the NEXT breakage is
        reported at once instead of being swallowed by a stale cooldown.
    """

    def __init__(self, marker: str, log_dir: str):
        self.marker = marker
        self.log_dir = log_dir
        # Whether THIS run found anything wrong -- not whether it managed to
        # write a line about it (the throttle may have swallowed that). It
        # gates `clear`, because "recovered" has to mean the whole run
        # succeeded. Getting this wrong is a real defect the suite caught: a
        # counter path that can be READ as absent but never WRITTEN cleared
        # the marker on every fire and then re-reported, putting one line per
        # tool use into the file the throttle exists to keep readable.
        self.degraded_this_run = False

    def report(self, reason: str) -> None:
        self.degraded_this_run = True
        now = int(time.time())
        try:
            with open(self.marker, encoding="utf-8") as handle:
                last = int((handle.readline() or "0").strip() or 0)
        except (OSError, ValueError):
            last = 0
        if last and now - last < DEGRADED_REPORT_INTERVAL:
            return
        try:
            os.makedirs(self.log_dir, exist_ok=True)
            with open(self.marker, "w", encoding="utf-8", newline="\n") as handle:
                handle.write("%d\n" % now)
            line = "%s turn-counter: review NOT attempted -- %s\n" % (now_utc_iso(), reason)
            with open(os.path.join(self.log_dir, "persist-failures.log"),
                      "a", encoding="utf-8", newline="\n") as handle:
                handle.write(line)
        except OSError:
            # Nowhere to report TO. Not silence by choice: the store itself is
            # unwritable, which every other write below will hit too.
            pass

    def clear_if_recovered(self) -> None:
        """Drop the marker only if nothing went wrong this run."""
        if self.degraded_this_run:
            return
        try:
            os.unlink(self.marker)
        except OSError:
            pass


def load_state(counter_file: str, degraded: Degraded):
    """Return (session, memory_turns, skill_iters, total_turns, last_review,
    session_started).

    Three outcomes that the pre-jsonio bash collapsed into one, kept apart
    here because keeping them apart IS the fix:

      * file absent      -- NORMAL on the first tool use of a session. The
                            defaults are the right answer and this case must
                            stay silent, or a failure line per new session
                            trains everyone to ignore the file.
      * unparseable      -- NOT normal. Reported, then reset: a corrupt
                            counter would otherwise wedge counting forever,
                            and the accumulated state is unreadable either
                            way.
      * non-numeric      -- the same silent collapse wearing a different hat.
                            `// 0` only substitutes for null/false, so a
                            counter stored as the STRING "abc" flowed through
                            and then evaluated to 0 inside bash arithmetic.
                            Reported and reset, like the unparseable case.
    """
    defaults = ("none", 0, 0, 0, "", "")
    if not os.path.isfile(counter_file):
        return defaults

    try:
        with open(counter_file, encoding="utf-8") as handle:
            obj = json.load(handle)
        if not isinstance(obj, dict):
            raise ValueError("counter file is not a JSON object")
    except (OSError, ValueError) as exc:
        degraded.report(
            "%s could not be read: %s -- this session's turn count was reset "
            "to 0 and the file rewritten" % (counter_file, exc)
        )
        return defaults

    counters = {}
    for key in ("memory_turns", "skill_iterations", "total_turns_this_session"):
        value = obj.get(key, 0)
        # bool is an int subclass and `true` is not a count; reject it here
        # rather than let it read as 1.
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            degraded.report(
                "%s parses as JSON but its counters are not numbers "
                "(memory_turns=%r, skill_iterations=%r, "
                "total_turns_this_session=%r) -- reset to 0"
                % (counter_file, obj.get("memory_turns"),
                   obj.get("skill_iterations"), obj.get("total_turns_this_session"))
            )
            return defaults
        counters[key] = value

    session = obj.get("session_id")
    last_review = obj.get("last_review_at")
    started = obj.get("session_started_at")
    return (
        session if isinstance(session, str) and session else "none",
        counters["memory_turns"],
        counters["skill_iterations"],
        counters["total_turns_this_session"],
        last_review if isinstance(last_review, str) else "",
        started if isinstance(started, str) else "",
    )


def run(args) -> int:
    session_id = read_payload_session_id()
    state_dir = os.path.dirname(args.counter_file) or "."
    try:
        os.makedirs(state_dir, exist_ok=True)
    except OSError:
        return 0

    degraded = Degraded(args.degraded_marker, args.log_dir)

    with Lock(args.lock_dir):
        (current_session, memory_turns, skill_iters, total_turns,
         last_review, session_started) = load_state(args.counter_file, degraded)

        # Session boundary: a new id resets everything. "unknown" is
        # deliberately excluded -- an unreadable payload must not be mistaken
        # for a new session and wipe a real one's counts.
        if session_id != current_session and session_id != "unknown":
            memory_turns = skill_iters = total_turns = 0
            last_review = ""
            session_started = now_utc_iso()
            current_session = session_id

        skill_iters += 1
        total_turns += 1
        if total_turns % TURNS_PER_MEMORY_TURN == 0:
            memory_turns += 1

        review_memory = memory_turns >= args.memory_interval
        if review_memory:
            memory_turns = 0
        review_skills = skill_iters >= args.skill_interval
        if review_skills:
            skill_iters = 0

        # Written BEFORE the cooldown gate below, exactly as the bash did:
        # a suppressed signal must still leave the turn count advanced, or a
        # session in cooldown stops counting altogether.
        try:
            write_atomic(args.counter_file, json.dumps({
                "session_id": current_session,
                "memory_turns": memory_turns,
                "skill_iterations": skill_iters,
                "last_review_at": last_review,
                "session_started_at": session_started,
                "total_turns_this_session": total_turns,
            }, indent=2) + "\n")
        except OSError as exc:
            degraded.report("could not write %s: %s -- turns are not being "
                            "counted and no review can ever trigger"
                            % (args.counter_file, exc))
            return 0

        # Recovery is asserted only HERE, after a run that both read and wrote
        # successfully -- not at the point the read happened to be fine.
        degraded.clear_if_recovered()

        if not (review_memory or review_skills):
            return 0

        # Minimum gap between two reviews. Parsed here rather than shelled
        # out to lib/isotime.py: same parser, one fewer process.
        if last_review:
            last_epoch = parse_iso(last_review)
            if last_epoch is not None and int(time.time()) - last_epoch < REVIEW_COOLDOWN_SECONDS:
                return 0

        try:
            write_atomic(args.signal_file, json.dumps({
                "review_memory": review_memory,
                "review_skills": review_skills,
                "triggered_at": now_utc_iso(),
                "session_id": current_session,
                "total_turns": total_turns,
            }, indent=2) + "\n")
        except OSError as exc:
            degraded.report("could not write %s: %s -- the threshold was "
                            "reached but no review will be triggered"
                            % (args.signal_file, exc))
    return 0


def main(argv=None) -> int:
    try:
        sys.stdout.reconfigure(newline="\n")
    except (AttributeError, ValueError):
        pass
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--counter-file", required=True)
    parser.add_argument("--signal-file", required=True)
    parser.add_argument("--lock-dir", required=True)
    parser.add_argument("--degraded-marker", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--memory-interval", type=int, default=10)
    parser.add_argument("--skill-interval", type=int, default=10)
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Exception:  # noqa: BLE001 -- hook discipline: never a nonzero exit
        # An unexpected failure still has to leave a trace, and
        # persist-failures.log is the only channel doctor.sh reads.
        import traceback
        Degraded(args.degraded_marker, args.log_dir).report(
            "turn counting raised an unexpected error: %s"
            % traceback.format_exc(limit=3).replace("\n", " ")
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
