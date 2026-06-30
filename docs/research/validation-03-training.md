# Validation 03: Training & Fine-Tuning Systems

**Validated on:** 2026-06-30
**Repos verified:**
- Main agent: `/tmp/hermes-agent-research/` (exists, fully accessible)
- Self-evolution: `/tmp/hermes-agent-evolution/` (exists, fully accessible)
- Tinker-Atropos: `/tmp/tinker-atropos/` (exists, fully accessible)
- Compression eval: `/tmp/hermes-compression-eval/` (exists, fully accessible)

---

## 1. Main Repo -- batch_runner.py

### Claim: Exists with multiprocessing.Pool usage
**VERIFIED.** File at `/tmp/hermes-agent-research/batch_runner.py` (1321 lines).

- Uses `from multiprocessing import Pool, Lock` (line 41).
- `BatchRunner.run()` creates a `Pool(processes=self.num_workers)` and dispatches batch tasks via `pool.imap_unordered(_process_batch_worker, tasks)` (line 959).
- Default `num_workers=4` (line 543).

### Claim: Checkpointing for fault tolerance
**VERIFIED.** The `BatchRunner` class has:
- `self.checkpoint_file = self.output_dir / "checkpoint.json"` (line 616).
- `_load_checkpoint()` and `_save_checkpoint()` methods (lines 688-730).
- Incremental checkpoint writes after each batch completes inside the Pool loop (lines 964-980), using a `Lock()` for thread safety.
- Content-based resume via `_scan_completed_prompts_by_content()` (lines 732-774) which matches on prompt text rather than indices, surviving index changes between runs.
- CLI supports `--resume` flag (line 816).

### Claim: Tool distribution integration
**VERIFIED.** `batch_runner.py` imports `sample_toolsets_from_distribution` and `validate_distribution` from `toolset_distributions` (lines 50-54). Each prompt gets independently sampled toolsets via `sample_toolsets_from_distribution(config["distribution"])` (line 318). The selected toolsets are passed to `AIAgent(enabled_toolsets=selected_toolsets)` (line 332).

---

## 2. Main Repo -- trajectory_compressor.py

### Claim: Exists with protect head/tail, compress middle strategy
**VERIFIED.** File at `/tmp/hermes-agent-research/trajectory_compressor.py` (1575 lines).

The docstring at the top (lines 8-15) states:
```
Compression Strategy:
1. Protect first turns (system, human, first gpt, first tool)
2. Protect last N turns (final actions and conclusions)
3. Compress MIDDLE turns only, starting from 2nd tool response
4. Compress only as much as needed to fit under target
5. Replace compressed region with a single human summary message
6. Keep remaining tool calls intact
```

The `_find_protected_indices()` method (lines 477-523) implements this by:
- Tracking first occurrences of system, human, gpt, and tool turns.
- Protecting first N turns of each type based on config flags (`protect_first_system`, `protect_first_human`, `protect_first_gpt`, `protect_first_tool`).
- Protecting last N turns (default `protect_last_n_turns=4`).
- Computing compressible region as everything between protected head and tail.

The `compress_trajectory()` method (lines 743-877) accumulates middle turns until enough token savings are reached, then replaces them with a single LLM-generated summary as a `"human"` turn.

### Additional detail: Boundary snapping
The compressor includes `_snap_boundary()` (lines 538-562) which ensures compression boundaries never split a tool_call/tool_response pair -- a detail likely not in the research document but architecturally significant.

---

## 3. Main Repo -- agent/trajectory.py

### Claim: ShareGPT format and save_trajectory() function
**VERIFIED.** File at `/tmp/hermes-agent-research/agent/trajectory.py` (57 lines).

- The `save_trajectory()` function (lines 30-57) takes a `trajectory` parameter described as "The ShareGPT-format conversation list" (line 35).
- It wraps the trajectory in an entry dict with keys `conversations`, `timestamp`, `model`, `completed` and appends it as JSONL.
- Default output filename: `trajectory_samples.jsonl` (successful) or `failed_trajectories.jsonl` (failed).

**Note:** The actual `_convert_to_trajectory_format()` method lives in `run_agent.py` (line 1785) and delegates to `agent.agent_runtime_helpers.convert_to_trajectory_format`. The format uses `{"from": "system"|"human"|"gpt"|"tool", "value": "..."}` dictionaries (confirmed by the compressor which operates on this format).

---

## 4. Main Repo -- toolset_distributions.py

### Claim: Tool distribution system
**VERIFIED.** File at `/tmp/hermes-agent-research/toolset_distributions.py` (359 lines).

