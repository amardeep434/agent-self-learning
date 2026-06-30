# Validation Notes: 02-self-learning-mechanisms.md
**Validated against:** /tmp/hermes-agent-study/
**Date:** 2026-06-30
**Validator:** Subagent

## Findings

### Section 1: Background Review (Post-Turn Daemon)

**1.1 File: `agent/background_review.py` line count**
- Doc claims: 865 lines
- Actual: 874 lines
- **Status:** ⚠️ INACCURATE (minor, 874 not 865)

**1.2 Turn counting code in `agent/turn_context.py`**
- Doc claims lines 275-301 with snippet:
  ```python
  agent._turns_since_memory += 1
  if agent._turns_since_memory >= agent._memory_nudge_interval:
      should_review_memory = True
      agent._turns_since_memory = 0
  ```
- Actual location: lines 295-301
- Actual code (lines 295-301):
  ```python
  if (agent._memory_nudge_interval > 0
          and "memory" in agent.valid_tool_names
          and agent._memory_store):
      agent._turns_since_memory += 1
      if agent._turns_since_memory >= agent._memory_nudge_interval:
          should_review_memory = True
          agent._turns_since_memory = 0
  ```
- **Status:** ⚠️ INACCURATE -- the doc's snippet omits the guard conditions (`_memory_nudge_interval > 0`, `"memory" in agent.valid_tool_names`, `agent._memory_store`). These are important because they mean memory review ONLY fires if the memory tool is registered and a memory store exists. Line numbers are also off (295-301 not 275-301).

**1.3 Skill iteration counting in `agent/turn_finalizer.py`**
- Doc claims lines 436-441 with snippet checking `_iters_since_skill >= _skill_nudge_interval`
- Actual location: lines 437-441
- Actual code matches almost exactly:
  ```python
  if (agent._skill_nudge_interval > 0
          and agent._iters_since_skill >= agent._skill_nudge_interval
          and "skill_manage" in agent.valid_tool_names):
      _should_review_skills = True
      agent._iters_since_skill = 0
  ```
- **Status:** ✅ VERIFIED (line numbers off by 1, code matches)

**1.4 Spawn decision in `agent/turn_finalizer.py`**
- Doc claims lines 453-461
- Actual location: lines 453-461
- Actual code:
  ```python
  if final_response and not interrupted and (_should_review_memory or _should_review_skills):
      try:
          agent._spawn_background_review(
              messages_snapshot=list(messages),
              review_memory=_should_review_memory,
              review_skills=_should_review_skills,
          )
      except Exception:
          pass  # Background review is best-effort
  ```
- **Status:** ✅ VERIFIED (code matches, try/except wrapper not shown in doc but semantically correct)

---

## Section 2: Skill Library & Lifecycle Management

### Section 2: Skill Library — Finding 1: File Location
- **Claim:** Doc says the primary file is `tools/skill_usage.py` (full module)
- **Actual:** File exists at `tools/skill_usage.py`, 947 lines
- **Verdict:** VERIFIED
- **Source:** `tools/skill_usage.py`

### Section 2: Skill Library — Finding 2: PROTECTED_BUILTIN_SKILLS
- **Claim:** `PROTECTED_BUILTIN_SKILLS = {"plan"}` -- never archived, backs `/plan` slash command
- **Actual:** Exact match at line 66-68: `PROTECTED_BUILTIN_SKILLS: Set[str] = {"plan",}`
- **Verdict:** VERIFIED
- **Source:** `tools/skill_usage.py:66-68`

### Section 2: Skill Library — Finding 3: Usage telemetry JSON schema
- **Claim:** Doc shows `.usage.json` per-skill record with fields: `use_count`, `view_count`, `patch_count`, `last_used_at`, `last_viewed_at`, `last_patched_at`, `last_activity_at`, `created_at`, `created_by`, `state`, `pinned`
- **Actual:** `_empty_record()` at line 484-496 contains: `created_by`, `use_count`, `view_count`, `last_used_at`, `last_viewed_at`, `patch_count`, `last_patched_at`, `created_at`, `state`, `pinned`, `archived_at`. Notably **`last_activity_at` is NOT a stored field** -- it is a computed value via `latest_activity_at()` function (line 146). Also **`archived_at`** is present in the real schema but not shown in the doc's JSON sample.
- **Verdict:** INACCURATE -- `last_activity_at` is presented as a stored field in the doc's JSON sample but is actually computed on-the-fly. `archived_at` is a real field omitted from the doc's sample.
- **Source:** `tools/skill_usage.py:146-163` (computed), `tools/skill_usage.py:484-497` (empty record)

