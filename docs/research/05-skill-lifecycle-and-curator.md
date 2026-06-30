# Skill Lifecycle & Curator System

Deep technical reference covering the three-layer skill lifecycle management in Hermes: provenance classification, usage telemetry, deterministic lifecycle transitions, LLM-driven consolidation, and the CRUD operations that underpin it all.

Source files:
- `agent/curator.py` (1977 lines)
- `tools/skill_usage.py` (948 lines)
- `tools/skill_manager_tool.py` (1440 lines)

---

## 1. Skill Provenance

Every skill on disk is classified into one of three provenance categories. The classification determines whether the curator may touch it, how its lifecycle is tracked, and what guards fire on write operations.

### 1.1 Three Categories

**Bundled** -- Skills seeded from the Hermes bundled repo during installation or update. Detected by reading `~/.hermes/skills/.bundled_manifest`, a flat file with `name:hash` entries per line:

```python
def _read_bundled_manifest_names() -> Set[str]:
    """Return the set of skill names that were seeded from the bundled repo.

    Reads ~/.hermes/skills/.bundled_manifest (format: "name:hash" per line).
    Returns empty set if the file is missing or unreadable.
    """
    manifest = _skills_dir() / ".bundled_manifest"
    if not manifest.exists():
        return set()
    names: Set[str] = set()
    try:
        for line in manifest.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            name = line.split(":", 1)[0].strip()
            if name:
                names.add(name)
    except OSError as e:
        logger.debug("Failed to read bundled manifest: %s", e)
    return names
```

**Hub-installed** -- Skills installed via the Skills Hub marketplace. Detected by reading `~/.hermes/skills/.hub/lock.json`:

```python
def _read_hub_installed_names() -> Set[str]:
    """Return the set of skill names installed via the Skills Hub.

    Reads ~/.hermes/skills/.hub/lock.json (see tools/skills_hub.py :: HubLockFile).
    """
    lock_path = _skills_dir() / ".hub" / "lock.json"
    if not lock_path.exists():
        return set()
    try:
        data = json.loads(lock_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            installed = data.get("installed") or {}
            if isinstance(installed, dict):
                names = {str(k) for k in installed.keys()}
                # ... also reads install_path entries and parses SKILL.md name: fields
                return names
    except (OSError, json.JSONDecodeError) as e:
        logger.debug("Failed to read hub lock file: %s", e)
    return set()
```

**Agent-created** -- Skills authored by the agent during background review passes, or by user-directed `skill_manage(action="create")` calls. Identified by a usage record where `created_by == "agent"` or `agent_created == True`:

```python
def _is_curator_managed_record(record: Any) -> bool:
    """Return True when a usage record opts a skill into curator management."""
    if not isinstance(record, dict):
        return False
    return record.get("created_by") == "agent" or record.get("agent_created") is True
```

### 1.2 Provenance Query Functions

```python
def is_agent_created(skill_name: str) -> bool:
    """Whether *skill_name* is neither bundled nor hub-installed."""
    off_limits = _read_bundled_manifest_names() | _read_hub_installed_names()
    if skill_name in off_limits:
        return False
    return not (
        _find_skill_dir(skill_name) is None
        and _find_external_skill_dir(skill_name) is not None
    )

def is_hub_installed(skill_name: str) -> bool:
    """Whether *skill_name* was installed via the Skills Hub."""
    return skill_name in _read_hub_installed_names()

def is_bundled(skill_name: str) -> bool:
    """Whether *skill_name* was seeded from the bundled repo skills."""
    return skill_name in _read_bundled_manifest_names()

def provenance(skill_name: str) -> str:
    """Classify a skill's origin: 'hub', 'bundled', or 'agent'."""
    if is_hub_installed(skill_name):
        return "hub"
    if is_bundled(skill_name):
        return "bundled"
    return "agent"
```

### 1.3 Protected Built-in Skills

A hard-coded set of skill names that the curator must NEVER archive, consolidate, or auto-transition, regardless of any configuration flag:

```python
PROTECTED_BUILTIN_SKILLS: Set[str] = {
    "plan",
}
```

These back load-bearing UX paths (e.g. `plan` powers the `/plan` slash-command). Silently archiving one turns its slash command into "Unknown command" with no signal to the user.

```python
def is_protected_builtin(skill_name: str) -> bool:
    """Whether *skill_name* is a load-bearing built-in the curator never touches."""
    return skill_name in PROTECTED_BUILTIN_SKILLS
```

Protected built-ins are filtered out at every level:
- `list_agent_created_skill_names()` drops them from the candidate list
- `is_curation_eligible()` returns `False` for them
- `archive_skill()` refuses with a specific error message
- `_background_review_write_guard()` blocks all write actions against them

### 1.4 Curation Eligibility

The combined eligibility check that governs whether the curator may track, archive, or transition a skill:

```python
def is_curation_eligible(skill_name: str, skill_path: Optional[Path] = None) -> bool:
    """Whether the curator may track/archive *skill_name*.

    Agent-created skills are always eligible. Bundled built-ins become eligible
    only when ``curator.prune_builtins`` is enabled. Hub-installed and external
    skill-dir skills are NEVER eligible.
    Protected built-ins (``PROTECTED_BUILTIN_SKILLS``) are NEVER eligible
    regardless of any flag.
    """
    if skill_path is not None and is_external_skill_path(skill_path):
        return False
    if is_protected_builtin(skill_name):
        return False
    if is_hub_installed(skill_name):
        return False
    if is_bundled(skill_name):
        return _prune_builtins_enabled()
    local_dir = _find_skill_dir(skill_name)
    if local_dir is not None:
        return not is_external_skill_path(local_dir)
    if _find_external_skill_dir(skill_name) is not None:
        return False
    return True
```

---

## 2. Usage Telemetry (.usage.json)

All per-skill telemetry is stored in a sidecar JSON file at `~/.hermes/skills/.usage.json`, keyed by skill name. This is separate from user-authored SKILL.md content to avoid conflict pressure for bundled/hub skills.

### 2.1 Record Schema

The `_empty_record()` function defines every field in a usage record:

```python
def _empty_record() -> Dict[str, Any]:
    return {
        "created_by": None,       # "agent" when created by background review
        "use_count": 0,           # bumped when skill is actively used/loaded
        "view_count": 0,          # bumped when skill_view() is called
        "last_used_at": None,     # ISO timestamp of last use
        "last_viewed_at": None,   # ISO timestamp of last view
        "patch_count": 0,         # bumped on edit/patch/write_file/remove_file
        "last_patched_at": None,  # ISO timestamp of last patch
        "created_at": _now_iso(), # ISO timestamp of record creation
        "state": STATE_ACTIVE,    # lifecycle state: "active" | "stale" | "archived"
        "pinned": False,          # opt-out from auto transitions
        "archived_at": None,      # ISO timestamp when archived
    }
```

