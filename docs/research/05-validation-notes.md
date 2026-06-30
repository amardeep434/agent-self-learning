# Validation Notes: 05-skill-lifecycle-and-curator.md
**Validated against:** /tmp/hermes-agent-research/
**Date:** 2026-06-30
**Validator:** Subagent

## Findings

### Finding 1: Source File Line Counts
- **Claim:** `agent/curator.py` (1977 lines), `tools/skill_usage.py` (948 lines), `tools/skill_manager_tool.py` (1440 lines)
- **Actual:** `agent/curator.py` (1976 lines), `tools/skill_usage.py` (947 lines), `tools/skill_manager_tool.py` (1439 lines)
- **Verdict:** PARTIALLY CORRECT
- **Source:** `wc -l` on all three files
- **Notes:** Each file is off by exactly 1 line. The document claims 1977/948/1440 but the actual counts are 1976/947/1439. This is a consistent off-by-one, possibly due to counting with/without a trailing newline. The files are the correct ones and the magnitudes are accurate.

### Finding 2: Lifecycle State Constants (Section 2.1)
- **Claim:** Module-level constants `STATE_ACTIVE = "active"`, `STATE_STALE = "stale"`, `STATE_ARCHIVED = "archived"`, `_VALID_STATES = {STATE_ACTIVE, STATE_STALE, STATE_ARCHIVED}`
- **Actual:** Exact match at lines 53-56 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:53-56

### Finding 3: PROTECTED_BUILTIN_SKILLS (Section 1.3)
- **Claim:** `PROTECTED_BUILTIN_SKILLS: Set[str] = {"plan",}` and `is_protected_builtin()` function
- **Actual:** Exact match at lines 66-68 and 71-78 of `tools/skill_usage.py`. The set contains only `"plan"`. The `is_protected_builtin` function body is verbatim.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:66-78

### Finding 4: _read_bundled_manifest_names() (Section 1.1)
- **Claim:** Function reads `~/.hermes/skills/.bundled_manifest` with `name:hash` per line format
- **Actual:** Exact verbatim match at lines 181-201 of `tools/skill_usage.py`. Every line of the code snippet in the document matches the source.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:181-201

### Finding 5: _read_hub_installed_names() (Section 1.1)
- **Claim:** Function reads `~/.hermes/skills/.hub/lock.json`, parses `installed` dict keys
- **Actual:** The document's code snippet is TRUNCATED with a comment `# ... also reads install_path entries and parses SKILL.md name: fields`. The actual source at lines 204-239 has additional logic (lines 218-236) that iterates `installed.values()`, reads `install_path` entries, resolves relative paths, reads SKILL.md `name:` fields, and adds those names. The truncated portion is accurately described by the comment. The lines shown verbatim do match.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:204-239

### Finding 6: _is_curator_managed_record() (Section 1.1)
- **Claim:** Checks `record.get("created_by") == "agent" or record.get("agent_created") is True`
- **Actual:** Exact verbatim match at lines 473-477 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:473-477

### Finding 7: Provenance Query Functions (Section 1.2)
- **Claim:** `is_agent_created()`, `is_hub_installed()`, `is_bundled()`, `provenance()` functions
- **Actual:** All four functions match verbatim at lines 419-906 of `tools/skill_usage.py`. `is_agent_created` at 419-427, `is_hub_installed` at 430-432, `is_bundled` at 435-437, `provenance` at 896-906.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:419-437, 896-906

### Finding 8: is_curation_eligible() (Section 1.4)
- **Claim:** Function with external path, protected builtin, hub-installed, bundled, local dir, and external skill dir checks
- **Actual:** Exact verbatim match at lines 447-470 of `tools/skill_usage.py`. The docstring in source is slightly longer (mentions "they have an external upstream owner" and more detail about protected builtins), but the code body is identical.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:447-470

