# Hermes Agent: Training, Fine-Tuning & Continuous Improvement

**Research Date:** 2026-06-30
**Source Repos:**
- `NousResearch/hermes-agent` (main agent — private/empty on public clone)
- `NousResearch/hermes-agent-self-evolution` (instruction/skill optimization)
- `NousResearch/tinker-atropos` (RL weight training via Tinker API)
- `NousResearch/hermes-compression-eval` (compression quality evaluation)

---

## 1. Training Pipeline Overview

Hermes Agent uses a **three-layer improvement architecture** where each layer operates independently and targets a different optimization surface:

| Layer | Target | Method | GPU Required? |
|-------|--------|--------|---------------|
| **Model Weights** | Base LLM parameters | RL (Atropos + Tinker LoRA) | Yes (remote via Tinker API) |
| **Instructions** | Skill text / system prompts | DSPy GEPA evolution | No (API calls only) |
| **Tool Code** | Tool implementations | Darwinian Evolver (git-based) | No (code execution only) |

### Architecture Diagram (Data Flow)

```
Real Conversations (Claude/Copilot/Hermes sessions)
        │
        ▼
┌─────────────────────────────────┐
│  External Importers              │
│  (secret scrubbing, relevance   │
│   filtering, LLM scoring)       │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  EvalDataset (train/val/holdout) │
│  JSONL splits, DSPy-compatible   │
└──────┬──────────────┬───────────┘
       │              │
       ▼              ▼
┌────────────┐  ┌──────────────────┐
│ Skill Evo  │  │ Atropos RL Envs  │
│ (DSPy GEPA │  │ (trajectory      │
│  or MIPROv2)│  │  collection)     │
└─────┬──────┘  └───────┬──────────┘
      │                  │
      ▼                  ▼
┌────────────┐  ┌──────────────────┐
│ Evolved    │  │ Tinker API       │
│ SKILL.md   │  │ (LoRA training,  │
│ files      │  │  importance      │
│            │  │  sampling loss)  │
└─────┬──────┘  └───────┬──────────┘
      │                  │
      ▼                  ▼
┌─────────────────────────────────┐
│  Benchmark Gating               │
│  (TBLite, YC-Bench,            │
│   TerminalBench2, pytest)       │
└─────────────────────────────────┘
```

### Key Design Principles

1. **No GPU required for instruction evolution** — everything via API calls
2. **On-policy distillation** for weight training (logp_teacher - logp_student as per-token advantages)
3. **Importance sampling loss** for stable RL updates
4. **Benchmark gating** prevents regression (TBLite threshold: 2%)
5. **Secret detection** at data ingestion — 20+ regex patterns block sensitive data from entering training pipelines

---

## 2. Data Generation & Collection

### 2.1 External Session Importers

**File:** `/tmp/hermes-agent-evolution/evolution/core/external_importers.py` (786 lines)

Three importers collect real conversation data from developer sessions:

```python
class ClaudeCodeImporter:
    """Import from Claude Code history (~/.claude/history.jsonl)."""
    
    def import_sessions(self) -> list[ConversationTurn]:
        history_path = Path.home() / ".claude" / "history.jsonl"
        # Reads JSONL, extracts user/assistant pairs
        # Applies secret scrubbing before returning


class CopilotImporter:
    """Import from GitHub Copilot sessions."""
    
    def import_sessions(self) -> list[ConversationTurn]:
        # Reads ~/.copilot/session-state/*/events.jsonl
        # Extracts user.message / assistant.message pairs


class HermesSessionImporter:
    """Import from Hermes Agent's own sessions."""
    
    def import_sessions(self) -> list[ConversationTurn]:
        # Reads ~/.hermes/sessions/*.json
        # OpenAI-format message lists
```

### 2.2 Secret Detection (Pre-Training Safety Gate)

**File:** `/tmp/hermes-agent-evolution/evolution/core/external_importers.py`

All imported data passes through secret detection before entering any training pipeline:

