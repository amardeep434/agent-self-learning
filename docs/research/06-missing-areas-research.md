# Missing Self-Learning Areas Research
**Source:** /tmp/hermes-agent-research/
**Date:** 2026-06-30

---

## 1. Session Search (FTS5) -- Long-Term Conversation Recall

### Files
- `tools/session_search_tool.py` (922 lines) -- Single-shape tool with four calling modes: DISCOVERY, SCROLL, READ, BROWSE
- `hermes_state.py` -- Underlying SQLite session DB with FTS5 index, anchored views, message retrieval
- `tests/tools/test_session_search.py` -- Test suite
- `tests/hermes_cli/test_web_server_session_search.py` -- Web server integration tests

### How It Works

The Session Search tool provides FTS5-backed full-text retrieval over the agent's SQLite message store. It operates with **zero LLM calls** -- every shape returns actual messages from the database.

**Four Calling Shapes** (inferred from args, no explicit mode parameter):

1. **DISCOVERY** -- pass `query`. Runs FTS5 via `db.search_messages()`, dedupes hits by session lineage, returns top N sessions. Each result carries:
   - `snippet`: FTS5-highlighted match excerpt
   - `bookend_start`: first 3 user+assistant messages (the goal/kickoff)
   - `messages`: +/-5 messages around the FTS5 match (the hit in context)
   - `bookend_end`: last 3 user+assistant messages (the resolution/decisions)
   - Structure allows reconstructing goal -> match -> resolution without loading the full transcript

2. **SCROLL** -- pass `session_id` + `around_message_id`. Returns a window of +/-`window` messages centered on an anchor. Supports forward/backward scrolling by re-anchoring on the first/last message id. Window clamped to [1, 20].

3. **READ** -- pass `session_id` only. Dumps the whole session (first 20 + last 10 messages for large sessions). Resolves `@session:<profile>/<id>` link references.

4. **BROWSE** -- no args. Returns recent sessions chronologically with titles, previews, timestamps. Uses `db.list_sessions_rich()` with `order_by_last_active=True`.

**Session Lineage Resolution** (`_resolve_to_parent`): Walks `parent_session_id` chain to the lineage root. This is critical because compaction/delegation creates child sessions -- the tool deduplicates by lineage root so the same conversation doesn't appear multiple times.