### Finding 9: _empty_record() Schema (Section 2.1)
- **Claim:** Returns dict with keys: created_by (None), use_count (0), view_count (0), last_used_at (None), last_viewed_at (None), patch_count (0), last_patched_at (None), created_at (_now_iso()), state (STATE_ACTIVE), pinned (False), archived_at (None)
- **Actual:** Exact verbatim match at lines 484-497 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:484-497

### Finding 10: latest_activity_at() (Section 2.2)
- **Claim:** Iterates `last_used_at`, `last_viewed_at`, `last_patched_at` keys, excludes `created_at`
- **Actual:** Exact verbatim match at lines 146-163 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:146-163

### Finding 11: activity_count() (Section 2.2)
- **Claim:** Sums `use_count`, `view_count`, `patch_count`
- **Actual:** Exact verbatim match at lines 166-174 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:166-174

### Finding 12: Counter Bump Helpers (Section 2.3)
- **Claim:** `bump_view()`, `bump_use()`, `bump_patch()` functions
- **Actual:** All three match verbatim. `bump_view` at lines 611-620, `bump_use` at 623-632, `bump_patch` at 635-643. The doc's snippets omit the extended docstrings (e.g. "Tracks every skill regardless of provenance -- built-ins and hub skills included.") but the function bodies are identical.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:611-643

### Finding 13: _mutate() Pattern (Section 2.4)
- **Claim:** Load-apply-save with file locking, `require_curation_eligible` gate
- **Actual:** Exact verbatim match at lines 579-604 of `tools/skill_usage.py`. The docstring uses an em dash (—) in source vs double dash (--) in doc, but the code body is identical.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:579-604

### Finding 14: _mutate() Callers Gate Usage (Section 2.4)
- **Claim:** `set_state()` passes `require_curation_eligible=True`, `set_pinned()` passes it, `mark_agent_created()` passes it, bump helpers do NOT
- **Actual:** Confirmed: `set_state` at line 669, `set_pinned` at line 675, `mark_agent_created` at line 654 all pass `require_curation_eligible=True`. `bump_view` (620), `bump_use` (632), `bump_patch` (643) do NOT pass it (defaulting to False).
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:620-675

### Finding 15: File Locking (Section 2.5)
- **Claim:** `_usage_file_lock()` uses `fcntl.flock()` on Unix and `msvcrt.locking()` on Windows, lock file at `.json.lock`
- **Actual:** Exact match at lines 89-122 of `tools/skill_usage.py`. The doc's snippet is abbreviated but accurately describes the pattern.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:89-122

### Finding 16: save_usage() Atomic I/O (Section 2.6)
- **Claim:** Uses `tempfile.mkstemp()` + `os.replace()` for crash safety, with prefix `.usage_` and suffix `.tmp`
- **Actual:** Exact verbatim match at lines 520-541 of `tools/skill_usage.py`. Every line matches including the `os.fsync(f.fileno())` call and error handling.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:520-541

### Finding 17: Curator Configuration Constants (Section 3.1)
- **Claim:** `DEFAULT_INTERVAL_HOURS = 24 * 7`, `DEFAULT_MIN_IDLE_HOURS = 2`, `DEFAULT_STALE_AFTER_DAYS = 30`, `DEFAULT_ARCHIVE_AFTER_DAYS = 90`, `DEFAULT_CONSOLIDATE = False`
- **Actual:** Exact verbatim match at lines 56-64 of `agent/curator.py`
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:56-64

### Finding 18: Config Getter Functions (Section 3.1)
- **Claim:** `get_interval_hours()`, `get_min_idle_hours()`, `get_stale_after_days()`, `get_archive_after_days()`, `get_consolidate()`, `get_prune_builtins()`
- **Actual:** All six functions exist. `get_interval_hours` at 146-151, `get_min_idle_hours` at 154-159, `get_stale_after_days` at 162-167, `get_archive_after_days` at 170-176, `get_prune_builtins` at 178-188, `get_consolidate` at 190-204. The doc claims `get_prune_builtins()` defaults to True, and the source confirms `bool(cfg.get("prune_builtins", True))` at line 187.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:146-204