```python
SECRET_PATTERNS = [
    re.compile(r'sk-ant-[a-zA-Z0-9_-]{20,}'),           # Anthropic API keys
    re.compile(r'sk-or-v1-[a-zA-Z0-9]{48,}'),           # OpenRouter keys
    re.compile(r'ghp_[a-zA-Z0-9]{36,}'),                # GitHub PATs
    re.compile(r'gho_[a-zA-Z0-9]{36,}'),                # GitHub OAuth
    re.compile(r'xoxb-[0-9]+-[a-zA-Z0-9]+'),            # Slack bot tokens
    re.compile(r'xoxp-[0-9]+-[a-zA-Z0-9]+'),            # Slack user tokens
    re.compile(r'AKIA[0-9A-Z]{16}'),                     # AWS access keys
    re.compile(r'-----BEGIN (?:RSA |EC )?PRIVATE KEY'), # PEM private keys
    re.compile(r'(?:password|secret|token|api_key)\s*[=:]\s*["\']?[^\s"\']{8,}', re.I),
    # ... 20+ total patterns
]
```

Any conversation turn matching these patterns is **dropped entirely** — not redacted, dropped.

### 2.3 Relevance Filtering (Two-Stage)

**File:** `/tmp/hermes-agent-evolution/evolution/core/external_importers.py`

```python
class RelevanceFilter:
    """Two-stage relevance filtering: heuristic pre-filter + LLM scoring."""
    
    def __init__(self, skill_name: str, skill_text: str, model: str):
        self.skill_name = skill_name
        self.skill_text = skill_text
        self.model = model
    
    def filter(self, turns: list[ConversationTurn]) -> list[ConversationTurn]:
        # Stage 1: Heuristic pre-filter (keyword matching, length checks)
        candidates = [t for t in turns if self._heuristic_pass(t)]
        
        # Stage 2: LLM relevance scoring via DSPy
        scored = []
        for turn in candidates:
            score = self._llm_score(turn)
            if score >= 0.6:  # Relevance threshold
                scored.append(turn)
        return scored


class ScoreRelevance(dspy.Signature):
    """Score how relevant a conversation turn is to a specific skill."""
    skill_description: str = dspy.InputField()
    conversation_turn: str = dspy.InputField()
    relevance_score: float = dspy.OutputField(desc="0.0 to 1.0")
    reasoning: str = dspy.OutputField()
```

### 2.4 Synthetic Dataset Generation

**File:** `/tmp/hermes-agent-evolution/evolution/core/dataset_builder.py`

```python
@dataclass
class EvalExample:
    task_input: str
    expected_behavior: str
    difficulty: str          # "easy", "medium", "hard"
    category: str            # skill-specific category
    source: str              # "synthetic", "golden", "session"


class SyntheticDatasetBuilder:
    """Generate synthetic test cases using DSPy ChainOfThought."""
    
    class GenerateTestCases(dspy.Signature):
        """Generate diverse test cases for evaluating an agent skill."""
        skill_text: str = dspy.InputField(desc="The skill being tested")
        num_examples: int = dspy.InputField(desc="How many to generate")
        difficulty_distribution: str = dspy.InputField()
        test_cases: list = dspy.OutputField()
    
    def build(self, skill_text: str, num_examples: int = 20) -> EvalDataset:
        generator = dspy.ChainOfThought(self.GenerateTestCases)
        result = generator(
            skill_text=skill_text,
            num_examples=num_examples,
            difficulty_distribution="40% easy, 40% medium, 20% hard"
        )
        # Parse, validate, split into train/val/holdout
        return self._split_dataset(result.test_cases)
```

### 2.5 Dataset Splits & Persistence

```python
class EvalDataset:
    train: list[EvalExample]
    val: list[EvalExample]
    holdout: list[EvalExample]
    
    def save(self, path: Path):
        """Save as JSONL with split markers."""
        for split_name, examples in [("train", self.train), ("val", self.val), ("holdout", self.holdout)]:
            split_path = path / f"{split_name}.jsonl"
            with open(split_path, "w") as f:
                for ex in examples:
                    f.write(json.dumps(asdict(ex)) + "\n")
    
    def to_dspy_examples(self, split: str = "train") -> list[dspy.Example]:
        """Convert to DSPy format for optimizer consumption."""
        examples = getattr(self, split)
        return [
            dspy.Example(task_input=ex.task_input, output=ex.expected_behavior).with_inputs("task_input")
            for ex in examples
        ]
```

**Default split ratios (from config):**
- Train: 50%
- Validation: 25%
- Holdout: 25%

### 2.6 CLI for Dataset Building

