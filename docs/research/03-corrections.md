# Corrections: 03-training-and-finetuning.md

**Date:** 2026-06-30
**Corrected against:** Actual source code in `/tmp/hermes-agent-evolution/` and `/tmp/hermes-agent-research/`
**Original validation notes:** `03-validation-notes.md`

---

## Correction 1 (Finding 3): Importer Method Signatures

**Section 2.1 -- External Session Importers**

**What the doc says:**
All three importer classes have an instance method `import_sessions() -> list[ConversationTurn]`. The type `ConversationTurn` is referenced throughout.

**What the actual code is:**
All three classes use a `@staticmethod` named `extract_messages(limit: int = 0) -> list[dict]`. There is no `ConversationTurn` type anywhere in the file. The return type is `list[dict]` where each dict contains keys like `source`, `task_input`, `project`, `session_id`, and optionally `assistant_response`.

**Source:** `external_importers.py` lines 167-168, 224-225, 348-349

**Verbatim actual signatures:**

```python
# ClaudeCodeImporter (line 167-168)
@staticmethod
def extract_messages(limit: int = 0) -> list[dict]:

# CopilotImporter (line 224-225)
@staticmethod
def extract_messages(limit: int = 0) -> list[dict]:

# HermesSessionImporter (line 348-349)
@staticmethod
def extract_messages(limit: int = 0) -> list[dict]:
```

**Corrected text for Section 2.1:**

```python
class ClaudeCodeImporter:
    """Import user prompts from Claude Code history.jsonl.

    Claude Code stores a flat JSONL of user messages at ~/.claude/history.jsonl.
    Each line has: display (user text), timestamp, project, sessionId.
    Only user inputs are available -- no assistant responses.
    """

    HISTORY_PATH = Path.home() / ".claude" / "history.jsonl"

    @staticmethod
    def extract_messages(limit: int = 0) -> list[dict]:
        """Read user messages from Claude Code history.

        Returns:
            List of dicts with keys: source, task_input, project, session_id, timestamp.
        """
        # Reads JSONL, extracts user text from "display" field
        # Skips entries < 10 chars, applies secret scrubbing via _contains_secret()


class CopilotImporter:
    """Import conversations from GitHub Copilot session events."""

    SESSION_DIR = Path.home() / ".copilot" / "session-state"

    @staticmethod
    def extract_messages(limit: int = 0) -> list[dict]:
        """Read user/assistant message pairs from Copilot sessions.

        Returns:
            List of dicts with keys: source, task_input, assistant_response,
            project, session_id.
        """
        # Reads ~/.copilot/session-state/*/events.jsonl
        # Pairs user.message / assistant.message events


class HermesSessionImporter:
    """Import conversations from Hermes Agent session files."""

    SESSION_DIR = Path.home() / ".hermes" / "sessions"

    @staticmethod
    def extract_messages(limit: int = 0) -> list[dict]:
        """Read user/assistant pairs from Hermes session files.

        Returns:
            List of dicts with keys: source, task_input, assistant_response,
            session_id.
        """
        # Reads ~/.hermes/sessions/*.json
        # OpenAI-format message lists, pairs user with next assistant response
```

---

## Correction 2 (Finding 4): SECRET_PATTERNS Structure

**Section 2.2 -- Secret Detection**

**What the doc says:**
Shows `SECRET_PATTERNS` as a Python list of separate `re.compile()` calls, each compiling an individual pattern. The individual regex syntax is also wrong (e.g., `sk-ant-[a-zA-Z0-9_-]{20,}` instead of `sk-ant-api\S+`).

**What the actual code is:**
`SECRET_PATTERNS` is a single `re.compile()` call with a multi-line alternation pattern using `|` operators, compiled with `re.IGNORECASE`. The patterns themselves use simpler `\S+` suffixes rather than character-class quantifiers.

**Source:** `external_importers.py` lines 45-70

**Verbatim actual code:**

