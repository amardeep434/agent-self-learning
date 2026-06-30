# Hermes Agent Self-Learning Mechanisms — Exhaustive Research

**Repository:** NousResearch/hermes-agent  
**Commit analyzed:** HEAD of main branch (cloned 2026-06-30)  
**Source path:** `/tmp/hermes-agent-study/`

---

## Table of Contents

1. [Background Review (Post-Turn Daemon)](#1-background-review-post-turn-daemon)
2. [Skill Library & Lifecycle Management](#2-skill-library--lifecycle-management)
3. [Memory System (Bounded File-Backed Stores)](#3-memory-system-bounded-file-backed-stores)
4. [Curator (Periodic Skill Maintenance)](#4-curator-periodic-skill-maintenance)
5. [Training Data Pipeline (Trajectory Generation)](#5-training-data-pipeline-trajectory-generation)
6. [Learning Graph (Visualization)](#6-learning-graph-visualization)
7. [External Memory Providers](#7-external-memory-providers)
8. [/learn Command (User-Triggered Skill Distillation)](#8-learn-command-user-triggered-skill-distillation)

---

## 1. Background Review (Post-Turn Daemon)

### What It Does

The **core self-learning mechanism** in Hermes Agent. After every N turns, the agent forks itself into a daemon thread that replays the conversation and asks "should any skill or memory be saved/updated?" The fork runs with a restricted tool whitelist (memory + skill management only), writes directly to the skill/memory stores, and reports a summary back to the user.

### How It Works (Code-Level)

**File:** `agent/background_review.py` (865 lines)

The mechanism is orchestrated across three files:

1. **Turn counting** (`agent/turn_context.py`, lines 275-301):
   ```python
   # Memory nudge counter
   agent._turns_since_memory += 1
   if agent._turns_since_memory >= agent._memory_nudge_interval:
       should_review_memory = True
       agent._turns_since_memory = 0
   ```

2. **Skill iteration counting** (`agent/turn_finalizer.py`, lines 436-441):
   ```python
   if (agent._skill_nudge_interval > 0
           and agent._iters_since_skill >= agent._skill_nudge_interval
           and "skill_manage" in agent.valid_tool_names):
       _should_review_skills = True
       agent._iters_since_skill = 0
   ```

3. **Spawn decision** (`agent/turn_finalizer.py`, lines 453-461):
   ```python
   if final_response and not interrupted and (_should_review_memory or _should_review_skills):
       agent._spawn_background_review(
           messages_snapshot=list(messages),
           review_memory=_should_review_memory,
           review_skills=_should_review_skills,
       )
   ```

4. **Fork execution** (`agent/background_review.py`, `_run_review_in_thread()`):
   - Creates a new `AIAgent` instance inheriting the parent's runtime (provider, model, API key, cached system prompt)
   - Sets `skip_memory=True` to prevent external memory plugins from being touched
   - Pins `_cached_system_prompt` from parent for prefix-cache reuse (26% cost reduction measured)
   - Sets `compression_enabled = False` to prevent the fork from rotating the parent's session
   - Installs a thread-level tool whitelist: only `memory` and `skill_manage` tools are allowed
   - Calls `review_agent.run_conversation()` with the review prompt + full conversation history
   - After completion, scans tool results for successful actions and surfaces a summary

### Review Prompts

Three prompt variants exist (defined as module-level constants):

- **`_MEMORY_REVIEW_PROMPT`**: Focus on user persona, desires, preferences, personal details, expectations about agent behavior. Save with memory tool if something stands out.

- **`_SKILL_REVIEW_PROMPT`**: The most detailed (100+ lines). Key instruction: "Be ACTIVE -- most sessions produce at least one skill update. A pass that does nothing is a missed learning opportunity, not a neutral outcome." Signals to look for:
  - User corrected style/tone/format/verbosity
  - User corrected workflow/approach/sequence
  - Non-trivial technique, fix, workaround emerged
  - A loaded skill turned out wrong/missing/outdated
  
  Preference order for updates:
  1. Update a currently-loaded skill (was in play this session)
  2. Update an existing umbrella skill
  3. Add a support file (`references/`, `templates/`, `scripts/`) under existing umbrella
  4. Create a new class-level umbrella skill (last resort)

  Explicit DO NOT capture list:
  - Environment-dependent failures (missing binaries, unconfigured credentials)
  - Negative claims about tools ("browser tools do not work")
  - Session-specific transient errors that resolved
  - One-off task narratives

- **`_COMBINED_REVIEW_PROMPT`**: Merged version when both memory and skill review fire on the same turn.

### Auxiliary Model Routing

`_resolve_review_runtime()` supports routing the review to a cheaper model via config:
```yaml
auxiliary:
  background_review:
    provider: openrouter
    model: anthropic/claude-3-haiku
```

When routed to a different model (cache cold anyway), the fork replays a **digest** instead of full history (`_digest_history()`): keeps recent 24 messages verbatim, collapses older turns into one synthetic user-role summary to minimize cold-written tokens.

### Data Flow

```
User turn N arrives
  → turn_context.py: increment _turns_since_memory (modulo interval)
  → turn completes, tool iterations counted
  → turn_finalizer.py: check _iters_since_skill >= _skill_nudge_interval
  → if either trigger fires AND final_response AND not interrupted:
      → spawn daemon thread
        → fork AIAgent (inherits runtime, cached prompt, session_id)
        → replay full conversation (or digest if routed to different model)
        → run review prompt with tool whitelist [memory, skill_manage]
        → writes land on disk immediately (MEMORY.md, USER.md, SKILL.md files)
        → scan tool results, build action summary
        → print "Self-improvement review: ..." to user
```

### Storage Format

- Skills: `~/.hermes/skills/<category>/<name>/SKILL.md` + `references/`, `templates/`, `scripts/`
- Memory: `~/.hermes/memories/MEMORY.md` (agent notes) and `~/.hermes/memories/USER.md` (user profile)
- Usage telemetry: `~/.hermes/skills/.usage.json`

### When It Triggers

- **Memory review**: Every `_memory_nudge_interval` user turns (default: 10)
- **Skill review**: Every `_skill_nudge_interval` tool iterations (default: 10)
- **Combined review**: When both fire on the same turn
- **Gates**: Only fires if `final_response` is truthy AND the turn was not `interrupted`

---

## 2. Skill Library & Lifecycle Management

### What It Does

A persistent, file-backed collection of reusable knowledge organized as `SKILL.md` files. Skills encode "how to do this class of task for this user" -- class-level instructions and experiential knowledge that compound across sessions. Each skill is a complete package with support directories.

### How It Works (Code-Level)

**File:** `tools/skill_usage.py` (full module)

**Skill structure on disk:**
```
~/.hermes/skills/
├── <category>/
│   └── <skill-name>/
│       ├── SKILL.md           # Primary instruction document
│       ├── references/        # Session-specific detail, API docs excerpts
│       ├── templates/         # Starter files to copy/modify
│       ├── scripts/           # Re-runnable verification/fixture scripts
│       └── assets/            # Static assets
├── .usage.json                # Telemetry sidecar
├── .curator_state             # Curator scheduler state
└── .archive/                  # Archived (not deleted) skills
```

**Usage telemetry sidecar** (`.usage.json`):
```json
{
  "skill-name": {
    "use_count": 5,
    "view_count": 12,
    "patch_count": 3,
    "last_used_at": "2026-06-15T10:30:00Z",
    "last_viewed_at": "2026-06-28T14:00:00Z",
    "last_patched_at": "2026-06-20T09:15:00Z",
    "last_activity_at": "2026-06-28T14:00:00Z",
    "created_at": "2026-05-01T08:00:00Z",
    "created_by": "agent",
    "state": "active",
    "pinned": false
  }
}
```

**Lifecycle states:**
- `active` (default) -- skill is live and discoverable
- `stale` -- unused > `stale_after_days` (default: 30 days)
- `archived` -- unused > `archive_after_days` (default: 90 days); moved to `.archive/`

**Counter bumping** happens in the existing skill tools:
- `skill_view` → increments `view_count`
- `skill_manage` (patch/edit) → increments `patch_count`
- Skill loading/use → increments `use_count`

All counter bumps are best-effort (failures log at DEBUG, never break tool calls). Atomic writes via `tempfile + os.replace`. File locking with `fcntl` (Unix) or `msvcrt` (Windows).

**Protected skills:**
- Bundled skills (shipped with Hermes) -- curator cannot edit
- Hub-installed skills (installed via `hermes skills install`) -- curator cannot edit
- `PROTECTED_BUILTIN_SKILLS = {"plan"}` -- never archived, backs `/plan` slash command

**Pinned skills:**
- User marks via `hermes curator pin <skill-name>`
- Bypass all auto-transitions (stale/archive)
- CAN still be patched/improved by agent -- pin only blocks deletion/consolidation

### Data Flow

```
Session starts
  → skill_usage.load_usage() reads .usage.json
  → skills_list tool shows available skills with descriptions
  → user loads skill via /skill-name or skill_view
    → bump view_count, update last_viewed_at
  → agent uses skill during work
    → bump use_count, update last_used_at
  → background review fires
    → may patch existing skill (bump patch_count)
    → may create new skill (created_by: "agent")
    → may add support file (references/, templates/, scripts/)
```

### Storage Format

SKILL.md frontmatter:
```yaml
---
name: my-skill-name
description: One sentence, <=60 chars, ends with period.
version: 0.1.0
author: Hermes
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Relevant, Tags]
    category: development
    related_skills: [other-skill, another-skill]
---
```

### When It Triggers

- **Creation**: Background review decides a new class-level umbrella is needed
- **Patching**: Background review finds a loaded skill was wrong/outdated
- **User-initiated**: `/learn` command distills a workflow into a skill
- **State transitions**: Curator applies deterministic lifecycle (active→stale→archived)

---

## 3. Memory System (Bounded File-Backed Stores)

### What It Does

Two bounded, file-backed stores that persist the agent's knowledge across sessions. `MEMORY.md` stores the agent's operational notes (environment facts, project conventions, tool quirks). `USER.md` stores what the agent knows about the user (preferences, communication style, expectations). Both are injected as a frozen snapshot into the system prompt at session start.

### How It Works (Code-Level)

**File:** `tools/memory_tool.py`

**Key design decisions:**

1. **Frozen snapshot pattern**: Memory content is injected into the system prompt at session start. Mid-session writes update the files on disk immediately but do NOT change the running system prompt. This preserves the prefix cache for the entire session (the prompt bytes stay identical). Fresh content becomes visible on the next session start.

2. **Entry delimiter**: `\n§\n` (section sign). Entries can be multiline.

3. **Character limits** (not tokens -- model-independent):
   - `MEMORY.md`: 2200 characters
   - `USER.md`: 1375 characters

4. **Single tool interface**: One `memory` tool with `action` parameter:
   - `add` -- append a new entry
   - `replace` -- find and replace using short unique substring matching
   - `remove` -- delete an entry matching a substring

5. **Security scanning**: Before any write, content is scanned for injection/exfiltration patterns via `tools/threat_patterns.py` (strict scope). Blocks prompt injection attempts that could persist across sessions.

6. **File operations**: Atomic writes via `atomic_replace()`. File locking with `fcntl`/`msvcrt`.

**Storage location:** `~/.hermes/memories/MEMORY.md` and `~/.hermes/memories/USER.md`

### Data Flow

```
Session start:
  → Read MEMORY.md + USER.md from disk
  → Inject as frozen snapshot into system prompt
  → Prompt is cached (prefix cache)

During session:
  → Agent calls memory tool (add/replace/remove)
  → File updated on disk immediately
  → System prompt unchanged (cache preserved)
  → Tool response shows current live state

Background review:
  → Fork calls memory tool
  → Writes land on disk
  → Parent session prompt still unchanged
  → Summary shown: "Memory updated" / "User profile updated"

Next session:
  → Fresh read from disk captures all accumulated writes
```

### Storage Format

`MEMORY.md`:
```markdown
Project uses Kotlin + Ktor backend with JWT auth
§
User prefers concise responses without excessive explanation
§
The CI pipeline requires REQUIRE_DB=true for integration tests
```

`USER.md`:
```markdown
Name: Amardeep. Prefers direct answers. Works on VyapaarLink B2B wholesale app.
§
Communication style: technical, no hand-holding. Gets frustrated with verbosity.
```

### When It Triggers

- **Background review** (every 10 turns): Evaluates whether user revealed persona/preferences worth saving
- **Agent-initiated during work**: Agent may explicitly call memory tool if it encounters something worth remembering
- **User-initiated**: User can instruct agent to remember something

---

## 4. Curator (Periodic Skill Maintenance)

### What It Does

A background skill library maintenance system that runs periodically (default: every 7 days) when the agent is idle. It has two modes: (1) deterministic automatic transitions that move skills through lifecycle states based on inactivity timestamps, and (2) an optional LLM-driven consolidation pass that merges overlapping skills into class-level umbrellas.

### How It Works (Code-Level)

**File:** `agent/curator.py` (1977 lines)

**Configuration** (`~/.hermes/config.yaml`):
```yaml
curator:
  enabled: true                # default: true
  interval_hours: 168          # default: 7 days
  min_idle_hours: 2            # default: 2 hours idle before running
  stale_after_days: 30         # default: 30 days
  archive_after_days: 90       # default: 90 days
  consolidate: false           # default: false (opt-in for LLM pass)
  prune_builtins: true         # default: true (built-ins become curation candidates)
```

**State persistence** (`~/.hermes/skills/.curator_state`):
```json
{
  "last_run_at": "2026-06-23T10:00:00Z",
  "last_run_duration_seconds": 45,
  "last_run_summary": "marked_stale: 2, archived: 1",
  "last_run_summary_shown_at": null,
  "last_report_path": "~/.hermes/logs/curator/20260623-100000/REPORT.md",
  "paused": false,
  "run_count": 12
}
```

#### 4a. Automatic Transitions (Deterministic, No LLM)

**Function:** `apply_automatic_transitions()`

Walks every curator-managed skill and moves lifecycle state based on activity timestamps:

```python
stale_cutoff = now - timedelta(days=get_stale_after_days())     # 30 days
archive_cutoff = now - timedelta(days=get_archive_after_days()) # 90 days

# For each skill:
anchor = last_activity_at or created_at or now

if anchor <= archive_cutoff and current != STATE_ARCHIVED:
    archive_skill(name)                    # move to .archive/
elif anchor <= stale_cutoff and current == STATE_ACTIVE:
    set_state(name, STATE_STALE)           # mark stale
elif anchor > stale_cutoff and current == STATE_STALE:
    set_state(name, STATE_ACTIVE)          # reactivate (used again)
```

**Protection rules:**
- Pinned skills: never touched
- Cron-referenced skills: never auto-transitioned (scheduler depends on them)
- Never-used skills (use_count == 0): grace floor -- don't archive until at least `stale_after_days` old
- Protected builtins (`plan`): never archived
- Hub-installed skills: never pruned regardless of config

#### 4b. LLM Consolidation Pass (Opt-In)

**Function:** Uses `CURATOR_REVIEW_PROMPT` to spawn a forked AIAgent

Only runs when `curator.consolidate: true` is set in config (default: OFF).

The consolidation prompt is extremely detailed (150+ lines). Key instructions:

- **Goal**: Build a library of CLASS-LEVEL skills, not hundreds of narrow one-session-one-skill entries
- **Process**: Identify PREFIX CLUSTERS (skills sharing domain keywords), then merge siblings into umbrellas
- **Three consolidation methods**:
  1. Merge into existing umbrella (patch it to absorb siblings)
  2. Create new umbrella skill (when no member is broad enough)
  3. Demote to support files (`references/`, `templates/`, `scripts/`)
- **Hard rules**: Never delete (only archive), never touch bundled/hub/pinned, respect package integrity
- **Output**: Human-readable summary + structured YAML block (`consolidations` and `prunings` lists)
- **Expected**: "If you end the pass with fewer than 10 archives, you stopped too early"

**Report generation** (`_write_run_report()`):
- Writes `run.json` + `REPORT.md` per curator execution
- Stored in `~/.hermes/logs/curator/{YYYYMMDD-HHMMSS}/`
- Classifies removed skills as consolidated vs pruned (`_classify_removed_skills()`)

### Data Flow

```
Agent idle for 2+ hours AND last_run_at > 7 days ago
  → should_run_now() returns True
  → maybe_run_curator() spawns background task
  
  Phase 1 (always): apply_automatic_transitions()
    → Walk all curator-managed skills
    → Move active→stale (30d unused)
    → Move stale→archived (90d unused, move to .archive/)
    → Reactivate stale→active (if used again)
    
  Phase 2 (if consolidate=true): spawn forked AIAgent
    → Build candidate list (exclude bundled, hub, pinned, protected)
    → Run CURATOR_REVIEW_PROMPT with skill_manage + skills_list tools
    → LLM identifies clusters, merges overlapping skills
    → Archives absorbed siblings
    → Writes run report
    
  → Update .curator_state with run timestamp + summary
```

### When It Triggers

- **Gate 1**: `curator.enabled == True` (default: yes)
- **Gate 2**: Not paused (`hermes curator pause`)
- **Gate 3**: `last_run_at` older than `interval_hours` (default: 7 days)
- **Gate 4**: Agent idle for `min_idle_hours` (default: 2 hours)
- **First-run**: Seeds `last_run_at` to now and defers by one full interval
- **Manual**: `hermes curator run` (with `--dry-run` for preview)

---

## 5. Training Data Pipeline (Trajectory Generation)

### What It Does

A manual (not auto-triggered) pipeline for generating fine-tuning data from agent sessions. Runs the agent across batches of prompts in parallel, captures full conversation trajectories, then compresses them to fit within token budgets for model training. This is how NousResearch trains the Hermes models themselves -- NOT a user-facing self-learning feature.

### How It Works (Code-Level)

**Files:**
- `batch_runner.py` -- parallel batch processing of prompts through the agent
- `trajectory_compressor.py` -- post-processing to fit trajectories within token budget

#### batch_runner.py

- Loads dataset from JSONL file
- Processes prompts in parallel using `multiprocessing.Pool`
- Each worker instantiates a full `AIAgent` and runs a conversation
- Saves trajectories in `from/value` pair format (standard fine-tuning JSONL)
- Checkpointing for fault tolerance and resumption
- Aggregates tool usage statistics across all batches

```bash
python batch_runner.py --dataset_file=data.jsonl --batch_size=10 --run_name=my_run
python batch_runner.py --dataset_file=data.jsonl --run_name=my_run --resume
python batch_runner.py --dataset_file=data.jsonl --distribution=image_gen
```

**Toolset distributions**: Different training datasets can use different tool configurations to generate diverse training data (e.g., `image_gen` distribution for image generation tasks).

#### trajectory_compressor.py

Post-processes completed trajectories to compress within a target token budget while preserving training signal quality.

**Compression strategy:**
1. Protect first turns (system, human, first GPT response, first tool call)
2. Protect last N turns (final actions and conclusions)
3. Compress MIDDLE turns only, starting from 2nd tool response
4. Compress only as much as needed to fit under target
5. Replace compressed region with a single human summary message
6. Keep remaining tool calls intact (model continues working after summary)

```bash
python trajectory_compressor.py --input=data/my_run
python trajectory_compressor.py --input=data/trajectories.jsonl --target_max_tokens=16000
python trajectory_compressor.py --input=data/trajectories.jsonl --sample_percent=15
```

**Auxiliary model routing**: The compressor uses an LLM to generate summaries of compressed regions. Supports routing to different models and respects temperature contracts.

### Data Flow

```
Dataset (JSONL with prompts)
  → batch_runner.py: parallel processing
    → Each prompt → full AIAgent conversation
    → Trajectory saved as from/value JSONL
    → Tool stats aggregated
    → Checkpoints for resumption
  → trajectory_compressor.py: post-processing
    → Load trajectories
    → Count tokens per trajectory
    → If over budget: compress middle turns
    → LLM generates summary of compressed region
    → Output: compressed JSONL ready for fine-tuning
```

### Storage Format

Raw trajectory (JSONL, one entry per conversation):
```json
{
  "conversations": [
    {"from": "system", "value": "You are Hermes..."},
    {"from": "human", "value": "User prompt..."},
    {"from": "gpt", "value": "Agent response with tool calls..."},
    {"from": "tool", "value": "Tool result..."},
    {"from": "gpt", "value": "Final response..."}
  ],
  "tool_stats": {"terminal": {"count": 3, "success": 3, "failure": 0}},
  "metadata": {"run_name": "my_run", "timestamp": "..."}
}
```

### When It Triggers

**Never automatically.** This is a developer-facing pipeline for NousResearch model training. It requires:
- A dataset file of prompts
- Manual invocation via CLI
- Explicit configuration of model/provider for the compression step

---

## 6. Learning Graph (Visualization)

### What It Does

Builds a graph payload for the desktop "Learning Panel" that visualizes what the agent has learned over time. Shows skill-to-skill relationships, memory-to-skill connections, usage statistics, and cluster organization. Makes the self-learning process visible and inspectable to the user.

### How It Works (Code-Level)

**File:** `agent/learning_graph.py` (321 lines)

**`build_learning_graph()`** -- the main entry point:

1. **Collect skill nodes**: Scans all SKILL.md files across skill roots (base + profile)
2. **Filter to learned skills**: Only includes skills that are NOT base-installed AND show real learning signal (agent-created or `use_count > 0`)
3. **Build skill-to-skill edges**: From `related_skills` frontmatter declarations (undirected, both endpoints must exist)
4. **Load memory cards**: Splits `MEMORY.md` and `USER.md` on `§` delimiters, each chunk becomes a graph node
5. **Build memory-to-skill edges**: Lexical overlap scoring (skill name in text = +6 score, token intersection)
6. **Assemble clusters**: Group by category, add "memory" cluster

**Node types:**
- `kind: "skill"` -- with id, label, timestamp, category, useCount, state, createdBy, pinned
- `kind: "memory"` -- with id (format: `memory:{source}:{idx}`), label (first line truncated), memorySource, timestamp

**Edge derivation for memory→skill:**
```python
# For each memory card, score against all learned skills:
if skill_name_lower in text:
    score += 6  # exact name match
score += len(tokens & text_tokens)  # token intersection
# Keep top 4 scoring skills per memory card
```

**Statistics computed:**
- `nodes`, `related_edges`, `edges_per_node`
- `linked_nodes`, `isolated_pct` (% of nodes with zero edges)
- `categories` (count), `agent_created` (count), `used` (count)
- `memory_nodes`, `memory_skill_edges`, `learned_skills`
- `top_categories` (top 8 by skill count)

### Data Flow

```
Desktop UI requests learning graph
  → build_learning_graph()
    → Scan ~/.hermes/skills/ for SKILL.md files
    → Load .usage.json for telemetry data
    → Filter to agent-created or used skills (exclude base)
    → Build skill↔skill edges from related_skills frontmatter
    → Read MEMORY.md + USER.md, split on §
    → Score memory→skill edges via lexical overlap
    → Compute cluster groupings and statistics
  → Return JSON payload to desktop panel
```

### Storage Format

Return value (JSON):
```json
{
  "nodes": [
    {"id": "my-skill", "label": "my-skill", "kind": "skill", "category": "dev", "useCount": 5, ...},
    {"id": "memory:memory:0", "label": "First memory entry...", "kind": "memory", ...}
  ],
  "edges": [
    {"source": "skill-a", "target": "skill-b"},
    {"source": "memory:memory:0", "target": "skill-a"}
  ],
  "clusters": [{"category": "dev", "count": 12}, ...],
  "memory": [{"source": "memory", "timestamp": ..., "title": "...", "body": "..."}],
  "stats": {"nodes": 25, "related_edges": 8, "memory_nodes": 5, ...}
}
```

### When It Triggers

On-demand when the desktop Learning Panel is opened. Not part of the automatic learning loop -- purely a visualization layer over the data accumulated by mechanisms 1-4.

---

## 7. External Memory Providers

### What It Does

Pluggable external memory backends that augment the built-in MEMORY.md/USER.md system. Providers implement semantic search, dialectic user modeling, cross-session recall, and other advanced memory patterns. Only ONE external plugin provider is allowed at a time.

### How It Works (Code-Level)

**File:** `agent/memory_manager.py` (1080 lines)

**`MemoryManager` class:**
- Orchestrates the memory provider lifecycle
- Delegates to registered providers
- Only ONE external plugin provider allowed (rejects second with warning)
- Background executor for non-blocking sync operations
- Shutdown timeout: 5 seconds for in-flight work to drain

**Key integration points in `run_agent.py`:**
```python
# System prompt injection
prompt_parts.append(self._memory_manager.build_system_prompt())

# Pre-turn: prefetch relevant context
context = self._memory_manager.prefetch_all(user_message)

# Post-turn: sync the completed turn
self._memory_manager.sync_all(user_msg, assistant_response)
self._memory_manager.queue_prefetch_all(user_msg)
```

**Available providers** (from `plugins/memory/`):

1. **Honcho** (`plugins/memory/honcho/__init__.py`):
   - Dialectic user modeling with "peer cards"
   - Semantic search over past sessions
   - Reasoning layer that synthesizes relevant context
   - Each session generates structured user model updates

2. **Mem0** -- personal memory layer with semantic recall
3. **Hindsight** -- retrospective analysis of conversations
4. **SuperMemory** -- enhanced memory with categorization

**Provider interface** (`agent/memory_provider.py`):
- `get_tool_schemas()` -- expose provider-specific tools to the agent
- `build_system_prompt()` -- inject provider context into system prompt
- `prefetch_all(query)` -- pre-load relevant memories before turn
- `sync_all(user_msg, assistant_response)` -- persist turn data
- `on_session_end()` -- cleanup and final flush

**Background review isolation**: When the background review fork runs, it sets `skip_memory=True` to prevent the fork from:
- Leaking the review harness prompt into user's external memory namespace
- Triggering prefetch/sync on external providers with artificial conversation data
- Side-effecting the user's real Honcho/Mem0/etc. session

### Data Flow

```
Session start:
  → MemoryManager initialized
  → Provider's build_system_prompt() injects context
  → prefetch_all(first_message) loads relevant memories

Each turn:
  → sync_all(user_msg, response) persists the exchange
  → queue_prefetch_all(user_msg) prepares for next turn

Session end:
  → on_session_end() flushes buffers
  → shutdown_all() with 5s drain timeout
```

### When It Triggers

- **Every turn**: sync + prefetch (async, non-blocking)
- **Session boundaries**: startup context injection, end-of-session flush
- **NOT during background review**: fork explicitly opts out

---

## 8. /learn Command (User-Triggered Skill Distillation)

### What It Does

A user-facing command that explicitly tells the agent to distill a workflow, technique, or external knowledge source into a reusable SKILL.md. The agent gathers material from whatever the user points it at (files, URLs, conversation history, pasted text) and authors a skill following strict authoring standards.

### How It Works (Code-Level)

**File:** `agent/learn_prompt.py` (135 lines)

**`build_learn_prompt(user_request)`** builds a complete instruction that the agent executes as a normal turn:

1. **Gather material**: Agent uses existing tools (`read_file`, `search_files`, `web_extract`, conversation history)
2. **Author ONE SKILL.md**: Via `skill_manage` tool with `action="create"`
3. **Follow authoring standards**: Embedded `_AUTHORING_STANDARDS` constant (96 lines of strict rules)

**Authoring standards enforced:**
- `name`: lowercase-hyphenated, <=64 chars
- `description`: ONE sentence, <=60 characters (system-prompt skill index truncates at 60)
- `version`: 0.1.0
- `author`: always literal "Hermes" (never environment-derived -- privacy protection)
- `platforms`: only if OS-bound primitives used
- Body section order: Title → When to Use → Prerequisites → How to Run → Quick Reference → Procedure → Pitfalls → Verification
- Hermes-tool framing: reference tools by name (`terminal`, `read_file`, etc.)
- Quality: exact commands from source, ~100-200 lines, no router/index skills

**Default behavior when no source specified:**
```python
if not req:
    req = "the workflow we just went through in this conversation — review "
          "the steps taken and distill them into a reusable skill"
```

### Data Flow

```
User types: /learn <description of what to learn>
  → build_learn_prompt(user_request) constructs instruction
  → Agent receives instruction as normal turn
  → Agent gathers sources (read_file, web_extract, conversation)
  → Agent calls skill_manage(action="create", ...)
  → New skill written to ~/.hermes/skills/<category>/<name>/SKILL.md
  → Agent reports: skill name, category, one-line summary
```

### Storage Format

Output is a standard SKILL.md with full frontmatter and body sections, stored in the skill library alongside agent-created and bundled skills. The `.usage.json` sidecar is updated with `created_by: "agent"` and initial timestamps.

### When It Triggers

- **User-initiated only**: `/learn` command in CLI or gateway
- **Dashboard**: "Learn a skill" panel in desktop app
- **Background review may also create skills** -- but via the review mechanism, not /learn

---

## Summary: The Self-Learning Architecture

The self-learning system in Hermes Agent operates as a layered architecture:

| Layer | Mechanism | Trigger | Frequency | LLM Required |
|-------|-----------|---------|-----------|--------------|
| **Immediate** | Memory tool writes | During conversation | Any turn | No (tool call) |
| **Post-turn** | Background Review | Every 10 turns/iterations | ~Every 10 turns | Yes (fork) |
| **On-demand** | /learn command | User-initiated | Manual | Yes (same session) |
| **Periodic** | Curator (deterministic) | Every 7 days idle | Weekly | No |
| **Periodic** | Curator (consolidation) | Every 7 days idle (opt-in) | Weekly | Yes (aux model) |
| **Manual** | Trajectory pipeline | Developer-initiated | Never auto | Yes (compressor) |
| **Passive** | Learning Graph | Desktop panel opened | On-demand | No |
| **Per-turn** | External Memory Providers | Every turn | Continuous | Provider-dependent |

**Key design principles:**

1. **Prefix-cache preservation**: The frozen snapshot pattern ensures memory/skill updates never invalidate the running session's prompt cache (measured 26% cost reduction).

2. **Best-effort, never blocking**: All learning operations are daemon threads, background tasks, or async. Failures log at DEBUG and never break the user's conversation.

3. **Class-level over session-level**: The system aggressively consolidates narrow skills into broad umbrellas. The curator, background review prompts, and authoring standards all enforce this.

4. **Bounded storage**: Character limits (2200/1375), lifecycle transitions, and periodic curation prevent unbounded growth.

5. **User preference embedding in skills, not just memory**: When a user corrects the agent's approach, the fix goes into the SKILL that governs that task class -- so the next session starts already knowing, without needing to recall from memory.

6. **Negative-capture avoidance**: Explicit rules against capturing environment-dependent failures or negative tool claims as skills, preventing the agent from developing persistent self-imposed constraints that outlive the original problem.