```bash
# Build dataset from external sessions for a specific skill
python -m evolution.core.external_importers \
    --source claude \
    --skill "arxiv-research" \
    --model "openai/gpt-4.1-mini" \
    --max-examples 50 \
    --dry-run  # Preview without saving
```

---

## 3. Quality Filtering & Constraints

### 3.1 Constraint Validation System

**File:** `/tmp/hermes-agent-evolution/evolution/core/constraints.py`

```python
class ConstraintValidator:
    """Validates evolved artifacts against hard constraints."""
    
    def __init__(self, config: EvolutionConfig):
        self.max_skill_size = config.max_skill_size          # 15,000 chars
        self.max_tool_desc = config.max_tool_desc_size       # 500 chars
        self.max_param_desc = config.max_param_desc_size     # 200 chars
        self.max_growth = config.max_prompt_growth           # 0.2 (20%)
        self.run_pytest = config.run_pytest
    
    def validate_all(self, evolved_text: str, baseline_text: str) -> tuple[bool, list[str]]:
        """Run all constraint checks. Returns (passed, list_of_violations)."""
        violations = []
        violations.extend(self._check_size(evolved_text))
        violations.extend(self._check_growth(evolved_text, baseline_text))
        violations.extend(self._check_non_empty(evolved_text))
        violations.extend(self._check_skill_structure(evolved_text))
        if self.run_pytest:
            violations.extend(self.run_test_suite())
        return (len(violations) == 0, violations)
    
    def _check_size(self, text: str) -> list[str]:
        if len(text) > self.max_skill_size:
            return [f"Skill exceeds {self.max_skill_size} chars: {len(text)}"]
        return []
    
    def _check_growth(self, evolved: str, baseline: str) -> list[str]:
        growth = (len(evolved) - len(baseline)) / max(len(baseline), 1)
        if growth > self.max_growth:
            return [f"Growth {growth:.1%} exceeds {self.max_growth:.0%} limit"]
        return []
    
    def _check_skill_structure(self, text: str) -> list[str]:
        """Verify YAML frontmatter with required name + description fields."""
        if not text.startswith("---"):
            return ["Missing YAML frontmatter delimiter"]
        # Parse frontmatter, check for 'name' and 'description' keys
        ...
```

### 3.2 Fitness Scoring (LLM-as-Judge)

**File:** `/tmp/hermes-agent-evolution/evolution/core/fitness.py`

```python
@dataclass
class FitnessScore:
    correctness: float       # Weight: 0.5
    procedure_following: float  # Weight: 0.3
    conciseness: float       # Weight: 0.2
    length_penalty: float    # 0.0 to 0.3 (ramps from 90% to 100%+ of size limit)
    
    @property
    def weighted_total(self) -> float:
        raw = (self.correctness * 0.5 +
               self.procedure_following * 0.3 +
               self.conciseness * 0.2)
        return raw - self.length_penalty


class LLMJudge:
    """Score agent outputs using a judge model."""
    
    class JudgeSignature(dspy.Signature):
        """Evaluate agent output quality across multiple dimensions."""
        task_input: str = dspy.InputField()
        expected_behavior: str = dspy.InputField()
        agent_output: str = dspy.InputField()
        skill_text: str = dspy.InputField()
        scores: str = dspy.OutputField(desc="JSON with correctness, procedure_following, conciseness (each 0-5)")
        feedback: str = dspy.OutputField()
    
    def score(self, example: EvalExample, output: str, skill_text: str) -> FitnessScore:
        judge = dspy.ChainOfThought(self.JudgeSignature)
        result = judge(
            task_input=example.task_input,
            expected_behavior=example.expected_behavior,
            agent_output=output,
            skill_text=skill_text
        )
        scores = json.loads(result.scores)
        return FitnessScore(
            correctness=scores["correctness"] / 5.0,
            procedure_following=scores["procedure_following"] / 5.0,
            conciseness=scores["conciseness"] / 5.0,
            length_penalty=self._calc_length_penalty(output, skill_text)
        )
```

### 3.3 Fast Proxy Metric (No LLM Call)

```python
def skill_fitness_metric(example: dspy.Example, prediction: dspy.Prediction, trace=None) -> float:
    """Fast proxy fitness using keyword overlap. Used during GEPA inner loops."""
    expected = set(example.output.lower().split())
    predicted = set(prediction.output.lower().split())
    if not expected:
        return 0.3
    overlap = len(expected & predicted) / len(expected)
    return 0.3 + 0.7 * overlap
```

