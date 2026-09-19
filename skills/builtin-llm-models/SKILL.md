---
name: builtin-llm-models
description: >
  Reference for the autonomous agent's built-in foundation models, model-driven delegation, recursive subagents, and request shapes. Read this before every root routing decision and every subagent delegation decision. The model making the decision chooses the next model from task meaning, modality, execution needs, observations, and model strengths; the backend never selects a model by matching user-message keywords.
---

# Built-in LLM Models

The root strategic brain is Claude Fable 5 through VMCO. It receives the user objective, persistent task state, dynamic PlanSteps graph, latest real observations, complete tool catalog, active subagent tree, and this skill. It decides the root plan, which model handles each direct step, whether work should be delegated, how wide or deep the subagent tree should become, and when results need integration or verification.

Model selection is semantic and model-driven. A word appearing in the request is evidence about the task, never a backend routing rule. The backend validates only that a model id exists and executes the decision that a model made.

Every configured model can run as a subagent. Every subagent receives the complete tool registry. A subagent can use VM, browser, desktop, filesystem, document, memory, HTTP, reasoning, and subagent-management tools, and can recursively create any number of child subagents with any configured model. Child agents are persistent, have parent-child identities, run independently, can execute concurrently, and return their results to the caller through the subagent tools.

## Model catalog

| Model role id | Runtime model | Provider | Primary strengths |
| --- | --- | --- | --- |
| `orchestrator` | `claude-fable-5` | VMCO | Root strategy, decomposition, PlanSteps graph management, delegation, coordination, synthesis, verification, and delegated strategic subagents |
| `gpt6_astra` | `openai/gpt-6-astra:flex` | Requesty | Coding, debugging, implementation, software engineering, technical investigation, shell/file/browser-driven digital execution, iterative error correction, and broad computer work |
| `glm52` | `zai/glm-5.2` | Requesty | Detailed astrology interpretation and astrology-specific reasoning when that capability is materially useful |
| `gemini38` | `gemini-3.8-flash` | Google Gemini Interactions API | Image, screenshot, video, visual-interface, spatial, and pixel-level multimodal analysis |
| `minimax_m3` | `minimaxi/minimax-m3` | Requesty | Reading, extracting, preserving, and reasoning over long documents and document-heavy source material |
| `grok43` | `grok-4.3` | Requesty | Intimate or sexual subject-area reasoning when that domain capability is materially useful |

## Root planning and delegation

The root behaves as a strategic coordinator rather than a keyword router. It creates and mutates a dynamic PlanSteps dependency graph and may execute direct steps or delegate independent work into subagent trees.

Use direct root plan steps when one model should perform the work in the root execution flow. Use subagents when parallelism, independent verification, wide research, isolated reasoning, specialist collaboration, or recursive decomposition improves the task. A root decision may fan out several subagents at once and later wait for and synthesize them.

Every root delegation explicitly chooses a model and goal. The backend never substitutes another model based on the goal text. Any configured model, including `orchestrator`, may be chosen for a subagent.

## Recursive subagent behavior

Every subagent follows the same atomic agentic cycle:

ANALYZE -> PLAN/SELECT -> ACT/EXECUTE -> OBSERVE -> REFLECT/VERIFY -> repeat until the delegated goal is verified.

Subagents have the same tool access as the root. A subagent may call `spawn_subagent` repeatedly to create children, including multiple agents using the same model. It may create a wide parallel fan-out or a deep recursive tree. There is no semantic backend rule that decides when or which model to spawn.

Use `wait_subagents` to synchronize after parallel fan-out. Use `list_subagents` and `get_subagent` to inspect the tree, `message_subagent` to add new evidence or instructions without resetting the child, and `stop_subagent` when a model deliberately decides a child is no longer needed.

Use `get_plan` to inspect the complete shared dynamic PlanSteps graph. Use `replace_remaining_plan` to replace the unfinished part of that graph with a newly model-selected dependency graph while preserving already completed steps. The backend validates graph consistency but never selects the strategy or model for the replacement.

Failures stay with the evidence. A model may retry itself, repair through tools, message a child, delegate to another model, create independent verification agents, or mutate the remaining plan. No model automatically owns a failure category.

## Tool access

All models have access to the complete registered tool catalog. Tool availability is not filtered by model role. The root and every subagent can use real InstaVM execution, PTY, browser, desktop, file, document, memory, HTTP, reasoning, and subagent-management tools. Models must use real tool observations instead of claiming external actions happened.

## Request shapes

### GPT-6 Astra Pro

Use Requesty's OpenAI-compatible chat-completions endpoint with model `openai/gpt-6-astra:flex`, `reasoning_effort` set to `max`, reasoning body `{ "effort": "max", "mode": "pro" }`, and Requesty auto cache enabled.

### GLM 5.2

Use Requesty's OpenAI-compatible chat-completions endpoint with model `zai/glm-5.2`, temperature `0`, `max_tokens` `131072`, and `reasoning_effort` `max`.

### MiniMax M3

Use Requesty's OpenAI-compatible chat-completions endpoint with model `minimaxi/minimax-m3`, temperature `0`, `max_tokens` `131072`, and adaptive thinking enabled.

### Grok 4.3

Use Requesty's OpenAI-compatible chat-completions endpoint with model `grok-4.3`, `reasoning_effort` `high`, Requesty auto cache enabled, and OpenAI-compatible multimodal content when media is supplied.

### Gemini 3.8

Use the Gemini Interactions API with model `gemini-3.8-flash`, code execution, Google Search, and URL context tools enabled, `max_output_tokens` `65536`, and thinking level `high`. Use the Gemini prompt from `config/prompts.yaml` rather than embedding it in the Nim source.

### Claude Fable 5

Use the VMCO OpenAI-compatible chat-completions endpoint with model `claude-fable-5` for the root strategic brain and whenever another model explicitly delegates a strategic subagent to `orchestrator`.

## Root route contract

The root routing response explicitly chooses `primary_model`, optional `secondary_models`, the root `plan`, optional `delegations`, and `completion_criteria`. Every plan step explicitly chooses its model. Every delegation explicitly chooses its model. The backend does not inspect the user text to override these choices.

A delegation has `model`, `goal`, and optional `name`, `instructions`, and `context`. Independent delegations may run concurrently. Nested delegations are created by the subagents themselves through the same tool interface.
