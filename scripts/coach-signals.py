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
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

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
    home = str(Path.home())
    rules_enabled = flag("SL_COACH_RULES_ENABLED")
    export_enabled = flag("SL_COACH_EXPORT_ENABLED")
    signals_file = Path(os.environ.get(
        "SL_COACH_SIGNALS_FILE",
        os.path.join(home, ".claude", "state", "self-learning", "coach-signals.json")))

    if not rules_enabled and not export_enabled:
        if signals_file.is_file():
            signals_file.unlink()
        return 0

    merged = {}

    if rules_enabled:
        rules_dir = os.environ.get(
            "SL_COACH_RULES_DIR",
            os.path.join(home, ".claude", "scripts", "self-learning", "coach-rules"))
        db_path = os.environ.get(
            "SL_SEARCH_DB", os.path.join(home, ".claude", "sessions", "search.db"))
        for sig in run_route([sys.executable, str(SCRIPT_DIR / "coach-rules-eval.py"),
                              rules_dir, db_path]):
            merged[sanitize_text(sig["id"])] = {
                "id": sanitize_text(sig["id"]),
                "severity": sanitize_text(sig.get("severity", "unknown")),
                "suggestion": sanitize_text(sig.get("suggestion", "")),
                "count": int(sig.get("count", 0) or 0),
                "source": sig.get("source", "unknown"),
            }

    if export_enabled:
        export_path = os.environ.get(
            "SL_COACH_EXPORT_PATH", os.path.join(home, ".aiec", "summary-latest.json"))
        for sig in run_route([sys.executable, str(SCRIPT_DIR / "coach-export-read.py"),
                              export_path]):
            # export runs second: wins dedupe by design
            merged[sanitize_text(sig["id"])] = {
                "id": sanitize_text(sig["id"]),
                "severity": sanitize_text(sig.get("severity", "unknown")),
                "suggestion": sanitize_text(sig.get("suggestion", "")),
                "count": int(sig.get("count", 0) or 0),
                "source": sig.get("source", "unknown"),
            }

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "signals": sorted(merged.values(), key=lambda s: s["id"]),
    }

    signals_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = signals_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    os.replace(str(tmp), str(signals_file))
    return 0


if __name__ == "__main__":
    sys.exit(main())