The three valid lifecycle states are defined as module-level constants:

```python
STATE_ACTIVE = "active"
STATE_STALE = "stale"
STATE_ARCHIVED = "archived"
_VALID_STATES = {STATE_ACTIVE, STATE_STALE, STATE_ARCHIVED}
```

### 2.2 Derived Activity Timestamp

The `latest_activity_at()` function computes the newest real activity timestamp from a usage record. It intentionally excludes `created_at` so callers can distinguish never-active skills:

```python
def latest_activity_at(record: Dict[str, Any]) -> Optional[str]:
    """Return the newest actual activity timestamp for a usage record.

    "Activity" means a skill was used, viewed, or patched. Creation time is
    intentionally excluded.
    """
    latest_dt: Optional[datetime] = None
    latest_raw: Optional[str] = None
    for key in ("last_used_at", "last_viewed_at", "last_patched_at"):
        raw = record.get(key)
        dt = _parse_iso_timestamp(raw)
        if dt is None:
            continue
        if latest_dt is None or dt > latest_dt:
            latest_dt = dt
            latest_raw = str(raw)
    return latest_raw
```

Total activity count across all event types:

```python
def activity_count(record: Dict[str, Any]) -> int:
    """Return the total observed activity count across use/view/patch events."""
    total = 0
    for key in ("use_count", "view_count", "patch_count"):
        try:
            total += int(record.get(key) or 0)
        except (TypeError, ValueError):
            continue
    return total
```

### 2.3 Counter Bump Helpers

Three public helpers bump telemetry for ALL skills regardless of provenance -- usage tracking is pure observability:

```python
def bump_view(skill_name: str) -> None:
    """Bump view_count and last_viewed_at. Called from skill_view()."""
    def _apply(rec: Dict[str, Any]) -> None:
        rec["view_count"] = int(rec.get("view_count") or 0) + 1
        rec["last_viewed_at"] = _now_iso()
    _mutate(skill_name, _apply)

def bump_use(skill_name: str) -> None:
    """Bump use_count and last_used_at. Called when a skill is actively used."""
    def _apply(rec: Dict[str, Any]) -> None:
        rec["use_count"] = int(rec.get("use_count") or 0) + 1
        rec["last_used_at"] = _now_iso()
    _mutate(skill_name, _apply)

def bump_patch(skill_name: str) -> None:
    """Bump patch_count and last_patched_at. Called from skill_manage (patch/edit)."""
    def _apply(rec: Dict[str, Any]) -> None:
        rec["patch_count"] = int(rec.get("patch_count") or 0) + 1
        rec["last_patched_at"] = _now_iso()
    _mutate(skill_name, _apply)
```

### 2.4 The `_mutate()` Pattern

All record modifications go through a single `_mutate()` function that handles load-apply-save with file locking:

```python
def _mutate(skill_name: str, mutator, *, require_curation_eligible: bool = False) -> None:
    """Load, apply *mutator(record)* in place, save. Best-effort.

    By default this records telemetry for ANY skill -- bundled, hub-installed,
    or agent-created -- because usage tracking is pure observability and is
    orthogonal to whether a skill is ever curated. Lifecycle mutators
    (``set_state``, ``set_pinned``, ``mark_agent_created``) pass
    ``require_curation_eligible=True`` so they never write meaningless state
    onto a skill the curator can't manage.
    """
    if not skill_name:
        return
    try:
        if require_curation_eligible and not is_curation_eligible(skill_name):
            return
        with _usage_file_lock():
            data = load_usage()
            rec = data.get(skill_name)
            if not isinstance(rec, dict):
                rec = _empty_record()
            mutator(rec)
            data[skill_name] = rec
            save_usage(data)
    except Exception as e:
        logger.debug("skill_usage._mutate(%s) failed: %s", skill_name, e, exc_info=True)
```

The `require_curation_eligible` gate is used by lifecycle mutators:
- `set_state()` -- passes `require_curation_eligible=True`
- `set_pinned()` -- passes `require_curation_eligible=True`
- `mark_agent_created()` -- passes `require_curation_eligible=True`
- `bump_view()`, `bump_use()`, `bump_patch()` -- do NOT gate (pure observability)

### 2.5 File Locking

Concurrent access to `.usage.json` is serialized via `_usage_file_lock()`, using `fcntl.flock()` on Unix and `msvcrt.locking()` on Windows:

```python
@contextmanager
def _usage_file_lock():
    """Serialize .usage.json read-modify-write cycles across processes."""
    lock_path = _usage_file().with_suffix(".json.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    # ... platform-specific locking with fcntl or msvcrt
```

### 2.6 Atomic I/O

Writes use `tempfile.mkstemp()` + `os.replace()` for crash safety -- the same pattern as `.bundled_manifest`:

```python
def save_usage(data: Dict[str, Dict[str, Any]]) -> None:
    """Write the usage map atomically. Best-effort."""
    path = _usage_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=str(path.parent), prefix=".usage_", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, sort_keys=True, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, path)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except Exception as e:
        logger.debug("Failed to write %s: %s", path, e, exc_info=True)
```

---

## 3. Curator Deterministic Lifecycle

The curator has two operational modes: a pure deterministic state-transition pass (always runs), and an optional LLM consolidation pass (opt-in). Both are orchestrated by `run_curator_review()`.

### 3.1 Configuration Constants

```python
DEFAULT_INTERVAL_HOURS = 24 * 7  # 7 days
DEFAULT_MIN_IDLE_HOURS = 2
DEFAULT_STALE_AFTER_DAYS = 30
DEFAULT_ARCHIVE_AFTER_DAYS = 90
DEFAULT_CONSOLIDATE = False  # LLM pass is OFF by default
```

All are overridable via `~/.hermes/config.yaml` under the `curator` key:

```python
def get_interval_hours() -> int:       # curator.interval_hours
def get_min_idle_hours() -> float:     # curator.min_idle_hours
def get_stale_after_days() -> int:     # curator.stale_after_days
def get_archive_after_days() -> int:   # curator.archive_after_days
def get_consolidate() -> bool:         # curator.consolidate
def get_prune_builtins() -> bool:      # curator.prune_builtins (default True)
```

### 3.2 Lifecycle State Transitions: `active -> stale @ 30d -> archived @ 90d`

The `apply_automatic_transitions()` function walks every curator-managed skill and applies deterministic state changes based on the latest real activity timestamp:

