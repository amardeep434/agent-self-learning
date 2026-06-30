# 04 -- Prompts & Reflection System

This document is an exhaustive reference for the prompt templates, reflection
architecture, and write-approval mechanics that drive Hermes Agent's
self-learning loop. All code snippets, constants, and configuration values are
taken verbatim from two source files:

- `/tmp/hermes-agent/agent/background_review.py` (875 lines)
- `/tmp/hermes-agent/agent/learn_prompt.py` (136 lines)

---

## 1. Background Review Prompts

Three module-level string constants define the exact text the review fork
receives as its user message. The agent class (`AIAgent`) re-exports them as
class attributes for backward compatibility, but the canonical text lives in
`background_review.py`.

### 1.1 `_MEMORY_REVIEW_PROMPT`

Used when only the memory review trigger fires (`review_memory=True`,
`review_skills=False`). Its job is narrow: decide whether the user revealed
anything about themselves worth persisting.

```python
_MEMORY_REVIEW_PROMPT = (
    "Review the conversation above and consider saving to memory if appropriate.\n\n"
    "Focus on:\n"
    "1. Has the user revealed things about themselves — their persona, desires, "
    "preferences, or personal details worth remembering?\n"
    "2. Has the user expressed expectations about how you should behave, their work "
    "style, or ways they want you to operate?\n\n"
    "If something stands out, save it using the memory tool. "
    "If nothing is worth saving, just say 'Nothing to save.' and stop."
)
```

Key design notes:

- Two explicit focus areas: (1) persona/preferences/personal details,
  (2) behavioral expectations and work-style.
- The escape hatch is `"Nothing to save."` -- the fork must say exactly this
  and stop if nothing qualifies.
- No mention of skills at all; this prompt is pure memory-domain.

### 1.2 `_SKILL_REVIEW_PROMPT`

Used when only the skill review trigger fires (`review_memory=False`,
`review_skills=True`). This is the longest and most prescriptive of the three
prompts. Full verbatim text:

```python
_SKILL_REVIEW_PROMPT = (
    "Review the conversation above and update the skill library. Be "
    "ACTIVE — most sessions produce at least one skill update, even if "
    "small. A pass that does nothing is a missed learning opportunity, "
    "not a neutral outcome.\n\n"
    "Target shape of the library: CLASS-LEVEL skills, each with a rich "
    "SKILL.md and a `references/` directory for session-specific detail. "
    "Not a long flat list of narrow one-session-one-skill entries. This "
    "shapes HOW you update, not WHETHER you update.\n\n"
    "Signals to look for (any one of these warrants action):\n"
    "  • User corrected your style, tone, format, legibility, or "
    "verbosity. Frustration signals like 'stop doing X', 'this is too "
    "verbose', 'don't format like this', 'why are you explaining', "
    "'just give me the answer', 'you always do Y and I hate it', or an "
    "explicit 'remember this' are FIRST-CLASS skill signals, not just "
    "memory signals. Update the relevant skill(s) to embed the "
    "preference so the next session starts already knowing.\n"
    "  • User corrected your workflow, approach, or sequence of steps. "
    "Encode the correction as a pitfall or explicit step in the skill "
    "that governs that class of task.\n"
    "  • Non-trivial technique, fix, workaround, debugging path, or "
    "tool-usage pattern emerged that a future session would benefit "
    "from. Capture it.\n"
    "  • A skill that got loaded or consulted this session turned out "
    "to be wrong, missing a step, or outdated. Patch it NOW.\n\n"
    "Preference order — prefer the earliest action that fits, but do "
    "pick one when a signal above fired:\n"
    "  1. UPDATE A CURRENTLY-LOADED SKILL. Look back through the "
    "conversation for skills the user loaded via /skill-name or you "
    "read via skill_view. If any of them covers the territory of the "
    "new learning, PATCH that one first. It is the skill that was in "
    "play, so it's the right one to extend.\n"
    "  2. UPDATE AN EXISTING UMBRELLA (via skills_list + skill_view). "
    "If no loaded skill fits but an existing class-level skill does, "
    "patch it. Add a subsection, a pitfall, or broaden a trigger.\n"
    "  3. ADD A SUPPORT FILE under an existing umbrella. Skills can be "
    "packaged with three kinds of support files — use the right "
    "directory per kind:\n"
    "     • `references/<topic>.md` — session-specific detail (error "
    "transcripts, reproduction recipes, provider quirks) AND "
    "condensed knowledge banks: quoted research, API docs, external "
    "authoritative excerpts, or domain notes you found while working "
    "on the problem. Write it concise and for the value of the task, "
    "not as a full mirror of upstream docs.\n"
    "     • `templates/<name>.<ext>` — starter files meant to be "
    "copied and modified (boilerplate configs, scaffolding, a "
    "known-good example the agent can `reproduce with modifications`).\n"
    "     • `scripts/<name>.<ext>` — statically re-runnable actions "
    "the skill can invoke directly (verification scripts, fixture "
    "generators, deterministic probes, anything the agent should run "
    "rather than hand-type each time).\n"
    "     Add support files via skill_manage action=write_file with "
    "file_path starting 'references/', 'templates/', or 'scripts/'. "
    "The umbrella's SKILL.md should gain a one-line pointer to any "
    "new support file so future agents know it exists.\n"
    "  4. CREATE A NEW CLASS-LEVEL UMBRELLA SKILL when no existing "
    "skill covers the class. The name MUST be at the class level. "
    "The name MUST NOT be a specific PR number, error string, feature "
    "codename, library-alone name, or 'fix-X / debug-Y / audit-Z-today' "
    "session artifact. If the proposed name only makes sense for "
    "today's task, it's wrong — fall back to (1), (2), or (3).\n\n"
    "User-preference embedding (important): when the user expressed a "
    "style/format/workflow preference, the update belongs in the "
    "SKILL.md body, not just in memory. Memory captures 'who the user "
    "is and what the current situation and state of your operations "
    "are'; skills capture 'how to do this class of task for this "
    "user'. When they complain about how you handled a task, the "
    "skill that governs that task needs to carry the lesson.\n\n"
    "If you notice two existing skills that overlap, note it in your "
    "reply — the background curator handles consolidation at scale.\n\n"
    "Protected skills (DO NOT edit these):\n"
    "  • Bundled skills (shipped with Hermes, e.g. 'hermes-agent').\n"
    "  • Hub-installed skills (installed via 'hermes skills install').\n"
    "Pinned skills (marked via 'hermes curator pin') CAN be improved — "
    "pin only blocks deletion/archive/consolidation by the curator, not "
    "content updates. Patch them when a pitfall or missing step turns up, "
    "same as any other agent-created skill.\n"
    "If the only skills that need updating are protected, say\n"
    "'Nothing to save.' and stop.\n\n"
    "Do NOT capture (these become persistent self-imposed constraints "
    "that bite you later when the environment changes):\n"
    "  • Environment-dependent failures: missing binaries, fresh-install "
    "errors, post-migration path mismatches, 'command not found', "
    "unconfigured credentials, uninstalled packages. The user can fix "
    "these — they are not durable rules.\n"
    "  • Negative claims about tools or features ('browser tools do not "
    "work', 'X tool is broken', 'cannot use Y from execute_code'). These "
    "harden into refusals the agent cites against itself for months "
    "after the actual problem was fixed.\n"
    "  • Session-specific transient errors that resolved before the "
    "conversation ended. If retrying worked, the lesson is the retry "
    "pattern, not the original failure.\n"
    "  • One-off task narratives. A user asking 'summarize today's "
    "market' or 'analyze this PR' is not a class of work that warrants "
    "a skill.\n\n"
    "If a tool failed because of setup state, capture the FIX (install "
    "command, config step, env var to set) under an existing setup or "
    "troubleshooting skill — never 'this tool does not work' as a "
    "standalone constraint.\n\n"
    "'Nothing to save.' is a real option but should NOT be the "
    "default. If the session ran smoothly with no corrections and "
    "produced no new technique, just say 'Nothing to save.' and stop. "
    "Otherwise, act."
)
```

