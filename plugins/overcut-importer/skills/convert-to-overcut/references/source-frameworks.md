# Source frameworks: recognize and map

How to detect each source framework and translate its constructs to Overcut (`Skill` / `Agent` / workflow `step` / `trigger` / dropped). Work per file - a repo may mix frameworks. When nothing matches, use the **generic fallback** at the end.

Universal rule across all frameworks, applied per layer:
- **Skill-bound content** (checklists, standards, prompt bodies, playbooks) → **preserve** it near-verbatim. Only strip old-runtime references and framework wiring that would mislead the agent; splitting one big skill into focused skills is encouraged, dropping content is not.
- **Agent/workflow orchestration** (who runs, in what order, on what trigger, with what tools) → **redesign** toward Overcut best practice: specialized single-responsibility agents, dedicated per-goal workflows modeled on playbooks. Drop the machinery that only existed to run the old framework.

Two structural facts about the target shape every mapping below relies on (details in `target-formats.md`):
- **Flow is a single linear chain.** Overcut runs steps one at a time; there are no parallel branches and no conditional edges. Source fan-out becomes one `agent.session` step with several sub-agents (its coordinator splits and merges the work); source branching becomes either a trigger `conditions` group (when the branch is decided by the trigger context), an instruction to the agent ("if X, do A; otherwise B"), or separate workflows.
- **Deterministic shell work is a `script.run` step**, not an agent. A container `command`, a CI `run:` block, or a test/lint/build invocation with no judgment in it maps to `script.run` (with `cwd` pointing at the cloned repo). Reserve `agent.run` for steps that need an LLM to decide something.

---

## Argo Workflows / CronWorkflow / WorkflowTemplate

**Recognize:** YAML with `apiVersion: argoproj.io/v1alpha1` and `kind: Workflow | CronWorkflow | WorkflowTemplate | ClusterWorkflowTemplate`. Keys like `templates:`, `dag:`, `steps:`, `entrypoint:`.

**Map:**