### Section 2: Skill Library — Finding 4: Lifecycle states and defaults
- **Claim:** `stale` = unused > 30 days (default), `archived` = unused > 90 days (default)
- **Actual:** `DEFAULT_STALE_AFTER_DAYS` and `DEFAULT_ARCHIVE_AFTER_DAYS` confirmed at 30 and 90 respectively via `hermes_cli/config.py:2234-2237` and `tests/agent/test_curator.py:86-87`
- **Verdict:** VERIFIED
- **Source:** `hermes_cli/config.py:2234,2237`, `tests/agent/test_curator.py:86-87`

### Section 2: Skill Library — Finding 5: Counter bumping functions
- **Claim:** `skill_view` increments `view_count`, `skill_manage` (patch/edit) increments `patch_count`, skill loading/use increments `use_count`. All best-effort (failures log at DEBUG, never break tool calls).
- **Actual:** `bump_view()` at line 611, `bump_use()` at line 623, `bump_patch()` at line 635 — all use `_mutate()` which wraps in try/except and logs at DEBUG (line 604). Design notes at line 11 confirm "All counter bumps are best-effort: failures log at DEBUG and return silently."
- **Verdict:** VERIFIED
- **Source:** `tools/skill_usage.py:611-643`, `tools/skill_usage.py:11-12`

### Section 2: Skill Library — Finding 6: Atomic writes mechanism
- **Claim:** "Atomic writes via `tempfile + os.replace`. File locking with `fcntl` (Unix) or `msvcrt` (Windows)."
- **Actual:** `save_usage()` at line 520 uses `tempfile.mkstemp()` + `os.replace()`. File locking at line 89-114 uses `fcntl` (Unix) with `msvcrt` fallback (Windows), line 41-50.
- **Verdict:** VERIFIED
- **Source:** `tools/skill_usage.py:41-50,89-114,520-530`

### Section 2: Skill Library — Finding 7: Pinned skill behavior
- **Claim:** "User marks via `hermes curator pin <skill-name>`. Bypass all auto-transitions. CAN still be patched/improved by agent -- pin only blocks deletion/consolidation."
- **Actual:** `set_pinned()` at line 672 sets `pinned` boolean. The curator's `apply_automatic_transitions()` skips pinned skills (confirmed in curator.py). Patching is not blocked by pinned status -- `bump_patch()` does not check pinned state.
- **Verdict:** VERIFIED
- **Source:** `tools/skill_usage.py:672-675`

---

## Section 3: Memory System (Bounded File-Backed Stores)

### Section 3: Memory System — Finding 1: File reference
- **Claim:** Doc says file is `tools/memory_tool.py`
- **Actual:** File exists at `tools/memory_tool.py`, 1146 lines
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py`

### Section 3: Memory System — Finding 2: Character limits
- **Claim:** `MEMORY.md`: 2200 characters, `USER.md`: 1375 characters
- **Actual:** `__init__` at line 130: `memory_char_limit: int = 2200, user_char_limit: int = 1375`. Also confirmed by `agent/agent_init.py:1215-1216`: `memory_char_limit=mem_config.get("memory_char_limit", 2200)` and `user_char_limit=mem_config.get("user_char_limit", 1375)`.
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:130`, `agent/agent_init.py:1215-1216`

### Section 3: Memory System — Finding 3: Entry delimiter
- **Claim:** `\n§\n` (section sign). Entries can be multiline.
- **Actual:** Line 59: `ENTRY_DELIMITER = "\n§\n"`. Module docstring at line 16: "Entry delimiter: § (section sign). Entries can be multiline."
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:59`

### Section 3: Memory System — Finding 4: Single tool interface with action parameter
- **Claim:** One `memory` tool with `action` parameter: `add`, `replace`, `remove`
- **Actual:** Methods defined at lines 336 (`add`), 388 (`replace`), 457 (`remove`). Module docstring at line 20: "Single `memory` tool with action parameter: add, replace, remove".
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:336,388,457`

