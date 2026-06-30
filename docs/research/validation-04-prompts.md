# Validation Report: 04 -- Prompts & Reflection System

**Validated against:** `/tmp/hermes-agent-research/agent/background_review.py` (874 lines per `wc -l`) and `/tmp/hermes-agent-research/agent/learn_prompt.py` (136 lines per `wc -l`)

**Date:** 2026-06-30

**Overall verdict:** Exceptionally accurate. Every verbatim code snippet in the document matches the actual source. The document is the most reliable of the set -- its claims are virtually all VERIFIED EXACT.

---

## File Metadata

The document header (line 8-9) states the sources are:
- `background_review.py` (875 lines) -- actual: 874 content lines + trailing newline (Read tool displays 875 line positions). **VERIFIED APPROXIMATE** -- off by 1 due to trailing newline counting.
- `learn_prompt.py` (136 lines) -- actual: 136 per `wc -l`. **VERIFIED EXACT.**

---

## Claim 1: `_MEMORY_REVIEW_PROMPT`

**Document lines 27-36 vs source lines 159-168.**

**Verdict: VERIFIED EXACT.**

Every character of the Python string literal matches. The prompt text, the `\n\n` placement, the two numbered focus areas, and the "Nothing to save." escape hatch are all identical.

The document's line reference in the Appendix (`background_review.py:159`) is also correct.

---

## Claim 2: `_SKILL_REVIEW_PROMPT`

**Document lines 54-157 vs source lines 170-273.**

**Verdict: VERIFIED EXACT.**

This is the longest constant (~100 lines of Python string concatenation). Every string literal, every bullet point, every line break, and every punctuation mark matches. Specifically verified:

- "Be ACTIVE -- most sessions produce at least one skill update" -- exact match (source line 172)
- 4-tier preference order (UPDATE LOADED > UPDATE UMBRELLA > ADD SUPPORT FILE > CREATE NEW) -- exact match (source lines 196-230)
- Support file taxonomy (`references/`, `templates/`, `scripts/`) -- exact match (source lines 208-224)
- "User-preference embedding (important)" section -- exact match (source lines 231-237)
- Protected skills section (bundled, hub-installed, pinned) -- exact match (source lines 240-248)
- DO NOT capture anti-patterns (4 categories) -- exact match (source lines 249-264)
- "Nothing to save." escape hatch -- exact match (source lines 269-272)

The document's line reference in the Appendix (`background_review.py:170`) is correct.

---

## Claim 3: `_COMBINED_REVIEW_PROMPT`

**Document lines 181-264 vs source lines 275-358.**

**Verdict: VERIFIED EXACT.**

Every string literal matches. The document's analysis of how the combined prompt differs from the skill-only prompt (lines 267-274) is also accurate:
- Opens with explicit Memory section -- confirmed (source lines 276-280)
- Signals condensed to 3 bullets vs 4 -- confirmed (source lines 288-296 vs skill prompt lines 179-194)
- Closing says "Act on whichever of the two dimensions" -- confirmed (source lines 355-357)

The document's line reference in the Appendix (`background_review.py:275`) is correct.

---

## Claim 4: `_AUTHORING_STANDARDS` in `learn_prompt.py`

**Document lines 650-716 vs source lines 30-96.**

**Verdict: VERIFIED EXACT.**

The entire multi-line string (66 lines of Python) matches verbatim. Specifically verified:

- `description <= 60 chars` rule with the truncation rationale -- exact match (source lines 37-47)
- `author = always "Hermes"` with privacy leak rationale -- exact match (source lines 49-53)
- Section order (8 sections) -- exact match (source lines 62-71)
- Hermes-tool framing rules with specific tool names -- exact match (source lines 73-84)
- Quality bar with `~100 lines` / `~200 lines` guidance -- exact match (source lines 86-96)
- Banned marketing words list -- exact match (source line 39)