**Recall Ranking** (`_order_for_recall`): Implements a two-tier ranking system:
- Interactive sessions rank above automation (cron) sessions
- Within each class, original BM25/recency order is preserved (stable sort)
- Prevents "recall blindness" where high-volume cron sessions dominate top-N results (#19434)

**Cross-Profile Search** (`_resolve_profile_db`, `_locate_session_db`): Can read sessions from other Hermes profiles' databases in read-only mode. Falls back to scanning every profile when a session ID isn't found in the target profile.

### Key Constants/Thresholds
- `_HIDDEN_SESSION_SOURCES` = `("subagent", "tool")` -- excluded from browsing/searching entirely
- `_DEMOTED_SESSION_SOURCES` = `("cron",)` -- searchable but demoted below interactive sessions
- `_DISCOVER_SCAN_LIMIT` = 300 -- how many FTS rows discovery scans before dedup-by-lineage
- Scroll window clamped to [1, 20]
- Discovery limit clamped to [1, 10] (default 3)
- Read shape: first 20 + last 10 messages for large sessions

### FTS5 Syntax Support
- AND is default (multi-word queries require all terms)
- OR for broader recall (`alpha OR beta OR gamma`)
- Quoted phrases for exact match (`"docker networking"`)
- Boolean NOT (`python NOT java`)
- Prefix wildcards (`deploy*`)

### Connection to Self-Learning
Session search is the **episodic memory** complement to the declarative memory (MEMORY.md / memory tool). The system prompt explicitly instructs the agent (via `SESSION_SEARCH_GUIDANCE` in `prompt_builder.py`):

> "When the user references something from a past conversation or you suspect relevant cross-session context exists, use session_search to recall it before asking them to repeat themselves."

The `MEMORY_GUIDANCE` also explicitly differentiates the two systems:

> "Do NOT save task progress, session outcomes, completed-work logs to memory; use session_search to recall those from past transcripts."

This creates a clear division: memory stores durable facts/preferences, session_search retrieves episodic conversation history. Together they form the agent's long-term recall system.

---

## 2. SOUL.md Identity System

### Files
- `hermes_cli/default_soul.py` (77 lines) -- Default SOUL.md template and legacy detection
- `agent/prompt_builder.py` -- Loads SOUL.md and injects it as the agent identity in system prompt
- `hermes_cli/config.py` -- Configuration for SOUL.md location
- `hermes_cli/profiles.py` -- Per-profile SOUL.md support
- `hermes_cli/claw.py` -- SOUL.md within the claw (profile distribution) system
- `agent/system_prompt.py` -- System prompt assembly that uses SOUL.md content

### How It Works

**Default Identity** (`default_soul.py`):
The system ships with a hardcoded `DEFAULT_SOUL_MD` string:

> "You are Hermes Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct. You assist users with a wide range of tasks including answering questions, writing and editing code, analyzing information, creative work, and executing actions via your tools. You communicate clearly, admit uncertainty when appropriate, and prioritize being genuinely useful over being verbose unless otherwise directed below. Be targeted and efficient in your exploration and investigations."

This same text also appears as `DEFAULT_AGENT_IDENTITY` in `prompt_builder.py` (line 126), serving as the fallback when no SOUL.md is found.

**SOUL.md Location**: Stored at `HERMES_HOME/SOUL.md` (typically `~/.hermes/SOUL.md`). Loaded fresh each message -- no restart needed to change personality.

**Legacy Template Detection** (`is_legacy_template_soul`): Older installers seeded comment-only scaffold SOUL.md files instead of the actual persona text. The system detects these "empty template" souls (two known variants stored in `_LEGACY_TEMPLATE_SOULS`) and upgrades them in-place to `DEFAULT_SOUL_MD`. Detection uses normalized comparison (stripped, line-endings unified, BOM-removed) so Windows artifacts don't break matching.

**Identity Injection in System Prompt**: The `prompt_builder.py` module loads SOUL.md content as the very first element of the system prompt. The identity is the foundation of every conversation -- it defines who the agent is before any skills, context, or memory are layered on top.

**Per-Profile Identity**: Each Hermes profile can have its own SOUL.md, enabling different personas (e.g., "coder" profile vs "researcher" profile). The profile system (`hermes_cli/profiles.py`) manages separate `HERMES_HOME` directories per profile.

### Key Constants/Thresholds
- `DEFAULT_SOUL_MD` -- Default identity string (~65 words)
- `DEFAULT_AGENT_IDENTITY` -- Same text, used as fallback in prompt_builder
- `_LEGACY_TEMPLATE_SOULS` -- Tuple of 2 known legacy template strings for upgrade detection

### Connection to Self-Learning
SOUL.md is the **identity anchor** that persists across sessions. While memory accumulates learned facts and skills capture workflows, SOUL.md defines the fundamental character. The system is designed so users can customize it freely -- the hot-reload (loaded fresh each message) means the identity can evolve without session restarts.

The learning loop connection is indirect but important: the agent's personality affects HOW it learns (what it saves to memory, how it interacts with skills). A SOUL.md that says "You are a concise technical expert" will produce different memory entries than one that says "You are a warm, playful assistant."

---

## 3. Skill Preprocessing and Variable Substitution

### Files
- `agent/skill_preprocessing.py` (145 lines) -- Core preprocessing: template variables + inline shell execution
- `agent/skill_commands.py` -- Skill loading and command dispatch
- `agent/prompt_builder.py` -- Where preprocessed skills get assembled into system prompt
- `hermes_cli/config.py` -- Configuration for preprocessing features (template_vars, inline_shell)

### How It Works

**Two-Stage Preprocessing** (`preprocess_skill_content`, line 128):
Skills go through two preprocessing stages before injection into the system prompt:

1. **Template Variable Substitution** (`substitute_template_vars`, line 39):
   - Pattern: `${HERMES_SKILL_DIR}` and `${HERMES_SESSION_ID}` tokens
   - Regex: `_SKILL_TEMPLATE_RE = re.compile(r"\$\{(HERMES_SKILL_DIR|HERMES_SESSION_ID)\}")`
   - Only substitutes tokens for which concrete values are available -- unresolved tokens are left in place for debugging
   - `${HERMES_SKILL_DIR}` resolves to the absolute path of the skill's directory
   - `${HERMES_SESSION_ID}` resolves to the current session identifier
   - Controlled by config: `skills.template_vars` (default: `True`)

2. **Inline Shell Execution** (`expand_inline_shell`, line 106):
   - Pattern: `` !`cmd` `` snippets in SKILL.md content
   - Regex: ``_INLINE_SHELL_RE = re.compile(r"!`([^`\n]+)`")``
   - Runs each snippet via `bash -c` with the skill directory as CWD
   - Captures stdout (falls back to stderr if stdout empty)
   - Failures return a short `[inline-shell error: ...]` marker -- one bad snippet cannot wreck the whole skill
   - Controlled by config: `skills.inline_shell` (default: `False` -- opt-in)
   - Timeout controlled by config: `skills.inline_shell_timeout` (default: `10` seconds)

**Configuration Loading** (`load_skills_config`, line 25):
Reads the `skills` section from `config.yaml` to determine which preprocessing stages are active.

### Key Constants/Thresholds
- `_SKILL_TEMPLATE_RE` -- Regex matching `${HERMES_SKILL_DIR}` and `${HERMES_SESSION_ID}` tokens
- `_INLINE_SHELL_RE` -- Regex matching `` !`cmd` `` snippets (single-line only, non-greedy)
- `_INLINE_SHELL_MAX_OUTPUT` = 4000 -- Cap on inline-shell output to prevent context blowout
- Default `inline_shell` = `False` (opt-in for security)
- Default `inline_shell_timeout` = 10 seconds
- Default `template_vars` = `True` (on by default)

### Connection to Self-Learning
Skill preprocessing is the bridge between **static skill definitions** and **dynamic runtime context**. The variable substitution system allows skills to reference their own location (`${HERMES_SKILL_DIR}`) to find companion scripts, data files, or sub-skills. The inline shell feature enables skills to inject **live system state** (e.g., `` !`date +%Y-%m-%d` ``, `` !`git branch --show-current` ``) into their content at runtime.

This makes skills context-aware rather than purely static -- a skill that includes `` !`ls ${HERMES_SKILL_DIR}/scripts/` `` will show the current set of available scripts, adapting as scripts are added or removed. This is a form of environmental learning: skills evolve their effective content based on what is actually present on the system.

---

## 4. System Prompt Assembly & Skills Injection

### Files
- `agent/system_prompt.py` (537 lines) -- Three-tier prompt assembly orchestrator
- `agent/prompt_builder.py` (1972+ lines) -- Skills cache, context file discovery, identity loading, guidance constants
- `agent/coding_context.py` (300+ lines) -- Coding posture detection and skill category demotion

### How It Works

**Three-Tier Architecture** (`build_system_prompt_parts`, system_prompt.py:113):
The system prompt is assembled once per session and cached for all turns. It is split into three tiers joined by `\n\n`:

1. **Stable Tier** -- Identity + tool guidance + skills prompt + environment hints + platform hints. Cache-friendly: never changes mid-session.
   - SOUL.md loaded first as identity (falls back to `DEFAULT_AGENT_IDENTITY` hardcoded string)
   - `HERMES_AGENT_HELP_GUIDANCE` -- pointer to the hermes-agent skill
   - `TASK_COMPLETION_GUIDANCE` -- anti-fabrication, no-stubs discipline (gated by `agent.task_completion_guidance` config, default True)
   - `PARALLEL_TOOL_CALL_GUIDANCE` -- instructs model to batch independent tool calls (gated by `agent.parallel_tool_call_guidance`, default True)
   - **Tool-conditional guidance**: `MEMORY_GUIDANCE` only if `"memory"` tool loaded, `SESSION_SEARCH_GUIDANCE` only if `"session_search"` loaded, `SKILLS_GUIDANCE` only if `"skill_manage"` loaded, `KANBAN_GUIDANCE` only if kanban tools loaded
   - `STEER_CHANNEL_NOTE` -- steering-only channel for tool results
   - Computer-use guidance (if `"computer_use"` tool loaded)
   - Nous subscription prompt (if managed Nous tools enabled)
   - `TOOL_USE_ENFORCEMENT_GUIDANCE` -- tells models to call tools rather than describe actions (config-driven: `"auto"` matches `TOOL_USE_ENFORCEMENT_MODELS` list; `true`/`false`/custom list)
   - Per-model operational guidance: `GOOGLE_MODEL_OPERATIONAL_GUIDANCE` for Gemini/Gemma, `OPENAI_MODEL_EXECUTION_GUIDANCE` for GPT/Codex/Grok
   - Skills prompt (see below)
   - Coding posture blocks (see Section 5)
   - Active profile hint
   - Platform hints (built-in + plugin-registered + per-platform config overrides)

2. **Context Tier** -- Caller-supplied `system_message` + context files discovered under `TERMINAL_CWD`. Changes between sessions but stable within a session.

3. **Volatile Tier** -- Memory snapshot, USER.md profile, external memory provider block, timestamp/session/model/provider line. Changes per session.

**Prompt Caching Strategy**: The system prompt is built once and stored on `agent._cached_system_prompt`. It is only rebuilt after context compression events via `invalidate_system_prompt()`. The timestamp uses date-only format (not minute-precision) to keep the prompt byte-stable for the full day, maximizing prefix cache hits.

**Two-Layer Skills Cache** (`build_skills_system_prompt`, prompt_builder.py:1417):

Layer 1 -- **In-process LRU dict** keyed by a composite tuple:
- `(skills_dir, external_dirs, available_tools, available_toolsets, platform, disabled_skills, compact_categories)`
- Thread-safe with `_SKILLS_PROMPT_CACHE_LOCK`
- Bounded by `_SKILLS_PROMPT_CACHE_MAX`

Layer 2 -- **Disk snapshot** (`.skills_prompt_snapshot.json`):
- Validated by mtime/size manifest of skill files
- Survives process restarts
- Cold path: full filesystem scan writes a new snapshot

**Skill Filtering Pipeline**:
1. Platform filtering via `skill_matches_platform()` -- skills can declare supported platforms in frontmatter
2. Disabled-skill filtering via `get_disabled_skill_names()` -- per-platform disabled lists
3. Condition filtering via `_skill_should_show()` -- skills can declare `conditions` in frontmatter requiring specific tools or toolsets to be loaded
4. External skill directories (`skills.external_dirs` in config.yaml) scanned alongside local `~/.hermes/skills/`, local takes precedence on name collisions
5. Category-level `DESCRIPTION.md` files provide category descriptions in the rendered index

**Category Demotion** (`compact_categories`, prompt_builder.py:1599):
Under the opt-in `focus` coding mode, non-coding skill categories (like social-media, music, etc.) are demoted to a single names-only line in the rendered index. Descriptions are dropped to cut noise, but every skill name remains visible so memory-anchored recall (`"load <name>"`) keeps working. Skills are NEVER removed entirely -- the agent created skills are the model's project memory, and models do not reach for `skills_list` to rediscover what the index stops showing them.

**Rendered Skills Prompt Format**:
```
## Skills (mandatory)
Before replying, scan the skills below. If a skill matches or is even partially relevant
to your task, you MUST load it with skill_view(name) and follow its instructions...

<available_skills>
  category: description
    - skill_name: skill description
  demoted_category [names only]: name1, name2, name3
</available_skills>

Only proceed without loading a skill if genuinely none are relevant to the task.
```

The guidance text is notably aggressive about skill loading -- it says "Err on the side of loading" and explicitly tells the model that skills contain specialized knowledge, proven workflows, and the user's preferred conventions that outperform general-purpose approaches.

### Key Constants/Thresholds
- `TOOL_USE_ENFORCEMENT_MODELS` -- hardcoded model-name substrings for auto-mode enforcement
- `_SKILLS_PROMPT_CACHE_LOCK` -- threading.Lock for LRU cache
- `_SKILLS_PROMPT_CACHE_MAX` -- max entries in the LRU cache
- Date-only timestamp format (not minute-precision) for prompt stability

### Connection to Self-Learning
The system prompt assembly is the **orchestration layer** that brings all self-learning subsystems together. It decides:
- WHICH guidance to inject based on loaded tools (memory, session_search, skills, kanban)
- HOW skills are indexed and presented based on the coding posture
- WHAT memory and user profile content enters the prompt
- WHEN to rebuild (only after compression, never mid-session)

The three-tier architecture is specifically designed around **prefix cache optimization** -- stable content first, volatile last. This means the agent's learned identity, skills, and tool guidance get cached by the LLM provider, while only the volatile memory/profile content varies. The design trades freshness for efficiency: mid-session memory writes do NOT update the system prompt (they persist to disk and take effect next session).

---

## 5. Context Engine & Coding Posture Detection

### Files
- `agent/context_engine.py` (227 lines) -- Abstract base class for pluggable context engines
- `agent/coding_context.py` (300+ lines) -- Coding workspace detection, ContextProfile registry, RuntimeMode
- `agent/prompt_builder.py` (lines 1796-1972) -- Context file discovery (AGENTS.md, CLAUDE.md, .cursorrules, .hermes.md)

### How It Works

#### Context Engine (Pluggable Compaction)

The `ContextEngine` ABC (`context_engine.py`) defines the interface for conversation context management when approaching the model's token limit.

**Selection**: Config-driven via `context.engine` in config.yaml (default: `"compressor"` -- the built-in summarizer). Only one engine is active at a time.

**Lifecycle**:
1. `on_session_start(session_id)` -- load persisted state
2. `update_from_response(usage)` -- track token usage from each API response
3. `should_compress(prompt_tokens)` -- check if compaction should fire
4. `compress(messages, current_tokens, focus_topic)` -- compact the message list
5. `on_session_end(session_id, messages)` -- flush state, close connections

**Compaction Parameters** (defaults on ABC):
- `threshold_percent = 0.75` -- fire compaction at 75% of context window
- `protect_first_n = 3` -- always preserve first 3 non-system messages (plus the system prompt implicitly)
- `protect_last_n = 6` -- always preserve last 6 messages

**Extension Points**:
- `get_tool_schemas()` -- engines can expose tools to the agent (e.g., LCM engine would provide `lcm_grep`, `lcm_describe`, `lcm_expand`)
- `handle_tool_call(name, args)` -- dispatch agent tool calls
- `update_model(model, context_length)` -- recalculate budgets when user switches models mid-session
- `should_compress_preflight(messages)` -- cheap pre-API-call estimate
- `has_content_to_compress(messages)` -- guard for manual `/compress` command
- `on_session_reset()` -- resets compression_count and token tracking on `/new` or `/reset`

**State Tracking** (engines MUST maintain these; `run_agent.py` reads them directly):
- `last_prompt_tokens`, `last_completion_tokens`, `last_total_tokens`
- `threshold_tokens`, `context_length`, `compression_count`

#### Context File Discovery (`build_context_files_prompt`, prompt_builder.py:1924)

Priority-based discovery -- **first match wins** (only ONE project context type is loaded):
1. `.hermes.md` / `HERMES.md` -- walks to git root
2. `AGENTS.md` / `agents.md` -- cwd only
3. `CLAUDE.md` / `claude.md` -- cwd only
4. `.cursorrules` + `.cursor/rules/*.mdc` -- cwd only

SOUL.md from `HERMES_HOME` is independent and always included when present (unless `skip_soul=True` because it was already loaded as identity in the stable tier).

**Security**: Each context source is scanned via `_scan_context_content()` for injection/promptware patterns before injection. Content is truncated by `_truncate_content()` using a dynamic cap that scales with the model's context window (or falls back to 20,000 chars). An explicit `context_file_max_chars` in config.yaml always wins.

#### Coding Posture Detection (`coding_context.py`)

**Architecture**: The coding posture is modelled as a frozen `RuntimeMode` selected from a `ContextProfile` registry. A profile is pure data -- it declares the toolset, operating brief, model hint, memory policy, and compact skill categories.

**ContextProfile Data Class** (frozen):
- `name` -- identifier ("coding", "general")
- `toolset` -- collapse to this toolset under focus mode; `None` keeps platform default
- `guidance` -- operating brief injected into stable system prompt
- `model_hint` -- routing preference (extension seam, not yet consumed)
- `memory_policy` -- memory namespace/weighting hint (extension seam)
- `compact_skill_categories` -- categories demoted to names-only in focus mode

**Workspace Detection** (`_has_code_files`):
- `_PROJECT_MARKERS` tuple: `pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, `Dockerfile`, `AGENTS.md`, `CLAUDE.md`, `.cursorrules`, etc. (18 total)
- `_CODE_EXTENSIONS` frozenset: `.py`, `.js`, `.ts`, `.go`, `.rs`, `.java`, `.kt`, `.rb`, `.php`, etc. (52 total)
- `_CODE_SCAN_MAX_ENTRIES = 500` -- bounded sweep of top two directory levels
- `_CODE_SCAN_SKIP_DIRS` -- `node_modules`, `.git`, `venv`, `__pycache__`, etc.
- A git repo of loose scripts (no manifest) still reads as a code workspace if source files are found. A bare notes/writing repo does not.

**Activation Modes** (`agent.coding_context` config):
- `auto` (default) -- posture (brief + snapshot) on interactive coding surfaces in code workspaces. Prompt-only; toolsets and skill index untouched.
- `focus` -- like auto, but additionally collapses toolset to `coding` set + enabled MCP servers and demotes non-coding skill categories to names-only
- `on` -- force posture everywhere
- `off` -- disable entirely

**Interactive Coding Platforms**: `INTERACTIVE_CODING_PLATFORMS = {"cli", "tui", "acp", "desktop", ""}` -- messaging platforms (telegram, discord, slack) are intentionally absent.

**Edit Format Steering** (`_EDIT_FORMAT_GUIDANCE`):
Per-model family, the coding brief steers toward the edit tool format the model was trained on:
- GPT/Codex -> `mode='patch'` (V4A diff) for ALL edits including single-file
- Claude/Gemini/DeepSeek/Qwen/Llama/Mistral -> `mode='replace'` (find-and-swap); V4A only for genuine multi-file edits

**CODING_AGENT_GUIDANCE**: A detailed operating brief (~25 lines) injected into the stable tier. Key instructions: "Gather context first", "Make changes through the tools, not the chat", "Verify, and know when to stop". Includes concrete tool names: `read_file`, `search_files`, `patch`, `write_file`, `terminal`, `todo`.

**Cache Safety**: The mode is resolved once and is immutable. The workspace snapshot is built once at prompt-build time and baked into the stable tier -- never re-probed per turn. Branch and dirty state drift mid-session, so the brief tells the model to re-check with `git` before acting on the snapshot. A `/coding` flip takes effect next session (deferred).

### Key Constants/Thresholds
- `threshold_percent = 0.75` (context engine default)
- `protect_first_n = 3`, `protect_last_n = 6` (context engine defaults)
- `_CODE_SCAN_MAX_ENTRIES = 500`
- `_MAX_VERIFY_COMMANDS = 8` -- verify commands surfaced in workspace snapshot
- `_MAX_FACT_FILE_BYTES = 256 * 1024` -- cap on fact files in snapshot
- `_GIT_TIMEOUT = 2.5` seconds
- `INTERACTIVE_CODING_PLATFORMS = {"cli", "tui", "acp", "desktop", ""}`

### Connection to Self-Learning
The context engine and coding posture form the **adaptive framing** layer of self-learning:

1. **Context engines** decide what the agent remembers from the current conversation. The compaction process (summarize, discard, preserve) is itself a form of learning -- the engine decides what information is important enough to keep when the context window fills up. The pluggable architecture allows different strategies (the default summarizer vs. hypothetical DAG-based engines like LCM that could expose grep/expand tools for structured recall).

2. **Coding posture** dynamically adapts the agent's behavior and available guidance based on the environment. When the agent detects a code workspace, it injects a detailed operating brief that changes HOW the agent approaches tasks -- "gather context first", "make changes through tools", "verify before claiming done". This is environmental learning: the system adapts its behavior based on what it detects about the workspace.

3. **Context file discovery** loads project-specific instructions (.hermes.md, AGENTS.md, CLAUDE.md, .cursorrules) that override the agent's default behavior. This is user-authored learning: the human teaches the agent project-specific conventions that persist across sessions.

---

## 6. Memory Provider Plugin Architecture

### Files
- `agent/memory_provider.py` (316 lines) -- Abstract base class for pluggable memory providers
- `agent/memory_manager.py` (200+ lines) -- Orchestrator enforcing one-external-provider limit
- `plugins/memory/__init__.py` (451 lines) -- Plugin discovery and loading for bundled and user-installed providers
- `tools/memory_tool.py` (800+ lines) -- Built-in MemoryStore with MEMORY.md and USER.md

### How It Works

#### MemoryProvider ABC (`memory_provider.py`)

Defines the interface all external memory providers must implement. External providers (Honcho, Hindsight, Mem0, etc.) are registered via `MemoryManager` and run alongside the built-in MEMORY.md/USER.md system.

**Core Lifecycle** (called by MemoryManager, wired in run_agent.py):
1. `initialize(session_id, **kwargs)` -- connect, create resources, warm up. kwargs include `hermes_home`, `platform`, `agent_context` ("primary"/"subagent"/"cron"/"flush"), `agent_identity` (profile name), `parent_session_id`, `user_id`
2. `system_prompt_block()` -- static text for the system prompt (instructions, status)
3. `prefetch(query, session_id)` -- background recall before each turn, returns formatted context
4. `queue_prefetch(query, session_id)` -- queue background recall for the NEXT turn
5. `sync_turn(user_content, assistant_content, session_id, messages)` -- persist completed turn to backend (should be non-blocking)
6. `get_tool_schemas()` -- OpenAI function calling format tool schemas
7. `handle_tool_call(tool_name, args)` -- dispatch tool calls, returns JSON string
8. `shutdown()` -- flush queues, close connections

**Optional Hooks** (override to opt in):
- `on_turn_start(turn_number, message, **kwargs)` -- per-turn tick with `remaining_tokens`, `model`, `platform`, `tool_count`
- `on_session_end(messages)` -- end-of-session fact extraction (only at real session boundaries, not per-turn)
- `on_session_switch(new_session_id, parent_session_id, reset, rewound)` -- fires on `/resume`, `/branch`, `/reset`, `/new`, gateway equivalents, and context compression
- `on_pre_compress(messages) -> str` -- extract knowledge before context compression discards messages
- `on_memory_write(action, target, content, metadata)` -- mirror built-in MEMORY.md/USER.md writes to external backend
- `on_delegation(task, result, **kwargs)` -- parent-side observation of subagent work
- `backup_paths() -> list[str]` -- extra on-disk paths for `hermes backup`

#### MemoryManager (`memory_manager.py`)

Orchestrates memory providers with strict constraints:
- **One external provider limit** -- prevents tool schema bloat and conflicting backends
- `_SYNC_DRAIN_TIMEOUT_S = 5.0` -- timeout for draining async sync queues at shutdown
- Context fencing with `<memory-context>` tags
- `StreamingContextScrubber` for streaming responses
- `normalize_tool_schema()` handles both OpenAI tool formats (with and without `function` wrapper)

#### Plugin Discovery (`plugins/memory/__init__.py`)

**Two scan locations** (bundled takes precedence on name collisions):
1. Bundled providers: `plugins/memory/<name>/` (shipped with hermes-agent)
2. User-installed providers: `$HERMES_HOME/plugins/<name>/`

**Provider Detection Heuristic** (`_is_memory_provider_dir`): Reads first 8KB of `__init__.py` and checks for `register_memory_provider` or `MemoryProvider` strings. Cheap text scan, no import needed.

**Loading Strategy** (`_load_provider_from_dir`):
1. Try `register(ctx)` pattern first -- the standard plugin registration API via `_ProviderCollector` fake context
2. Fallback: find a `MemoryProvider` subclass in the module and instantiate it directly
3. Handles relative imports via synthetic parent package registration (`_register_synthetic_package`)
4. Pre-registers submodules for relative import support (e.g., `from .store import MemoryStore`)

**CLI Command Discovery** (`discover_plugin_cli_commands`):
Only loads CLI registration for the ACTIVE memory provider (read from `memory.provider` in config.yaml). Looks for `register_cli(subparser)` function in the plugin's `cli.py`. Lightweight scan that does not import the full plugin module. Returns at most one command dict.

**Active Provider Selection**: `_get_active_memory_provider()` reads `memory.provider` from config.yaml. Only ONE provider can be active at a time.

#### Built-in MemoryStore (`tools/memory_tool.py`)

The built-in memory system maintains two parallel files:
- `MEMORY.md` -- agent's personal notes and observations (environment facts, project conventions, tool quirks)
- `USER.md` -- what the agent knows about the user (preferences, communication style, expectations, workflow habits)

**Two parallel states**:
1. `_system_prompt_snapshot` -- frozen at `load_from_disk()` time, used for system prompt injection. NEVER mutated mid-session. Keeps prefix cache stable.
2. `memory_entries` / `user_entries` -- live state, mutated by tool calls, persisted to disk immediately.

**Entry format**: Delimiter `§` (section sign). Entries can be multiline. Character limits (not tokens) because char counts are model-independent.

**Security**: Entries scanned for injection/exfiltration patterns via `scan_for_threats(content, scope="strict")` at both write time and load time. At load time, poisoned entries are replaced with `[BLOCKED: ...]` placeholders in the snapshot (the original stays in live state so the user can see and remove it).

**Drift Detection** (`_detect_external_drift`): Detects when external tools (patch tool, shell append, manual edit, sister-session write) modified the memory file. Two signals: (1) round-trip mismatch, (2) entry-size overflow. When detected, a `.bak.<timestamp>` snapshot is saved and the mutation is refused to prevent silent data loss.

**Consolidation Failure Budget**: `_consolidation_failures` tracks consecutive failures per turn. After repeated failures, the tool instructs the model to stop retrying and continue with its reply.

### Key Constants/Thresholds
- `ENTRY_DELIMITER = "\n§\n"` -- section sign delimiter
- `_SYNC_DRAIN_TIMEOUT_S = 5.0` -- timeout for sync queue drain at shutdown
- Memory char limits: configurable per target (memory vs user)
- Threat scan scope: `"strict"` (broadest pattern set)
- `_ProviderCollector` -- fake plugin context for `register()` pattern
- `_USER_NAMESPACE = "_hermes_user_memory"` -- synthetic parent package for user-installed plugins

### Connection to Self-Learning
The memory provider architecture is the **extensible persistence layer** for self-learning:

1. **Built-in dual-store** (MEMORY.md + USER.md) provides the agent's core learning: facts, preferences, project conventions, and user profile. The frozen snapshot pattern means learned knowledge enters every session but does not change the prompt mid-conversation.

2. **External providers** (Honcho, Hindsight, Mem0) can add sophisticated recall mechanisms (embeddings, knowledge graphs, conversation summarization) that go beyond the built-in flat-file approach. The lifecycle hooks (on_pre_compress, on_memory_write, on_delegation) let external providers observe and learn from the agent's activities.

3. **Mirror writes** (`on_memory_write`) let external providers shadow the built-in memory system. When the agent writes to MEMORY.md, the external provider gets notified and can store its own representation. This creates a unified learning signal regardless of which memory backend is active.

4. **Plugin discovery** makes the system open -- anyone can create a `$HERMES_HOME/plugins/<name>/` directory with a MemoryProvider implementation and activate it via config. The bundled-takes-precedence policy prevents user plugins from accidentally shadowing core functionality.

---

## 7. User Profile System (USER.md)

### Files
- `tools/memory_tool.py` (lines 674-681, 189, 199, 284, 615-626) -- USER.md storage, rendering, and format_for_system_prompt
- `agent/system_prompt.py` (lines 426-435) -- USER.md injection into volatile tier
- `agent/prompt_builder.py` (line 126+) -- MEMORY_GUIDANCE constant referencing user profile

### How It Works

**Storage**: USER.md lives at `$HERMES_HOME/memories/USER.md` alongside MEMORY.md. Same entry delimiter (`§`), same file format, same read/write mechanics. The `MemoryStore._path_for(target)` method routes `target="user"` to `USER.md` and everything else to `MEMORY.md`.

**Rendering** (`_render_block`, memory_tool.py:664):
When `target == "user"`, the header reads:
```
══════════════════════════════════════════════
USER PROFILE (who the user is) [X% — N/M chars]
══════════════════════════════════════════════
<entries joined by § delimiter>
```

This contrasts with the memory block header:
```
══════════════════════════════════════════════
MEMORY (your personal notes) [X% — N/M chars]
══════════════════════════════════════════════
```

**System Prompt Injection** (system_prompt.py:426-435):
USER.md is in the **volatile tier** of the system prompt. It is included when `agent._user_profile_enabled` is True (separate from `agent._memory_enabled`). Both use the same `format_for_system_prompt()` method but different target keys ("user" vs "memory").

```python
if agent._user_profile_enabled:
    user_block = agent._memory_store.format_for_system_prompt("user")
    if user_block:
        volatile_parts.append(user_block)
```

**Behavioral Guidance** (from `MEMORY_GUIDANCE` in prompt_builder.py):
The system prompt instructs the agent on the distinction between the two stores:
- MEMORY.md is for the agent's own notes (environment facts, project conventions, tool quirks, things learned)
- USER.md is for what the agent knows about the user (preferences, communication style, expectations, workflow habits)

The guidance explicitly tells the agent NOT to save task progress, session outcomes, or completed-work logs to either store -- those belong in session_search (episodic memory).

**Same Operations, Same Limits**: USER.md uses the exact same `add()`, `replace()`, `remove()`, and `batch()` operations as MEMORY.md. It has its own `user_char_limit` (configurable, separate from `memory_char_limit`). The same drift detection, file locking, atomic writes, duplicate rejection, and threat scanning apply.

**Frozen Snapshot Pattern**: Like MEMORY.md, USER.md content is frozen at `load_from_disk()` time. Mid-session writes persist to disk immediately but do NOT change the system prompt snapshot. The snapshot refreshes on the next session start. This preserves prefix cache stability.

### Key Constants/Thresholds
- `user_char_limit` -- configurable character limit for USER.md (separate from memory_char_limit)
- Same `ENTRY_DELIMITER = "\n§\n"`
- Same threat scanning at `"strict"` scope
- Same drift detection and backup mechanisms

### Connection to Self-Learning
USER.md is the **personalization layer** of the self-learning system. While MEMORY.md stores learned facts about the environment and projects, USER.md stores learned facts about the human. Over time, the agent builds a profile of:
- Communication preferences (verbose vs. concise, formal vs. casual)
- Technical skill level and domain expertise
- Workflow habits and tool preferences
- Expectations and quality standards

This separation matters because user profiles are more durable than project memory. A user's communication style stays constant across projects, while project conventions change. The dual-store design lets the agent carry user knowledge into new projects while starting with fresh project memory.

The `_user_profile_enabled` flag being separate from `_memory_enabled` means operators can run the agent with user profiling disabled (e.g., for privacy-sensitive deployments) while keeping MEMORY.md active, or vice versa.

---

## 8. Skill Hub & Distribution (skills_hub.py)

### Files
- `hermes_cli/skills_hub.py` (1998 lines) -- Full Skills Hub CLI with search, install, publish, audit, snapshot workflows
- `agent/skill_preprocessing.py` (145 lines) -- Template variable substitution and inline shell (covered in Section 3)
- `agent/prompt_builder.py` -- Skills injection into system prompt (covered in Section 4)

### How It Works

**Skills Hub** (`skills_hub.py`) is a comprehensive CLI for discovering, installing, inspecting, auditing, and publishing skills. It implements a full package-manager-like workflow with security scanning and trust levels.

**Core Commands**:
- `do_search(query)` -- Search skills across configured registries
- `do_browse()` -- Browse available skills by category
- `do_install(name_or_url)` -- Install a skill with quarantine-first security pipeline
- `do_inspect(name)` -- Show detailed skill metadata and content
- `do_list()` -- List installed skills
- `do_check()` -- Verify installed skills for issues
- `do_update()` -- Update installed skills
- `do_audit()` -- Security audit of installed skills
- `do_uninstall(name)` -- Remove an installed skill
- `do_publish(name)` -- Publish a skill to a registry
- `do_snapshot_export()` / `do_snapshot_import()` -- Export/import skill snapshots for portability
- `do_tap(url)` -- Add a custom skill registry (like Homebrew taps)

**Install Pipeline** (security-first):
1. **Fetch** -- Download skill from registry or URL
2. **Quarantine** -- Place in quarantine directory, NOT in active skills
3. **Security Scan** -- Automated security analysis of skill content
4. **Confirm** -- User confirmation before activation
5. **Install** -- Move from quarantine to active skills directory

**Trust Levels**:
- `builtin` -- Skills shipped with hermes-agent (highest trust)
- `trusted` -- Skills from verified/official sources
- `community` -- Skills from community registries (lowest trust, most scrutiny)

**Source Router** (registry resolution):
Skills can be installed from multiple registries, resolved in priority order:
- `hermes-index` -- official Hermes skill index
- `official` -- official registry
- `github` -- GitHub repositories
- `clawhub` -- ClaWhub registry
- `claude-marketplace` -- Claude marketplace
- `lobehub` -- LobeHub registry
- `browse-sh` -- Browse.sh registry

**Snapshot Export/Import**:
Skills can be exported as portable snapshots and imported on other machines. This enables skill sharing and backup/restore workflows.

**Skill Audit** (`do_audit`):
Security audit of installed skills checks for:
- Suspicious patterns in skill content (injection attempts, credential access)
- Inline shell commands (`` !`cmd` `` -- requires explicit opt-in per Section 3)
- File system access patterns
- External URL references

### Key Constants/Thresholds
- Trust levels: `builtin`, `trusted`, `community`
- Quarantine directory used as staging area before installation
- Registry priority order for source resolution
- Security scan patterns for audit

### Connection to Self-Learning
The Skills Hub is the **knowledge distribution layer** of the self-learning system:

1. **Skill Discovery** enables agents to find and install specialized knowledge. When the agent encounters a new domain (e.g., Kubernetes, Terraform, specific API), the Skills Hub provides a marketplace to acquire relevant skills rather than learning from scratch.

2. **Quarantine-First Security** prevents malicious skills from corrupting the agent's behavior. Since skills are injected directly into the system prompt (see Section 4), a compromised skill could hijack the agent's behavior. The quarantine + scan + confirm pipeline ensures skills are vetted before activation.

3. **Skill Publishing** creates a feedback loop: agents (or their users) can publish skills learned from experience, making them available to the community. This is collective learning -- one agent's hard-won workflow becomes another agent's starting point.

4. **Snapshots** enable knowledge portability. An agent's entire skill library (its accumulated domain expertise) can be exported and imported, transferring learned capabilities between machines or profiles.

5. **Trust Levels** create a graduated learning system: built-in skills provide baseline competence, official skills add curated expertise, and community skills offer long-tail domain knowledge with appropriate trust boundaries.

The Skills Hub transforms skills from static configurations into a living ecosystem where knowledge flows between agents, users, and registries. Combined with the skill preprocessing (Section 3) that makes skills dynamic at runtime, and the prompt assembly (Section 4) that injects them into every conversation, the Skills Hub completes the lifecycle: create -> publish -> discover -> install -> preprocess -> inject -> use -> update -> republish.

---

## Cross-Cutting Architecture Summary

The eight subsystems documented above form a coherent self-learning architecture:

| Layer | Subsystem | Role |
|-------|-----------|------|
| **Episodic Memory** | Session Search (FTS5) | Long-term conversation recall via full-text search |
| **Identity** | SOUL.md | Persistent agent personality across sessions |
| **Knowledge** | Skills + Preprocessing + Hub | Reusable domain expertise with runtime dynamism |
| **Orchestration** | System Prompt Assembly | Three-tier cache-friendly assembly of all learning signals |
| **Adaptation** | Context Engine + Coding Posture | Environmental awareness and behavior adaptation |
| **Persistence** | Memory Provider Architecture | Pluggable persistence with built-in + external providers |
| **Personalization** | User Profile (USER.md) | Learned user preferences and communication style |
| **Distribution** | Skill Hub & Registries | Knowledge sharing, discovery, and security-gated installation |

**Information Flow**:
1. User interacts with agent -> conversation stored in SQLite (Session Search)
2. Agent learns facts -> written to MEMORY.md/USER.md (Memory System)
3. Agent learns workflows -> saved as skills (Skill Hub)
4. Next session starts -> SOUL.md identity loaded, skills preprocessed, memory frozen into system prompt, context files discovered (Prompt Assembly)
5. Coding workspace detected -> operating brief injected, skill categories adapted (Coding Posture)
6. Context fills up -> engine compresses, prompt rebuilt with fresh memory (Context Engine)
7. External providers shadow all of this -> Honcho/Hindsight/Mem0 get lifecycle hooks (Memory Providers)

The design philosophy throughout is: **learn incrementally, persist durably, inject at session start, keep the prompt stable for cache efficiency**. Every subsystem writes to disk immediately but defers system prompt changes to the next session (or next compression event), trading freshness for the significant performance benefit of prefix cache stability.