```python
def apply_automatic_transitions(now: Optional[datetime] = None) -> Dict[str, int]:
    """Walk every curator-managed skill and move active/stale/archived based on
    the latest real activity timestamp. Pinned skills are never touched."""
    from tools import skill_usage as _u

    if now is None:
        now = datetime.now(timezone.utc)
    stale_cutoff = now - timedelta(days=get_stale_after_days())     # 30 days
    archive_cutoff = now - timedelta(days=get_archive_after_days()) # 90 days

    cron_referenced = _cron_referenced_skills()

    counts = {"marked_stale": 0, "archived": 0, "reactivated": 0, "checked": 0, "seeded": 0}

    for row in _u.agent_created_report():
        counts["checked"] += 1
        name = row["name"]
        if row.get("pinned"):
            continue

        # Skills referenced by any cron job are never auto-transitioned
        if name in cron_referenced:
            continue

        # First sight of an eligible skill with no persisted record: seed it
        if not row.get("_persisted", True):
            _u.seed_record_if_missing(name)
            counts["seeded"] += 1
            continue

        last_activity = _parse_iso(row.get("last_activity_at"))
        anchor = last_activity or _parse_iso(row.get("created_at")) or now
        if anchor.tzinfo is None:
            anchor = anchor.replace(tzinfo=timezone.utc)

        current = row.get("state", _u.STATE_ACTIVE)

        # Never-used skills (use_count == 0) get a grace floor
        never_used = int(row.get("use_count", 0) or 0) == 0
        if never_used and anchor > stale_cutoff:
            if current == _u.STATE_STALE:
                _u.set_state(name, _u.STATE_ACTIVE)
                counts["reactivated"] += 1
            continue

        if anchor <= archive_cutoff and current != _u.STATE_ARCHIVED:
            ok, _msg = _u.archive_skill(name)
            if ok:
                counts["archived"] += 1
        elif anchor <= stale_cutoff and current == _u.STATE_ACTIVE:
            _u.set_state(name, _u.STATE_STALE)
            counts["marked_stale"] += 1
        elif anchor > stale_cutoff and current == _u.STATE_STALE:
            # Skill got used again after being marked stale -- reactivate
            _u.set_state(name, _u.STATE_ACTIVE)
            counts["reactivated"] += 1

    return counts
```

Key rules:
- **Pinned** skills are never touched
- **Cron-referenced** skills are treated like pinned (never auto-transitioned)
- **Never-used** skills (`use_count == 0`) get a grace floor: they won't be archived until at least `stale_after_days` old
- **First-sight seeding**: built-ins with no usage record get their clock anchored to "now" via `seed_record_if_missing()`
- The transition **never deletes** -- only archives (recoverable)

### 3.3 Run Scheduling: 7-Day Interval

The `should_run_now()` function gates whether a curator pass should run:

```python
def should_run_now(now: Optional[datetime] = None) -> bool:
    """Return True if the curator should run immediately.

    Gates:
      - curator.enabled == True
      - not paused
      - last_run_at present AND older than interval_hours
    """
```

First-run behavior: when there is no `last_run_at` (fresh install), the curator does NOT run immediately. It seeds `last_run_at` to "now" and defers the first real pass by one full interval (7 days by default). Users who want to run it sooner can invoke `hermes curator run` explicitly.

### 3.4 Curator State Persistence

State is stored in `~/.hermes/skills/.curator_state`:

```python
def _default_state() -> Dict[str, Any]:
    return {
        "last_run_at": None,
        "last_run_duration_seconds": None,
        "last_run_summary": None,
        "last_run_summary_shown_at": None,
        "last_report_path": None,
        "paused": False,
        "run_count": 0,
    }
```

### 3.5 The `CURATOR_REVIEW_PROMPT` (Verbatim)

This is the full prompt sent to the forked AIAgent for the LLM consolidation pass. It is defined at lines 403-554 of `curator.py`:

```python
CURATOR_REVIEW_PROMPT = (
    "You are running as Hermes' background skill CURATOR. This is an "
    "UMBRELLA-BUILDING consolidation pass, not a passive audit and not a "
    "duplicate-finder.\n\n"
    "The goal of the skill collection is a LIBRARY OF CLASS-LEVEL "
    "INSTRUCTIONS AND EXPERIENTIAL KNOWLEDGE. A collection of hundreds of "
    "narrow skills where each one captures one session's specific bug is "
    "a FAILURE of the library — not a feature. An agent searching skills "
    "matches on descriptions, not on exact names; one broad umbrella "
    "skill with labeled subsections beats five narrow siblings for "
    "discoverability, not the other way around.\n\n"
    "The right target shape is CLASS-LEVEL skills with rich SKILL.md "
    "bodies + `references/`, `templates/`, and `scripts/` subfiles for "
    "session-specific detail — not one-session-one-skill micro-entries.\n\n"
    "Hard rules — do not violate:\n"
    "1. DO NOT touch bundled, hub-installed, or external-dir skills "
    "(`skills.external_dirs`). The candidate list below is already filtered "
    "to local curator-managed skills only; external skills are externally "
    "owned and read-only to this background curator.\n"
    "2. DO NOT delete any skill. Archiving (moving the skill's directory "
    "into ~/.hermes/skills/.archive/) is the maximum destructive action. "
    "Archives are recoverable; deletion is not.\n"
    "3. DO NOT touch skills shown as pinned=yes. Skip them entirely.\n"
    "3b. DO NOT archive, delete, consolidate, move, or otherwise modify any "
    "skill named in the protected built-ins list (currently: plan). These "
    "back load-bearing UX (slash-command entry points referenced in docs and "
    "tips) and are filtered out of the candidate list below — never resurrect "
    "one as an archive or absorb target.\n"
    "3c. DO NOT archive or prune any skill marked `cron=yes` in the candidate "
    "list. A cron job depends on it and will fail to load it on its next "
    "run. You MAY still consolidate it into an umbrella — but only because "
    "the curator rewrites cron job skill references to follow consolidations; "
    "never simply prune it.\n"
    "4. DO NOT use usage counters as a reason to skip consolidation. The "
    "counters are new and often mostly zero. Judge overlap on CONTENT, "
    "not on use_count. 'use=0' is not evidence a skill is valuable; it's "
    "absence of evidence either way. Corollary: 'use=0' is ALSO not a "
    "reason to PRUNE a skill. Never archive a never-used skill (use=0) "
    "unless it is at least 30 days old (check last_activity / created date) "
    "AND its content is genuinely obsolete or fully absorbed elsewhere — a "
    "recently-created skill simply may not have had its trigger come up yet.\n"
    "5. DO NOT reject consolidation on the grounds that 'each skill has "
    "a distinct trigger'. Pairwise distinctness is the wrong bar. The "
    "right bar is: 'would a human maintainer write this as N separate "
    "skills, or as one skill with N labeled subsections?' When the "
    "answer is the latter, merge.\n\n"
    "How to work — not optional:\n"
    "1. Scan the full candidate list. Identify PREFIX CLUSTERS (skills "
    "sharing a first word or domain keyword). Examples you are likely "
    "to find: hermes-config-*, hermes-dashboard-*, gateway-*, codex-*, "
    "ollama-*, anthropic-*, gemini-*, mcp-*, salvage-*, pr-*, "
    "competitor-*, python-*, security-*, etc. Expect 10-25 clusters.\n"
    "2. For each cluster with 2+ members, do NOT ask 'are these pairs "
    "overlapping?' — ask 'what is the UMBRELLA CLASS these skills all "
    "serve? Would a maintainer name that class and write one skill for "
    "it?' If yes, pick (or create) the umbrella and absorb the siblings "
    "into it.\n"
    "3. Three ways to consolidate — use the right one per cluster:\n"
    "   a. MERGE INTO EXISTING UMBRELLA — one skill in the cluster is "
    "already broad enough to be the umbrella (example: `pr-triage-"
    "salvage` for the PR review cluster). Patch it to add a labeled "
    "section for each sibling's unique insight, then archive the "
    "siblings.\n"
    "   b. CREATE A NEW UMBRELLA SKILL.md — no existing member is broad "
    "enough. Use skill_manage action=create to write a new class-level "
    "skill whose SKILL.md covers the shared workflow and has short "
    "labeled subsections. Archive the now-absorbed narrow siblings.\n"
    "   c. DEMOTE TO REFERENCES/TEMPLATES/SCRIPTS — a sibling has "
    "narrow-but-valuable session-specific content. Move it into the "
    "umbrella's appropriate support directory:\n"
    "      • `references/<topic>.md` for session-specific detail OR "
    "condensed knowledge banks (quoted research, API docs excerpts, "
    "domain notes, provider quirks, reproduction recipes)\n"
    "      • `templates/<name>.<ext>` for starter files meant to be "
    "copied and modified\n"
    "      • `scripts/<name>.<ext>` for statically re-runnable actions "
    "(verification scripts, fixture generators, probes)\n"
    "      Then archive the old sibling. Use `terminal` with `mkdir -p "
    "~/.hermes/skills/<umbrella>/references/ && mv ... <umbrella>/"
    "references/<topic>.md` (or templates/ / scripts/).\n\n"
    "Package integrity — not optional:\n"
    "Before demoting or archiving a skill, inspect it as a COMPLETE "
    "directory package, not just SKILL.md. A skill root may include "
    "`references/`, `templates/`, `scripts/`, and `assets/`; `skill_view` "
    "discovers those relative to the skill root. A reference markdown file "
    "inside another skill is NOT a new skill root and does not get its own "
    "linked-file discovery.\n"
    "If the source skill has support files OR SKILL.md contains relative "
    "links such as `references/...`, `templates/...`, `scripts/...`, or "
    "`assets/...`, DO NOT flatten only SKILL.md into "
    "`<umbrella>/references/<old>.md`. Choose one safe path instead:\n"
    "   • keep it as a standalone skill, OR\n"
    "   • fully merge it by re-homing every needed support file into the "
    "umbrella's canonical `references/`, `templates/`, `scripts/`, or "
    "`assets/` directories AND rewrite the destination instructions to "
    "the new paths, OR\n"
    "   • archive the entire original skill package unchanged.\n"
    "Never leave archived/demoted instructions pointing at files that were "
    "left behind under the old skill directory.\n"
    "4. Also flag skills whose NAME is too narrow (contains a PR number, "
    "a feature codename, a specific error string, an 'audit' / "
    "'diagnosis' / 'salvage' session artifact). These almost always "
    "belong as a subsection or support file under a class-level umbrella.\n"
    "5. Iterate. After one consolidation round, scan the remaining set "
    "and look for the NEXT umbrella opportunity. Don't stop after 3 "
    "merges.\n\n"
    "Your toolset:\n"
    "  - skills_list, skill_view        — read the current landscape\n"
    "  - skill_manage action=patch      — add sections to the umbrella\n"
    "  - skill_manage action=create     — create a new umbrella SKILL.md\n"
    "  - skill_manage action=write_file — add a references/, templates/, "
    "or scripts/ file under an existing skill (the skill must already "
    "exist)\n"
    "  - skill_manage action=delete     — archive a skill. MUST pass "
    "`absorbed_into=<umbrella>` when you've merged its content into another "
    "skill, or `absorbed_into=\"\"` when you're truly pruning with no "
    "forwarding target. This drives cron-job skill-reference migration — "
    "guessing from your YAML summary after the fact is fragile.\n"
    "  - terminal                       — move LOCAL candidate content into "
    "a support subfile when package integrity requires it; never mv, cp, rm, "
    "patch, or rewrite bundled, hub-installed, or external-dir skills\n\n"
    "'keep' is a legitimate decision ONLY when the skill is already a "
    "class-level umbrella and none of the proposed merges would improve "
    "discoverability. 'This is narrow but distinct from its siblings' "
    "is NOT a reason to keep — it's a reason to move it under an "
    "umbrella as a subsection or support file.\n\n"
    "Expected output: real umbrella-ification. Process every obvious "
    "cluster. If you end the pass with fewer than 10 archives, you "
    "stopped too early — go back and look at the clusters you left "
    "alone.\n\n"
    "When done, write a human summary AND a structured machine-readable "
    "block so downstream tooling can distinguish consolidation from "
    "pruning. Format EXACTLY:\n\n"
    "## Structured summary (required)\n"
    "```yaml\n"
    "consolidations:\n"
    "  - from: <old-skill-name>\n"
    "    into: <umbrella-skill-name>\n"
    "    reason: <one short sentence — why merged, not just 'similar'>\n"
    "prunings:\n"
    "  - name: <skill-name>\n"
    "    reason: <one short sentence — why archived with no merge target>\n"
    "```\n\n"
    "Every skill you moved to .archive/ MUST appear in exactly one of the "
    "two lists. If you consolidated X into umbrella Y (patched Y, wrote "
    "a references file to Y, or created Y with X's content absorbed), X "
    "goes under `consolidations` with `into: Y`. If you archived X with "
    "no absorption — truly stale, irrelevant, or obsolete — X goes under "
    "`prunings`. Leave a list empty (`consolidations: []`) if none. Do "
    "not omit the block. The block comes AFTER your human-readable "
    "summary of clusters processed, patches made, and decisions left alone."
)
```

### 3.6 Dry-Run Banner

When running in dry-run mode, this banner is prepended to the prompt:

```python
CURATOR_DRY_RUN_BANNER = (
    "═══════════════════════════════════════════════════════════════\n"
    "DRY-RUN — REPORT ONLY. DO NOT MUTATE THE SKILL LIBRARY.\n"
    "═══════════════════════════════════════════════════════════════\n"
    "\n"
    "This is a PREVIEW pass. Follow every instruction below EXCEPT:\n"
    "\n"
    "  • DO NOT call skill_manage with action=patch, create, delete, "
    "write_file, or remove_file.\n"
    "  • DO NOT call terminal to mv skill directories into .archive/.\n"
    "  • DO NOT call terminal to mv, cp, rm, or rewrite any file under "
    "~/.hermes/skills/.\n"
    "  • skills_list and skill_view are FINE — read as much as you need.\n"
    "\n"
    "Your output IS the deliverable. Produce the exact same "
    "human-readable summary and structured YAML block you would "
    "produce on a live run — but describe the actions you WOULD take, "
    "not actions you took. A downstream reviewer will read the report "
    "and decide whether to approve a live run with "
    "`hermes curator run` (no flag).\n"
    "\n"
    "If you accidentally take a mutating action, say so explicitly in "
    "the summary so the reviewer can revert it.\n"
    "═══════════════════════════════════════════════════════════════"
)
```

### 3.7 Consolidation: Umbrella-Building

When `curator.consolidate` is `True` (or `--consolidate` is passed on the CLI), the curator spawns a forked `AIAgent` to run the LLM review prompt. The fork is configured with:

```python
review_agent = AIAgent(
    model=_model_name,
    provider=_resolved_provider,
    api_key=_api_key,
    base_url=_base_url,
    api_mode=_api_mode,
    max_iterations=9999,       # high ceiling for large skill collections
    quiet_mode=True,
    platform="curator",
    skip_context_files=True,
    skip_memory=True,
)
# Disable recursive nudges
review_agent._memory_nudge_interval = 0
review_agent._skill_nudge_interval = 0
# Tag as background review so write guards fire
review_agent._memory_write_origin = "background_review"
```

The candidate list rendered for the LLM includes per-skill metadata:

```python
def _render_candidate_list() -> str:
    rows = skill_usage.agent_created_report()
    # ...
    for r in rows:
        lines.append(
            f"- {r['name']}  "
            f"state={r['state']}  "
            f"pinned={'yes' if r.get('pinned') else 'no'}  "
            f"cron={'yes' if r['name'] in cron_referenced else 'no'}  "
            f"activity={r.get('activity_count', 0)}  "
            f"use={r.get('use_count', 0)}  "
            f"view={r.get('view_count', 0)}  "
            f"patches={r.get('patch_count', 0)}  "
            f"last_activity={r.get('last_activity_at') or 'never'}"
        )