- Defines a `DISTRIBUTIONS` dict (lines 29-213) with 16 named distributions: `default`, `image_gen`, `research`, `science`, `development`, `safe`, `balanced`, `minimal`, `terminal_only`, `terminal_web`, `creative`, `reasoning`, `browser_use`, `browser_only`, `browser_tasks`, `terminal_tasks`, `mixed_tasks`.
- Each distribution maps toolset names (web, vision, image_gen, terminal, file, browser) to a selection probability percentage.
- `sample_toolsets_from_distribution()` (lines 241-282) samples each toolset independently based on its probability, ensuring at least one is selected.
- Includes `validate_distribution()`, `list_distributions()`, and `print_distribution_info()` helpers.

---

## 5. Self-Evolution Repo -- DSPy GEPA

### Claim: DSPy GEPA (Genetic-Pareto Prompt Evolution) is used
**VERIFIED.** The `evolve_skill.py` file (lines 156-159) calls `dspy.GEPA(metric=skill_fitness_metric, max_steps=iterations)` directly. It falls back to `dspy.MIPROv2` if GEPA is not available (lines 167-176).

The README.md describes GEPA as "Genetic-Pareto Prompt Evolution" and references it as an "ICLR 2026 Oral, MIT licensed" paper (line 26). The PLAN.md extensively references GEPA throughout all phases.

**CORRECTED (minor):** The code wraps `dspy.GEPA()` in a try/except and falls back to MIPROv2 (line 167), suggesting GEPA may be experimental or not yet merged into DSPy stable. The README references `https://github.com/gepa-ai/gepa` as a standalone package. Any document claim that GEPA is the definitive optimizer should note this fallback behavior.

### Claim: Three-layer improvement architecture (weights, instructions, tool code)
**VERIFIED from PLAN.md with corrections.** The plan describes:
1. **Phase 1:** Skill files (SKILL.md) -- instruction text optimization via GEPA.
2. **Phase 2:** Tool descriptions -- description text optimization via GEPA.
3. **Phase 3:** System prompt sections -- prompt text optimization via GEPA.
4. **Phase 4:** Tool code (using Darwinian Evolver, not GEPA).

**CORRECTED:** The layers are more accurately: (1) instructions/skills, (2) tool descriptions, (3) system prompts, and (4) tool code. The "weights" layer is explicitly excluded from self-evolution -- PLAN.md line 17 states: "No GPU training required. Everything in this plan operates via API calls only." Weight training is handled by Tinker-Atropos, a completely separate system. If the research document describes a unified three-layer architecture including weights, it conflates two independent systems.

---

## 6. Self-Evolution Repo -- external_importers.py

### Claim: Secret detection patterns (20+ regex patterns)
**VERIFIED.** File at `/tmp/hermes-agent-evolution/evolution/core/external_importers.py`.

The `SECRET_PATTERNS` compiled regex (lines 45-70) contains exactly **21 patterns**:
1. `sk-ant-api\S+` (Anthropic API keys)
2. `sk-or-v1-\S+` (OpenRouter API keys)
3. `sk-\S{20,}` (Generic OpenAI-style keys)
4. `ghp_\S+` (GitHub PATs)
5. `ghu_\S+` (GitHub user tokens)
6. `xoxb-\S+` (Slack bot tokens)
7. `xapp-\S+` (Slack app tokens)
8. `ntn_\S+` (Notion tokens)
9. `AKIA[0-9A-Z]{16}` (AWS access key IDs)
10. `Bearer\s+\S{20,}` (Bearer auth headers)
11. `-----BEGIN\s+(RSA\s+)?PRIVATE\sKEY-----` (PEM keys)
12. `ANTHROPIC_API_KEY` (env var name)
13. `OPENAI_API_KEY` (env var name)
14. `OPENROUTER_API_KEY` (env var name)
15. `SLACK_BOT_TOKEN` (env var name)
16. `GITHUB_TOKEN` (env var name)
17. `AWS_SECRET_ACCESS_KEY` (env var name)
18. `DATABASE_URL` (env var name)
19. `\bpassword\s*[=:]\s*\S+` (password assignments)
20. `\bsecret\s*[=:]\s*\S+` (secret assignments)
21. `\btoken\s*[=:]\s*\S{10,}` (token assignments)

### Claim: RelevanceFilter with two-stage filtering (heuristic + LLM)
**VERIFIED.** The `RelevanceFilter` class (lines 422-543) implements:
- **Stage 1 (heuristic):** `_is_relevant_to_skill()` function (lines 121-151) does keyword overlap between message text and skill name/description. Requires either exact skill name match or 2+ keyword overlaps from skill text.
- **Stage 2 (LLM):** `ScoreRelevance` DSPy Signature (lines 430-443) scores each candidate via `dspy.ChainOfThought`. Returns JSON with `relevant` boolean, `expected_behavior`, `difficulty`, and `category`.