### 3.4 Benchmark Gating

From `/tmp/hermes-agent-evolution/PLAN.md`:

```
Regression Prevention:
- TBLite (TerminalBench Lite): 2% regression threshold blocks merge
- pytest: Full test suite must pass
- YC-Bench: Startup task evaluation
- TerminalBench2: Real terminal task performance

Config:
  run_pytest: true (default)
  run_tblite: false (opt-in, requires API access)
  tblite_regression_threshold: 0.02
```

---

## 4. Fine-Tuning Process

### 4.1 Instruction-Level Optimization (DSPy GEPA)

**File:** `/tmp/hermes-agent-evolution/evolution/skills/evolve_skill.py`

GEPA = Genetic-Pareto Prompt Evolution (ICLR 2026 Oral). It treats skill text as an optimizable parameter and evolves it using genetic operations (mutation, crossover) with Pareto-optimal selection.

```python
def evolve_skill(
    skill: str,
    iterations: int = 10,
    eval_source: str = "synthetic",  # or "golden" or "sessiondb"
    dataset_path: Optional[str] = None,
    optimizer_model: str = "openai/gpt-4.1",
    eval_model: str = "openai/gpt-4.1-mini",
    hermes_repo: Optional[str] = None,
    run_tests: bool = True,
    dry_run: bool = False,
):
    """
    10-step skill optimization pipeline:
    
    1. Find skill file in hermes-agent repo
    2. Build evaluation dataset (synthetic/golden/session-derived)
    3. Validate baseline performance
    4. Configure DSPy with optimizer model
    5. Run GEPA optimizer (fallback: MIPROv2 if GEPA unavailable)
    6. Extract evolved text from optimized module
    7. Validate evolved text against constraints
    8. Evaluate on holdout set
    9. Generate metrics report
    10. Save artifacts to output/<skill>/<timestamp>/
    """
    
    # Step 1: Find skill
    config = EvolutionConfig(hermes_agent_path=hermes_repo)
    repo_path = config.get_hermes_agent_path()
    skill_path, skill_text = find_skill(skill, repo_path / "skills")
    
    # Step 2: Build dataset
    if eval_source == "synthetic":
        builder = SyntheticDatasetBuilder(model=eval_model)
        dataset = builder.build(skill_text, num_examples=config.eval_dataset_size)
    elif eval_source == "golden":
        dataset = GoldenDatasetLoader(dataset_path).load()
    elif eval_source == "sessiondb":
        dataset = build_dataset_from_external(source="hermes", skill=skill)
    
    # Step 3: Baseline
    module = SkillModule(skill_text)
    baseline_scores = evaluate(module, dataset.val)
    
    # Step 4: Configure DSPy
    dspy.configure(lm=dspy.LM(optimizer_model))
    
    # Step 5: Optimize
    try:
        optimizer = dspy.GEPAv1(
            metric=skill_fitness_metric,
            num_iterations=iterations,
            population_size=config.population_size,
        )
    except AttributeError:
        # Fallback if GEPA not available in installed DSPy version
        optimizer = dspy.MIPROv2(
            metric=skill_fitness_metric,
            num_candidates=config.population_size,
        )
    
    optimized_module = optimizer.compile(
        module,
        trainset=dataset.to_dspy_examples("train"),
        valset=dataset.to_dspy_examples("val"),
    )
    
    # Step 6: Extract evolved text
    evolved_text = optimized_module.skill_text  # DSPy optimized the parameter
    
    # Step 7: Validate constraints
    validator = ConstraintValidator(config)
    passed, violations = validator.validate_all(evolved_text, skill_text)
    if not passed:
        raise EvolutionConstraintError(violations)
    
    # Step 8: Holdout evaluation
    holdout_scores = evaluate(optimized_module, dataset.holdout)
    
    # Step 9-10: Report and save
    save_evolution_artifacts(skill, evolved_text, skill_text, baseline_scores, holdout_scores)
```

### 4.2 Skill Module (DSPy Integration)

**File:** `/tmp/hermes-agent-evolution/evolution/skills/skill_module.py`

