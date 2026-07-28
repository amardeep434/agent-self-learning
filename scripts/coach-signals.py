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
Route failures are non-fatal: a failing route contributes no signals.
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


def run_route(argv):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("coach-signals: route failed ({})".format(exc), file=sys.stderr)
        return []
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        return []
    try:
        out = json.loads(proc.stdout)
        return out if isinstance(out, list) else []
    except json.JSONDecodeError:
        return []


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
        for sig in run_route([sys.executable, str(SCRIPT_DIR / "coach-rules-eval.py"),
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
        for sig in run_route([sys.executable, str(SCRIPT_DIR / "coach-export-read.py"),
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