Structural breakdown of the skill review prompt:

| Section | Purpose |
|---------|---------|
| Opening bias-to-action | "Be ACTIVE" -- frames inaction as a missed opportunity |
| Library shape | Class-level skills with `references/`, not flat one-per-session |
| Signals (4 bullets) | Style corrections, workflow corrections, new techniques, stale skills |
| Preference order (1-4) | Update loaded skill > update umbrella > add support file > create new |
| Support file taxonomy | `references/`, `templates/`, `scripts/` with exact usage rules |
| User-preference embedding | Skills carry "how to do this for this user", not just memory |
| Protected skills | Bundled and hub-installed are read-only; pinned CAN be patched |
| Anti-pattern rules | 4 explicit categories of what NOT to save (see Section 4) |
| Escape hatch | "Nothing to save." only when genuinely nothing happened |

### 1.3 `_COMBINED_REVIEW_PROMPT`

Used when both triggers fire simultaneously (`review_memory=True`,
`review_skills=True`). This prompt merges the memory and skill domains into a
single instruction. Full verbatim text:

```python
_COMBINED_REVIEW_PROMPT = (
    "Review the conversation above and update two things:\n\n"
    "**Memory**: who the user is. Did the user reveal persona, "
    "desires, preferences, personal details, or expectations about "
    "how you should behave? Save facts about the user and durable "
    "preferences with the memory tool.\n\n"
    "**Skills**: how to do this class of task. Be ACTIVE — most "
    "sessions produce at least one skill update. A pass that does "
    "nothing is a missed learning opportunity, not a neutral outcome.\n\n"
    "Target shape of the skill library: CLASS-LEVEL skills with a rich "
    "SKILL.md and a `references/` directory for session-specific detail. "
    "Not a long flat list of narrow one-session-one-skill entries.\n\n"
    "Signals that warrant a skill update (any one is enough):\n"
    "  • User corrected your style, tone, format, legibility, "
    "verbosity, or approach. Frustration is a FIRST-CLASS skill "
    "signal, not just a memory signal. 'stop doing X', 'don't format "
    "like this', 'I hate when you Y' — embed the lesson in the skill "
    "that governs that task so the next session starts fixed.\n"
    "  • Non-trivial technique, fix, workaround, or debugging path "
    "emerged.\n"
    "  • A skill that was loaded or consulted turned out wrong, "
    "missing, or outdated — patch it now.\n\n"
    "Preference order for skills — pick the earliest that fits:\n"
    "  1. UPDATE A CURRENTLY-LOADED SKILL. Check what skills were "
    "loaded via /skill-name or skill_view in the conversation. If one "
    "of them covers the learning, PATCH it first. It was in play; "
    "it's the right place.\n"
    "  2. UPDATE AN EXISTING UMBRELLA (skills_list + skill_view to "
    "find the right one). Patch it.\n"
    "  3. ADD A SUPPORT FILE under an existing umbrella via "
    "skill_manage action=write_file. Three kinds: "
    "`references/<topic>.md` for session-specific detail OR condensed "
    "knowledge banks (quoted research, API docs excerpts, domain "
    "notes) written concise and task-focused; `templates/<name>.<ext>` "
    "for starter files meant to be copied and modified; "
    "`scripts/<name>.<ext>` for statically re-runnable actions "
    "(verification, fixture generators, probes). Add a one-line "
    "pointer in SKILL.md so future agents find them.\n"
    "  4. CREATE A NEW CLASS-LEVEL UMBRELLA when nothing exists. "
    "Name at the class level — NOT a PR number, error string, "
    "codename, library-alone name, or 'fix-X / debug-Y' session "
    "artifact. If the name only fits today's task, fall back to (1), "
    "(2), or (3).\n\n"
    "User-preference embedding: when the user complains about how "
    "you handled a task, update the skill that governs that task — "
    "memory alone isn't enough. Memory says 'who the user is and "
    "what the current situation and state of your operations are'; "
    "skills say 'how to do this class of task for this user'. Both "
    "should carry user-preference lessons when relevant.\n\n"
    "If you notice overlapping existing skills, mention it — the "
    "background curator handles consolidation.\n\n"
    "Protected skills (DO NOT edit these):\n"
    "  • Bundled skills (shipped with Hermes, e.g. 'hermes-agent').\n"
    "  • Hub-installed skills (installed via 'hermes skills install').\n"
    "Pinned skills (marked via 'hermes curator pin') CAN be improved — "
    "pin only blocks deletion/archive/consolidation by the curator, not "
    "content updates. Patch them when a pitfall or missing step turns up, "
    "same as any other agent-created skill.\n"
    "If the only skills that need updating are protected, say\n"
    "'Nothing to save.' and stop.\n\n"
    "Do NOT capture as skills (these become persistent self-imposed "
    "constraints that bite you later when the environment changes):\n"
    "  • Environment-dependent failures: missing binaries, fresh-install "
    "errors, post-migration path mismatches, 'command not found', "
    "unconfigured credentials, uninstalled packages. The user can fix "
    "these — they are not durable rules.\n"
    "  • Negative claims about tools or features ('browser tools do not "
    "work', 'X tool is broken', 'cannot use Y from execute_code'). These "
    "harden into refusals the agent cites against itself for months "
    "after the actual problem was fixed.\n"
    "  • Session-specific transient errors that resolved before the "
    "conversation ended. If retrying worked, the lesson is the retry "
    "pattern, not the original failure.\n"
    "  • One-off task narratives. A user asking 'summarize today's "
    "market' or 'analyze this PR' is not a class of work that warrants "
    "a skill.\n\n"
    "If a tool failed because of setup state, capture the FIX (install "
    "command, config step, env var to set) under an existing setup or "
    "troubleshooting skill — never 'this tool does not work' as a "
    "standalone constraint.\n\n"
    "Act on whichever of the two dimensions has real signal. If "
    "genuinely nothing stands out on either, say 'Nothing to save.' "
    "and stop — but don't reach for that conclusion as a default."
)
```