```python
SECRET_PATTERNS = re.compile(
    r'('
    r'sk-ant-api\S+'           # Anthropic API keys
    r'|sk-or-v1-\S+'          # OpenRouter API keys
    r'|sk-\S{20,}'            # Generic OpenAI-style keys (20+ chars after sk-)
    r'|ghp_\S+'               # GitHub personal access tokens
    r'|ghu_\S+'               # GitHub user tokens
    r'|xoxb-\S+'              # Slack bot tokens
    r'|xapp-\S+'              # Slack app tokens
    r'|ntn_\S+'               # Notion integration tokens
    r'|AKIA[0-9A-Z]{16}'      # AWS access key IDs
    r'|Bearer\s+\S{20,}'      # Bearer auth headers (20+ char tokens)
    r'|-----BEGIN\s+(RSA\s+)?PRIVATE\sKEY-----'  # PEM private keys
    r'|ANTHROPIC_API_KEY'      # Known env var names (exact match)
    r'|OPENAI_API_KEY'
    r'|OPENROUTER_API_KEY'
    r'|SLACK_BOT_TOKEN'
    r'|GITHUB_TOKEN'
    r'|AWS_SECRET_ACCESS_KEY'
    r'|DATABASE_URL'
    r'|\bpassword\s*[=:]\s*\S+' # password assignments (password=xxx, password: xxx)
    r'|\bsecret\s*[=:]\s*\S+'   # secret assignments (secret=xxx, secret: xxx)
    r'|\btoken\s*[=:]\s*\S{10,}' # token assignments with 10+ char values
    r')',
    re.IGNORECASE,
)
```

**Key differences from doc:**
- Single compiled regex vs. list of separate compiles
- `sk-ant-api\S+` not `sk-ant-[a-zA-Z0-9_-]{20,}`
- `ghu_\S+` not `gho_[a-zA-Z0-9]{36,}` (different prefix entirely)
- `xapp-\S+` not `xoxp-[0-9]+-[a-zA-Z0-9]+` (different token type)
- Includes `Bearer\s+\S{20,}`, `ntn_\S+`, env var name patterns (ANTHROPIC_API_KEY, etc.)
- Uses `re.IGNORECASE` flag
- Doc's generic pattern `(?:password|secret|token|api_key)\s*[=:]\s*["\']?[^\s"\']{8,}` is actually three separate patterns: `\bpassword\s*[=:]\s*\S+`, `\bsecret\s*[=:]\s*\S+`, `\btoken\s*[=:]\s*\S{10,}`

---

## Correction 3 (Finding 6): RelevanceFilter Signature

**Section 2.3 -- Relevance Filtering**

**What the doc says:**
```python
class RelevanceFilter:
    def __init__(self, skill_name: str, skill_text: str, model: str):
        self.skill_name = skill_name
        self.skill_text = skill_text
        self.model = model

    def filter(self, turns: list[ConversationTurn]) -> list[ConversationTurn]:
        # ...
        if score >= 0.6:  # Relevance threshold
```

**What the actual code is:**
`__init__` takes only `model: str`. The filtering method is `filter_and_score()` which takes `messages`, `skill_name`, `skill_text`, and `max_examples` as parameters. It returns `list[EvalExample]`, not `list[ConversationTurn]`. Relevance is determined by a boolean `relevant` field in a JSON response, not a numeric `>= 0.6` threshold.

**Source:** `external_importers.py` lines 422-543

**Verbatim actual code:**

```python
class RelevanceFilter:
    """Use LLM-as-judge to determine which messages are relevant to a skill.

    Two-stage pipeline:
      1. Cheap heuristic pre-filter (_is_relevant_to_skill)
      2. LLM scoring for final relevance + eval metadata generation
    """

    class ScoreRelevance(dspy.Signature):
        # (see Correction 4 below for full fields)
        ...

    def __init__(self, model: str):
        self.scorer = dspy.ChainOfThought(self.ScoreRelevance)
        self.model = model

    def filter_and_score(
        self,
        messages: list[dict],
        skill_name: str,
        skill_text: str,
        max_examples: int = 50,
    ) -> list[EvalExample]:
        """Filter messages by relevance and generate eval examples."""
        skill_desc = skill_text[:800]

        # Stage 0: drop messages missing required fields
        messages = [m for m in messages if m.get("task_input") and m.get("source")]

        # Stage 1: cheap heuristic pre-filter
        candidates = [
            m for m in messages
            if _is_relevant_to_skill(m["task_input"], skill_name, skill_text)
        ]

        # If heuristics found too few, sample remaining messages
        if len(candidates) < max_examples:
            candidate_ids = {id(m) for m in candidates}
            remaining = [m for m in messages if id(m) not in candidate_ids]
            random.shuffle(remaining)
            candidates.extend(remaining[:max_examples * 2])

        # Cap candidates to control LLM costs
        candidates = candidates[:max_examples * 3]

        # Stage 2: LLM relevance scoring
        examples = []
        # ...
        for msg in candidates:
            with dspy.context(lm=lm):
                result = self.scorer(
                    skill_name=skill_name,
                    skill_description=skill_desc,
                    user_message=msg["task_input"][:1000],
                    assistant_response=msg.get("assistant_response", "")[:1000],
                )

            scoring = _parse_scoring_json(result.scoring)
            # ...
            if scoring.get("relevant", False):  # Boolean, not numeric threshold
                validated = _validate_eval_example(...)
                if validated:
                    examples.append(EvalExample(source=msg["source"], **validated))

        return examples
```