```

### 3.8 Classification of Removed Skills

After the LLM pass, removed skills are classified as either "consolidated" (absorbed into an umbrella) or "pruned" (archived for staleness). The classification pipeline has three layers of authority:

1. **`absorbed_into` declarations** (authoritative) -- extracted from `skill_manage(action='delete', absorbed_into=...)` calls via `_extract_absorbed_into_declarations()`
2. **Model's structured YAML block** -- parsed from the LLM's final response via `_parse_structured_summary()`
3. **Tool-call heuristic** -- scans `skill_manage` calls for evidence of absorption via `_classify_removed_skills()`

These are reconciled by `_reconcile_classification()`, which evaluates in order: model-declared `absorbed_into` at delete time is authoritative, then model's YAML block (if target exists), then tool-call heuristic, then fallback to pruned.

### 3.9 Cron Job Rewriting

When skills are consolidated, cron jobs referencing the old skill name are automatically rewritten:

```python
if consolidated_map or pruned_names:
    from cron.jobs import rewrite_skill_refs as _rewrite_cron_refs
    cron_rewrites = _rewrite_cron_refs(
        consolidated=consolidated_map,
        pruned=pruned_names,
    )
```

### 3.10 Per-Run Reports

Each curator run writes artifacts under `~/.hermes/logs/curator/{YYYYMMDD-HHMMSS}/`:
- `run.json` -- full machine-readable record
- `REPORT.md` -- human-readable summary
- `cron_rewrites.json` -- only when cron jobs were touched

### 3.11 Pre-Run Backup

Before applying automatic transitions, the curator takes a snapshot:

```python
from agent import curator_backup
snap = curator_backup.snapshot_skills(reason="pre-curator-run")
```

---

## 4. Skill Manager Operations

The `skill_manage()` function in `tools/skill_manager_tool.py` is the single entry point for all skill CRUD operations. It dispatches to six action handlers.

### 4.1 Constants and Validation

```python
MAX_SKILL_CONTENT_CHARS = 100_000   # ~36k tokens at 2.75 chars/token
MAX_SKILL_FILE_BYTES = 1_048_576    # 1 MiB per supporting file
MAX_NAME_LENGTH = 64
MAX_DESCRIPTION_LENGTH = 1024

# Characters allowed in skill names (filesystem-safe, URL-friendly)
VALID_NAME_RE = re.compile(r'^[a-z0-9][a-z0-9._-]*$')

# Subdirectories allowed for write_file/remove_file
ALLOWED_SUBDIRS = {"references", "templates", "scripts", "assets"}
```

### 4.2 `create` -- Create a New Skill

```python
def _create_skill(name: str, content: str, category: str = None) -> Dict[str, Any]:
```

Validation chain:
1. `_validate_name(name)` -- checks `VALID_NAME_RE`, max 64 chars
2. `_validate_category(category)` -- single directory segment, same regex
3. `_validate_frontmatter(content)` -- requires `---` delimited YAML with `name:` and `description:` fields, plus non-empty body after frontmatter
4. `_validate_content_size(content)` -- max 100,000 chars
5. `_find_skill(name)` -- collision check across all directories
6. Creates `~/.hermes/skills/[category/]name/SKILL.md`
7. `_security_scan_skill()` -- rolls back on block (deletes entire directory)

### 4.3 `edit` -- Full Rewrite of SKILL.md

```python
def _edit_skill(name: str, content: str) -> Dict[str, Any]:
```

Same validation as create (frontmatter + size), but targets an existing skill. Backs up original content for rollback if security scan blocks the edit.

### 4.4 `patch` -- Targeted Find-and-Replace

```python
def _patch_skill(
    name: str,
    old_string: str,
    new_string: str,
    file_path: str = None,
    replace_all: bool = False,
) -> Dict[str, Any]:
```

Uses the fuzzy matching engine from `tools.fuzzy_match`:

```python
from tools.fuzzy_match import fuzzy_find_and_replace