### Finding 19: _default_state() Schema (Section 3.4)
- **Claim:** Keys: last_run_at, last_run_duration_seconds, last_run_summary, last_run_summary_shown_at, last_report_path, paused, run_count
- **Actual:** Exact verbatim match at lines 75-84 of `agent/curator.py`
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:75-84

### Finding 20: should_run_now() First-Run Behavior (Section 3.3)
- **Claim:** When no `last_run_at` exists, curator does NOT run immediately. Seeds `last_run_at` to "now" and defers first real pass by one full interval.
- **Actual:** Confirmed at lines 219-269 of `agent/curator.py`. When `last is None` (line 247), the function seeds `state["last_run_at"] = now.isoformat()` (line 254) and returns `False` (line 262). The docstring at lines 227-234 explicitly states this behavior.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:219-269

### Finding 21: apply_automatic_transitions() (Section 3.2)
- **Claim:** Walks every curator-managed skill, applies state changes based on latest activity timestamp. Pinned skills skipped, cron-referenced skills skipped, never-used skills get grace floor, first-sight seeding.
- **Actual:** Exact verbatim match at lines 291-369 of `agent/curator.py`. The function signature, the counts dict keys ("marked_stale", "archived", "reactivated", "checked", "seeded"), the logic flow (pinned check, cron_referenced check, _persisted check, never_used grace floor, archive/stale/reactivate transitions) all match the document's code snippet character for character.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:291-369

### Finding 22: CURATOR_REVIEW_PROMPT Line Numbers (Section 3.5)
- **Claim:** Defined at lines 403-554 of `curator.py`
- **Actual:** The prompt starts at line 403 and ends at line 554 (the closing parenthesis). This is exact.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:403-554

### Finding 23: CURATOR_REVIEW_PROMPT Content (Section 3.5)
- **Claim:** Full verbatim prompt text
- **Actual:** Character-for-character match between the document's quoted prompt and lines 403-554 of `agent/curator.py`. All hard rules (1-5), the "How to work" section, the three consolidation methods (a/b/c), the package integrity section, the toolset list, and the structured YAML summary format all match exactly.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:403-554

### Finding 24: CURATOR_DRY_RUN_BANNER (Section 3.6)
- **Claim:** Full verbatim dry-run banner text
- **Actual:** Character-for-character match at lines 376-400 of `agent/curator.py`
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:376-400

### Finding 25: LLM Review Agent Configuration (Section 3.7)
- **Claim:** `AIAgent(model=..., max_iterations=9999, quiet_mode=True, platform="curator", skip_context_files=True, skip_memory=True)` with `_memory_nudge_interval = 0`, `_skill_nudge_interval = 0`, `_memory_write_origin = "background_review"`
- **Actual:** Exact match at lines 1878-1905 of `agent/curator.py`. All kwargs and post-construction assignments match verbatim.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1878-1905

### Finding 26: _render_candidate_list() (Section 3.7)
- **Claim:** Renders per-skill metadata with `name`, `state`, `pinned`, `cron`, `activity`, `use`, `view`, `patches`, `last_activity` fields
- **Actual:** Exact verbatim match at lines 1458-1477 of `agent/curator.py`. The format string and all field names match.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1458-1477

### Finding 27: Classification Pipeline (Section 3.8)
- **Claim:** Three layers: (1) `absorbed_into` declarations via `_extract_absorbed_into_declarations()`, (2) model's YAML block via `_parse_structured_summary()`, (3) tool-call heuristic via `_classify_removed_skills()`. Reconciled by `_reconcile_classification()`.
- **Actual:** All four functions exist: `_extract_absorbed_into_declarations` at 804-855, `_parse_structured_summary` at 723-801, `_classify_removed_skills` at 601-720, `_reconcile_classification` at 858-986. The reconciliation logic at lines 899-985 confirms the priority order: declared `absorbed_into` at delete time is authoritative (checked first), then model's YAML block (if target exists), then heuristic, then fallback to pruned.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:601-986