### Section 3: Memory System — Finding 5: Frozen snapshot pattern
- **Claim:** Memory content injected as frozen snapshot at session start. Mid-session writes update disk but do NOT change running system prompt. Preserves prefix cache.
- **Actual:** Module docstring at lines 11-14: "Both are injected into the system prompt as a frozen snapshot at session start. Mid-session writes update files on disk immediately (durable) but do NOT change the system prompt -- this preserves the prefix cache for the entire session." Class field `_system_prompt_snapshot` at line 136, set once in `load_from_disk()`.
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:11-14,136`

### Section 3: Memory System — Finding 6: Security scanning
- **Claim:** Before any write, content scanned for injection/exfiltration via `tools/threat_patterns.py` (strict scope).
- **Actual:** `_scan_memory_content()` at line 78 calls `first_threat_message(content, scope="strict")` from `tools/threat_patterns.py`. Called in `add()` at line 343, `replace()` at line 398. Comments at lines 62-73 explain the strict scope rationale.
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:75-80,343,398`

### Section 3: Memory System — Finding 7: Storage location
- **Claim:** `~/.hermes/memories/MEMORY.md` and `~/.hermes/memories/USER.md`
- **Actual:** `get_memory_dir()` at line 55-57 returns `get_hermes_home() / "memories"`. Files loaded at line 188-189 as `mem_dir / "MEMORY.md"` and `mem_dir / "USER.md"`.
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:55-57,188-189`

### Section 3: Memory System — Finding 8: File operations
- **Claim:** "Atomic writes via `atomic_replace()`. File locking with `fcntl`/`msvcrt`."
- **Actual:** `from utils import atomic_replace` at line 36. Used at line 779. File locking with `fcntl`/`msvcrt` fallback at lines 39-47, same pattern as skill_usage.py.
- **Verdict:** VERIFIED
- **Source:** `tools/memory_tool.py:36,39-47,779`

---

## Section 4: Curator (Periodic Skill Maintenance)

### Section 4: Curator — Finding 1: File and line count
- **Claim:** Doc says file is `agent/curator.py` (1977 lines)
- **Actual:** File exists at `agent/curator.py`, 1976 lines
- **Verdict:** INACCURATE (minor: 1976, not 1977)
- **Source:** `agent/curator.py`

### Section 4: Curator — Finding 2: Default configuration values
- **Claim:** `interval_hours: 168` (7 days), `min_idle_hours: 2`, `stale_after_days: 30`, `archive_after_days: 90`, `consolidate: false`, `prune_builtins: true`
- **Actual:** Lines 56-64: `DEFAULT_INTERVAL_HOURS = 24 * 7` (= 168), `DEFAULT_MIN_IDLE_HOURS = 2`, `DEFAULT_STALE_AFTER_DAYS = 30`, `DEFAULT_ARCHIVE_AFTER_DAYS = 90`, `DEFAULT_CONSOLIDATE = False`. `get_prune_builtins()` at line 187 defaults to `True`. `get_consolidate()` at line 203 defaults to `DEFAULT_CONSOLIDATE` (False).
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:56-64,187,203`

### Section 4: Curator — Finding 3: .curator_state schema
- **Claim:** Doc shows state with fields: `last_run_at`, `last_run_duration_seconds`, `last_run_summary`, `last_run_summary_shown_at`, `last_report_path`, `paused`, `run_count`
- **Actual:** `_default_state()` at lines 75-84 contains exactly: `last_run_at`, `last_run_duration_seconds`, `last_run_summary`, `last_run_summary_shown_at`, `last_report_path`, `paused`, `run_count`. All match.
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:75-84`

### Section 4: Curator — Finding 4: apply_automatic_transitions() logic
- **Claim:** Doc shows pseudocode with stale_cutoff, archive_cutoff, anchor fallback to `created_at`, and three transitions: active->stale, stale->archived, stale->active (reactivate).
- **Actual:** Function at line 291. Lines 307-308 define cutoffs. Line 339: `anchor = last_activity or _parse_iso(row.get("created_at")) or now`. Lines 357-367 implement: archive if `anchor <= archive_cutoff` (line 357), stale if `anchor <= stale_cutoff and current == STATE_ACTIVE` (line 361), reactivate if `anchor > stale_cutoff and current == STATE_STALE` (line 364). Logic matches.
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:291-369`