The combined prompt differs from the skill-only prompt in these ways:

- Opens with an explicit **Memory** section defining what to save (persona,
  desires, preferences, behavioral expectations).
- Signals list is slightly condensed (3 bullets instead of 4; the
  "workflow/approach correction" bullet is merged into the first).
- Closing instruction says "Act on whichever of the two dimensions has real
  signal" instead of being skill-only.

### 1.4 Runtime Prompt Suffix

Beyond the stored prompt constant, `_run_review_in_thread` appends an
additional constraint when it calls `run_conversation`:

```python
review_agent.run_conversation(
    user_message=(
        prompt
        + "\n\nYou can only call memory and skill "
        "management tools. Other tools will be denied "
        "at runtime — do not attempt them."
    ),
    conversation_history=_review_history,
)
```

This suffix is always appended regardless of which prompt was selected.

### 1.5 Prompt Selection Logic

The function `spawn_background_review_thread` selects the prompt based on two
boolean flags, with fallback to per-agent overrides:

```python
def spawn_background_review_thread(
    agent: Any,
    messages_snapshot: List[Dict],
    review_memory: bool = False,
    review_skills: bool = False,
):
    if review_memory and review_skills:
        prompt = getattr(agent, "_COMBINED_REVIEW_PROMPT", _COMBINED_REVIEW_PROMPT)
    elif review_memory:
        prompt = getattr(agent, "_MEMORY_REVIEW_PROMPT", _MEMORY_REVIEW_PROMPT)
    else:
        prompt = getattr(agent, "_SKILL_REVIEW_PROMPT", _SKILL_REVIEW_PROMPT)

    def _target() -> None:
        _run_review_in_thread(agent, messages_snapshot, prompt)

    return _target, prompt
```

The `getattr` pattern allows old code paths that set
`agent._MEMORY_REVIEW_PROMPT` (etc.) directly to override the module-level
constants, preserving backward compatibility.

---

## 2. Review Fork Architecture

The background review is a forked `AIAgent` instance that runs in a daemon
thread, inheriting the parent's runtime to hit the same provider prefix cache.
This section documents every configuration value and architectural decision.

### 2.1 Thread Entry Point

`spawn_background_review_thread` returns a `(target, prompt)` tuple. The
caller (`AIAgent._spawn_background_review`) owns actual
`threading.Thread` construction so test patches keep working:

```python
def spawn_background_review_thread(
    agent: Any,
    messages_snapshot: List[Dict],
    review_memory: bool = False,
    review_skills: bool = False,
):
    # ... prompt selection ...
    def _target() -> None:
        _run_review_in_thread(agent, messages_snapshot, prompt)

    return _target, prompt
```

The thread is created as a daemon by the caller, meaning it will not prevent
process exit.

### 2.2 Dangerous-Command Auto-Deny

Before any agent work, the thread installs a non-interactive approval callback
to prevent deadlocks against the parent's `prompt_toolkit` TUI:

```python
def _bg_review_auto_deny(command, description, **kwargs):
    logger.warning(
        "Background review auto-denied dangerous command: %s (%s)",
        command, description,
    )
    return "deny"
try:
    _set_approval_callback(_bg_review_auto_deny)
except Exception:
    pass
```