**Key differences from doc:**
- `__init__` takes only `model: str`, not `(skill_name, skill_text, model)`
- Method is `filter_and_score()`, not `filter()`
- Takes `messages: list[dict]`, not `turns: list[ConversationTurn]`
- Returns `list[EvalExample]`, not `list[ConversationTurn]`
- Relevance uses `scoring.get("relevant", False)` (boolean), not `score >= 0.6` (float)
- `skill_name` and `skill_text` are passed to `filter_and_score()`, not stored in `__init__`

---

## Correction 4 (Finding 7): ScoreRelevance DSPy Signature

**Section 2.3 -- ScoreRelevance**

**What the doc says:**
```python
class ScoreRelevance(dspy.Signature):
    """Score how relevant a conversation turn is to a specific skill."""
    skill_description: str = dspy.InputField()
    conversation_turn: str = dspy.InputField()
    relevance_score: float = dspy.OutputField(desc="0.0 to 1.0")
    reasoning: str = dspy.OutputField()
```

**What the actual code is:**
The signature has 4 input fields (not 2) and 1 output field (not 2). The output is a JSON string with structured fields, not a float + reasoning pair.

**Source:** `external_importers.py` lines 430-443

**Verbatim actual code:**

```python
class ScoreRelevance(dspy.Signature):
    """Score whether a user message is relevant to a specific agent skill.

    Return a JSON object with:
    - relevant: boolean (true if the message relates to what this skill does)
    - expected_behavior: string (if relevant, what should a good response do?)
    - difficulty: string (easy, medium, or hard)
    - category: string (what aspect of the skill this tests)
    """
    skill_name: str = dspy.InputField(desc="Name of the skill")
    skill_description: str = dspy.InputField(desc="First 800 chars of the skill file")
    user_message: str = dspy.InputField(desc="The user's message to evaluate")
    assistant_response: str = dspy.InputField(desc="The assistant's actual response (may be empty)")
    scoring: str = dspy.OutputField(desc="JSON object with: relevant, expected_behavior, difficulty, category")
```

**Key differences from doc:**
- 4 input fields (`skill_name`, `skill_description`, `user_message`, `assistant_response`), not 2 (`skill_description`, `conversation_turn`)
- Single output field `scoring: str` (JSON string), not two fields (`relevance_score: float`, `reasoning: str`)
- Output contains structured data: `{relevant: bool, expected_behavior: str, difficulty: str, category: str}`
- No numeric relevance score at all -- uses boolean `relevant`

---

## ADDITIONAL FABRICATIONS (not in validation notes)

The following fabrications were discovered by checking ALL code snippets in doc 03 against actual source.

---

## Correction 5: ConstraintValidator API Surface

**Section 3.1 -- Constraint Validation System**

**What the doc says:**
```python
class ConstraintValidator:
    def __init__(self, config: EvolutionConfig):
        self.max_skill_size = config.max_skill_size          # 15,000 chars
        self.max_tool_desc = config.max_tool_desc_size       # 500 chars
        self.max_param_desc = config.max_param_desc_size     # 200 chars
        self.max_growth = config.max_prompt_growth           # 0.2 (20%)
        self.run_pytest = config.run_pytest

    def validate_all(self, evolved_text: str, baseline_text: str) -> tuple[bool, list[str]]:
```
Shows `_check_size`, `_check_growth` returning `list[str]`, and `validate_all` returning `tuple[bool, list[str]]`.