new_content, match_count, _strategy, match_error = fuzzy_find_and_replace(
    content, old_string, new_string, replace_all
)
```

This handles whitespace normalization, indentation differences, and escape sequences. On match failure, a preview of the file (first 500 chars) is returned along with a no-match hint.

If patching SKILL.md (no `file_path`), frontmatter validation is re-run on the result.

### 4.5 `delete` -- Remove a Skill

```python
def _delete_skill(name: str, absorbed_into: Optional[str] = None) -> Dict[str, Any]:
```

Guard chain:
1. `_background_review_write_guard()` -- blocks autonomous writes to external/bundled/hub/pinned skills
2. `_curator_consolidation_delete_guard()` -- fail-closed on unverified deletes during consolidation
3. `_pinned_guard()` -- blocks deletion of pinned skills
4. `absorbed_into` validation -- if non-empty, the target must exist on disk
5. `_validate_delete_target()` -- defense-in-depth: refuses symlinks, skills roots, paths outside known roots

During the curator consolidation pass (`is_background_review()` is True), deletion is routed through `archive_skill()` for recoverability. Foreground user-directed deletes use `shutil.rmtree()`.

### 4.6 `write_file` -- Add/Overwrite Supporting File

```python
def _write_file(name: str, file_path: str, file_content: str) -> Dict[str, Any]:
```

File path must be under one of `ALLOWED_SUBDIRS` (`references`, `templates`, `scripts`, `assets`) or be `SKILL.md` itself. Path traversal is checked via `tools.path_security.has_traversal_component()`. Content is limited to `MAX_SKILL_FILE_BYTES` (1 MiB) and `MAX_SKILL_CONTENT_CHARS` (100,000).

### 4.7 `remove_file` -- Remove a Supporting File

```python
def _remove_file(name: str, file_path: str) -> Dict[str, Any]:
```

Same path validation as `write_file`. On file-not-found, lists available files under allowed subdirectories so the model can self-correct. Cleans up empty parent directories after removal.

### 4.8 `_background_review_write_guard()`

This is the critical guard that prevents the autonomous curator fork from modifying externally-owned skills:

```python
def _background_review_write_guard(
    name: str,
    skill_dir: Path,
    action: str,
) -> Optional[Dict[str, Any]]:
    """Refuse autonomous curator writes to externally owned skills."""
    try:
        from tools.skill_provenance import is_background_review
        if not is_background_review():
            return None  # foreground agents pass through
    except Exception:
        return None

    # Pinned check (stricter than foreground: blocks ALL writes, not just delete)
    try:
        from tools import skill_usage
        if skill_usage.get_record(name).get("pinned"):
            return {
                "success": False,
                "error": (
                    f"Refusing background curator {action} for pinned skill "
                    f"'{name}': pinned skills are off-limits to autonomous "
                    "maintenance."
                ),
            }
    except Exception:
        pass

    # External skill dirs check
    try:
        from agent.skill_utils import is_external_skill_path
        if is_external_skill_path(skill_dir):
            return {
                "success": False,
                "error": (
                    f"Refusing background curator {action} for skill '{name}': "
                    "the skill lives in skills.external_dirs."
                ),
            }
    except Exception:
        pass

    # Protected builtin, hub-installed, and bundled checks
    try:
        from tools import skill_usage
        if skill_usage.is_protected_builtin(name):
            return {"success": False, "error": f"Refusing background curator {action} for protected built-in skill '{name}'."}
        if skill_usage.is_hub_installed(name):
            return {"success": False, "error": f"Refusing background curator {action} for hub-installed skill '{name}'."}
        if skill_usage.is_bundled(name):
            return {"success": False, "error": f"Refusing background curator {action} for bundled skill '{name}'."}
    except Exception:
        pass
    return None
```

Note the asymmetry: for the **foreground** agent, pin only blocks deletion (`_pinned_guard`). For the **background** curator fork, pin blocks ALL writes (patch, edit, write_file, remove_file, delete) because there is no user in the loop to consent.

### 4.9 `_curator_consolidation_delete_guard()`

Fail-closed guard that prevents the LLM consolidation pass from pruning skills without declaring where the content went:

```python
def _curator_consolidation_delete_guard(
    name: str, absorbed_into: Optional[str]
) -> Optional[Dict[str, Any]]:
    """Fail closed on unverified deletes during the curator consolidation pass."""
    try:
        from tools.skill_provenance import is_background_review
        if not is_background_review():
            return None
    except Exception:
        return None

    declared = isinstance(absorbed_into, str) and absorbed_into.strip()
    if declared:
        return None  # verified consolidation, allow

    return {
        "success": False,
        "error": (
            f"Refusing background curator delete of skill '{name}': the "
            "consolidation pass may only archive a skill it has absorbed into "
            "an umbrella. Pass absorbed_into=<umbrella> (the umbrella must "
            "already exist) to record a verified consolidation. Pruning a "
            "skill with no forwarding target is not permitted here — the "
            "deterministic inactivity prune handles staleness archival "
            "separately. Keeping '{name}' active."
        ),
        "_fail_closed": True,
    }
```

This was added to fix issue #29912, where the consolidation pass archived whole clusters with zero verified consolidations.

### 4.10 Telemetry Integration in `skill_manage()`

After a successful action, `skill_manage()` updates telemetry:

```python
if result.get("success"):
    # ... clear prompt cache ...
    try:
        from tools.skill_usage import bump_patch, forget, mark_agent_created
        from tools.skill_provenance import is_background_review
        if action == "create":
            if is_background_review():
                mark_agent_created(name)
        elif action in {"patch", "edit", "write_file", "remove_file"}:
            bump_patch(name)
        elif action == "delete":
            if not result.get("_archived"):
                forget(name)
    except Exception:
        pass