### Finding 28: Cron Job Rewriting (Section 3.9)
- **Claim:** `from cron.jobs import rewrite_skill_refs as _rewrite_cron_refs` called when consolidated_map or pruned_names exist
- **Actual:** Exact match at lines 1194-1199 of `agent/curator.py`, inside `_write_run_report()`. The import and call match verbatim.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1194-1199

### Finding 29: Per-Run Report Artifacts (Section 3.10)
- **Claim:** Reports written under `~/.hermes/logs/curator/{YYYYMMDD-HHMMSS}/` containing `run.json`, `REPORT.md`, and optionally `cron_rewrites.json`
- **Actual:** Confirmed at lines 1079-1268 of `agent/curator.py`. The `_write_run_report` function creates the stamp directory, writes `run.json` (line 1243), `REPORT.md` (line 1253), and `cron_rewrites.json` only when `jobs_updated > 0` (lines 1259-1266). The `_reports_root()` at line 575 confirms the path.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1079-1268

### Finding 30: Pre-Run Backup (Section 3.11)
- **Claim:** `from agent import curator_backup; snap = curator_backup.snapshot_skills(reason="pre-curator-run")`
- **Actual:** Exact match at lines 1536-1537 of `agent/curator.py` inside `run_curator_review()`. The `curator_backup` module exists at `/tmp/hermes-agent-research/agent/curator_backup.py`.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1536-1537

### Finding 31: Skill Manager Constants (Section 4.1)
- **Claim:** `MAX_SKILL_CONTENT_CHARS = 100_000`, `MAX_SKILL_FILE_BYTES = 1_048_576`, `MAX_NAME_LENGTH = 64`, `MAX_DESCRIPTION_LENGTH = 1024`, `VALID_NAME_RE = re.compile(r'^[a-z0-9][a-z0-9._-]*$')`, `ALLOWED_SUBDIRS = {"references", "templates", "scripts", "assets"}`
- **Actual:** Exact verbatim match at lines 382-389 of `tools/skill_manager_tool.py`. `MAX_NAME_LENGTH` at line 111, `MAX_DESCRIPTION_LENGTH` at line 112. All values match exactly.
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:111-112, 382-389

### Finding 32: _create_skill() Validation Chain (Section 4.2)
- **Claim:** Validation order: name, category, frontmatter, content size, collision check, directory creation, security scan with rollback
- **Actual:** Confirmed at lines 703-768 of `tools/skill_manager_tool.py`. The exact order is: `_validate_name(name)` (706), `_validate_category(category)` (710), `_validate_frontmatter(content)` (714), `_validate_content_size(content)` (718), `_find_skill(name)` collision check (722), `skill_dir.mkdir()` (732), `SKILL.md` write (736-737), `_security_scan_skill(skill_dir)` with `shutil.rmtree` rollback (740-743).
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:703-768

### Finding 33: _patch_skill() Fuzzy Matching (Section 4.4)
- **Claim:** Uses `from tools.fuzzy_match import fuzzy_find_and_replace` with `(content, old_string, new_string, replace_all)` signature
- **Actual:** Exact match at lines 865-869 of `tools/skill_manager_tool.py`. The import and call including return values `(new_content, match_count, _strategy, match_error)` match verbatim.
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:865-869

### Finding 34: _delete_skill() Guard Chain (Section 4.5)
- **Claim:** Guards in order: `_background_review_write_guard()`, `_curator_consolidation_delete_guard()`, `_pinned_guard()`, `absorbed_into` validation, `_validate_delete_target()`
- **Actual:** Confirmed at lines 921-981 of `tools/skill_manager_tool.py`. The order is: `_find_skill` (933), `_background_review_write_guard` (936-938), `_curator_consolidation_delete_guard` (943-945), `_pinned_guard` (947-949), `absorbed_into` validation (952-973), `_validate_delete_target` (979-981).
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:921-981