The `filter_and_score()` method (lines 449-543) runs Stage 1 first, supplements with random samples if too few candidates, then runs Stage 2 (LLM scoring) on up to `max_examples * 3` candidates.

---

## 7. Self-Evolution Repo -- constraints.py

### Claim: ConstraintValidator with max_skill_size=15000, max_growth=0.2
**VERIFIED.** File at `/tmp/hermes-agent-evolution/evolution/core/constraints.py`.

- `ConstraintValidator` class (lines 24-175) runs four constraint checks: `_check_size`, `_check_growth`, `_check_non_empty`, `_check_skill_structure`.
- Size limits are read from `config.max_skill_size`, `config.max_tool_desc_size`, `config.max_param_desc_size`.
- Growth limit is read from `config.max_prompt_growth`.

The config defaults in `config.py` (lines 29-31):
```python
max_skill_size: int = 15_000  # 15KB default
max_tool_desc_size: int = 500  # chars
max_param_desc_size: int = 200  # chars
max_prompt_growth: float = 0.2  # 20% max growth over baseline
```

**Confirmed exact values:** `max_skill_size=15000` and `max_growth=0.2`.

---

## 8. Self-Evolution Repo -- fitness.py

### Claim: LLMJudge with correctness/procedure_following/conciseness dimensions
**VERIFIED.** File at `/tmp/hermes-agent-evolution/evolution/core/fitness.py`.

- `FitnessScore` dataclass (lines 13-30) has fields: `correctness`, `procedure_following`, `conciseness`, `length_penalty`, `feedback`.
- Composite score formula (lines 25-30): `0.5 * correctness + 0.3 * procedure_following + 0.2 * conciseness` minus `length_penalty`.
- `LLMJudge` class (lines 34-104) uses a `JudgeSignature` DSPy Signature with three output fields: `correctness`, `procedure_following`, `conciseness` (all 0.0-1.0), plus `feedback`.
- Length penalty ramps from 0 at 90% of max size to 0.3 at 100%+.

---

## 9. Tinker-Atropos Repo

### Claim: TinkerAtroposTrainer exists
**VERIFIED.** File at `/tmp/tinker-atropos/tinker_atropos/trainer.py` (867 lines).

The `TinkerAtroposTrainer` class (line 31) implements the full training loop.

### Claim: Importance sampling loss
**VERIFIED.** The `train_step()` method (line 422-423) calls:
```python
fwd_bwd_result = await self.training_client.forward_backward_async(
    data, loss_fn="importance_sampling"
)
```
The comment on lines 418-420 states: "IS loss handles both RL and distillation -- when distillation is active, advantages were already overwritten with per-token logp_teacher - logp_student."

### Claim: LoRA config
**VERIFIED.** The `TinkerConfig` dataclass in `config.py` (lines 42-49) has:
```python
lora_rank: int = 32
learning_rate: float = 4e-5
```
The trainer creates a LoRA training client via `self.service_client.create_lora_training_client_async(base_model=self.base_model, rank=self.lora_rank)` (lines 71-74).

### Claim: On-policy distillation
**VERIFIED.** The `pad_data_to_good_offset()` method (lines 174-365) includes detailed on-policy distillation logic:
- Checks for `distill_token_ids` and `distill_logprobs` fields in batch items (lines 233-238).
- When present, overwrites per-token advantages with `logp_teacher - logp_student` (lines 283-286).
- References: `https://thinkingmachines.ai/blog/on-policy-distillation/` (lines 187, 263).
- Tracks distillation statistics (`distil/teacher_logp_mean`, `distil/kl_approx`, etc.) (lines 346-358).

### Additional detail: Adam optimizer params
The trainer uses Adam with `beta1=0.9, beta2=0.95, eps=1e-8` (line 428).

### Additional detail: FastAPI inference server
The trainer also runs a FastAPI server (lines 546-837) exposing OpenAI-compatible `/v1/completions` and `/v1/chat/completions` endpoints, plus a `/generate` endpoint for Atropos integration and a `/logprobs` endpoint for computing per-token log probabilities.

---

## 10. Compression Eval Repo