```python
class SkillModule(dspy.Module):
    """Wraps a skill's text as an optimizable DSPy parameter."""
    
    class TaskWithSkill(dspy.Signature):
        """Execute a task following skill instructions."""
        skill_instructions: str = dspy.InputField(
            desc="The skill text that guides how to approach the task"
        )
        task_input: str = dspy.InputField(
            desc="The task to perform"
        )
        output: str = dspy.OutputField(
            desc="The agent's response following the skill"
        )
    
    def __init__(self, skill_text: str):
        super().__init__()
        self.skill_text = skill_text  # This becomes a DSPy-optimizable parameter
        self.predictor = dspy.ChainOfThought(self.TaskWithSkill)
    
    def forward(self, task_input: str) -> dspy.Prediction:
        result = self.predictor(
            skill_instructions=self.skill_text,
            task_input=task_input
        )
        return dspy.Prediction(output=result.output)


def load_skill(path: Path) -> tuple[dict, str]:
    """Parse SKILL.md: YAML frontmatter + markdown body."""
    content = path.read_text()
    # Split on --- delimiters
    parts = content.split("---", 2)
    frontmatter = yaml.safe_load(parts[1])
    body = parts[2].strip()
    return frontmatter, body


def reassemble_skill(frontmatter: dict, evolved_body: str) -> str:
    """Rejoin frontmatter + evolved body into valid SKILL.md."""
    fm_text = yaml.dump(frontmatter, default_flow_style=False)
    return f"---\n{fm_text}---\n\n{evolved_body}"
```

### 4.3 Weight-Level Training (Tinker + Atropos)

**File:** `/tmp/tinker-atropos/tinker_atropos/trainer.py` (867 lines)

LoRA fine-tuning via remote Tinker API with Atropos RL environments:

```python
class TinkerAtroposTrainer:
    """RL trainer using Tinker API for remote LoRA training."""
    
    def setup(self):
        """Initialize training and sampling clients."""
        self.training_client = TinkerClient(
            api_key=os.environ["TINKER_API_KEY"],
            model=self.config.base_model,
            lora_rank=self.config.lora_rank,
        )
        self.sampling_client = TinkerClient(
            api_key=os.environ["TINKER_API_KEY"],
            model=self.config.base_model,
        )
    
    async def train_step(self, batch):
        """
        Single training step:
        1. Fetch batch from Atropos environment
        2. Calculate advantages via on-policy distillation
        3. Compute loss and update weights
        """
        # Get trajectories from environment
        trajectories = await self.fetch_batch(batch)
        
        # On-policy distillation: logp_teacher - logp_student as per-token advantages
        # K=1 only for Tinker (per-token advantages)
        # K>1 requires torchtitan (group-relative advantages)
        advantages = self.compute_advantages(trajectories)
        
        # Forward-backward with importance sampling loss
        await self.training_client.forward_backward_async(
            input_ids=trajectories.input_ids,
            advantages=advantages,
            loss_fn="importance_sampling",
        )
        
        # Optimizer step (Adam)
        await self.training_client.optim_step_async(
            optimizer="adam",
            lr=self.config.learning_rate,     # 4e-5
            beta1=0.9,
            beta2=0.95,
        )
        
        # Sync weights to sampling client
        await self.training_client.save_weights_async()
        await self.sampling_client.load_weights_async()
    
    async def run(self):
        """Main training loop."""
        self.setup()
        for step in range(self.config.num_steps):
            batch = await self.get_batch_from_atropos()
            metrics = await self.train_step(batch)
            if self.config.use_wandb:
                wandb.log(metrics, step=step)
            if step % self.config.save_checkpoint_interval == 0:
                await self.save_checkpoint(step)
```

### 4.4 Training Configuration

**File:** `/tmp/tinker-atropos/configs/default.yaml`

```yaml
# Environment configuration (Atropos)
env:
  group_size: 16              # Completions per prompt
  batch_size: 128             # Prompts per batch
  max_batches_offpolicy: 3    # Max off-policy batches before refresh
  tokenizer_name: "meta-llama/Llama-3.1-8B-Instruct"
  use_wandb: true
  rollout_server_url: "http://localhost:8000"
  max_token_length: 256       # Max generation length
  max_num_workers: 24         # Parallel environment workers
  total_steps: 50             # Training steps
  steps_per_eval: 100         # Eval frequency

# Inference server (OpenAI-compatible)
openai:
  - model_name: "meta-llama/Llama-3.1-8B-Instruct"
    base_url: "http://localhost:8001/v1"
    api_key: "x"
    weight: 1.0
    num_requests_for_eval: 256

# Tinker-specific training config
tinker:
  lora_rank: 32                       # LoRA rank
  learning_rate: 0.00004              # 4e-5
  max_token_trainer_length: 2048      # Max sequence length for training
  checkpoint_dir: "./temp/"
  save_checkpoint_interval: 0         # 0 = don't save intermediate
  wandb_project: "atropos-tinker"
  wandb_group: null                   # Auto-generated if not specified
  wandb_run_name: "atropos-tinker-run"
```

