# Validation Notes: 03-training-and-finetuning.md
**Validated against:** /tmp/ repos
**Date:** 2026-06-30
**Validator:** Subagent

## Findings

### Finding 1: All three repos exist and are accessible
- **Claim:** Three external repos cloned to /tmp/
- **Status:** CONFIRMED
- `/tmp/hermes-agent-evolution/` -- present, has evolution/core/, evolution/skills/, generate_report.py, PLAN.md
- `/tmp/tinker-atropos/` -- present, has tinker_atropos/, configs/, launch_training.py, serve.py
- `/tmp/hermes-compression-eval/` -- present, has DESIGN.md, grader.py, run_eval.py, fixtures/, probes/

### Finding 2: external_importers.py -- line count off by 1
- **Claim (Section 2.1):** "786 lines"
- **Actual:** 785 lines (wc -l)
- **Severity:** Trivial

### Finding 3: Class names correct but method signatures FABRICATED
- **Claim (Section 2.1):** Three importer classes: `ClaudeCodeImporter`, `CopilotImporter`, `HermesSessionImporter`
- **Status:** Class names CONFIRMED (lines 157, 210, 334)
- **PROBLEM:** Document shows method `import_sessions() -> list[ConversationTurn]` for all three classes. The actual method is `extract_messages(limit: int = 0) -> list[dict]`. There is no `ConversationTurn` type anywhere in the file. The return type is `list[dict]`, not `list[ConversationTurn]`.

### Finding 4: SECRET_PATTERNS structure FABRICATED
- **Claim (Section 2.2):** Shows a list of separate `re.compile()` calls stored in a `SECRET_PATTERNS` list
- **Actual:** `SECRET_PATTERNS` is a single `re.compile()` with a multi-line alternation pattern using `|` operators (lines 45-70)
- **Specific pattern differences:**
  - Doc: `sk-ant-[a-zA-Z0-9_-]{20,}` / Actual: `sk-ant-api\S+`
  - Doc: `sk-or-v1-[a-zA-Z0-9]{48,}` / Actual: `sk-or-v1-\S+`
  - Doc: `ghp_[a-zA-Z0-9]{36,}` / Actual: `ghp_\S+`
  - Doc: `gho_[a-zA-Z0-9]{36,}` / Actual: has `ghu_\S+` instead (different prefix)
  - Doc: `xoxp-[0-9]+-[a-zA-Z0-9]+` / Actual: has `xapp-\S+` instead
  - Doc shows exactly the patterns listed; actual has additional patterns like `sk-\S{20,}`, `Bearer\s+\S{20,}`, env var name patterns (`ANTHROPIC_API_KEY`, etc.)
- **Severity:** The document conveys the right idea (secret scrubbing with regex patterns) but the code snippet is fabricated, not copied from source.

### Finding 5: Secret handling behavior CONFIRMED
- **Claim:** "Any conversation turn matching these patterns is dropped entirely -- not redacted, dropped."
- **Status:** CONFIRMED. All three importers call `_contains_secret(text)` and `continue` past matching entries.

### Finding 6: RelevanceFilter signature FABRICATED
- **Claim (Section 2.3):** `__init__(self, skill_name: str, skill_text: str, model: str)` with method `filter(self, turns: list[ConversationTurn])`
- **Actual:** `__init__(self, model: str)` with method `filter_and_score(self, messages: list[dict], skill_name: str, skill_text: str, max_examples: int = 50) -> list[EvalExample]`
- **Claim:** Uses `score >= 0.6` as relevance threshold (numeric float)
- **Actual:** Uses a JSON response with boolean `relevant` field -- no numeric threshold at all
- **Severity:** HIGH -- the API surface shown in the document does not match reality

### Finding 7: ScoreRelevance DSPy Signature PARTIALLY WRONG
- **Claim:** Fields are `skill_description`, `conversation_turn`, `relevance_score: float`, `reasoning: str`
- **Actual:** Fields are `skill_name`, `skill_description`, `user_message`, `assistant_response`, `scoring` (JSON string with relevant/expected_behavior/difficulty/category)
- The actual signature is more sophisticated than documented (includes assistant_response, outputs structured scoring JSON rather than a single float)

### Finding 8: Session file paths CONFIRMED
- **Claim:** Claude Code: `~/.claude/history.jsonl` -- CONFIRMED (line 165)
- **Claim:** Copilot: `~/.copilot/session-state/*/events.jsonl` -- CONFIRMED (lines 222, 239)
- **Claim:** Hermes: `~/.hermes/sessions/*.json` -- CONFIRMED (line 346)