**What the actual code is:**
`__init__` stores the entire config object (`self.config = config`), does not unpack fields. `validate_all` has a different signature and returns `list[ConstraintResult]` (a dataclass), not `tuple[bool, list[str]]`. The method also takes an `artifact_type` parameter. `run_test_suite` is a separate method (not called from `validate_all`).

**Source:** `constraints.py` lines 24-53

**Verbatim actual code:**

```python
@dataclass
class ConstraintResult:
    """Result of constraint validation."""
    passed: bool
    constraint_name: str
    message: str
    details: Optional[str] = None


class ConstraintValidator:
    """Validates evolved artifacts against hard constraints."""

    def __init__(self, config: EvolutionConfig):
        self.config = config

    def validate_all(
        self,
        artifact_text: str,
        artifact_type: str,
        baseline_text: Optional[str] = None,
    ) -> list[ConstraintResult]:
        """Run all applicable constraints. Returns list of results."""
        results = []
        results.append(self._check_size(artifact_text, artifact_type))
        if baseline_text:
            results.append(self._check_growth(artifact_text, baseline_text, artifact_type))
        results.append(self._check_non_empty(artifact_text))
        if artifact_type == "skill":
            results.append(self._check_skill_structure(artifact_text))
        return results

    def run_test_suite(self, hermes_repo: Path) -> ConstraintResult:
        """Run the full hermes-agent test suite. Must pass 100%."""
        # Separate method, not called from validate_all
        ...
```

**Key differences from doc:**
- `__init__` stores `self.config = config`, does not unpack individual fields
- `validate_all` returns `list[ConstraintResult]`, not `tuple[bool, list[str]]`
- `validate_all` takes `artifact_type: str` parameter (not in doc)
- `baseline_text` is `Optional[str] = None` (not required)
- `_check_size` and `_check_growth` take `artifact_type` parameter, return `ConstraintResult`
- `run_test_suite` is separate, takes `hermes_repo: Path`, not called from `validate_all`

---

## Correction 6: FitnessScore Property Name and Missing Field

**Section 3.2 -- Fitness Scoring**

**What the doc says:**
```python
@dataclass
class FitnessScore:
    correctness: float       # Weight: 0.5
    procedure_following: float  # Weight: 0.3
    conciseness: float       # Weight: 0.2
    length_penalty: float    # 0.0 to 0.3

    @property
    def weighted_total(self) -> float:
        raw = (self.correctness * 0.5 + ...)
        return raw - self.length_penalty
```

**What the actual code is:**
The property is named `composite`, not `weighted_total`. The dataclass also has a `feedback: str = ""` field used by GEPA for reflective mutation.

**Source:** `fitness.py` lines 15-32

**Verbatim actual code:**

```python
@dataclass
class FitnessScore:
    """Multi-dimensional fitness score."""
    correctness: float = 0.0
    procedure_following: float = 0.0
    conciseness: float = 0.0
    length_penalty: float = 0.0
    feedback: str = ""  # Textual feedback for GEPA's reflective analysis

    @property
    def composite(self) -> float:
        """Weighted composite score."""
        raw = (
            0.5 * self.correctness
            + 0.3 * self.procedure_following
            + 0.2 * self.conciseness
        )
        return max(0.0, raw - self.length_penalty)
```

**Key differences from doc:**
- Property is `composite`, not `weighted_total`
- Missing `feedback: str = ""` field (used for GEPA reflective analysis)
- All fields have default values `= 0.0` in actual
- Actual uses `max(0.0, raw - self.length_penalty)` to clamp at zero

---

## Correction 7: LLMJudge Signature Output Fields and score() Method

**Section 3.2 -- LLMJudge**

**What the doc says:**
```python
class LLMJudge:
    class JudgeSignature(dspy.Signature):
        # ...
        scores: str = dspy.OutputField(desc="JSON with correctness, procedure_following, conciseness (each 0-5)")
        feedback: str = dspy.OutputField()

    def score(self, example: EvalExample, output: str, skill_text: str) -> FitnessScore:
        # ... parses JSON, divides by 5.0
```

**What the actual code is:**
JudgeSignature has individual typed output fields (not a single JSON string). Scores are 0.0-1.0, not 0-5. The `score()` method takes individual strings, not an `EvalExample` object. Constructor takes `config: EvolutionConfig`.