This mirrors the `_subagent_auto_deny` pattern from `tools/delegate_tool.py`.

### 2.3 Aux-Model Routing (`_resolve_review_runtime`)

The review fork can run on either the parent's model (default) or a
user-configured cheaper model. The routing policy:

```python
def _resolve_review_runtime(agent: Any) -> Dict[str, Any]:
```

Decision table:

| Config state | `routed` | Behavior |
|---|---|---|
| No `auxiliary.background_review` set, or `provider="auto"` | `False` | Inherit parent's live runtime; warm cache reuse |
| Same provider+model as parent | `False` | Treated as not routed; warm cache reuse |
| Different provider or model | `True` | Resolve via `resolve_runtime_provider`; cold cache; digest replay |

When `routed=True`, a codex_app_server -> codex_responses downgrade is applied:

```python
parent_api_mode = parent_runtime.get("api_mode") or None
if parent_api_mode == "codex_app_server":
    parent_api_mode = "codex_responses"
```

Configuration is read from `hermes_cli.config.load_config()` under the path
`auxiliary.background_review.{provider, model, base_url, api_key}`.

### 2.4 Digest History for Routed Models

When the review is routed to a different model (cache is cold regardless), the
conversation is compacted via `_digest_history`:

```python
def _digest_history(messages_snapshot: List[Dict], tail: int = 24) -> List[Dict]:
```

- Keeps the last `tail=24` messages verbatim.
- Ensures the kept window does not start with a `tool` role message (expands
  `tail` until a non-tool message is at the front).
- Collapses older turns into a single synthetic `user`-role digest message.
- User messages are truncated to 300 chars, assistant text to 200 chars.
- Tool calls are summarized as `ASSISTANT[tools: name1, name2]`.

The digest message has this prefix:

```python
"[Earlier conversation digest — older turns summarised to bound the "
"review's cold-write cost on the routed aux model. Recent turns "
"follow verbatim below.]\n"
```

For the same-model (non-routed) path, the full `messages_snapshot` is replayed
unchanged to maximize prefix-cache hits.

### 2.5 Fork Agent Construction

The `AIAgent` is constructed with these exact parameters:

```python
review_agent = AIAgent(
    model=_rt.get("model") or agent.model,
    max_iterations=16,
    quiet_mode=True,
    platform=agent.platform,
    provider=_rt.get("provider") or agent.provider,
    api_mode=_rt.get("api_mode"),
    base_url=_rt.get("base_url") or None,
    api_key=_rt.get("api_key") or None,
    credential_pool=getattr(agent, "_credential_pool", None),
    parent_session_id=agent.session_id,
    enabled_toolsets=getattr(agent, "enabled_toolsets", None),
    disabled_toolsets=getattr(agent, "disabled_toolsets", None),
    skip_memory=True,
)
```

Key constructor arguments:

| Parameter | Value | Rationale |
|---|---|---|
| `max_iterations` | `16` | Hard ceiling on tool-call loops |
| `quiet_mode` | `True` | Suppress verbose output |
| `skip_memory` | `True` | Prevents touching external memory plugins (honcho, mem0, supermemory) |
| `enabled_toolsets` / `disabled_toolsets` | Inherited from parent | Keeps `tools[]` byte-identical for cache key parity |
| `credential_pool` | Inherited from parent | Shares OAuth/credential-pool auth |
| `parent_session_id` | `agent.session_id` | Links fork to parent session |

### 2.6 Post-Construction Configuration

After construction, numerous attributes are set directly on the fork:

```python
review_agent._memory_write_origin = "background_review"
review_agent._memory_write_context = "background_review"
review_agent._skip_mcp_refresh = True
review_agent._memory_store = agent._memory_store
review_agent._memory_enabled = agent._memory_enabled
review_agent._user_profile_enabled = agent._user_profile_enabled
review_agent._memory_nudge_interval = 0
review_agent._skill_nudge_interval = 0
review_agent.suppress_status_output = True
review_agent._end_session_on_close = False
review_agent.compression_enabled = False
```

Detailed rationale for each:

| Attribute | Value | Rationale |
|---|---|---|
| `_memory_write_origin` | `"background_review"` | Provenance tag on memory writes |
| `_memory_write_context` | `"background_review"` | Execution context tag |
| `_skip_mcp_refresh` | `True` | Prevents between-turns MCP tool refresh that would break cache key parity |
| `_memory_store` | Parent's store | Shares the parent's MEMORY.md/USER.md file store |
| `_memory_enabled` | Parent's value | Inherits memory-enabled state |
| `_user_profile_enabled` | Parent's value | Inherits user-profile state |
| `_memory_nudge_interval` | `0` | Disables periodic "should I save memory?" nudges |
| `_skill_nudge_interval` | `0` | Disables periodic "should I update skills?" nudges |
| `suppress_status_output` | `True` | Prevents "Iteration budget exhausted", rate-limit retries, compression warnings from leaking to user |
| `_end_session_on_close` | `False` | Prevents fork from finalizing the parent's still-active session row |
| `compression_enabled` | `False` | Prevents compression race conditions (issue #38727); review needs full context |

### 2.7 Prefix-Cache Parity (Same-Model Path)

When not routed (`_routed=False`), the fork inherits the parent's cached
system prompt verbatim:

```python
if not _routed:
    review_agent._cached_system_prompt = agent._cached_system_prompt
    review_agent.session_start = agent.session_start
review_agent.session_id = agent.session_id
```

The comment documents a ~26% end-to-end cost reduction on Sonnet 4.5 (issue
#25322, PR #17276). Without this, the fork would rebuild the system prompt
from scratch with a fresh timestamp, fresh session_id, and different
skills_prompt -- producing a byte-different prefix-cache key that misses.

### 2.8 Tool Whitelist

The review fork is restricted to memory and skill management tools only:

```python
from model_tools import get_tool_definitions
from hermes_cli.plugins import (
    set_thread_tool_whitelist,
    clear_thread_tool_whitelist,
)

review_whitelist = {
    t["function"]["name"]
    for t in get_tool_definitions(
        enabled_toolsets=["memory", "skills"],
        quiet_mode=True,
    )
}
set_thread_tool_whitelist(
    review_whitelist,
    deny_msg_fmt=(
        "Background review denied non-whitelisted tool: "
        "{tool_name}. Only memory/skill tools are allowed."
    ),
)
```

The whitelist is thread-local (set via `set_thread_tool_whitelist`), so it does
not affect the parent agent. The `deny_msg_fmt` template uses `{tool_name}` as
its format key. The whitelist is always cleared in a `finally` block:

```python
try:
    # ... run_conversation ...
finally:
    clear_thread_tool_whitelist()
```

### 2.9 Stdout/Stderr Suppression

The entire review runs inside a double redirect:

```python
with open(os.devnull, "w", encoding="utf-8") as _devnull, \
     contextlib.redirect_stdout(_devnull), \
     contextlib.redirect_stderr(_devnull):
```

This captures all output from agent construction, conversation execution, and
teardown. The `suppress_status_output = True` attribute handles the separate
`_emit_status` / `_vprint` pathway that bypasses `sys.stdout`.

### 2.10 Teardown and Cleanup

After `run_conversation` completes, the fork's messages are snapshot before
teardown:

```python
review_messages = list(getattr(review_agent, "_session_messages", []))
```

Then memory providers and the agent itself are shut down while stdout is still
redirected:

```python
try:
    review_agent.shutdown_memory_provider()
except Exception:
    pass
try:
    review_agent.close()
except Exception:
    pass
review_agent = None
```

A `finally` block provides safety-net cleanup for the exception path,
re-opening devnull for silent teardown:

```python
finally:
    if review_agent is not None:
        try:
            with open(os.devnull, "w", encoding="utf-8") as _fn, \
                 contextlib.redirect_stdout(_fn), \
                 contextlib.redirect_stderr(_fn):
                try:
                    review_agent.shutdown_memory_provider()
                except Exception:
                    pass
                try:
                    review_agent.close()
                except Exception:
                    pass
        except Exception:
            pass
    try:
        _set_approval_callback(None)
    except Exception:
        pass
```

The approval callback is also cleared to prevent a recycled thread-id from
inheriting a stale reference.

---

## 3. Learn Command (`/learn`)

The `/learn` command is implemented in `learn_prompt.py`. It takes free-text
input from the user and builds a single prompt that the live agent executes as
a normal conversation turn. There is no separate distillation engine and no
additional model-tool footprint.

### 3.1 Module Docstring (Design Philosophy)

From the module docstring:

> `/learn` is open-ended. The user can point it at anything they can describe:
> a directory of code, an API doc URL, a workflow they just walked the agent
> through in this conversation, or pasted notes.

The prompt instructs the agent to:

1. Gather sources using existing tools (`read_file`/`search_files` for dirs,
   `web_extract` for URLs, conversation history for "what I just did", raw
   text for pasted material).
2. Author a single `SKILL.md` via `skill_manage` following the Hermes
   skill-authoring standards.

### 3.2 `_AUTHORING_STANDARDS` Constant

This is the embedded copy of the "HARDLINE" skill-authoring rules from
`AGENTS.md`. Full verbatim text:

```python
_AUTHORING_STANDARDS = """\
Follow the Hermes skill-authoring standards exactly. These are the same
HARDLINE rules a maintainer enforces in review:

Frontmatter:
- name: lowercase-hyphenated, <=64 chars, no spaces.
- description: ONE sentence, **<=60 characters**, ends with a period. State the
  capability, not the implementation. No marketing words (powerful,
  comprehensive, seamless, advanced, robust). Do NOT repeat the skill name. If
  the description contains a colon, wrap the whole value in double quotes.
  This is the most-violated rule and it is NOT cosmetic: the system-prompt
  skill index truncates the description to 60 chars and loads it every
  session, so anything past char 60 is silently cut and never routes. After
  you write the description, COUNT the characters; if it is over 60, cut it
  down before saving — do not ship a sentence and hope.
    Good (<=60): `Search arXiv papers by keyword, author, or ID.`
    Bad (123):   `A comprehensive skill that lets the agent search arXiv for
                  academic papers using keywords, authors, and categories.`
- version: 0.1.0
- author: always the literal value `Hermes`. NEVER fill it from the host
  environment — the OS/login username (e.g. the `user=` line in your
  environment hints), git config, or any identity you can probe must not be
  written. Skills get shared and published, so an environment-derived name is
  a privacy leak the user never opted into; the skill names itself as Hermes.
- platforms: declare `[macos]`, `[linux]`, and/or `[windows]` IF the skill
  uses OS-bound primitives (osascript/apt/systemctl => the matching OS; /proc,
  os.setsid, signal.SIGKILL => linux; fcntl/termios => POSIX). Prefer fixing it
  cross-platform first (tempfile.gettempdir(), pathlib.Path, psutil); gate only
  when the dependency is genuinely platform-bound. Omit the field for portable
  skills.
- metadata.hermes.tags: a few Capitalized, Relevant, Tags.

Body section order (omit a section only if it genuinely has no content):
1. "# <Human Title>" then a 2-3 sentence intro: what it does, what it does NOT
   do, and the key dependency stance (e.g. "stdlib only").
2. "## When to Use" — bullet list of concrete trigger phrases.
3. "## Prerequisites" — exact env vars, install steps, credentials.
4. "## How to Run" — the canonical invocation, framed through Hermes tools.
5. "## Quick Reference" — a flat command/endpoint list, no narration.
6. "## Procedure" — numbered steps with copy-paste-exact commands.
7. "## Pitfalls" — known limits, rate limits, things that look broken but aren't.
8. "## Verification" — a single command/check that proves the skill worked.

Hermes-tool framing (this is what makes it a skill, not shell docs):
- Frame running scripts as "invoke through the `terminal` tool".
- Reference Hermes tools by name in backticks: `terminal`, `read_file`,
  `write_file`, `search_files`, `patch`, `web_extract`, `web_search`,
  `vision_analyze`, `browser_navigate`, `delegate_task`, `image_generate`,
  `text_to_speech`, `cronjob`, `memory`, `skill_view`, `execute_code`.
- Do NOT name shell utilities the agent already has wrapped: say `read_file`
  not cat/head/tail, `search_files` not grep/rg/find/ls, `patch` not sed/awk,
  `web_extract` not curl-to-scrape, `write_file` not echo>file or heredocs.
- Third-party CLIs (ffmpeg, gh, an SDK) are fine inside a script file, but the
  prose still frames them as "invoke through the `terminal` tool". If the
  skill needs an MCP server, name it and document its setup in Prerequisites.

Quality bar:
- Prefer exact commands, endpoint URLs, function signatures, and config keys
  that appear VERBATIM in the source. NEVER invent flags, paths, or APIs — if
  you didn't see it in the source, don't write it.
- Keep it tight and scannable: ~100 lines for a simple skill, ~200 for a
  complex one. Don't re-paste the source docs.
- Don't write a router/index/hub skill that only points at other skills.
- Larger scripts/parsers belong in a `scripts/` file (add via
  `skill_manage` write_file), referenced from SKILL.md by relative path — not
  inlined for the agent to re-type every run. References go in `references/`,
  templates in `templates/`."""
```

### 3.3 Frontmatter Rules Summary

| Field | Rule | Critical Detail |
|---|---|---|
| `name` | lowercase-hyphenated, <=64 chars, no spaces | -- |
| `description` | ONE sentence, <=60 chars, ends with period | System-prompt skill index truncates at 60 chars; anything past is silently cut |
| `version` | `0.1.0` | Always this value for new skills |
| `author` | Always literal `"Hermes"` | NEVER from host environment (privacy leak) |
| `platforms` | Only if OS-bound primitives used | Prefer cross-platform fix first |
| `metadata.hermes.tags` | `Capitalized, Relevant, Tags` | -- |

Banned description words: "powerful", "comprehensive", "seamless", "advanced",
"robust".

### 3.4 Section Order

The required section order for SKILL.md body:

1. `# <Human Title>` -- 2-3 sentence intro (does, does NOT, dependency stance)
2. `## When to Use` -- bullet list of trigger phrases
3. `## Prerequisites` -- env vars, install steps, credentials
4. `## How to Run` -- canonical invocation via Hermes tools
5. `## Quick Reference` -- flat command/endpoint list
6. `## Procedure` -- numbered steps with exact commands
7. `## Pitfalls` -- limits, rate limits, false-broken scenarios
8. `## Verification` -- single proof-of-success check

### 3.5 `build_learn_prompt` Function

```python
def build_learn_prompt(user_request: str) -> str:
```

If the user provides no text after `/learn`, the default request is:

```python
req = (
    "the workflow we just went through in this conversation — review "
    "the steps taken and distill them into a reusable skill"
)
```

The assembled prompt template:

```python
return (
    "[/learn] The user wants you to learn a reusable skill from the "
    "source(s) they described below, and save it.\n\n"
    f"WHAT TO LEARN FROM:\n{req}\n\n"
    "Do this:\n"
    "1. Gather the material. Resolve whatever the user named using the "
    "tools you already have — `read_file`/`search_files` for local files "
    "or directories, `web_extract` for URLs, the current conversation "
    "history if they referred to something you just did, and the text "
    "they pasted as-is. If the request is ambiguous about scope, make a "
    "reasonable choice and note it; do not stall.\n"
    "2. Author ONE SKILL.md and save it with the `skill_manage` tool "
    "(action=\"create\"). Pick a sensible category. If the procedure needs "
    "a non-trivial script, add it under the skill's `scripts/` with "
    "`skill_manage` write_file and reference it by relative path.\n\n"
    f"{_AUTHORING_STANDARDS}\n\n"
    "When done, tell the user the skill name, its category, and a "
    "one-line summary of what it captured."
)
```

The prompt structure:

1. **Header**: `[/learn]` tag + intent declaration
2. **Source block**: `WHAT TO LEARN FROM:\n{user_request}`
3. **Instructions**: Two numbered steps (gather, author)
4. **Standards**: Full `_AUTHORING_STANDARDS` embedded inline
5. **Closing**: Report skill name, category, and summary

---

## 4. Anti-Pattern Rules

The skill review prompts contain explicit "Do NOT capture" sections. These
rules appear identically in both `_SKILL_REVIEW_PROMPT` and
`_COMBINED_REVIEW_PROMPT`. The rationale line is:

> "these become persistent self-imposed constraints that bite you later when
> the environment changes"

### 4.1 Environment-Dependent Failures

```
  • Environment-dependent failures: missing binaries, fresh-install
    errors, post-migration path mismatches, 'command not found',
    unconfigured credentials, uninstalled packages. The user can fix
    these — they are not durable rules.
```

Examples: a tool fails because `node` is not installed, a path changed after
a migration, credentials are not configured yet. These are transient setup
issues, not durable knowledge.

### 4.2 Negative Claims About Tools or Features

```
  • Negative claims about tools or features ('browser tools do not
    work', 'X tool is broken', 'cannot use Y from execute_code'). These
    harden into refusals the agent cites against itself for months
    after the actual problem was fixed.
```

This is the most architecturally significant anti-pattern. Without this rule,
the agent would learn "tool X is broken" as a skill, then refuse to use tool X
in future sessions even after the underlying bug is fixed. The prompt calls
this "hardening into refusals."

### 4.3 Session-Specific Transient Errors

```
  • Session-specific transient errors that resolved before the
    conversation ended. If retrying worked, the lesson is the retry
    pattern, not the original failure.
```

The key insight: if retrying worked, the durable lesson is the retry *pattern*,
not the original failure itself.

### 4.4 One-Off Task Narratives

```
  • One-off task narratives. A user asking 'summarize today's
    market' or 'analyze this PR' is not a class of work that warrants
    a skill.
```

Skills must be class-level (reusable across sessions), not specific to a single
task instance.

### 4.5 The Fix Exception

There is one exception to the environment-failure anti-pattern:

```
If a tool failed because of setup state, capture the FIX (install
command, config step, env var to set) under an existing setup or
troubleshooting skill — never 'this tool does not work' as a
standalone constraint.
```

The distinction: "tool X does not work" is banned; "to make tool X work, run
`apt install X`" is allowed -- but only under an existing setup/troubleshooting
skill, never as a standalone constraint.

### 4.6 Skill Name Anti-Patterns

From the "CREATE A NEW CLASS-LEVEL UMBRELLA" rule:

```
The name MUST be at the class level.
The name MUST NOT be a specific PR number, error string, feature
codename, library-alone name, or 'fix-X / debug-Y / audit-Z-today'
session artifact. If the proposed name only makes sense for
today's task, it's wrong — fall back to (1), (2), or (3).
```

Banned name patterns:
- Specific PR numbers (e.g., `fix-pr-1234`)
- Error strings (e.g., `null-pointer-in-auth`)
- Feature codenames (e.g., `project-phoenix-rollout`)
- Library-alone names (e.g., `react-query` with no class framing)
- Session artifacts (e.g., `debug-login-today`, `audit-csp-headers-june`)

---

## 5. Write Approval Gate

### 5.1 Memory Write Metadata

The `build_memory_write_metadata` function constructs provenance metadata that
tags every memory write with its origin:

```python
def build_memory_write_metadata(
    agent: Any,
    *,
    write_origin: Optional[str] = None,
    execution_context: Optional[str] = None,
    task_id: Optional[str] = None,
    tool_call_id: Optional[str] = None,
) -> Dict[str, Any]:
    metadata: Dict[str, Any] = {
        "write_origin": write_origin or getattr(agent, "_memory_write_origin", "assistant_tool"),
        "execution_context": (
            execution_context
            or getattr(agent, "_memory_write_context", "foreground")
        ),
        "session_id": agent.session_id or "",
        "parent_session_id": agent._parent_session_id or "",
        "platform": agent.platform or os.environ.get("HERMES_SESSION_SOURCE", "cli"),
        "tool_name": "memory",
    }
    if task_id:
        metadata["task_id"] = task_id
    if tool_call_id:
        metadata["tool_call_id"] = tool_call_id
    return {k: v for k, v in metadata.items() if v not in {None, ""}}
```

Default values for the review fork (set in `_run_review_in_thread`):

| Field | Foreground Value | Background Review Value |
|---|---|---|
| `write_origin` | `"assistant_tool"` | `"background_review"` |
| `execution_context` | `"foreground"` | `"background_review"` |

### 5.2 Notification Tools and Action Filtering

The `summarize_background_review_actions` function controls which tool results
are surfaced to the user. It uses a strict notify-tool whitelist:

```python
notify_tools = {"memory", "skill_manage"}
```

Only tool calls to `memory` or `skill_manage` are surfaced in the action
summary. Other helper tools are filtered out even if they succeeded.

### 5.3 Notification Mode

The `notification_mode` parameter (exposed as `agent.memory_notifications`)
controls display detail:

```python
def summarize_background_review_actions(
    review_messages: List[Dict],
    prior_snapshot: List[Dict],
    notification_mode: str = "on",
) -> List[str]:
    mode = str(notification_mode or "on").lower()
    if mode == "off":
        return []
    verbose = mode == "verbose"
```

| Mode | Behavior |
|---|---|
| `"off"` | Return empty list; no notifications |
| `"on"` | Generic "Memory updated" / "Created" / "Updated" messages |
| `"verbose"` | Include compact content previews from tool-call arguments (120 char max for add/replace, 80 char max for patch old/new, 60 char max for remove) |

### 5.4 Stale Result Deduplication

To prevent re-surfacing stale results from inherited conversation history
(issue #14944), the function tracks existing tool call IDs and content:

```python
existing_tool_call_ids = set()
existing_tool_contents = set()
for prior in prior_snapshot or []:
    if not isinstance(prior, dict) or prior.get("role") != "tool":
        continue
    tcid = prior.get("tool_call_id")
    if tcid:
        existing_tool_call_ids.add(tcid)
    else:
        content = prior.get("content")
        if isinstance(content, str):
            existing_tool_contents.add(content)
```

Tool messages whose `tool_call_id` matches `existing_tool_call_ids` or whose
`content` matches `existing_tool_contents` are skipped.

### 5.5 Action Summary Delivery

Successful actions are deduplicated and joined, then printed and optionally
delivered via callback:

```python
if actions:
    summary = " · ".join(dict.fromkeys(actions))
    agent._safe_print(
        f"  \U0001f4be Self-improvement review: {summary}"
    )
    _bg_cb = agent.background_review_callback
    if _bg_cb:
        try:
            _bg_cb(
                f"\U0001f4be Self-improvement review: {summary}"
            )
        except Exception:
            pass
```

The `dict.fromkeys(actions)` call preserves order while deduplicating identical
action strings.

### 5.6 `skip_memory=True` and External Provider Isolation

The most critical write-gate is the `skip_memory=True` constructor argument.
The code comment explains all three ingestion sites that would otherwise leak
the harness prompt into the user's real memory namespace:

```python
# skip_memory=True keeps the review fork from
# touching external memory plugins (honcho, mem0,
# supermemory, etc.).  Without it, the fork's
# __init__ rebuilds its own _memory_manager from
# config, scoped to the parent's session_id, and
# run_conversation() then leaks the harness prompt
# into the user's real memory namespace via three
# ingestion sites: on_turn_start (cadence + turn
# message), prefetch_all (recall query), and
# sync_all (harness prompt + review output recorded
# as a (user, assistant) turn pair).
```

However, built-in MEMORY.md / USER.md writes still work because the fork
inherits the parent's `_memory_store` directly:

```python
review_agent._memory_store = agent._memory_store
```

This means the review fork can write to the local file-based memory (MEMORY.md)
but cannot write to external memory providers (Honcho, mem0, Supermemory).

---

## 6. Reflection Triggers

### 6.1 When Background Review Fires

The background review is triggered by `AIAgent.run_conversation` after every
turn, via `AIAgent._spawn_background_review`. The `spawn_background_review_thread`
function signature reveals the trigger mechanism:

```python
def spawn_background_review_thread(
    agent: Any,
    messages_snapshot: List[Dict],
    review_memory: bool = False,
    review_skills: bool = False,
):
```

Two independent boolean flags control what gets reviewed:

- `review_memory` -- whether to evaluate memory-worthy facts
- `review_skills` -- whether to evaluate skill updates

The caller (`AIAgent`) determines when these flags are `True` based on
configurable intervals tracked by `_memory_nudge_interval` and
`_skill_nudge_interval` on the parent agent. In the review fork, both are
set to `0` to disable recursive nudging:

```python
review_agent._memory_nudge_interval = 0
review_agent._skill_nudge_interval = 0
```

### 6.2 Prompt Selection Based on Triggers

The prompt selection is a straightforward conditional:

```python
if review_memory and review_skills:
    prompt = getattr(agent, "_COMBINED_REVIEW_PROMPT", _COMBINED_REVIEW_PROMPT)
elif review_memory:
    prompt = getattr(agent, "_MEMORY_REVIEW_PROMPT", _MEMORY_REVIEW_PROMPT)
else:
    prompt = getattr(agent, "_SKILL_REVIEW_PROMPT", _SKILL_REVIEW_PROMPT)
```

Note that when `review_memory=False` and `review_skills=False`, the function
still defaults to the skill review prompt (the `else` branch). However, in
practice, `_spawn_background_review` is only called when at least one flag is
`True`.

### 6.3 Conversation Replay Strategy

The replay strategy depends on whether the review is routed to a different
model:

```python
_review_history = (
    _digest_history(messages_snapshot) if _routed
    else messages_snapshot
)
review_agent.run_conversation(
    user_message=(
        prompt
        + "\n\nYou can only call memory and skill "
        "management tools. Other tools will be denied "
        "at runtime — do not attempt them."
    ),
    conversation_history=_review_history,
)
```

| Path | Replay | Rationale |
|---|---|---|
| Same model (`_routed=False`) | Full `messages_snapshot` | Warm cache hits; cheap reads |
| Different model (`_routed=True`) | `_digest_history(messages_snapshot)` | Cold cache regardless; minimize cold-written tokens |

### 6.4 Module Exports

The module's `__all__` declaration:

```python
__all__ = [
    "_MEMORY_REVIEW_PROMPT",
    "_SKILL_REVIEW_PROMPT",
    "_COMBINED_REVIEW_PROMPT",
    "spawn_background_review_thread",
    "summarize_background_review_actions",
    "build_memory_write_metadata",
]
```

---

## Appendix: Constants and Configuration Quick Reference

| Constant / Config | Value | Location |
|---|---|---|
| `_MEMORY_REVIEW_PROMPT` | Memory-only review prompt | `background_review.py:159` |
| `_SKILL_REVIEW_PROMPT` | Skill-only review prompt | `background_review.py:170` |
| `_COMBINED_REVIEW_PROMPT` | Combined memory+skill prompt | `background_review.py:275` |
| `_AUTHORING_STANDARDS` | Skill authoring HARDLINE rules | `learn_prompt.py:30` |
| `max_iterations` | `16` | Fork constructor |
| `compression_enabled` | `False` | Fork post-construction |
| `skip_memory` | `True` | Fork constructor |
| `_memory_nudge_interval` | `0` | Fork post-construction |
| `_skill_nudge_interval` | `0` | Fork post-construction |
| `_skip_mcp_refresh` | `True` | Fork post-construction |
| `_end_session_on_close` | `False` | Fork post-construction |
| `suppress_status_output` | `True` | Fork post-construction |
| `quiet_mode` | `True` | Fork constructor |
| `notify_tools` | `{"memory", "skill_manage"}` | `summarize_background_review_actions` |
| `tail` (digest) | `24` | `_digest_history` default parameter |
| Description max length | 60 chars | `_AUTHORING_STANDARDS` |
| Skill name max length | 64 chars | `_AUTHORING_STANDARDS` |
| Default author | `"Hermes"` | `_AUTHORING_STANDARDS` |
| Default version | `0.1.0` | `_AUTHORING_STANDARDS` |
| Aux model config path | `auxiliary.background_review.{provider,model,base_url,api_key}` | `_resolve_review_runtime` |
| `_memory_write_origin` (fork) | `"background_review"` | `_run_review_in_thread` |
| `_memory_write_context` (fork) | `"background_review"` | `_run_review_in_thread` |