### 4.5 FastAPI Inference Server (During Training)

**File:** `/tmp/tinker-atropos/tinker_atropos/trainer.py`

The trainer spins up an OpenAI-compatible inference server so environments can query the current model weights during training:

```python
from fastapi import FastAPI
import uvicorn

app = FastAPI()

@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    """OpenAI-compatible endpoint serving current LoRA weights."""
    global trainer
    response = await trainer.sampling_client.generate(
        messages=request.messages,
        n=request.n,
        max_tokens=request.max_tokens,
        temperature=request.temperature,
        stop=request.stop,
    )
    return response

def run_fastapi_server():
    uvicorn.run(app, host="0.0.0.0", port=8001)
```

### 4.6 Training Launch

**File:** `/tmp/tinker-atropos/launch_training.py`

```python
async def main():
    """Launch training with YAML config + CLI overrides."""
    args = parse_args()
    config = load_config(args)
    
    # Initialize trainer
    trainer = TinkerAtroposTrainer(config=config)
    trainer_module.trainer = trainer  # Global ref for FastAPI endpoints
    
    # Start inference server in background
    server_thread = threading.Thread(target=run_fastapi_server, daemon=True)
    server_thread.start()
    await asyncio.sleep(3)  # Wait for server startup
    
    # Run training
    await trainer.run()
```

**CLI usage:**

```bash
# Three terminals required:

# Terminal 1: Atropos API server
run-api

# Terminal 2: Training loop
export TINKER_API_KEY="<your-key>"
python launch_training.py --config configs/default.yaml

# Terminal 3: Environment (any Atropos-compatible env)
python tinker_atropos/environments/gsm8k_tinker.py serve --config configs/default.yaml
```

---

## 5. Evaluation Loop

### 5.1 Compression Evaluation (Probe-Based)

**File:** `/tmp/hermes-compression-eval/DESIGN.md`

Six-dimension evaluation for context compression quality:

| Dimension | What it measures |
|-----------|-----------------|
| accuracy | File paths, function names, error codes are correct |
| context_awareness | Reflects current state, not a mid-session snapshot |
| artifact_trail | Knows which files were read / modified / created |
| completeness | Addresses all parts of the probe |
| continuity | Agent can continue without re-fetching |
| instruction_following | Probe answered in the requested form |

**Scoring:** 0-5 per dimension, per probe. Median over N=3 runs. Significance threshold: improvement >= 0.3 before claiming a win.

**Probe types:** recall, artifact, continuation, decision

```json
{
  "fixture": "feature-impl-context-priority",
  "probes": [
    {
      "id": "recall-error-code",
      "type": "recall",
      "question": "What was the original error code and endpoint?",
      "expected_facts": ["401", "/api/auth/login"]
    },
    {
      "id": "artifact-files-modified",
      "type": "artifact",
      "question": "Which files have been modified in this session?",
      "expected_facts": ["session_store.py", "redis_client.py"]
    }
  ]
}
```

**Cost:** ~$0.50-1.50 per full eval (3 fixtures x 10 probes x 3 runs = 90 judge calls)

### 5.2 Skill Evolution Evaluation

From the evolution pipeline, evaluation happens at three points:

1. **Baseline measurement** (before optimization)
2. **Validation set** (during optimization — guides GEPA selection)
3. **Holdout set** (after optimization — final report)

```python
def evaluate(module: SkillModule, examples: list[EvalExample]) -> dict:
    """Run module against examples, return dimension scores."""
    judge = LLMJudge(model=config.judge_model)
    scores = []
    for ex in examples:
        prediction = module(task_input=ex.task_input)
        score = judge.score(ex, prediction.output, module.skill_text)
        scores.append(score)
    return {
        "correctness": median([s.correctness for s in scores]),
        "procedure_following": median([s.procedure_following for s in scores]),
        "conciseness": median([s.conciseness for s in scores]),
        "overall": median([s.weighted_total for s in scores]),
    }
```