**Source:** `fitness.py` lines 34-104

**Verbatim actual code:**

```python
class LLMJudge:
    class JudgeSignature(dspy.Signature):
        """Evaluate an agent's response against an expected behavior rubric."""
        task_input: str = dspy.InputField(desc="The task the agent was given")
        expected_behavior: str = dspy.InputField(desc="Rubric describing what a good response looks like")
        agent_output: str = dspy.InputField(desc="The agent's actual response")
        skill_text: str = dspy.InputField(desc="The skill/instructions the agent was following")
        correctness: float = dspy.OutputField(desc="Score 0.0-1.0: Did the response correctly address the task?")
        procedure_following: float = dspy.OutputField(desc="Score 0.0-1.0: Did it follow the expected procedure?")
        conciseness: float = dspy.OutputField(desc="Score 0.0-1.0: Appropriately concise?")
        feedback: str = dspy.OutputField(desc="Specific, actionable feedback on what could be improved")

    def __init__(self, config: EvolutionConfig):
        self.config = config
        self.judge = dspy.ChainOfThought(self.JudgeSignature)

    def score(
        self,
        task_input: str,
        expected_behavior: str,
        agent_output: str,
        skill_text: str,
        artifact_size: Optional[int] = None,
        max_size: Optional[int] = None,
    ) -> FitnessScore:
        lm = dspy.LM(self.config.eval_model)
        with dspy.context(lm=lm):
            result = self.judge(
                task_input=task_input,
                expected_behavior=expected_behavior,
                agent_output=agent_output,
                skill_text=skill_text,
            )
        correctness = _parse_score(result.correctness)
        procedure_following = _parse_score(result.procedure_following)
        conciseness = _parse_score(result.conciseness)
        # ... length_penalty calculation ...
        return FitnessScore(
            correctness=correctness,
            procedure_following=procedure_following,
            conciseness=conciseness,
            length_penalty=length_penalty,
            feedback=str(result.feedback),
        )
```

**Key differences from doc:**
- Output fields are individual typed fields (`correctness: float`, etc.), not a single `scores: str` JSON string
- Scores are 0.0-1.0 (no `/5.0` division needed), not 0-5
- `score()` takes individual strings (`task_input`, `expected_behavior`, `agent_output`, `skill_text`), not `(example: EvalExample, output: str, skill_text: str)`
- `score()` also accepts optional `artifact_size` and `max_size` for length penalty
- Constructor takes `config: EvolutionConfig`, not shown in doc
- `feedback` is included in the returned `FitnessScore`

---

## Correction 8: skill_fitness_metric Uses Different Field Names

**Section 3.3 -- Fast Proxy Metric**

**What the doc says:**
```python
def skill_fitness_metric(example, prediction, trace=None) -> float:
    expected = set(example.output.lower().split())
    predicted = set(prediction.output.lower().split())
    if not expected:
        return 0.3
    overlap = len(expected & predicted) / len(expected)
    return 0.3 + 0.7 * overlap
```

**What the actual code is:**
Uses `getattr` for safe field access. Uses `expected_behavior` field (not `output`). Returns 0.0 for empty agent output (not 0.3 for empty expected). Clamps result with `min/max`.

**Source:** `fitness.py` lines 107-137

**Verbatim actual code:**

```python
def skill_fitness_metric(example: dspy.Example, prediction: dspy.Prediction, trace=None) -> float:
    """DSPy-compatible metric function for skill optimization."""
    agent_output = getattr(prediction, "output", "") or ""
    expected = getattr(example, "expected_behavior", "") or ""
    task = getattr(example, "task_input", "") or ""

    if not agent_output.strip():
        return 0.0

    score = 0.5  # Base score for non-empty output

    expected_lower = expected.lower()
    output_lower = agent_output.lower()

    expected_words = set(expected_lower.split())
    output_words = set(output_lower.split())
    if expected_words:
        overlap = len(expected_words & output_words) / len(expected_words)
        score = 0.3 + (0.7 * overlap)

    return min(1.0, max(0.0, score))
```

**Key differences from doc:**
- Uses `getattr(example, "expected_behavior", "")` not `example.output`
- Uses `getattr(prediction, "output", "")` not `prediction.output` directly
- Returns `0.0` for empty agent output, not `0.3` for empty expected
- Has `min(1.0, max(0.0, score))` clamping
- Also reads `task_input` field (unused in fast path but available)