### Finding 35: _delete_skill() Background Review Routing (Section 4.5)
- **Claim:** During curator consolidation pass (`is_background_review()` is True), deletion is routed through `archive_skill()` for recoverability. Foreground user-directed deletes use `shutil.rmtree()`.
- **Actual:** Exact match at lines 990-1009 of `tools/skill_manager_tool.py`. When `curator_pass` is True (line 996), it calls `skill_usage.archive_skill(name)` (line 999). Otherwise, `shutil.rmtree(skill_dir)` is called (line 1009).
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:990-1009

### Finding 36: _background_review_write_guard() (Section 4.8)
- **Claim:** Full function with pinned check, external skill dirs check, protected builtin/hub-installed/bundled checks
- **Actual:** The document's code snippet matches lines 238-321 of `tools/skill_manager_tool.py` with minor differences. The actual source has slightly different error messages (e.g., line 271 includes "Ask the user to run `hermes curator unpin {name}` if they want it changed." while the doc omits this extra sentence). The document also omits some `logger.debug` calls in the except blocks. The structure and logic are identical.
- **Verdict:** PARTIALLY CORRECT
- **Source:** tools/skill_manager_tool.py:238-321
- **Notes:** Code logic matches perfectly. Error message strings have minor additions in the source not shown in the document snippet. The document also slightly simplifies some except blocks.

### Finding 37: _curator_consolidation_delete_guard() (Section 4.9)
- **Claim:** Fail-closed guard preventing LLM consolidation pass from pruning without declaring where content went. References issue #29912.
- **Actual:** The function at lines 332-379 of `tools/skill_manager_tool.py` matches the document's snippet almost exactly. One difference: the source uses `.format(name=name)` at line 377 on the error string (since it uses `'{name}'` literal braces), while the doc's snippet shows the f-string directly. The `_fail_closed` key is present in both. The #29912 reference is confirmed in the docstring at line 345.
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:332-379

### Finding 38: Telemetry Integration in skill_manage() (Section 4.10)
- **Claim:** After success: `mark_agent_created` on background review create, `bump_patch` on patch/edit/write_file/remove_file, `forget` on non-archived delete
- **Actual:** Exact match at lines 1269-1296 of `tools/skill_manager_tool.py`. The conditional structure, the import, and the `if not result.get("_archived")` check all match verbatim.
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:1269-1296

### Finding 39: _validate_delete_target() Defense-in-Depth (Section 4.11)
- **Claim:** Port of Kilo Code #11227/#11240. Prevents rmtree on: paths outside skills root, skills root itself, symlink/junction directories.
- **Actual:** Exact match at lines 150-208 of `tools/skill_manager_tool.py`. The docstring at lines 155-156 explicitly references "Kilo Code's HTTP endpoint could (their issue #11227)". The three checks (symlink/junction at 172, root equality at 192, relative_to at 199) match the document's description.
- **Verdict:** VERIFIED
- **Source:** tools/skill_manager_tool.py:150-208

### Finding 40: archive_skill() (Section 5.2)
- **Claim:** Protected builtins refused, hub-installed refused, bundled refused unless prune_builtins enabled. Category nesting flattened, timestamp suffix on collision, cross-device fallback to shutil.move, state set to STATE_ARCHIVED, bundled archival adds suppressed name.
- **Actual:** Exact match at lines 696-754 of `tools/skill_usage.py`. Protected builtin check at 709-713, hub-installed at 714-715, bundled (with prune_builtins gate) at 716-719. Flattening at 735, timestamp suffix at 737, cross-device fallback at 744-747, `add_suppressed_name` for bundled at 750-751, `set_state` at 753.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:696-754