### 5.3 Evolution Report (Phase 1 Validation)

**File:** `/tmp/hermes-agent-evolution/generate_report.py`

Documented results from Phase 1 validation:

```
Result: +39.5% improvement on arxiv skill
Model: MiniMax M2.5 via OpenRouter
Optimizer: DSPy BootstrapFewShot
Time: <60 seconds
Cost: <$0.50
```

### 5.4 Noise Floor Measurement

From compression eval design:

```
Non-determinism caveat: two runs of the same fixture produce different scores.
A single run means nothing.

Empirical data point (gpt-5.4-mini, runs=1):
- Run A overall: 3.25
- Run B overall: 3.17 (delta -0.08)
- Individual dimensions: ±0.5 variance

Guidance: < 0.3 delta is noise on single-run comparisons.
With runs=3, per-dimension variance tightens.
```

---

## 6. Continuous Improvement Cycle

### 6.1 The Three-Layer Loop

```
┌─────────────────────────────────────────────────────────────┐
│                    CONTINUOUS IMPROVEMENT                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Layer 1: WEIGHT TRAINING (Tinker + Atropos)                │
│  ┌──────────────────────────────────────────┐               │
│  │ Collect trajectories from RL envs        │               │
│  │ → On-policy distillation advantages      │               │
│  │ → Importance sampling loss               │               │
│  │ → LoRA weight updates (rank 32, lr 4e-5) │               │
│  │ → Updated sampling weights               │               │
│  │ Trigger: Continuous (50-step runs)        │               │
│  └──────────────────────────────────────────┘               │
│                                                              │
│  Layer 2: INSTRUCTION EVOLUTION (DSPy GEPA)                 │
│  ┌──────────────────────────────────────────┐               │
│  │ Import real sessions as eval data        │               │
│  │ → Filter for relevance + scrub secrets   │               │
│  │ → Build train/val/holdout splits         │               │
│  │ → GEPA genetic optimization (10 iters)   │               │
│  │ → Constraint validation (size, growth)   │               │
│  │ → Holdout evaluation + benchmark gating  │               │
│  │ → Deploy evolved SKILL.md files          │               │
│  │ Trigger: Before merging prompt changes   │               │
│  └──────────────────────────────────────────┘               │
│                                                              │
│  Layer 3: TOOL CODE EVOLUTION (Darwinian Evolver)           │
│  ┌──────────────────────────────────────────┐               │
│  │ Git-based code organisms                 │               │
│  │ → Mutation + crossover on tool impls     │               │
│  │ → Fitness = test pass rate + perf        │               │
│  │ → Constraint: AGPL v3, external CLI only │               │
│  │ Trigger: On-demand for tool improvement  │               │
│  └──────────────────────────────────────────┘               │
│                                                              │
│  GATING: All layers must pass benchmarks before deployment  │
│  - TBLite: 2% regression threshold                          │
│  - pytest: Full suite must pass                             │
│  - Constraint validator: Size, growth, structure            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Evolution Configuration

**File:** `/tmp/hermes-agent-evolution/evolution/core/config.py`

```python
@dataclass
class EvolutionConfig:
    """Complete configuration for the self-evolution system."""
    
    # Repository discovery
    hermes_agent_path: Optional[Path] = field(
        default_factory=lambda: _discover_hermes_agent_path()
    )
    
    # Optimization parameters
    iterations: int = 10                    # GEPA generations
    population_size: int = 5               # Candidates per generation
    
    # Model selection
    optimizer_model: str = "openai/gpt-4.1"      # Drives evolution
    eval_model: str = "openai/gpt-4.1-mini"      # Generates synthetic data
    judge_model: str = "openai/gpt-4.1"          # Scores outputs
    
    # Constraints (hard limits)
    max_skill_size: int = 15_000           # 15KB per skill
    max_tool_desc_size: int = 500          # Tool description chars
    max_param_desc_size: int = 200         # Param description chars
    max_prompt_growth: float = 0.2         # Max 20% growth over baseline
    
    # Dataset configuration
    eval_dataset_size: int = 20            # Examples per dataset
    train_ratio: float = 0.5
    val_ratio: float = 0.25
    holdout_ratio: float = 0.25
    
    # Safety gates
    run_pytest: bool = True                # Always run tests
    run_tblite: bool = False               # Opt-in benchmark
    tblite_regression_threshold: float = 0.02  # 2% max regression