---

## Correction 9: evolve_skill Function Name and GEPA API

**Section 4.1 -- Instruction-Level Optimization**

**What the doc says:**
Function named `evolve_skill(skill: str, ...)` using `dspy.GEPAv1(metric=..., num_iterations=..., population_size=...)` with default `run_tests: bool = True`.

**What the actual code is:**
Function is named `evolve(skill_name: str, ...)`. Uses `dspy.GEPA(metric=..., max_steps=...)` (not `GEPAv1`, not `num_iterations`). Default `run_tests` is `False` not `True`.

**Source:** `evolution/skills/evolve_skill.py` lines 36-46, 156-159

**Verbatim actual code:**

```python
def evolve(
    skill_name: str,
    iterations: int = 10,
    eval_source: str = "synthetic",
    dataset_path: Optional[str] = None,
    optimizer_model: str = "openai/gpt-4.1",
    eval_model: str = "openai/gpt-4.1-mini",
    hermes_repo: Optional[str] = None,
    run_tests: bool = False,     # Default False, not True
    dry_run: bool = False,
):
```

```python
# GEPA instantiation (line 156-159):
optimizer = dspy.GEPA(          # Not dspy.GEPAv1
    metric=skill_fitness_metric,
    max_steps=iterations,       # Not num_iterations or population_size
)
```

**Additional differences:**
- Doc shows `config.get_hermes_agent_path()`; actual uses `resolve_hermes_agent_path(hermes_repo)`
- Doc shows `find_skill(skill, repo_path / "skills")` returning `(skill_path, skill_text)`; actual `find_skill(skill_name, config.hermes_agent_path)` returns `Optional[Path]`
- Doc shows `SyntheticDatasetBuilder(model=eval_model).build(skill_text, ...)`; actual uses `SyntheticDatasetBuilder(config).generate(artifact_text=skill["raw"], artifact_type="skill")`
- Doc shows `module = SkillModule(skill_text)` then `evaluate(module, dataset.val)`; actual uses `baseline_module = SkillModule(skill["body"])` and inline holdout scoring loop

---

## Correction 10: load_skill Return Type and find_skill Signature

**Section 4.2 -- Skill Module**

**What the doc says:**
```python
def load_skill(path: Path) -> tuple[dict, str]:
    """Parse SKILL.md: YAML frontmatter + markdown body."""
    content = path.read_text()
    parts = content.split("---", 2)
    frontmatter = yaml.safe_load(parts[1])
    body = parts[2].strip()
    return frontmatter, body
```

```python
def reassemble_skill(frontmatter: dict, evolved_body: str) -> str:
    fm_text = yaml.dump(frontmatter, default_flow_style=False)
    return f"---\n{fm_text}---\n\n{evolved_body}"
```

**What the actual code is:**
`load_skill` returns a single `dict` with keys `path`, `raw`, `frontmatter`, `body`, `name`, `description`. The `frontmatter` is stored as a `str` (raw YAML text), not a parsed dict. `reassemble_skill` takes `frontmatter: str`, not `dict`. No `yaml` module is imported.

**Source:** `evolution/skills/skill_module.py` lines 15-55, 117-123

**Verbatim actual code:**

```python
def load_skill(skill_path: Path) -> dict:
    """Load a skill file and parse its frontmatter + body.

    Returns:
        {
            "path": Path,
            "raw": str (full file content),
            "frontmatter": str (YAML between --- markers),
            "body": str (markdown after frontmatter),
            "name": str,
            "description": str,
        }
    """
    raw = skill_path.read_text()
    frontmatter = ""
    body = raw
    if raw.strip().startswith("---"):
        parts = raw.split("---", 2)
        if len(parts) >= 3:
            frontmatter = parts[1].strip()
            body = parts[2].strip()

    name = ""
    description = ""
    for line in frontmatter.split("\n"):
        if line.strip().startswith("name:"):
            name = line.split(":", 1)[1].strip().strip("'\"")
        elif line.strip().startswith("description:"):
            description = line.split(":", 1)[1].strip().strip("'\"")

    return {
        "path": skill_path,
        "raw": raw,
        "frontmatter": frontmatter,
        "body": body,
        "name": name,
        "description": description,
    }


def find_skill(skill_name: str, hermes_agent_path: Path) -> Optional[Path]:
    """Find a skill by name in the hermes-agent skills directory."""
    # Returns Optional[Path], not tuple[Path, str]


def reassemble_skill(frontmatter: str, evolved_body: str) -> str:
    """Reassemble a skill file from frontmatter and evolved body."""
    return f"---\n{frontmatter}\n---\n\n{evolved_body}\n"
```