### Finding 41: Suppression System (Section 5.3)
- **Claim:** Suppressed file at `~/.hermes/skills/.curator_suppressed`, one name per line, `read_suppressed_names()` skips `#` comments, atomic write pattern
- **Actual:** Exact match at lines 263-317 of `tools/skill_usage.py`. `_suppressed_file()` at 263-264, `read_suppressed_names()` at 267-285 (skips `#` at line 281), `_write_suppressed_names()` at 288-307 (uses tempfile + os.replace atomic pattern), `add_suppressed_name()` at 310-317, `remove_suppressed_name()` at 320-327.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:263-327

### Finding 42: restore_skill() (Section 5.4)
- **Claim:** Refuses restore over hub-installed, refuses over bundled unless prune_builtins enabled. Looks for exact match then timestamped duplicates (14-digit suffix). Restores to flat top-level. Clears suppression. Sets STATE_ACTIVE.
- **Actual:** Exact match at lines 757-829 of `tools/skill_usage.py`. Hub guard at 769-773, bundled guard at 776-780. Exact match search at 788, timestamped fallback at 797-807 (14-digit suffix check at 803-804). `remove_suppressed_name` at 826, `set_state(skill_name, STATE_ACTIVE)` at 828.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:757-829

### Finding 43: list_archived_skill_names() (Section 5.5)
- **Claim:** Enumerates `~/.hermes/skills/.archive/`, returns sorted set of directory names
- **Actual:** Exact verbatim match at lines 385-395 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:385-395

### Finding 44: mark_agent_created() (Section 6.1)
- **Claim:** Sets `created_by = "agent"`, passes `require_curation_eligible=True`
- **Actual:** Exact verbatim match at lines 646-654 of `tools/skill_usage.py`
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:646-654

### Finding 45: list_agent_created_skill_names() (Section 6.4)
- **Claim:** Walks `base.rglob("SKILL.md")`, skips excluded/external/hub/protected builtin, includes bundled when prune_builtins enabled, requires curator managed record for others
- **Actual:** Exact verbatim match at lines 330-382 of `tools/skill_usage.py`. The filter chain matches the document's code snippet character for character.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:330-382

### Finding 46: agent_created_report() (Section 6.4)
- **Claim:** Enriches names with usage data, carries `_persisted` field, backfills missing keys
- **Actual:** Exact verbatim match at lines 870-893 of `tools/skill_usage.py`. The `_persisted` logic, the key backfill loop, and the `last_activity_at`/`activity_count` enrichment all match.
- **Verdict:** VERIFIED
- **Source:** tools/skill_usage.py:870-893

### Finding 47: run_curator_review() Orchestration (Section 6.8)
- **Claim:** Steps: (1) pre-mutation snapshot, (2) apply deterministic transitions, (3) save state with last_run_at/run_count, (4) if consolidation enabled: snapshot, render candidates, build prompt, spawn LLM review, build rename summary, (5) write per-run report, (6) update state, (7) call on_summary. Synchronous=False runs in daemon thread.
- **Actual:** Confirmed at lines 1480-1741 of `agent/curator.py`. Pre-mutation snapshot at 1536-1544, `apply_automatic_transitions` at 1545, state save at 1561-1567, LLM pass in `_llm_pass()` nested function at 1569-1729, daemon thread at 1731-1735. All steps match the document's description.
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1480-1741

### Finding 48: maybe_run_curator() Entry Point (Section 6.9)
- **Claim:** Checks `should_run_now()`, enforces `min_idle_hours` gate via `idle_for_seconds` parameter, calls `run_curator_review()`
- **Actual:** Exact verbatim match at lines 1958-1976 of `agent/curator.py`
- **Verdict:** VERIFIED
- **Source:** agent/curator.py:1958-1976