| Argo | Overcut |
|---|---|
| The `Workflow` / `entrypoint` | one Workflow `definition` |
| `dag.tasks[]` + their `dependencies` | `steps[]` + a **linear** `flow[]` in topological order (first edge `from: ""`). Tasks that could run in parallel become consecutive steps, or one `agent.session` with a sub-agent per task when they are agent work. |
| `steps[][]` (sequential/parallel lists) | sequential groups → consecutive steps; a parallel group → one `agent.session` with several sub-agents (or consecutive steps if order doesn't matter) |
| a task whose template runs an LLM/agent | `agent.run` (or `agent.session` if it loops) |
| a task whose template runs a fixed script (tests, lint, build, a CLI) | `script.run` with the script body in `params.script` and `cwd` = the cloned folder |
| a task that checks out code | fold into `git.clone` with `repoFullName` = `{{trigger.repository.fullName}}` or a literal `org/repo` (+ `repo.identify` and `{{outputs.<id>}}` when the repo must be inferred) |
| `CronWorkflow.spec.schedule` | a `scheduled` trigger: `schedule: { cronExpression }` (max one per workflow) |
| task that reacts to a webhook/sensor (Argo Events) | matching Overcut trigger (`custom_event` with `customEvent.name`, or a PR/issue event) |
| `template.container/script/resource`, `image`, `args` | **drop** - keep the `command`/script body only when it becomes a `script.run`, otherwise keep the human intent |
| `retryStrategy`, `parallelism`, `podGC`, `activeDeadlineSeconds`, `volumes`, `nodeSelector`, `serviceAccountName` | **drop** (Overcut owns execution). A task that clearly needed a big box → `machineTierKey: "large"` on the definition. |
| `arguments.parameters` / `inputs.parameters` | plumbing (image tags, paths) → **drop**. A parameter that encodes a business value varying per team/env/repo (target branch, reviewer list, project key, threshold) → `{{params.<key>}}` + a `refs.contextParameters` entry; a value that is the same everywhere → plain instruction text. |

The distillation is the point: an Argo task is usually a container running a script. If the script is deterministic, carry it as a `script.run`. If it needed a person's judgment, you want the *sentence* describing what it accomplishes for the SDLC, expressed as an agent `instruction` - not the image or command.

---

## kagents (Kubernetes-native agents)

**Recognize:** CRD-style YAML with `kind: Agent` (and often `kind: Skill` / `kind: Team`/`kind: ModelConfig`) under a `kagent`/`kagents` API group; fields like `systemMessage`/`instructions`, `modelConfig`, `tools`.

**Map:**

| kagents | Overcut |
|---|---|
| `kind: Agent` | an Agent spec |
| `systemMessage` / `instructions` | `additionalInstructions` (distilled) |
| `modelConfig` / model ref | `modelKey` → placeholder `"<workspace-default>"` unless it names a model in the Overcut registry |
| `tools[]` (builtin) | `availableTools` (map via `integration-mapping.md`) |
| `tools[]` (MCP / external) | `mcpServers[]` recommendation + `secrets[]` |
| `kind: Skill` (reusable instruction) | a `SKILL.md` bundle |
| `kind: Team` / multi-agent group | a Workflow with an `agent.session` step: the members in `agentIds`, the team's objective in `goal` |
| replicas, resources, `imagePullPolicy`, k8s metadata | **drop** |

---

## LangGraph

**Recognize:** Python importing `langgraph`; `StateGraph(...)`, `.add_node(...)`, `.add_edge(...)`, `.add_conditional_edges(...)`, `.compile()`; a `TypedDict`/`State` schema.

**Map:**

| LangGraph | Overcut |
|---|---|
| the compiled graph | one Workflow `definition` |
| `add_node("x", fn)` where `fn` calls an LLM | an `agent.run` step (+ an Agent for the persona in `fn`'s prompt) |
| `add_node("x", fn)` where `fn` is plain code (no LLM) | `script.run` if it is a shell-able command; otherwise fold its effect into the neighbouring agent's instruction or drop it as glue |
| `add_edge(a, b)` | `flow` edge (the chain must stay linear) |
| `add_conditional_edges(a, router, {...})` | **no conditional edges exist.** If the router reads the trigger context → a trigger `conditions` group (often: separate workflows per branch). If it reads the LLM's own output → merge `a` and its branches into one `agent.run`/`agent.session` whose instruction states the decision rule. |
| a node that loops back (cycle) | collapse the loop into one `agent.session` step (`goal` = the loop's exit condition) |
| tool nodes / `ToolNode` / bound tools | `availableTools` (built-in first) or `mcpServers[]` per `integration-mapping.md` |
| `State` TypedDict, reducers, `checkpointer`, `MemorySaver`, `interrupt` | **drop** (Overcut manages state/memory) - but if the state carries a real business artifact passed between steps, note it in the step `instruction` |

---

## CrewAI

**Recognize:** Python importing `crewai`; `Agent(role=, goal=, backstory=)`, `Task(description=, expected_output=)`, `Crew(agents=, tasks=, process=)`.

**Map:**

| CrewAI | Overcut |
|---|---|
| each `Agent(...)` | an Agent spec; `additionalInstructions` distilled from `role` + `goal` + `backstory` |
| `Agent.tools` | `availableTools` / `mcpServers[]` |
| each `Task(...)` | an `agent.run` step; `description` + `expected_output` → the step `instruction` |
| `Task.context` / task dependencies | `flow` edges (linearized in dependency order) |
| `Crew(process="sequential")` | a linear `flow` |
| `Crew(process="hierarchical")` + `manager_llm` | one `agent.session` step (Overcut's coordinator replaces the manager); `agentIds` = the crew's agents, `goal` = the crew's overall objective |
| `expected_output` phrasing | fold into the instruction as the step's definition-of-done |
| `verbose`, `memory`, `cache`, `max_rpm`, embedder config | **drop** |

Reusable checklists embedded in a backstory/goal (e.g. "always verify X, Y, Z") are good candidates to lift into a **Skill** shared across agents.

---

## AutoGen / AG2

**Recognize:** Python importing `autogen`/`ag2`/`pyautogen`; `AssistantAgent`, `UserProxyAgent`, `GroupChat`, `GroupChatManager`, `initiate_chat`.

**Map:**

| AutoGen | Overcut |
|---|---|
| a single `AssistantAgent` doing a one-shot task | `agent.run` + an Agent |
| `GroupChat` / `GroupChatManager` / multi-agent back-and-forth | one `agent.session` step; the participating assistants → `agentIds`, the chat's purpose → `goal` |
| `UserProxyAgent` (human/tool executor) | usually **drop** as a persona; its *tool* executions map to `availableTools`/`mcpServers[]`; a genuine human-approval gate → note as a manual/hold consideration in the manifest |
| `llm_config` model | `modelKey` placeholder |
| `code_execution_config`, docker settings, `max_consecutive_auto_reply` | **drop** |

---

## n8n

**Recognize:** exported workflow JSON with `nodes[]` (each `{ type, parameters, position }`) and `connections{}`; node types like `n8n-nodes-base.*`, `@n8n/n8n-nodes-langchain.agent`.

**Map:**

| n8n | Overcut |
|---|---|
| the workflow JSON | one Workflow `definition` (or several, one per trigger node, when the graph fans out from multiple triggers) |
| `connections{}` | a **linear** `flow` in execution order; parallel branches → one `agent.session` with a sub-agent per branch, or consecutive steps |
| an AI Agent node (`*.agent`, `*.chainLlm`) | `agent.run` (+ an Agent) |
| `Execute Command` / `Code` nodes that run a fixed command | `script.run` |
| trigger nodes (`*.webhook`, `*.cron`, `*.githubTrigger`, `*.slackTrigger`) | Overcut trigger: `custom_event` (+ `customEvent.name`) / `scheduled` (+ `schedule.cronExpression`) / the matching `pull_request_*` or `issue_*` event / `mention` or `channel_message` |
| Slack / GitHub / GitLab / Jira / Linear nodes | **built-in tools** on the agent's `availableTools` (`post_channel_message`, `create_pull_request`, `read_ticket`, ...) - not MCP |
| other integration nodes (HTTP Request, Postgres, Notion, ...) | `mcpServers[]` + `secrets[]` per `integration-mapping.md` |
| `Set`/`Function`/`Merge` glue nodes | usually **drop** |
| an `IF`/`Switch` node | no conditional edges exist. If it tests trigger data (label, branch, author) → a trigger `conditions` group (often separate workflows per branch); if it tests an earlier node's output → state the rule in the downstream agent's `instruction` |
| a `Set` node or node parameter holding a per-environment constant (channel name, project key, branch, threshold) | `{{params.<key>}}` + `refs.contextParameters` entry |
| n8n credentials | `secrets[]` by **name** (never values) - or nothing at all when the provider is a built-in tool (the project's connection covers it) |

---

## GitHub Actions

**Recognize:** YAML under `.github/workflows/` with `on:`, `jobs:`, `steps:`, `uses:`/`run:`.

**Map:** Most Actions content is CI plumbing (checkout, setup-node, cache, build, deploy) and should be **dropped** - Overcut is not a CI runner. Convert only jobs/steps that embed **SDLC business logic an agent should perform** (e.g. an AI review step, a triage/labeling script, a changelog generator).

| GitHub Actions | Overcut |
|---|---|
| `on: pull_request` | `pull_request_opened`; `types: [synchronize, edited]` → add `pull_request_edited`; `closed` → `pull_request_closed` / `pull_request_merged`; `labeled` → `pull_request_labeled`; `on: pull_request_review` → `pull_request_reviewed` |
| `on: issues` / `issue_comment` | `issue_opened` / `issue_labeled` / `issue_closed` ... / `issue_commented` |
| `on: schedule` (cron) | `scheduled` trigger with `schedule: { cronExpression }` |
| `on: workflow_dispatch` | `manual` trigger with `slashCommand: { command, requireMention: false }` |
| `on: repository_dispatch` / custom webhook | `custom_event` with `customEvent.name` |
| `on: workflow_run` / `check_run` | a `ci_workflow_completed` / `ci_workflow_failed` trigger |
| `if:` on a job/step | trigger `conditions` when it tests event data (`github.event.label.name` → `context.trigger.label`, base branch → `context.pullRequest.baseBranch`, draft → `context.pullRequest.draft`); otherwise instruction text |
| a step that runs an LLM/agent action | `agent.run` (+ Agent) |
| a `run:` block with real business logic but no judgment (a triage script, a changelog generator) | `script.run` with the block as `params.script`, `cwd` = the cloned folder |
| `actions/checkout` | fold into `git.clone` (`repoFullName: "{{trigger.repository.fullName}}"`) |
| build/test/lint/deploy/cache/setup steps | **drop** unless the *decision logic* in them is the point; a build the agent must run itself → give the agent `run_terminal_cmd`, or a bigger `machineTierKey` |
| `uses: <owner>/<action>` that triggers another pipeline | `ci.executeWorkflow` |
| `secrets.*` used by a kept step | `secrets[]` by name |
| `vars.*`, `env:` constants, `workflow_dispatch.inputs` / `workflow_call.inputs` used by a kept step | `{{params.<key>}}` + `refs.contextParameters` entry (the input `default` becomes the parameter `default`). Never a credential. |

---

## Existing skill / prompt / markdown folders

**Recognize:** a `SKILL.md` (already skill-shaped), or loose `.md`/`.txt`/`.prompt` files that are system prompts, playbooks, checklists, or role definitions.

**Map** (skills are preserved, not rewritten - copy the body faithfully):
- Already a `SKILL.md` → normalize *only the frontmatter* to the `target-formats.md` shape (ensure `name`, `description`; strip non-Overcut fields) and **copy the body verbatim**, editing only old-runtime references. Do not condense or reword the instructions.
- A large or multi-topic skill → **split into several focused skills** rather than trimming it. Record the one-source → many-skills split in the manifest; every original instruction must land in one of the outputs.
- A system-prompt file for one persona → an **Agent** `additionalInstructions` (and, if it embeds a reusable checklist, lift that checklist into its own **Skill** so other agents can share it).
- A shared checklist/standard/playbook used by many → a **Skill**, attached only to the agents that use it.

---

## Generic fallback (unknown framework)

When no recognizer matches, do not force a mapping. Read the file and ask three questions of its content:

1. **Is it a reusable body of knowledge** (checklist, standard, domain rules)? → **Skill** - preserve it verbatim; split it if it spans several topics.
2. **Is it a persona/role definition** (system prompt, "you are...", role/goal)? → **Agent** - one per responsibility; split a do-everything persona into focused agents.
3. **Is it an ordered pipeline** (do A, then B, then C; a DAG; a state machine)? → **Workflow(s)** - decompose it into dedicated per-goal workflows (`steps` + `flow`) rather than one 1:1 port, each modeled on the nearest playbook, with each meaningful stage an `agent.run`/`agent.session` and each dependency an edge.

Anything that is purely infrastructure, packaging, or framework wiring → **drop**, and list it under "Dropped as plumbing" in the manifest so the user can confirm nothing important was lost.

Across every framework, apply one more test to each constant you keep: **would a second team, repository, or environment want a different value?** If yes (branch names, reviewer lists, ticket project keys, Slack channels, naming conventions, thresholds), reference it as `{{params.<key>}}` and declare it in the artifact's context parameter list (`refs.contextParameters` / `contextParameters`) instead of baking it into the instruction - see `target-formats.md` "Context parameters". If it is a credential, it is a secret, never a parameter.