def _discover_hermes_agent_path() -> Optional[Path]:
    """Auto-discover hermes-agent repo location."""
    # Priority: env var > ~/.hermes/hermes-agent > sibling directory
    env_path = os.environ.get("HERMES_AGENT_PATH")
    if env_path:
        return Path(env_path)
    home_path = Path.home() / ".hermes" / "hermes-agent"
    if home_path.exists():
        return home_path
    # Check sibling directories
    cwd = Path.cwd()
    sibling = cwd.parent / "hermes-agent"
    if sibling.exists():
        return sibling
    return None
```

### 6.3 End-to-End Pipeline (5 Phases)

From `/tmp/hermes-agent-evolution/PLAN.md`:

| Phase | Name | Duration | What It Does |
|-------|------|----------|--------------|
| 1 | Single-Skill Evolution | 2-3 weeks | Prove GEPA works on one skill end-to-end |
| 2 | Multi-Skill + Session Data | 3-4 weeks | Scale to all skills, integrate real session importers |
| 3 | Tool Registry Evolution | 3-4 weeks | Evolve tool descriptions and parameter schemas |
| 4 | Darwinian Code Evolution | 2-3 weeks | Evolve tool implementations via git-based organisms |
| 5 | Continuous Loop | 3-4 weeks | Automated scheduling, regression detection, deployment |

### 6.4 Integration Points with Hermes Agent

```
hermes-agent repo:
├── skills/              ← GEPA evolves these SKILL.md files
├── tools/registry.py    ← Phase 3 evolves tool descriptions
├── tools/*.py           ← Phase 4 Darwinian evolution targets
├── prompt_builder.py    ← System prompt, evolved indirectly
├── batch_runner.py      ← Runs trajectories for Atropos RL
└── trajectory.py        ← Stores session data for training
```

### 6.5 Version Control of Improvements

Each evolution run produces timestamped artifacts:

```
output/
├── arxiv-research/
│   ├── 2026-06-15T14-30-00/
│   │   ├── evolved_skill.md      # The improved skill text
│   │   ├── baseline_skill.md     # Original for comparison
│   │   ├── metrics.json          # Scores: baseline vs evolved
│   │   ├── dataset/              # The eval dataset used
│   │   │   ├── train.jsonl
│   │   │   ├── val.jsonl
│   │   │   └── holdout.jsonl
│   │   └── evolution_log.json    # Per-iteration population scores
│   └── 2026-06-20T09-15-00/
│       └── ...
└── code-review/
    └── ...
```

### 6.6 Deployment Path

1. **Evolution run completes** with holdout improvement >= 0.3
2. **Constraint validator passes** (size, growth, structure, pytest)
3. **Benchmark gate passes** (TBLite regression < 2%)
4. **PR created** with evolved skill + metrics report
5. **Human review** — the evolved text is readable markdown
6. **Merge** updates the live skill in hermes-agent

---

## Key Takeaways

1. **No single "training" script** — improvement is distributed across three independent optimization loops, each with its own trigger and deployment path.

2. **Real session data as training signal** — Claude Code, Copilot, and Hermes session histories feed both the RL environment (trajectories for weight training) and the evolution system (eval examples for instruction optimization).

3. **Safety is non-negotiable** — 20+ secret patterns blocked at import time, constraint validators enforce size/growth limits, benchmark gates prevent regressions.

4. **Instruction evolution is the main innovation** — GEPA (ICLR 2026 Oral) enables genetic-Pareto optimization of prompt text without any GPU training. The Phase 1 validation showed +39.5% improvement on a single skill in <60s for <$0.50.

5. **Weight training is commodity** — Tinker API abstracts away GPU infrastructure. The novel contribution is the on-policy distillation approach (logp_teacher - logp_student) with importance sampling loss.

6. **Evaluation is multi-layered** — LLM-as-judge for fitness scoring (3 dimensions), probe-based eval for compression (6 dimensions), benchmark suites for regression prevention (TBLite, YC-Bench, TerminalBench2).