### Claim: Probe-based evaluation
**VERIFIED.** The repo implements a two-phase probe evaluation system:
- **Phase 1 (Continuation):** `grader.py` `answer_probe()` (lines 48-83) feeds compressed messages + probe question to a continuation model, simulating the "next assistant turn."
- **Phase 2 (Grading):** `grader.py` `grade_probe()` (lines 86-136) uses a separate judge model to score the answer on six dimensions.

### Claim: 6 dimensions (accuracy, context_awareness, artifact_trail, completeness, continuity, instruction_following)
**VERIFIED.** File at `/tmp/hermes-compression-eval/rubric.py`.

`DIMENSIONS` list (lines 17-24):
```python
DIMENSIONS: List[str] = [
    "accuracy",
    "context_awareness",
    "artifact_trail",
    "completeness",
    "continuity",
    "instruction_following",
]
```

Each dimension has a detailed description in `DIMENSION_DESCRIPTIONS` (lines 26-60). Scoring uses a 0-5 integer scale with explicit anchors in `SCORE_SCALE` (lines 62-69).

The rubric header (lines 72-86) notes it was "Adapted from the methodology in https://factory.ai/news/evaluating-compression."

### Additional detail: Probe structure
Probes are stored as JSON files in `/tmp/hermes-compression-eval/probes/` with fields: `id`, `type` (recall, artifact, etc.), `question`, `expected_facts`. Three fixture files exist covering different session types (config-build, feature-impl, debug-session).

---

## Summary Table

| Claim | Verdict | Source File(s) |
|-------|---------|----------------|
| `batch_runner.py` exists with multiprocessing.Pool | VERIFIED | `batch_runner.py` line 41, 959 |
| `batch_runner.py` has checkpointing | VERIFIED | `batch_runner.py` lines 616, 688-730, 964-980 |
| `batch_runner.py` has tool distribution | VERIFIED | `batch_runner.py` lines 50-54, 318 |
| `trajectory_compressor.py` protect head/tail, compress middle | VERIFIED | `trajectory_compressor.py` lines 8-15, 477-877 |
| `agent/trajectory.py` ShareGPT format + `save_trajectory()` | VERIFIED | `agent/trajectory.py` lines 30-57 |
| `toolset_distributions.py` distribution system | VERIFIED | `toolset_distributions.py` (16 distributions, 359 lines) |
| Three-layer improvement (weights, instructions, tool code) | CORRECTED | Layers are instructions, tool descs, system prompts, tool code. Weights are NOT in self-evolution (Tinker-Atropos is separate). |
| DSPy GEPA (Genetic-Pareto Prompt Evolution) | VERIFIED | `evolve_skill.py` line 156: `dspy.GEPA(...)` with MIPROv2 fallback |
| Secret detection (20+ regex patterns) | VERIFIED | `external_importers.py` lines 45-70: exactly 21 patterns |
| RelevanceFilter two-stage filtering | VERIFIED | `external_importers.py` lines 121-151 (heuristic), 430-543 (LLM) |
| ConstraintValidator max_skill_size=15000, max_growth=0.2 | VERIFIED | `config.py` lines 29-31, `constraints.py` lines 95-134 |
| LLMJudge correctness/procedure_following/conciseness | VERIFIED | `fitness.py` lines 13-104 |
| TinkerAtroposTrainer + importance sampling loss | VERIFIED | `trainer.py` line 31, line 422-423 |
| LoRA config (rank=32, lr=4e-5) | VERIFIED | `config.py` lines 42-49, `trainer.py` lines 71-74 |
| On-policy distillation | VERIFIED | `trainer.py` lines 174-365, 283-286 |
| Compression eval with 6 dimensions | VERIFIED | `rubric.py` lines 17-24, 26-60 |
| Probe-based evaluation (continuation + grading) | VERIFIED | `grader.py` lines 48-136 |

---

## Findings Requiring Document Correction

1. **Three-layer architecture:** The document may describe this as "weights, instructions, tool code." Based on source, the self-evolution repo handles (1) skills/instructions, (2) tool descriptions, (3) system prompts, and (4) tool code. Weight training is handled by Tinker-Atropos, a completely separate system. The PLAN.md explicitly states "No GPU training required" for self-evolution.

2. **GEPA availability:** The code wraps `dspy.GEPA()` in a try/except and falls back to `dspy.MIPROv2`, suggesting GEPA may be experimental or not yet merged into DSPy stable. The README references a standalone `https://github.com/gepa-ai/gepa` package.

3. **Secret patterns count:** If the document says "20+", this is correct (21 patterns). If it claims a specific number other than 21, it should be corrected.

4. **Compression eval provenance:** The rubric explicitly credits the methodology to `https://factory.ai/news/evaluating-compression` -- worth noting as attribution.