### Finding 49: Summary Configuration Table (End of Document)
- **Claim:** Table lists all parameter defaults and config keys
- **Actual:** All values verified against source:
  - `DEFAULT_INTERVAL_HOURS = 168` (24*7): VERIFIED (curator.py:56)
  - `DEFAULT_MIN_IDLE_HOURS = 2`: VERIFIED (curator.py:57)
  - `DEFAULT_STALE_AFTER_DAYS = 30`: VERIFIED (curator.py:58)
  - `DEFAULT_ARCHIVE_AFTER_DAYS = 90`: VERIFIED (curator.py:59)
  - `DEFAULT_CONSOLIDATE = False`: VERIFIED (curator.py:64)
  - `prune_builtins` default `True`: VERIFIED (curator.py:187)
  - `MAX_SKILL_CONTENT_CHARS = 100,000`: VERIFIED (skill_manager_tool.py:382)
  - `MAX_SKILL_FILE_BYTES = 1,048,576`: VERIFIED (skill_manager_tool.py:383)
  - `MAX_NAME_LENGTH = 64`: VERIFIED (skill_manager_tool.py:111)
  - `MAX_DESCRIPTION_LENGTH = 1,024`: VERIFIED (skill_manager_tool.py:112)
  - `VALID_NAME_RE = ^[a-z0-9][a-z0-9._-]*$`: VERIFIED (skill_manager_tool.py:386)
  - `PROTECTED_BUILTIN_SKILLS = {"plan"}`: VERIFIED (skill_usage.py:66-68)
  - `ALLOWED_SUBDIRS = {"references", "templates", "scripts", "assets"}`: VERIFIED (skill_manager_tool.py:389)
- **Verdict:** VERIFIED
- **Source:** Multiple files as noted above

### Finding 50: File Locations Table (End of Document)
- **Claim:** Lists 10 file locations and their purposes
- **Actual:** All paths verified against code:
  - `.usage.json`: confirmed by `_usage_file()` at skill_usage.py:86
  - `.usage.json.lock`: confirmed by `_usage_file_lock()` at skill_usage.py:92
  - `.curator_state`: confirmed by `_state_file()` at curator.py:72
  - `.bundled_manifest`: confirmed by `_read_bundled_manifest_names()` at skill_usage.py:187
  - `.hub/lock.json`: confirmed by `_read_hub_installed_names()` at skill_usage.py:209
  - `.archive/`: confirmed by `_archive_dir()` at skill_usage.py:125-126
  - `.curator_suppressed`: confirmed by `_suppressed_file()` at skill_usage.py:263-264
  - `logs/curator/{timestamp}/run.json`: confirmed by `_write_run_report()` at curator.py:1243
  - `logs/curator/{timestamp}/REPORT.md`: confirmed by `_write_run_report()` at curator.py:1253
  - `logs/curator/{timestamp}/cron_rewrites.json`: confirmed by `_write_run_report()` at curator.py:1260-1266
- **Verdict:** VERIFIED
- **Source:** Multiple files as noted above

## Summary

| Verdict | Count |
|---------|-------|
| VERIFIED | 47 |
| PARTIALLY CORRECT | 3 |
| INACCURATE | 0 |
| FABRICATED | 0 |

**Overall Assessment:** This is an exceptionally accurate research document. Out of 50 findings, 47 are fully verified with verbatim or near-verbatim matches against the source code. The 3 partially correct findings are:

1. **Finding 1 (Line counts):** Off by exactly 1 line in each file (1977/948/1440 claimed vs 1976/947/1439 actual). Trivial and consistent -- likely a counting methodology difference.
2. **Finding 36 (_background_review_write_guard):** Code logic matches perfectly, but the document's snippet omits some error message addenda and logger.debug calls present in the actual source. The simplification does not misrepresent the logic.

No code snippets were fabricated. Every function signature, constant value, data structure, and logic flow description matches the source. The CURATOR_REVIEW_PROMPT (a 152-line string literal) matches character-for-character. The classification pipeline description, the guard chain ordering, and the lifecycle transition rules are all accurate.