```

Key distinction: `mark_agent_created()` is ONLY called when the background review fork creates a skill. Foreground `skill_manage(create)` calls are user-directed and those skills belong to the user -- the curator must not touch them.

### 4.11 Delete Target Validation (Defense-in-Depth)

Port of Kilo Code #11227/#11240 fix. The `_validate_delete_target()` function prevents `shutil.rmtree()` from operating on:

1. Paths not strictly inside a known skills root
2. A skills root itself (would wipe everything)
3. Directories reached via a symlink/junction

```python
def _validate_delete_target(skill_dir: Path) -> Optional[str]:
    # (3) Reject symlink/junction redirects
    if _is_path_redirect(skill_dir):
        return "Refusing to delete ..."

    resolved = skill_dir.resolve()
    roots = [root.resolve() for root in get_all_skills_dirs()]

    for root in roots:
        # (2) Never rmtree a skills root itself
        if resolved == root:
            return "Refusing to delete ..."
        # (1) Must be strictly inside a known root
        try:
            rel = resolved.relative_to(root)
        except ValueError:
            continue
        if rel.parts:  # at least one component below root
            return None

    return "Refusing to delete ..."
```

---

## 5. Archive & Restore

### 5.1 Archive Directory

All archived skills are moved to `~/.hermes/skills/.archive/`:

```python
def _archive_dir() -> Path:
    return _skills_dir() / ".archive"
```

### 5.2 `archive_skill()`

```python
def archive_skill(skill_name: str) -> Tuple[bool, str]:
    """Move a curator-eligible skill directory to ~/.hermes/skills/.archive/.

    Returns (ok, message). Never archives hub-installed skills. Bundled
    built-ins are only archivable when ``curator.prune_builtins`` is enabled.
    """
```

Key behaviors:
- Protected built-ins are refused with a specific message
- Hub-installed skills are refused
- Bundled skills are refused unless `curator.prune_builtins` is enabled
- Category nesting is flattened into a single `.archive/<skill>/`
- On collision, a timestamp suffix is appended: `<skill>-YYYYMMDDHHMMSS`
- Cross-device moves fall back to `shutil.move()`
- State is set to `STATE_ARCHIVED` in the usage record

### 5.3 Suppression System for Bundled Skills

When a bundled skill is archived, its name is added to `~/.hermes/skills/.curator_suppressed`. This prevents `hermes update` from re-seeding it:

```python
# In archive_skill():
if is_bundled(skill_name):
    add_suppressed_name(skill_name)
```

The suppression file is one skill name per line:

```python
def read_suppressed_names() -> Set[str]:
    """Built-in skills the curator pruned -- the re-seeder must leave archived."""
    path = _suppressed_file()
    if not path.exists():
        return set()
    names: Set[str] = set()
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                names.add(line)
    except OSError as e:
        logger.debug("Failed to read curator suppression list: %s", e)
    return names
```

Write operations use the same atomic pattern (tempfile + os.replace + os.fsync):

```python
def _write_suppressed_names(names: Set[str]) -> None:
    path = _suppressed_file()
    # ... tempfile + os.replace pattern ...
```

### 5.4 `restore_skill()`

```python
def restore_skill(skill_name: str) -> Tuple[bool, str]:
    """Move an archived skill back to ~/.hermes/skills/."""
```

Guard chain:
- Refuses to restore over a hub-installed skill (would shadow upstream)
- Refuses to restore over a bundled skill UNLESS `prune_builtins` is enabled
- Looks for exact name match in `.archive/`, then timestamped duplicates (only the 14-digit timestamp suffix format: `<skill>-YYYYMMDDHHMMSS`)
- Restores to flat top-level layout (original category nesting is NOT reconstructed)
- Clears suppression entry so future updates can re-seed the built-in

```python
# In restore_skill():
remove_suppressed_name(skill_name)
set_state(skill_name, STATE_ACTIVE)
```

### 5.5 Listing Archived Skills

```python
def list_archived_skill_names() -> List[str]:
    """Enumerate skills in ``~/.hermes/skills/.archive/``."""
    archive_root = _archive_dir()
    if not archive_root.exists():
        return []
    return sorted({p.name for p in archive_root.iterdir() if p.is_dir()})
```

---

## 6. Agent-Created Skill Flow

This section traces the full lifecycle of an agent-created skill from creation to eventual curation.

### 6.1 Creation During Background Review

When the curator's forked AIAgent creates a new skill via `skill_manage(action="create")`, the telemetry integration in `skill_manage()` fires:

```python
if action == "create":
    if is_background_review():
        mark_agent_created(name)
```

The `mark_agent_created()` function sets `created_by = "agent"` in the usage record:

```python
def mark_agent_created(skill_name: str) -> None:
    """Opt a skill created by skill_manage into curator management."""
    def _apply(rec: Dict[str, Any]) -> None:
        rec["created_by"] = "agent"
    _mutate(skill_name, _apply, require_curation_eligible=True)
```

This single field is what makes the skill eligible for curation. Without it, the skill would be treated as user-authored and left alone.

### 6.2 Foreground Creation (User-Directed)

When the user asks the agent to create a skill (foreground `skill_manage(create)`), `is_background_review()` returns `False`, so `mark_agent_created()` is NOT called. The skill belongs to the user and the curator will not touch it.

### 6.3 Telemetry Tracking

Once created, the skill accumulates telemetry through normal tool usage:
- `bump_view()` -- called when `skill_view()` displays the skill
- `bump_use()` -- called when the skill is loaded into the prompt path
- `bump_patch()` -- called on any edit/patch/write_file/remove_file

All three update their respective counters and timestamps.

### 6.4 Candidate Enumeration

The `list_agent_created_skill_names()` function builds the list of curator-managed skills:

```python
def list_agent_created_skill_names() -> List[str]:
    """Enumerate skills the curator may manage."""
    base = _skills_dir()
    hub = _read_hub_installed_names()
    bundled = _read_bundled_manifest_names()
    prune_builtins = _prune_builtins_enabled()
    usage = load_usage()

    names: List[str] = []
    for skill_md in base.rglob("SKILL.md"):
        if is_excluded_skill_path(skill_md):
            continue
        if is_external_skill_path(skill_md):
            continue
        name = _read_skill_name(skill_md, fallback=skill_md.parent.name)
        if name in hub:
            continue
        if is_protected_builtin(name):
            continue
        if name in bundled:
            if not prune_builtins:
                continue
            names.append(name)
            continue
        # Agent-authored skills must opt in via their record
        if not _is_curator_managed_record(usage.get(name)):
            continue
        names.append(name)
    return sorted(set(names))
```

The `agent_created_report()` function enriches these names with full usage data:

```python
def agent_created_report() -> List[Dict[str, Any]]:
    """Return {name, state, pinned, last_activity_at, ...} for every curator-managed skill."""
    data = load_usage()
    rows: List[Dict[str, Any]] = []
    for name in list_agent_created_skill_names():
        raw = data.get(name)
        persisted = isinstance(raw, dict)
        rec = raw if isinstance(raw, dict) else _empty_record()
        # ... backfill missing keys ...
        row = {"name": name, **rec, "_persisted": persisted}
        row["last_activity_at"] = latest_activity_at(row)
        row["activity_count"] = activity_count(row)
        rows.append(row)
    return rows
