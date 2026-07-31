# Self-Learning Protocol

## Where the store lives

Every path below is written relative to `<store>`. Resolve it once, do not
guess it, and never assume `~/.claude` -- this project's store is
vendor-neutral and is shared by Claude Code, Copilot CLI and VS Code Copilot
Chat as peers:

```bash
python3 <install-dir>/scripts/lib/paths.py get home   # -> <store>
```

By default that is `~/.local/share/agent-learning` (or `$AGENT_LEARNING_HOME`
/ `$XDG_DATA_HOME` when set). `paths.py all` prints every resolved key.

## Background Review (Mid-Session)

After completing a user request (not mid-task), check if the file
`<store>/state/review_signal.json` exists. If it does:

1. Read the signal file to determine review type (memory, skills, or both)
2. Delete the signal file immediately (prevents re-triggering)
3. Spawn a review subagent using the Agent tool, with the review instructions
   below as its prompt
4. The subagent has a budget of 16 tool uses maximum
5. After the subagent completes, continue with the user's work
6. Do NOT announce the review to the user unless you created something notable

If the signal file does not exist, do nothing -- proceed normally.

### Turn Counting Awareness

A PostToolUse hook (`turn-counter.sh`) increments a counter after every tool
use. When the counter reaches the review threshold (default: 10), the hook
writes a review signal file. You do not need to count turns yourself -- the
hook handles this automatically.

The counter resets after each review cycle and at session end.

### When to Spawn Review Subagent

Spawn the review subagent when ALL of these conditions are true:
- The review signal file (`<store>/state/review_signal.json`) exists
- You have just completed the user's current request (not mid-task)
- No review has run in the last 60 seconds

Do NOT spawn a review subagent:
- In the middle of a multi-step task
- When the user is waiting for an answer
- More than once per 60-second window

### Review Subagent Prompt

When spawning the review subagent via the Agent tool, use the combined review
prompt. The subagent should:

1. Read `<store>/memory/MEMORY.md` and `<store>/memory/USER.md`
2. Scan `<store>/learned-skills/` for existing skills
3. Review the conversation context for:
   - User corrections or preferences (propose for MEMORY.md or USER.md)
   - Reusable patterns or workflows (propose as skills)
   - Outdated skills that need patching
4. PROPOSE the updates as output -- do not write them to disk yourself. The
   review pipeline is reviewer-proposes / writer-persists:
   `scripts/persist-proposal.py` owns every write to the store, including the
   `<skill-name>/SKILL.md` layout and the `.usage.json` sidecar. A subagent
   that writes directly bypasses threat scanning, the character-limit
   enforcement, the near-duplicate refusal and the store lock.
5. Respect budget limits: max 3 memory writes, max 2 skill operations

### Memory Review Behavior

Memory is split into two bounded stores:
- **MEMORY.md** (`<store>/memory/MEMORY.md`, max 2200 chars): Agent operational
  notes -- project facts, corrections, tool quirks, workflow conventions.
- **USER.md** (`<store>/memory/USER.md`, max 1375 chars): User profile --
  name, role, communication style, tool preferences, timezone.

Rules:
- Each entry: one line, under 120 characters
- Read existing files first -- do not duplicate
- Replace outdated entries rather than add + remove
- Never save secrets, tokens, API keys, or passwords
- If at character limit, remove least relevant entry before adding

### Skill Review Behavior

Skills are stored in `<store>/learned-skills/<skill-name>/SKILL.md`.

Preference order for skill updates:
1. UPDATE an existing learned skill that was in play this session
2. UPDATE an existing umbrella skill in the same domain
3. ADD a support file (references/, templates/, scripts/) under an umbrella
4. CREATE a new class-level umbrella skill (last resort)

Rules:
- Prefer broad class-level skills over narrow one-off skills
- Skill names must match `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` -- max 64 chars,
  case-sensitive, letters/digits/underscore/hyphen only, NO dots. (This is the
  schema the writer validates against; a name it rejects discards the whole
  proposal, valid memory entries included.)
- Descriptions: one sentence, max 60 characters, ends with period
- Author field: always "agent-review" (never environment-derived)
- When the user corrects how you handle a task, update the skill that governs
  that task -- memory alone is not enough

### Session Search

Past sessions are indexed in a SQLite FTS5 database at
`<store>/sessions/search.db`. When you need to recall information from a
previous session, use the session search tool with one of four query shapes:
- **discover**: Full-text search across all sessions (BM25 ranked)
- **scroll**: Navigate within a session around an anchor message
- **read**: Read full session (first 20 + last 10 messages for large sessions)
- **browse**: List recent sessions chronologically

## Context Compression Guidance

When your context is being compressed:
1. Ensure the session's goal and initial user request survive compression
2. Ensure the most recent tool results and decisions survive compression
3. If you have unwritten learnings (patterns observed, corrections received),
   write them to memory BEFORE compression discards them
