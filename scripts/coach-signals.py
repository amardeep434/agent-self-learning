#!/usr/bin/env python3
"""coach-signals.py — merge enabled Coach routes into coach-signals.json.

Configuration via environment (set by scripts/lib/config.sh):
    SL_COACH_RULES_ENABLED   ("true"/"false")  Route A
    SL_COACH_EXPORT_ENABLED  ("true"/"false")  Route B
    SL_COACH_RULES_DIR, SL_SEARCH_DB, SL_COACH_EXPORT_PATH, SL_COACH_SIGNALS_FILE

Behavior:
    both off        -> delete signals file if present, exit 0
    either/both on  -> run enabled routes, merge (dedupe by id, export wins),
                       atomically write {"generated_at", "signals"} to
                       SL_COACH_SIGNALS_FILE
Route failures are non-fatal: a failing route contributes no signals -- but it
writes a NAMED line to ${SL_LOG_DIR}/persist-failures.log first, so that
"Coach refused our export" stops being indistinguishable from "Coach found no
anti-patterns". See run_route() and _log_failure() for why that file, and not
reviews/coach-signals.err, is the channel.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))
from isotime import now_iso  # noqa: E402  (fix round D: shared with skill-lifecycle.py, persist-proposal.py, index-session.py)


def _paths_defaults():
    """Fall back to the single vendor-neutral path resolver, never a
    hardcoded ~/.claude literal.

    In real operation every SL_* env var this module reads is already set
    by scripts/lib/config.sh before this script runs (both session-review.sh
    and copilot-session-review.sh source it first), so these defaults are
    never actually exercised on that path. But this file used to hardcode
    a dot-claude path segment as the fallback for exactly the
    Copilot/VS-Code-reachable code this project's global constraint forbids
    that store in -- a latent bug of the same shape the rest of this round
    fixes, just never triggered because the caller always sets the env var
    first. A caller invoking this script standalone (e.g. a test, or a
    future harness adapter that does not source config.sh) must still never
    default into that legacy, Claude-Code-only location.
    """
    sys.path.insert(0, str(SCRIPT_DIR / "lib"))
    import paths  # noqa: E402  (stdlib-only default path, import deferred)

    return paths.resolve_all()

_SAFE_CHARS = re.compile(r"[^A-Za-z0-9 .,:;()\[\]/_-]")


def sanitize_text(s):
    """Coach signals are untrusted input; strip everything except a plain-text
    allowlist, collapse whitespace, and cap length before it can reach a
    reviewer prompt."""
    s = _SAFE_CHARS.sub(" ", str(s))
    s = re.sub(r"\s+", " ", s).strip()
    return s[:240]


def flag(name):
    return os.environ.get(name, "false").strip().lower() == "true"


def _log_failure(message):
    """Append one line to ${SL_LOG_DIR}/persist-failures.log.

    Why this channel and not a doctor.sh check on reviews/coach-signals.err
    (the other option considered):

    coach-export-read.py prints a note to STDERR in its perfectly normal
    "Coach is not installed" case and exits 0 --

        print("coach-export-read: no export at {}".format(path), file=sys.stderr)
        print("[]")
        return 0                          (coach-export-read.py:65-67)

    run_route() forwards that stderr unconditionally (`if proc.stderr:
    sys.stderr.write(proc.stderr)`), and scripts/lib/review-common.sh:218-219
    appends OUR stderr to `${SL_LOG_DIR}/reviews/coach-signals.err`. So a
    recent, non-empty coach-signals.err is the STEADY STATE of every install
    that enables Route B without Coach present. A doctor.sh check on it would
    be red on those machines forever -- an alarm that is always on is an alarm
    nobody reads, and it would still not distinguish the benign note from the
    refusal, which is the entire defect being fixed.

    persist-failures.log carries only the refusal, is already the designated
    replacement for the exit code this detached pipeline cannot produce
    (CLAUDE.md hard rule 2), and doctor.sh already surfaces it loudly with a
    count and a bounded tail -- no new doctor.sh parsing at all.

    Line shape and fallback are copied deliberately from mirror-skills.py's
    _log_failure so all three writers of this file agree.
    """
    try:
        log_dir = os.environ.get("SL_LOG_DIR")
        if not log_dir:
            log_dir = str(_paths_defaults()["logs"])
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        with open(Path(log_dir) / "persist-failures.log", "a",
                  encoding="utf-8", newline="\n") as handle:
            handle.write("{} coach-signals: {}\n".format(now_iso(), message))
    except (OSError, ImportError, KeyError, RuntimeError):
        # RuntimeError is paths.py's unresolvable-home. stderr is not this
        # script's data channel (stdout is), so using it here corrupts nothing.
        try:
            print("coach-signals: {}".format(message), file=sys.stderr)
        except OSError:
            pass


def run_route(route, argv):
    """Run one route and return its signals. A failing route contributes none.

    Every `return []` below used to be indistinguishable, downstream, from the
    route legitimately finding nothing: this function swallowed the child's
    exit code, main() still returned 0, and review-common.sh `|| true`s the
    whole call. So "Coach refused our export" and "Coach found no
    anti-patterns" produced byte-identical state everywhere a human or
    doctor.sh could look. That is the silent-degradation class this project
    exists to eliminate (CLAUDE.md hard rule 2), so each of them now names
    itself in persist-failures.log. The route stays non-fatal to the review --
    only its invisibility ends.
    """
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("coach-signals: route failed ({})".format(exc), file=sys.stderr)
        _log_failure(
            "route '{}' could not be run ({}: {}) -- this review sees NO Coach "
            "signals from it, which is NOT the same as Coach finding none."
            .format(route, type(exc).__name__, exc))
        return []
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        # The reader's own contract (coach-export-read.py's module docstring)
        # reserves a nonzero exit for "something DID write an export and we
        # cannot read it" -- a truncated write, or an upstream schema change.
        # The reader's diagnostic is on its stderr, which we just forwarded;
        # the tail is included here so persist-failures.log is self-contained.
        _log_failure(
            "route '{}' REFUSED (exit {}) -- this review sees NO Coach signals "
            "from it, which is NOT the same as Coach finding none. Reason: {}"
            .format(route, proc.returncode,
                    _last_line(proc.stderr) or "(route printed nothing on stderr)"))
        return []
    try:
        out = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        _log_failure(
            "route '{}' exited 0 but its stdout is not JSON ({}) -- treated as "
            "zero signals. A route that cannot be parsed is a defect, not an "
            "absence of anti-patterns.".format(route, exc))
        return []
    if not isinstance(out, list):
        _log_failure(
            "route '{}' exited 0 but returned {}, not the documented JSON array "
            "-- treated as zero signals.".format(route, type(out).__name__))
        return []
    return out


def _last_line(text):
    """The final non-blank line of a route's stderr, capped and flattened.

    Whole stderr would be a multi-line blob inside a log doctor.sh reads with
    `tail -n 5` -- one failure could push four others out of view. The readers
    diagnostic is its last line by construction (it prints one message then
    `[]`)."""
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1][:240] if lines else ""


def main():
    rules_enabled = flag("SL_COACH_RULES_ENABLED")
    export_enabled = flag("SL_COACH_EXPORT_ENABLED")

    # Env vars are always set by lib/config.sh in real operation; only a
    # standalone invocation with an incomplete environment ever reaches
    # _paths_defaults(). Computed at most once, on demand.
    resolved = {}

    def default_path(key):
        if not resolved:
            resolved.update(_paths_defaults())
        return resolved[key]

    env_signals_file = os.environ.get("SL_COACH_SIGNALS_FILE")
    signals_file = Path(env_signals_file) if env_signals_file else default_path("state") / "coach-signals.json"

    if not rules_enabled and not export_enabled:
        if signals_file.is_file():
            signals_file.unlink()
        return 0

    merged = {}

    if rules_enabled:
        rules_dir = os.environ.get("SL_COACH_RULES_DIR") or str(default_path("scripts") / "coach-rules")
        db_path = os.environ.get("SL_SEARCH_DB") or str(default_path("sessions_db"))
        for sig in run_route("rules", [sys.executable, str(SCRIPT_DIR / "coach-rules-eval.py"),
                                       rules_dir, db_path]):
            merged[sanitize_text(sig["id"])] = {
                "id": sanitize_text(sig["id"]),
                "severity": sanitize_text(sig.get("severity", "unknown")),
                "suggestion": sanitize_text(sig.get("suggestion", "")),
                # An absence measured over a capped sample is not the global
                # claim its wording implies, so the evaluator states the
                # window it used. Carried in its OWN field: appended to
                # `suggestion` it would fall past the 240-character cap and
                # vanish silently, and a caveat that can be truncated away is
                # worse than no caveat, because the claim survives without it.
                # Sanitized like every other field -- still untrusted input.
                "scope": sanitize_text(sig.get("scope", "")),
                "count": int(sig.get("count", 0) or 0),
                # Route A counts matched records inside OUR telemetry window,
                # which telemetry.MAX_SESSIONS caps -- there is no total the
                # count is a fraction OF, so there is no honest denominator to
                # publish. Emitted as 0 (the renderer's "show no prevalence"
                # value) rather than omitted, so the key is uniform across
                # routes exactly as `scope` already is. Never fill this in
                # from a session count: it would invite the reviewer to
                # compare a Route A rate against a Route B one measured over
                # Coach's entire corpus.
                "denominator": 0,
                "source": sig.get("source", "unknown"),
            }

    if export_enabled:
        export_path = os.environ.get(
            "SL_COACH_EXPORT_PATH", str(Path.home() / ".aiec" / "summary-latest.json"))
        for sig in run_route("export", [sys.executable, str(SCRIPT_DIR / "coach-export-read.py"),
                                        export_path]):
            # export runs second: wins dedupe by design
            merged[sanitize_text(sig["id"])] = {
                "id": sanitize_text(sig["id"]),
                "severity": sanitize_text(sig.get("severity", "unknown")),
                "suggestion": sanitize_text(sig.get("suggestion", "")),
                # Route B reads Coach's own analysis over its own corpus, so
                # it carries no window of ours to disclose. The key is still
                # emitted, empty, so the renderer stays uniform across routes.
                "scope": sanitize_text(sig.get("scope", "")),
                "count": int(sig.get("count", 0) or 0),
                # The export's own `totals.requests` (see coach-export-read.py):
                # the denominator `count` is a fraction of. Kept as an int and
                # NOT passed through sanitize_text -- that returns a string,
                # and the renderer does arithmetic on this.
                "denominator": int(sig.get("denominator", 0) or 0),
                "source": sig.get("source", "unknown"),
            }

    payload = {
        "generated_at": now_iso(),
        "signals": sorted(merged.values(), key=lambda s: s["id"]),
    }

    signals_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = signals_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    os.replace(str(tmp), str(signals_file))
    return 0


if __name__ == "__main__":
    sys.exit(main())