**Key differences from doc:**
- `load_skill` returns `dict`, not `tuple[dict, str]`
- `frontmatter` is stored as raw `str`, not parsed via `yaml.safe_load()`
- No `yaml` module imported; frontmatter parsed with string splitting
- `reassemble_skill` takes `frontmatter: str`, not `frontmatter: dict`
- `find_skill` returns `Optional[Path]`, not `tuple[Path, str]`

---

## Correction 11: SyntheticDatasetBuilder API

**Section 2.4 -- Synthetic Dataset Generation**

**What the doc says:**
```python
class SyntheticDatasetBuilder:
    class GenerateTestCases(dspy.Signature):
        skill_text: str = dspy.InputField(desc="The skill being tested")
        num_examples: int = dspy.InputField(desc="How many to generate")
        difficulty_distribution: str = dspy.InputField()
        test_cases: list = dspy.OutputField()

    def build(self, skill_text: str, num_examples: int = 20) -> EvalDataset:
```

**What the actual code is:**
Input fields use different names. Output field is `str` (JSON), not `list`. Method is `generate()`, not `build()`. Constructor takes `config: EvolutionConfig`. No `difficulty_distribution` input field exists.

**Source:** `evolution/core/dataset_builder.py` lines 89-169

**Verbatim actual code:**

```python
class SyntheticDatasetBuilder:
    class GenerateTestCases(dspy.Signature):
        """Generate realistic evaluation test cases for an agent skill or tool."""
        artifact_text: str = dspy.InputField(desc="The full text of the skill/tool/prompt being tested")
        artifact_type: str = dspy.InputField(desc="Type: 'skill', 'tool_description', or 'prompt_section'")
        num_cases: int = dspy.InputField(desc="Number of test cases to generate")
        test_cases: str = dspy.OutputField(desc="JSON array of test cases, each with: task_input, expected_behavior, difficulty, category")

    def __init__(self, config: EvolutionConfig):
        self.config = config
        self.generator = dspy.ChainOfThought(self.GenerateTestCases)

    def generate(
        self,
        artifact_text: str,
        artifact_type: str = "skill",
        num_cases: Optional[int] = None,
    ) -> EvalDataset:
```

**Key differences from doc:**
- Input: `artifact_text` / `artifact_type` / `num_cases`, not `skill_text` / `num_examples` / `difficulty_distribution`
- Output: `test_cases: str` (JSON string), not `test_cases: list`
- Method: `generate()`, not `build()`
- Constructor: `__init__(self, config: EvolutionConfig)`, not shown in doc
- No `difficulty_distribution` parameter; the `"40% easy, 40% medium, 20% hard"` string shown in doc does not exist

---

## Correction 12: EvalDataset.to_dspy_examples Field Name

**Section 2.5 -- Dataset Splits**

**What the doc says:**
```python
def to_dspy_examples(self, split: str = "train") -> list[dspy.Example]:
    examples = getattr(self, split)
    return [
        dspy.Example(task_input=ex.task_input, output=ex.expected_behavior).with_inputs("task_input")
        for ex in examples
    ]
```

**What the actual code is:**
The DSPy Example uses `expected_behavior` as the field name (not `output`). This matters because DSPy field names must match between training examples and signature fields.

**Source:** `evolution/core/dataset_builder.py` lines 77-86

**Verbatim actual code:**

```python
def to_dspy_examples(self, split: str = "train") -> list[dspy.Example]:
    """Convert a split to DSPy Example objects."""
    data = getattr(self, split)
    return [
        dspy.Example(
            task_input=ex.task_input,
            expected_behavior=ex.expected_behavior,
        ).with_inputs("task_input")
        for ex in data
    ]
```

**Key difference from doc:**
- Doc uses `output=ex.expected_behavior` (renamed to `output`); actual preserves the field name as `expected_behavior=ex.expected_behavior`

---

## Correction 13: config.py Discovery Function and Env Var Name