The document's line reference in the Appendix (`learn_prompt.py:30`) is correct.

---

## Claim 5: `build_learn_prompt()` function

**Document lines 749-782 vs source lines 99-136.**

**Verdict: VERIFIED EXACT.**

- Function signature `def build_learn_prompt(user_request: str) -> str:` -- exact match (source line 99)
- Default request text when no args -- exact match (source lines 113-115):
  ```python
  req = (
      "the workflow we just went through in this conversation — review "
      "the steps taken and distill them into a reusable skill"
  )
  ```
- Assembled prompt template including `[/learn]` header, `WHAT TO LEARN FROM:` block, two-step instructions, `_AUTHORING_STANDARDS` embedding, and closing instruction -- exact match (source lines 118-136)

---

## Claim 6: Fork Construction Code

**Document lines 435-449 (AIAgent constructor) and lines 468-479 (post-construction attributes) vs source lines 641-720.**

**Verdict: VERIFIED EXACT.**

AIAgent constructor arguments (all match source lines 641-655):

| Parameter | Claimed Value | Source Value | Match |
|-----------|---------------|-------------|-------|
| `model` | `_rt.get("model") or agent.model` | same | EXACT |
| `max_iterations` | `16` | `16` | EXACT |
| `quiet_mode` | `True` | `True` | EXACT |
| `platform` | `agent.platform` | same | EXACT |
| `provider` | `_rt.get("provider") or agent.provider` | same | EXACT |
| `api_mode` | `_rt.get("api_mode")` | same | EXACT |
| `base_url` | `_rt.get("base_url") or None` | same | EXACT |
| `api_key` | `_rt.get("api_key") or None` | same | EXACT |
| `credential_pool` | `getattr(agent, "_credential_pool", None)` | same | EXACT |
| `parent_session_id` | `agent.session_id` | same | EXACT |
| `enabled_toolsets` | `getattr(agent, "enabled_toolsets", None)` | same | EXACT |
| `disabled_toolsets` | `getattr(agent, "disabled_toolsets", None)` | same | EXACT |
| `skip_memory` | `True` | `True` | EXACT |

Post-construction attribute assignments (all match, scattered through source lines 656-720 with interleaved comments):

| Attribute | Claimed Value | Source Line | Match |
|-----------|---------------|-------------|-------|
| `_memory_write_origin` | `"background_review"` | 656 | EXACT |
| `_memory_write_context` | `"background_review"` | 657 | EXACT |
| `_skip_mcp_refresh` | `True` | 664 | EXACT |
| `_memory_store` | `agent._memory_store` | 665 | EXACT |
| `_memory_enabled` | `agent._memory_enabled` | 666 | EXACT |
| `_user_profile_enabled` | `agent._user_profile_enabled` | 667 | EXACT |
| `_memory_nudge_interval` | `0` | 668 | EXACT |
| `_skill_nudge_interval` | `0` | 669 | EXACT |
| `suppress_status_output` | `True` | 677 | EXACT |
| `_end_session_on_close` | `False` | 709 | EXACT |
| `compression_enabled` | `False` | 720 | EXACT |

The document correctly strips interleaved comments for readability while preserving every assignment verbatim.

---

## Claim 7: `_bg_review_auto_deny` Callback

**Document lines 361-371 vs source lines 591-600.**

**Verdict: VERIFIED EXACT.**

Function signature, logger.warning format string, `return "deny"`, and the `try/except` wrapping `_set_approval_callback` all match character-for-character. The document correctly notes it mirrors the `_subagent_auto_deny` pattern from `tools/delegate_tool.py` (source comment on line 590 confirms).

---

## Claim 8: `_digest_history` Function

**Document lines 409-425 vs source lines 111-152.**

**Verdict: VERIFIED EXACT.**