```

The `_persisted` field distinguishes real records from backfilled ones. The curator uses this to seed the inactivity clock for newly-eligible skills rather than treating them as ancient.

### 6.5 Deterministic Lifecycle

The skill proceeds through the lifecycle:

1. **Active** (default at creation) -- skill is live, discoverable, and usable
2. **Stale** (after 30 days of no activity) -- `apply_automatic_transitions()` sets `state = "stale"`
3. **Archived** (after 90 days of no activity) -- `archive_skill()` moves directory to `.archive/`

At any point:
- **Using/viewing/patching** the skill resets the activity clock and reactivates it if stale
- **Pinning** the skill exempts it from all auto-transitions
- **Cron-referencing** the skill protects it from auto-transition (treated like pinned)

### 6.6 LLM Consolidation

If `curator.consolidate` is enabled and the skill shows up in the candidate list, the LLM review pass may:
- **Merge it into an existing umbrella** via `skill_manage(action="patch")` on the umbrella, then `skill_manage(action="delete", absorbed_into=<umbrella>)` on the narrow skill
- **Create a new umbrella** via `skill_manage(action="create")` and absorb it
- **Demote it to a reference file** via `skill_manage(action="write_file")` on the umbrella, then archive the original
- **Leave it alone** if it's already a class-level umbrella

Every delete during consolidation must pass `absorbed_into=<umbrella>` to satisfy `_curator_consolidation_delete_guard()`. The umbrella must exist on disk. This prevents the fail-open behavior from issue #29912.

### 6.7 Recovery

Archived skills are always recoverable:
- `hermes curator restore <name>` calls `restore_skill()`
- Manual `mv ~/.hermes/skills/.archive/<name> ~/.hermes/skills/<name>` also works
- The per-run `REPORT.md` documents what was archived and where it went
- Pre-run snapshots via `curator_backup.snapshot_skills()` provide bulk recovery

### 6.8 The `run_curator_review()` Orchestration

The full flow in `run_curator_review()`:

1. Take a pre-mutation snapshot (`curator_backup.snapshot_skills()`)
2. Apply deterministic transitions (`apply_automatic_transitions()`) -- unless dry-run
3. Save state with `last_run_at` and `run_count` (not bumped in dry-run)
4. If consolidation is enabled:
   a. Snapshot skill state before the LLM pass
   b. Render the candidate list with usage stats
   c. Build the prompt (with or without dry-run banner, with or without prune-builtins note)
   d. Spawn the forked AIAgent via `_run_llm_review(prompt)`
   e. Build the rename summary (`_build_rename_summary()`)
5. Write the per-run report (`_write_run_report()`)
6. Update `.curator_state` with final summary and report path
7. Call `on_summary` callback

When synchronous is False (default), the LLM pass runs in a daemon thread:

```python
if synchronous:
    _llm_pass()
else:
    t = threading.Thread(target=_llm_pass, daemon=True, name="curator-review")
    t.start()
```

### 6.9 Entry Point for Session-Start Hook

```python
def maybe_run_curator(
    *,
    idle_for_seconds: Optional[float] = None,
    on_summary: Optional[Callable[[str], None]] = None,
) -> Optional[Dict[str, Any]]:
    """Best-effort: run a curator pass if all gates pass. Never raises."""
    try:
        if not should_run_now():
            return None
        if idle_for_seconds is not None:
            min_idle_s = get_min_idle_hours() * 3600.0
            if idle_for_seconds < min_idle_s:
                return None
        return run_curator_review(on_summary=on_summary)
    except Exception as e:
        logger.debug("maybe_run_curator failed: %s", e, exc_info=True)
        return None
```

The idle check (`min_idle_hours`, default 2 hours) is enforced here at the call site, not in `should_run_now()`, because only the caller knows whether an agent is actively running.

---

## Summary of Key Configuration Values

| Parameter | Default | Config Key | Purpose |
|-----------|---------|------------|---------|
| `DEFAULT_INTERVAL_HOURS` | `168` (7 days) | `curator.interval_hours` | Minimum time between curator runs |
| `DEFAULT_MIN_IDLE_HOURS` | `2` | `curator.min_idle_hours` | Agent must be idle this long before curator fires |
| `DEFAULT_STALE_AFTER_DAYS` | `30` | `curator.stale_after_days` | Days of inactivity before marking stale |
| `DEFAULT_ARCHIVE_AFTER_DAYS` | `90` | `curator.archive_after_days` | Days of inactivity before archiving |
| `DEFAULT_CONSOLIDATE` | `False` | `curator.consolidate` | Whether LLM umbrella-building pass runs |
| `prune_builtins` | `True` | `curator.prune_builtins` | Whether bundled built-ins are curation candidates |
| `MAX_SKILL_CONTENT_CHARS` | `100,000` | -- | Max chars for SKILL.md or any supporting file |
| `MAX_SKILL_FILE_BYTES` | `1,048,576` (1 MiB) | -- | Max bytes for a supporting file |
| `MAX_NAME_LENGTH` | `64` | -- | Max chars for a skill name |
| `MAX_DESCRIPTION_LENGTH` | `1,024` | -- | Max chars for frontmatter description |
| `VALID_NAME_RE` | `^[a-z0-9][a-z0-9._-]*$` | -- | Allowed characters in skill names |
| `PROTECTED_BUILTIN_SKILLS` | `{"plan"}` | -- | Skills never touched by curator |
| `ALLOWED_SUBDIRS` | `{"references", "templates", "scripts", "assets"}` | -- | Valid subdirectories for write_file |

## File Locations

| File | Purpose |
|------|---------|
| `~/.hermes/skills/.usage.json` | Per-skill usage telemetry records |
| `~/.hermes/skills/.usage.json.lock` | File lock for concurrent access |
| `~/.hermes/skills/.curator_state` | Persistent scheduler state |
| `~/.hermes/skills/.bundled_manifest` | Bundled skill names + hashes |
| `~/.hermes/skills/.hub/lock.json` | Hub-installed skill registry |
| `~/.hermes/skills/.archive/` | Archived skill directories |
| `~/.hermes/skills/.curator_suppressed` | Suppressed bundled skill names |
| `~/.hermes/logs/curator/{timestamp}/run.json` | Machine-readable run report |
| `~/.hermes/logs/curator/{timestamp}/REPORT.md` | Human-readable run report |
| `~/.hermes/logs/curator/{timestamp}/cron_rewrites.json` | Cron job rewrite record |