**Section 6.2 -- Evolution Configuration**

**What the doc says:**
```python
def _discover_hermes_agent_path() -> Optional[Path]:
    env_path = os.environ.get("HERMES_AGENT_PATH")
    if env_path:
        return Path(env_path)
    # ...
    sibling = cwd.parent / "hermes-agent"
```

**What the actual code is:**
`_discover_hermes_agent_path` is a thin wrapper around `get_hermes_agent_path()`. The env var is `HERMES_AGENT_REPO` (not `HERMES_AGENT_PATH`). Sibling lookup uses `Path(__file__).parent.parent.parent` (not `cwd.parent`). `get_hermes_agent_path()` raises `FileNotFoundError` on failure (the wrapper catches it).

**Source:** `evolution/core/config.py` lines 50-88

**Verbatim actual code:**

```python
def _discover_hermes_agent_path() -> Optional[Path]:
    """Best-effort hermes-agent repo discovery that never raises."""
    try:
        return get_hermes_agent_path()
    except FileNotFoundError:
        return None


def get_hermes_agent_path() -> Path:
    """Discover the hermes-agent repo path.

    Priority:
    1. HERMES_AGENT_REPO env var
    2. ~/.hermes/hermes-agent (standard install location)
    3. ../hermes-agent (sibling directory)
    """
    env_path = os.getenv("HERMES_AGENT_REPO")
    if env_path:
        p = Path(env_path).expanduser()
        if p.exists():
            return p

    home_path = Path.home() / ".hermes" / "hermes-agent"
    if home_path.exists():
        return home_path

    sibling_path = Path(__file__).parent.parent.parent / "hermes-agent"
    if sibling_path.exists():
        return sibling_path

    raise FileNotFoundError(
        "Cannot find hermes-agent repo. Set HERMES_AGENT_REPO env var "
        "or ensure it exists at ~/.hermes/hermes-agent"
    )
```

**Key differences from doc:**
- Env var: `HERMES_AGENT_REPO`, not `HERMES_AGENT_PATH`
- `_discover_hermes_agent_path` is a try/except wrapper, not the inline logic shown in doc
- Sibling: `Path(__file__).parent.parent.parent / "hermes-agent"`, not `cwd.parent / "hermes-agent"`
- `get_hermes_agent_path()` raises `FileNotFoundError`, not returns `None`
- Uses `Path(env_path).expanduser()` with `.exists()` check

---

## Summary

| # | Section | Severity | Issue |
|---|---------|----------|-------|
| 1 | 2.1 Importers | HIGH | Method name `import_sessions` is fabricated; actual is `extract_messages`. `ConversationTurn` type does not exist. |
| 2 | 2.2 Secrets | MEDIUM | `SECRET_PATTERNS` structure fabricated (list of compiles vs single compile). Individual regex syntax wrong. |
| 3 | 2.3 RelevanceFilter | HIGH | Constructor, method name, parameter list, return type, and threshold logic all fabricated. |
| 4 | 2.3 ScoreRelevance | HIGH | Input/output fields fabricated. 4 inputs + 1 JSON output, not 2 inputs + float + reasoning. |
| 5 | 3.1 ConstraintValidator | MEDIUM | Return type, parameter signature, and internal structure fabricated. |
| 6 | 3.2 FitnessScore | LOW | Property name `weighted_total` is fabricated; actual is `composite`. Missing `feedback` field. |
| 7 | 3.2 LLMJudge | MEDIUM | Output fields, score method signature, and scoring scale all fabricated. |
| 8 | 3.3 skill_fitness_metric | LOW | Field names wrong (`example.output` vs `example.expected_behavior`). Logic subtly different. |
| 9 | 4.1 evolve_skill | HIGH | Function name, GEPA class name, parameter names, and defaults all fabricated. |
| 10 | 4.2 load_skill | MEDIUM | Return type fabricated (dict vs tuple). Frontmatter stored as str, not parsed YAML. |
| 11 | 2.4 SyntheticDatasetBuilder | MEDIUM | Field names, method name, constructor all fabricated. |
| 12 | 2.5 to_dspy_examples | LOW | DSPy field renamed from `expected_behavior` to `output` in doc. |
| 13 | 6.2 config.py | LOW | Env var name wrong. Discovery function structure fabricated. |