- Function signature with `tail: int = 24` default -- exact match (source line 111)
- Expansion logic for tool-role messages at window boundary -- confirmed (source lines 123-127)
- User message truncation to 300 chars (`text[:300]`) -- confirmed (source line 136)
- Assistant text truncation to 200 chars (`text[:200]`) -- confirmed (source line 143)
- Tool calls summarized as `ASSISTANT[tools: name1, name2]` -- confirmed (source line 141)
- Digest prefix string -- exact match (source lines 147-149)
- Collapse to synthetic `user`-role message -- confirmed (source line 144)

---

## Claim 9: `set_thread_tool_whitelist` Mechanism

**Document lines 519-549 vs source lines 722-760.**

**Verdict: VERIFIED EXACT.**

- Import of `get_tool_definitions`, `set_thread_tool_whitelist`, `clear_thread_tool_whitelist` -- exact match (source lines 722-726)
- Whitelist construction from `enabled_toolsets=["memory", "skills"]` -- exact match (source lines 728-733)
- `deny_msg_fmt` template with `{tool_name}` format key -- exact match (source lines 735-741)
- `clear_thread_tool_whitelist()` in `finally` block -- exact match (source line 760)

---

## Claim 10: `summarize_background_review_actions`

**Document lines 932-1010 vs source lines 362-541.**

**Verdict: VERIFIED EXACT.**

- `notify_tools = {"memory", "skill_manage"}` -- exact match (source line 401)
- Function signature with `notification_mode: str = "on"` -- exact match (source line 365)
- Three notification modes -- confirmed:
  - `"off"` returns `[]` (source line 381)
  - `"on"` produces generic messages (source lines 459-466, 532-540)
  - `"verbose"` includes content previews (source lines 477-531)
- Verbose character limits:
  - 120 chars for add/replace (`max_preview = 120`, source line 483) -- EXACT
  - 80 chars for patch old/new (`old_string[:80]`, `new_string[:80]`, source lines 490-494) -- EXACT
  - 60 chars for remove (`op_old[:60]`, source line 519) -- EXACT
- Stale result deduplication via `existing_tool_call_ids` and `existing_tool_contents` -- exact match (source lines 384-396)
- Action summary delivery with `dict.fromkeys(actions)` deduplication -- exact match (source line 794)
- Emoji representation: document uses `\U0001f4be` while source uses literal floppy-disk emoji -- functionally identical (same Unicode code point U+1F4BE)

---

## Claim 11: `build_memory_write_metadata` Function

**Document lines 897-921 vs source lines 544-568.**

**Verdict: VERIFIED EXACT.**

Every element of the function matches:
- Function signature (keyword-only args with `*`) -- exact match
- Metadata dict keys: `write_origin`, `execution_context`, `session_id`, `parent_session_id`, `platform`, `tool_name` -- exact match
- Default values: `"assistant_tool"` for write_origin, `"foreground"` for execution_context -- exact match
- Platform fallback: `os.environ.get("HERMES_SESSION_SOURCE", "cli")` -- exact match (source line 562)
- Optional fields (`task_id`, `tool_call_id`) conditional inclusion -- exact match
- Final filtering: `{k: v for k, v in metadata.items() if v not in {None, ""}}` -- exact match (source line 568)

The document correctly omits only the docstring (`"""Build provenance metadata for external memory-provider mirrors."""`), which is standard for reference documentation.

---

## Claim 12: Module `__all__`

**Document lines 1125-1132 vs source lines 867-874.**

**Verdict: VERIFIED EXACT.**

All six exported names match in the same order:
1. `"_MEMORY_REVIEW_PROMPT"` -- EXACT
2. `"_SKILL_REVIEW_PROMPT"` -- EXACT
3. `"_COMBINED_REVIEW_PROMPT"` -- EXACT
4. `"spawn_background_review_thread"` -- EXACT
5. `"summarize_background_review_actions"` -- EXACT
6. `"build_memory_write_metadata"` -- EXACT

---

## Additional Claims Verified