### Section 4: Curator — Finding 5: Protection rules
- **Claim:** Pinned skills never touched. Cron-referenced skills never auto-transitioned. Never-used skills (use_count == 0) get a grace floor. Protected builtins (`plan`) never archived. Hub-installed skills never pruned.
- **Actual:** Pinned check at line 317-318. Cron-referenced at lines 326-327. Never-used grace floor at lines 349-355. Protected builtins enforced by `PROTECTED_BUILTIN_SKILLS` in `skill_usage.py:66-68`. Hub-installed exclusion handled by `_is_curator_managed_record()` and `agent_created_report()` filtering.
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:317-355`, `tools/skill_usage.py:66-68`

### Section 4: Curator — Finding 6: Consolidation prompt length
- **Claim:** "The consolidation prompt is extremely detailed (150+ lines)"
- **Actual:** `CURATOR_REVIEW_PROMPT` spans 151 lines (lines 403-554). Starts with "You are running as Hermes' background skill CURATOR."
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:403-554`

### Section 4: Curator — Finding 7: Report generation
- **Claim:** Writes `run.json` + `REPORT.md` per curator execution, stored in `~/.hermes/logs/curator/{YYYYMMDD-HHMMSS}/`. Classifies removed skills as consolidated vs pruned via `_classify_removed_skills()`.
- **Actual:** `_write_run_report()` at line 1079 writes to `logs/curator/{YYYYMMDD-HHMMSS}/` (line 1090, 1102-1103). `_classify_removed_skills()` at line 601. Report directory at `get_hermes_home() / "logs" / "curator"` (line 575).
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:575,601,1079-1103`

### Section 4: Curator — Finding 8: First-run behavior
- **Claim:** "Seeds `last_run_at` to now and defers by one full interval"
- **Actual:** `should_run_now()` at line 219: when `last` is None (first run), seeds `state["last_run_at"] = now.isoformat()` at line 254 and returns `False` to defer. Comment at line 227-234 explicitly describes this behavior.
- **Verdict:** VERIFIED
- **Source:** `agent/curator.py:219-262`

### Section 4: Curator — Finding 9: "fewer than 10 archives" instruction
- **Claim:** Doc quotes: "If you end the pass with fewer than 10 archives, you stopped too early"
- **Actual:** Line 530-532: "If you end the pass with fewer than 10 archives, you stopped too early — go back and look at the clusters you left alone."
- **Verdict:** VERIFIED (verbatim match)
- **Source:** `agent/curator.py:530-532`

---

## Section 5: Training Data Pipeline (Trajectory Generation)

### Section 5: Training Pipeline — Finding 1: File references
- **Claim:** Doc says files are `batch_runner.py` and `trajectory_compressor.py`
- **Actual:** Both files exist at the repo root. `batch_runner.py` is 1321 lines. `trajectory_compressor.py` is 1574 lines.
- **Verdict:** VERIFIED
- **Source:** `batch_runner.py`, `trajectory_compressor.py`

### Section 5: Training Pipeline — Finding 2: Parallel processing mechanism
- **Claim:** "Processes prompts in parallel using `multiprocessing.Pool`"
- **Actual:** Line 41: `from multiprocessing import Pool, Lock`. Line 918: `with Pool(processes=self.num_workers) as pool:`. Line 959: `pool.imap_unordered(_process_batch_worker, tasks)`.
- **Verdict:** VERIFIED
- **Source:** `batch_runner.py:41,918,959`

### Section 5: Training Pipeline — Finding 3: CLI arguments
- **Claim:** Doc shows `--dataset_file`, `--batch_size`, `--run_name`, `--resume`, `--distribution` args
- **Actual:** Module docstring at lines 14-20 shows exact same arg names: `--dataset_file=data.jsonl --batch_size=10 --run_name=my_run`, `--resume`, `--distribution=image_gen`. Class `__init__` at lines 534-537 confirms: `dataset_file`, `batch_size`, `run_name`, `distribution`.
- **Verdict:** VERIFIED
- **Source:** `batch_runner.py:14-20,534-537`

### Section 5: Training Pipeline — Finding 4: Trajectory output format
- **Claim:** Doc shows `from/value` pair format with `conversations`, `tool_stats`, `metadata` fields
- **Actual:** Lines 473-483 show actual trajectory entry includes: `prompt_index`, `conversations`, `metadata`, `completed`, `partial`, `api_calls`, `toolsets_used`, `tool_stats`, `tool_error_counts`. The doc's sample is simplified -- it omits `prompt_index`, `completed`, `partial`, `api_calls`, `toolsets_used`, `tool_error_counts`.
- **Verdict:** INACCURATE -- doc's schema is correct at a high level but omits 5 additional fields (`prompt_index`, `completed`, `partial`, `api_calls`, `toolsets_used`, `tool_error_counts`) present in the real output.
- **Source:** `batch_runner.py:473-483`

### Section 5: Training Pipeline — Finding 5: Compression strategy steps
- **Claim:** Doc lists 6 compression steps: (1) protect first turns, (2) protect last N turns, (3) compress MIDDLE turns, (4) compress only as needed, (5) replace with summary message, (6) keep remaining tool calls intact
- **Actual:** Module docstring at lines 8-14 lists the exact same 6 steps verbatim: "1. Protect first turns ... 2. Protect last N turns ... 3. Compress MIDDLE turns only, starting from 2nd tool response ... 4. Compress only as much as needed to fit under target ... 5. Replace compressed region with a single human summary message ... 6. Keep remaining tool calls intact"
- **Verdict:** VERIFIED
- **Source:** `trajectory_compressor.py:8-14`

### Section 5: Training Pipeline — Finding 6: trajectory_compressor CLI
- **Claim:** Doc shows `--target_max_tokens=16000` and `--sample_percent=15` flags
- **Actual:** Module docstring at lines 17-30 shows identical CLI examples. `target_max_tokens` field at line 90 in `CompressionConfig` (default: 15250, not 16000). `sample_percent` at line 24 in docstring.
- **Verdict:** VERIFIED (CLI flags exist; doc's example value 16000 is an override, not the default which is 15250)
- **Source:** `trajectory_compressor.py:17-30,90`

---

## Section 6: Learning Graph (Visualization)

### Section 6: Learning Graph — Finding 1: File and line count
- **Claim:** Doc says `agent/learning_graph.py` (321 lines)
- **Actual:** File exists at `agent/learning_graph.py`, 320 lines (not 321, but could be trailing newline difference)
- **Verdict:** INACCURATE (minor: 320, not 321)
- **Source:** `agent/learning_graph.py`

### Section 6: Learning Graph — Finding 2: build_learning_graph() function
- **Claim:** Main entry point is `build_learning_graph()`
- **Actual:** Defined at line 246. Docstring: "Full payload for the desktop learning panel."
- **Verdict:** VERIFIED
- **Source:** `agent/learning_graph.py:246`

### Section 6: Learning Graph — Finding 3: Learned skills filter
- **Claim:** "Only includes skills that are NOT base-installed AND show real learning signal (agent-created or `use_count > 0`)"
- **Actual:** Lines 255-258: `learned_skills = {name: node for name, node in all_skills.items() if node.source != "base" and (node.created_by == "agent" or node.use_count > 0)}`
- **Verdict:** VERIFIED (exact match)
- **Source:** `agent/learning_graph.py:255-258`

### Section 6: Learning Graph — Finding 4: Skill-to-skill edge derivation
- **Claim:** "From `related_skills` frontmatter declarations (undirected, both endpoints must exist)"
- **Actual:** `build_edges()` at lines 148-160. Line 149: "Undirected related_skills edges where BOTH endpoints exist (deduped)." Uses `sorted((node.name, target))` for dedup (line 155).
- **Verdict:** VERIFIED
- **Source:** `agent/learning_graph.py:148-160`

### Section 6: Learning Graph — Finding 5: Memory card splitting
- **Claim:** "Splits `MEMORY.md` and `USER.md` on `§` delimiters, each chunk becomes a graph node"
- **Actual:** `_memory_cards()` at lines 185-212. Line 200: `text.split("\n§\n")`. Each chunk becomes a card dict. Cards are then turned into graph nodes at lines 285-298.
- **Verdict:** VERIFIED
- **Source:** `agent/learning_graph.py:185-212,285-298`

### Section 6: Learning Graph — Finding 6: Memory-to-skill edge scoring
- **Claim:** "skill name in text = +6 score, token intersection. Keep top 4 scoring skills per memory card."
- **Actual:** `_memory_skill_edges()` at lines 219-237. Line 229-231: `if skill_name_lower in text: score += 6` then `score += len(tokens & text_tokens)`. Line 235: `scored[:4]` -- top 4 kept.
- **Verdict:** VERIFIED (exact match)
- **Source:** `agent/learning_graph.py:219-237`

### Section 6: Learning Graph — Finding 7: Memory node ID format
- **Claim:** "id (format: `memory:{source}:{idx}`)"
- **Actual:** Line 223: `mem_id = f"memory:{card['source']}:{idx}"`. Line 288: `"id": f"memory:{card['source']}:{i}"`.
- **Verdict:** VERIFIED
- **Source:** `agent/learning_graph.py:223,288`

### Section 6: Learning Graph — Finding 8: Statistics fields
- **Claim:** Doc lists: `nodes`, `related_edges`, `edges_per_node`, `linked_nodes`, `isolated_pct`, `categories`, `agent_created`, `used`, `memory_nodes`, `memory_skill_edges`, `learned_skills`, `top_categories`
- **Actual:** `density_stats()` at lines 163-182 computes: `nodes`, `related_edges`, `edges_per_node`, `linked_nodes`, `isolated_pct`, `categories`, `agent_created`, `used`, `top_categories`. Additional stats at lines 311-313 add: `memory_nodes`, `memory_skill_edges`, `learned_skills`. All match.
- **Verdict:** VERIFIED
- **Source:** `agent/learning_graph.py:163-182,309-314`

---

## Section 7: External Memory Providers

### Section 7: External Memory — Finding 1: File and line count
- **Claim:** Doc says `agent/memory_manager.py` (1080 lines)
- **Actual:** File is 1081 lines
- **Verdict:** INACCURATE (minor: 1081 not 1080)
- **Source:** `agent/memory_manager.py`

### Section 7: External Memory — Finding 2: Only ONE external provider
- **Claim:** "Only ONE external plugin provider is allowed at a time (rejects second with warning)"
- **Actual:** Module docstring lines 6-8: "Only ONE external plugin provider is allowed at a time — attempting to register a second external provider is rejected with a warning." Class field at line 363: `self._has_external: bool = False`.
- **Verdict:** VERIFIED
- **Source:** `agent/memory_manager.py:6-8,363`

### Section 7: External Memory — Finding 3: Shutdown timeout
- **Claim:** "Shutdown timeout: 5 seconds for in-flight work to drain"
- **Actual:** Line 46: `_SYNC_DRAIN_TIMEOUT_S = 5.0`. Comment at line 42-45 explains the drain logic.
- **Verdict:** VERIFIED
- **Source:** `agent/memory_manager.py:46`

### Section 7: External Memory — Finding 4: Available providers
- **Claim:** Doc lists 4 providers: Honcho, Mem0, Hindsight, SuperMemory
- **Actual:** `plugins/memory/` contains **8** provider directories: `byterover`, `hindsight`, `holographic`, `honcho`, `mem0`, `openviking`, `retaindb`, `supermemory`. The doc omits 4 providers: byterover, holographic, openviking, retaindb.
- **Verdict:** INACCURATE -- doc lists only 4 of 8 available providers, omitting byterover, holographic, openviking, and retaindb.
- **Source:** `plugins/memory/` directory listing

### Section 7: External Memory — Finding 5: Honcho description
- **Claim:** "Dialectic user modeling with 'peer cards', semantic search, reasoning layer"
- **Actual:** `plugins/memory/honcho/__init__.py` line 3-5: "Provides cross-session user modeling with dialectic Q&A, semantic search, peer cards, and persistent conclusions via the Honcho SDK." Line 39-40 confirms `peer_card` tool: "Retrieve or update a peer card from Honcho."
- **Verdict:** VERIFIED
- **Source:** `plugins/memory/honcho/__init__.py:3-5,39-40`

### Section 7: External Memory — Finding 6: Provider interface methods
- **Claim:** Doc lists interface methods: `get_tool_schemas()`, `build_system_prompt()`, `prefetch_all(query)`, `sync_all(user_msg, assistant_response)`, `on_session_end()`
- **Actual:** The `MemoryProvider` ABC in `agent/memory_provider.py` defines: `system_prompt_block()` (NOT `build_system_prompt`), `prefetch()` (NOT `prefetch_all`), `sync_turn()` (NOT `sync_all`), `get_tool_schemas()`, `handle_tool_call()`, `shutdown()`, `on_session_end()`. The names in the doc match `MemoryManager` wrapper methods, not the `MemoryProvider` abstract interface.
- **Verdict:** INACCURATE -- doc conflates the `MemoryManager` orchestrator API (`build_system_prompt`, `prefetch_all`, `sync_all`) with the `MemoryProvider` abstract interface (`system_prompt_block`, `prefetch`, `sync_turn`). The interface description at line 15-22 of `memory_provider.py` lists the correct method names.
- **Source:** `agent/memory_provider.py:85-166` (abstract methods), `agent/memory_manager.py:456,495,558` (manager methods)

### Section 7: External Memory — Finding 7: Background review isolation
- **Claim:** "Fork sets `skip_memory=True` to prevent leaking review harness prompt into user's external memory namespace"
- **Actual:** `background_review.py` line 654: `skip_memory=True`. Comment at lines 623-633 explains: "skip_memory=True keeps the review fork from touching external memory plugins (honcho, mem0, supermemory, etc.)... the fork's __init__ rebuilds its own _memory_manager... and run_conversation() then leaks the harness prompt into the user's real memory namespace."
- **Verdict:** VERIFIED
- **Source:** `agent/background_review.py:623-634,654`

### Section 7: External Memory — Finding 8: Integration points in run_agent.py
- **Claim:** Doc shows code: `prompt_parts.append(self._memory_manager.build_system_prompt())`, `context = self._memory_manager.prefetch_all(user_message)`, `self._memory_manager.sync_all(user_msg, assistant_response)`, `self._memory_manager.queue_prefetch_all(user_msg)`
- **Actual:** `memory_manager.py` module docstring at lines 16-23 shows the exact same pattern: `prompt_parts.append(self._memory_manager.build_system_prompt())`, `context = self._memory_manager.prefetch_all(user_message)`, `self._memory_manager.sync_all(user_msg, assistant_response)`, `self._memory_manager.queue_prefetch_all(user_msg)`.
- **Verdict:** VERIFIED (the doc's code snippets come from the module's own docstring)
- **Source:** `agent/memory_manager.py:16-23`

---

## Section 8: /learn Command (User-Triggered Skill Distillation)

### Section 8: /learn — Finding 1: File and line count
- **Claim:** Doc says `agent/learn_prompt.py` (135 lines)
- **Actual:** File is 136 lines (likely a blank trailing line or off-by-one)
- **Verdict:** INACCURATE (minor: 136 not 135)
- **Source:** `agent/learn_prompt.py`

### Section 8: /learn — Finding 2: build_learn_prompt() function
- **Claim:** "`build_learn_prompt(user_request)` builds a complete instruction that the agent executes as a normal turn"
- **Actual:** Function at line 99: `def build_learn_prompt(user_request: str) -> str:`. Docstring: "Build the agent prompt for an open-ended /learn request... Returns: A complete instruction the agent runs as a normal turn."
- **Verdict:** VERIFIED
- **Source:** `agent/learn_prompt.py:99-110`

### Section 8: /learn — Finding 3: _AUTHORING_STANDARDS length
- **Claim:** "Embedded `_AUTHORING_STANDARDS` constant (96 lines of strict rules)"
- **Actual:** `_AUTHORING_STANDARDS` is defined at lines 30-96. The string content spans lines 31-96, which is 66 lines of actual rules content (the triple-quoted string). The doc claims 96 lines, likely confusing the ending line number (96) with the line count.
- **Verdict:** INACCURATE -- 66 lines of content, not 96. The "96" appears to be the ending line number, not a line count.
- **Source:** `agent/learn_prompt.py:30-96`

### Section 8: /learn — Finding 4: Authoring standards content
- **Claim:** Doc lists: name (lowercase-hyphenated, <=64 chars), description (ONE sentence, <=60 chars), version (0.1.0), author (always "Hermes"), platforms (only if OS-bound), body section order (Title, When to Use, Prerequisites, How to Run, Quick Reference, Procedure, Pitfalls, Verification), Hermes-tool framing, quality bar (~100-200 lines, no router/index skills)
- **Actual:** All confirmed verbatim in lines 35-96. Name (line 35), description <=60 chars (lines 36-44), version 0.1.0 (line 48), author "Hermes" (lines 49-53), platforms (lines 54-59), section order (lines 62-71), Hermes-tool framing (lines 73-84), quality bar (lines 87-96).
- **Verdict:** VERIFIED
- **Source:** `agent/learn_prompt.py:35-96`

### Section 8: /learn — Finding 5: Default behavior with no source
- **Claim:** When no source specified, defaults to: "the workflow we just went through in this conversation — review the steps taken and distill them into a reusable skill"
- **Actual:** Lines 111-116: `if not req: req = ("the workflow we just went through in this conversation — review " "the steps taken and distill them into a reusable skill")`. Exact verbatim match.
- **Verdict:** VERIFIED
- **Source:** `agent/learn_prompt.py:111-116`

### Section 8: /learn — Finding 6: Gather-then-author workflow
- **Claim:** Doc says agent: (1) gathers material using `read_file`, `search_files`, `web_extract`, conversation history, (2) authors ONE SKILL.md via `skill_manage` with `action="create"`, (3) follows authoring standards
- **Actual:** Prompt text at lines 118-135 instructs: step 1 "Gather the material... `read_file`/`search_files` for local files or directories, `web_extract` for URLs, the current conversation history..." step 2 "Author ONE SKILL.md and save it with the `skill_manage` tool (action=\"create\")." followed by the full `_AUTHORING_STANDARDS` block.
- **Verdict:** VERIFIED
- **Source:** `agent/learn_prompt.py:118-136`

### Section 8: /learn — Finding 7: .usage.json created_by field
- **Claim:** "The `.usage.json` sidecar is updated with `created_by: "agent"` and initial timestamps."
- **Actual:** The /learn prompt instructs the agent to call `skill_manage(action="create")`. In `tools/skill_manager_tool.py`, skill creation calls `skill_usage.mark_agent_created()` (confirmed in skill_usage.py line 646-654) which sets `created_by: "agent"`. The `_empty_record()` initializes `created_at` with `_now_iso()`.
- **Verdict:** VERIFIED
- **Source:** `tools/skill_usage.py:646-654,484-497`

---

## Summary

**Sections validated:** 2 through 8 (7 sections, 50 findings total)

**Verdict distribution:**
- VERIFIED: 42 findings
- INACCURATE: 8 findings (mostly minor line count discrepancies, plus notable issues with: S2 schema misrepresenting computed field, S5 omitting trajectory fields, S7 omitting memory providers and conflating interface names, S8 wrong _AUTHORING_STANDARDS line count)
- FABRICATED: 0

**Most significant inaccuracies:**
1. **Section 2, Finding 3:** `last_activity_at` presented as stored field but is actually computed on-the-fly
2. **Section 5, Finding 4:** Trajectory output schema omits 5 real fields (prompt_index, completed, partial, api_calls, toolsets_used, tool_error_counts)
3. **Section 7, Finding 4:** Only 4 of 8 memory providers listed (omits byterover, holographic, openviking, retaindb)
4. **Section 7, Finding 6:** Provider interface method names conflated between MemoryManager wrapper and MemoryProvider abstract class
5. **Section 8, Finding 3:** `_AUTHORING_STANDARDS` claimed as 96 lines but is 66 lines (line number vs count confusion)
