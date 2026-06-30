# Validation Notes: 01-architecture-and-structure.md
**Validated against:** /tmp/hermes-agent-research/
**Date:** 2026-06-30
**Validator:** Subagent

## Findings

### 1. Top-Level Files: Existence and Line Counts

**Doc claim (line 31):** `run_agent.py` is "~12k LOC"
**Actual:** 5,699 lines. The doc's own "File Size Reference" table (line 692) correctly says 5,699.
**Verdict:** ⚠️ INACCURATE — The inline description (~12k LOC) contradicts the doc's own table. The table is correct (5,699 lines).

**Doc claim (line 32):** `cli.py` is "~11k LOC"
**Actual:** 15,737 lines. The doc's own table (line 692) correctly says 15,737.
**Verdict:** ⚠️ INACCURATE — The inline description (~11k LOC) contradicts the doc's own table. The table is correct (15,737 lines).

**Doc claim (line 40):** `agent/conversation_loop.py` is "~3900 lines"
**Actual:** 5,006 lines. The doc's own table (line 694) correctly says 5,006.
**Verdict:** ⚠️ INACCURATE — The inline description (~3900) contradicts the doc's own table. The table is correct (5,006 lines).

**File Size Reference table (lines 690-696):** Claims cli.py=15,737, run_agent.py=5,699, conversation_loop.py=5,006, total=26,442.
**Actual:** All three numbers verified as exact matches via `wc -l`.
**Verdict:** ✅ VERIFIED — The table at the end of the doc is accurate; the inline descriptions earlier in the doc are wrong.

**Top-level file existence checks:**
- `run_agent.py` ✅ EXISTS
- `cli.py` ✅ EXISTS
- `batch_runner.py` ✅ EXISTS (1,321 lines)
- `model_tools.py` ✅ EXISTS (1,255 lines)
- `toolsets.py` ✅ EXISTS (941 lines)
- `hermes_constants.py` ✅ EXISTS (980 lines)
- `utils.py` ✅ EXISTS (509 lines)
**Verdict:** ✅ VERIFIED — All top-level files listed exist.

🆕 MISSING from directory structure: The doc omits several top-level files that exist:
- `toolset_distributions.py` — referenced later in text but not in directory tree
- `trajectory_compressor.py` — not mentioned at all
- `mcp_serve.py` — not mentioned
- `hermes_state.py` — listed under `hermes_state/` as a directory, but it is actually a top-level .py file (see Finding 14)
- `hermes_logging.py` — not mentioned
- `hermes_time.py` — not mentioned
- `hermes_bootstrap.py` — not mentioned
- `mini_swe_runner.py` — not mentioned

### 2. agent/ Directory: File Count and Key Modules

**Doc claim (line 39):** "Core agent subsystems (50+ modules)"
**Actual:** 107 files in `agent/` directory.
**Verdict:** ⚠️ INACCURATE — "50+" significantly underestimates. Actual count is 107 files (including `__init__.py` and subdirectories like `lsp/`, `pet/`, `secret_sources/`, `transports/`).

**Doc claim (line 87):** "(50+ more modules)" at end of listing
**Actual:** The doc lists ~47 specific files, then says "50+ more." With 107 total files, approximately 60 unlisted — so "50+ more" is roughly correct as a remainder.
**Verdict:** ✅ VERIFIED (roughly) — the remainder is approximately correct.

All 46 specific agent/ files listed in the doc exist at the stated paths. ✅ VERIFIED

🆕 MISSING from agent/ listing: Notable unlisted modules include:
- `auxiliary_client.py`, `azure_identity_adapter.py`, `billing_view.py`
- `browser_provider.py`, `browser_registry.py`, `chat_completion_helpers.py`
- `copilot_acp_client.py`, `credential_sources.py`, `credits_tracker.py`
- `curator_backup.py`, `errors.py`, `file_safety.py`, `gemini_schema.py`
- `image_gen_provider.py`, `image_gen_registry.py`, `image_routing.py`
- `lmstudio_reasoning.py`, `markdown_tables.py`, `message_content.py`
- `message_sanitization.py`, `moa_loop.py`, `model_metadata.py`, `models_dev.py`
- `moonshot_schema.py`, `nous_rate_guard.py`, `plugin_llm.py`, `portal_tags.py`
- `process_bootstrap.py`, `rate_limit_tracker.py`, `reasoning_timeouts.py`
- `replay_cleanup.py`, `runtime_cwd.py`, `secret_scope.py`, `shell_hooks.py`
- `ssl_guard.py`, `stream_diag.py`, `subdirectory_hints.py`
- `thinking_timeout_guidance.py`, `think_scrubber.py`, `title_generator.py`
- `tool_result_classification.py`, `transcription_provider.py`, `transcription_registry.py`
- `tts_provider.py`, `tts_registry.py`, `usage_pricing.py`
- `verify_hooks.py`, `video_gen_provider.py`, `video_gen_registry.py`
- `web_search_provider.py`, `web_search_registry.py`
- Subdirectories: `lsp/`, `pet/`, `secret_sources/`, `transports/`
- `account_usage.py`, `context_breakdown.py`, `codex_runtime.py`

### 3. tools/ Directory: File Count

**Doc claim (line 89):** "Tool implementations (80+ files)"
**Actual:** 92 files in `tools/` directory.
**Verdict:** ✅ VERIFIED — "80+" is correct (actual: 92).

**Doc claim (line 113):** "(60+ more tools)" at end of listing
**Actual:** The doc lists ~23 specific tools, and there are 92 total, so roughly 69 unlisted.
**Verdict:** ✅ VERIFIED — "60+ more" is roughly correct.

All 23 specific tools/ files listed in the doc exist at the stated paths. ✅ VERIFIED