### Runtime Prompt Suffix (Section 1.4)
**Document lines 282-291 vs source lines 750-758.** The suffix text `"\n\nYou can only call memory and skill management tools. Other tools will be denied at runtime -- do not attempt them."` is **VERIFIED EXACT**.

### Prompt Selection Logic (Section 1.5)
**Document lines 301-317 vs source lines 839-864.** The `getattr` pattern with module-level fallbacks is **VERIFIED EXACT**. The document correctly notes this allows per-agent overrides for backward compatibility.

### Aux-Model Routing (Section 2.3)
**Document lines 381-401 vs source lines 45-99.** The `_resolve_review_runtime` function, the `codex_app_server -> codex_responses` downgrade, the decision table, and the config path `auxiliary.background_review.{provider,model,base_url,api_key}` are all **VERIFIED EXACT**.

### Stdout/Stderr Suppression (Section 2.9)
**Document lines 557-559 vs source lines 605-607.** The double redirect pattern with `os.devnull` is **VERIFIED EXACT**.

### Prefix-Cache Parity (Section 2.7)
**Document lines 503-506 vs source lines 692-702.** The conditional `_cached_system_prompt` and `session_start` pinning, and the ~26% cost reduction reference (issue #25322, PR #17276) are **VERIFIED EXACT**.

### Teardown and Cleanup (Section 2.10)
**Document lines 570-614 vs source lines 765-835.** The message snapshot, `shutdown_memory_provider()`, `close()`, safety-net `finally` block, and approval callback clearing are all **VERIFIED EXACT**.

### `skip_memory=True` Comment (Section 5.6)
**Document lines 1019-1029 vs source lines 623-638.** The three ingestion sites comment (`on_turn_start`, `prefetch_all`, `sync_all`) is **VERIFIED EXACT**.

### Appendix Line References
All line numbers in the Appendix table are **VERIFIED EXACT**:
- `_MEMORY_REVIEW_PROMPT` at line 159 -- correct
- `_SKILL_REVIEW_PROMPT` at line 170 -- correct
- `_COMBINED_REVIEW_PROMPT` at line 275 -- correct
- `_AUTHORING_STANDARDS` at line 30 -- correct

---

## Summary

| # | Claim | Verdict |
|---|-------|---------|
| 1 | `_MEMORY_REVIEW_PROMPT` text | VERIFIED EXACT |
| 2 | `_SKILL_REVIEW_PROMPT` text | VERIFIED EXACT |
| 3 | `_COMBINED_REVIEW_PROMPT` text | VERIFIED EXACT |
| 4 | `_AUTHORING_STANDARDS` text | VERIFIED EXACT |
| 5 | `build_learn_prompt()` function | VERIFIED EXACT |
| 6 | Fork constructor args + post-construction attrs | VERIFIED EXACT |
| 7 | `_bg_review_auto_deny` callback | VERIFIED EXACT |
| 8 | `_digest_history` (tail=24, truncation limits) | VERIFIED EXACT |
| 9 | `set_thread_tool_whitelist` mechanism | VERIFIED EXACT |
| 10 | `summarize_background_review_actions` (notify_tools, modes, limits) | VERIFIED EXACT |
| 11 | `build_memory_write_metadata` dict structure | VERIFIED EXACT |
| 12 | Module `__all__` exports | VERIFIED EXACT |

**Only discrepancy found:** The document header states `background_review.py` is 875 lines; `wc -l` reports 874 (the file has 874 complete newline-terminated lines, but the Read tool shows 875 line positions due to the final newline). This is a trivial counting artifact.

**Conclusion:** This is the most accurate document in the research set. Every verbatim code snippet -- including three multi-page prompt constants, function signatures, constructor arguments, post-construction attribute lists, and utility functions -- matches the actual source character-for-character. The document's analytical commentary (anti-pattern taxonomy, prompt comparison tables, rationale explanations) is also accurate and consistent with source comments.
