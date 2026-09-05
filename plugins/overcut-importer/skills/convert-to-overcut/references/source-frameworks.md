# Source frameworks: recognize and map

How to detect each source framework and translate its constructs to Overcut (`Skill` / `Agent` / workflow `step` / `trigger` / dropped). Work per file - a repo may mix frameworks. When nothing matches, use the **generic fallback** at the end.

Universal rule across all frameworks: **distill business logic, drop plumbing.** Keep intent (what/when/order/capabilities); discard the machinery that only existed to run the old framework.

---

## Argo Workflows / CronWorkflow / WorkflowTemplate

**Recognize:** YAML with `apiVersion: argoproj.io/v1alpha1` and `kind: Workflow | CronWorkflow | WorkflowTemplate | ClusterWorkflowTemplate`. Keys like `templates:`, `dag:`, `steps:`, `entrypoint:`.

**Map:**

| Argo | Overcut |
|---|---|
| The `Workflow` / `entrypoint` | one Workflow `definition` |
| `dag.tasks[]` + their `dependencies` | `steps[]` + `flow[]` (each `dependencies` entry → a `flow` edge `from` dep `to` task) |
| `steps[][]` (sequential/parallel lists) | `steps[]` chained by `flow`; parallel siblings share the same upstream `from` |
| a task whose template runs an LLM/agent | `agent.run` (or `agent.session` if it loops) |
| a task that checks out code | fold into `git.clone` (+ `repo.identify` if the repo comes from the trigger) |
| `CronWorkflow.spec.schedule` | a schedule trigger (cron) |
| task that reacts to a webhook/sensor (Argo Events) | matching Overcut trigger (`custom_event`, PR/issue event) |
| `template.container/script/resource`, `image`, `command`, `args` | **drop** - keep only the human intent of what that container did |
| `retryStrategy`, `parallelism`, `podGC`, `activeDeadlineSeconds`, `volumes`, `nodeSelector`, `serviceAccountName` | **drop** (Overcut owns execution). |
| `arguments.parameters` / `inputs.parameters` | plumbing (image tags, paths) → **drop**. A parameter that encodes a business value varying per team/env/repo (target branch, reviewer list, project key, threshold) → `{{params.<key>}}` + a `contextParameters` entry; a value that is the same everywhere → plain instruction text. |

The distillation is the point: an Argo task is usually a container running a script. You want the *sentence* describing what that script accomplishes for the SDLC, expressed as an agent `instruction` - not the image or command.

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
| `kind: Team` / multi-agent group | a Workflow with an `agent.session` step referencing the members |
| replicas, resources, `imagePullPolicy`, k8s metadata | **drop** |

---

## LangGraph

**Recognize:** Python importing `langgraph`; `StateGraph(...)`, `.add_node(...)`, `.add_edge(...)`, `.add_conditional_edges(...)`, `.compile()`; a `TypedDict`/`State` schema.

**Map:**

| LangGraph | Overcut |
|---|---|
| the compiled graph | one Workflow `definition` |
| `add_node("x", fn)` where `fn` calls an LLM | an `agent.run` step (+ an Agent for the persona in `fn`'s prompt) |
| `add_edge(a, b)` | `flow` edge |
| `add_conditional_edges(a, router, {...})` | `flow` edges with a `condition` each |
| a node that loops back (cycle) | collapse the loop into one `agent.session` step |
| tool nodes / `ToolNode` / bound tools | `availableTools` or `mcpServers[]` per `integration-mapping.md` |
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
| `Task.context` / task dependencies | `flow` edges |
| `Crew(process="sequential")` | a linear `flow` |
| `Crew(process="hierarchical")` + `manager_llm` | one `agent.session` step (Overcut's coordinator replaces the manager); sub-agents = the crew's agents |
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
| `GroupChat` / `GroupChatManager` / multi-agent back-and-forth | one `agent.session` step; the participating assistants → sub-agents |
| `UserProxyAgent` (human/tool executor) | usually **drop** as a persona; its *tool* executions map to `availableTools`/`mcpServers[]`; a genuine human-approval gate → note as a manual/hold consideration in the manifest |
| `llm_config` model | `modelKey` placeholder |
| `code_execution_config`, docker settings, `max_consecutive_auto_reply` | **drop** |

---

## n8n

**Recognize:** exported workflow JSON with `nodes[]` (each `{ type, parameters, position }`) and `connections{}`; node types like `n8n-nodes-base.*`, `@n8n/n8n-nodes-langchain.agent`.

**Map:**

| n8n | Overcut |
|---|---|
| the workflow JSON | one Workflow `definition` |
| `connections{}` | `flow` edges |
| an AI Agent node (`*.agent`, `*.chainLlm`) | `agent.run` (+ an Agent) |
| trigger nodes (`*.webhook`, `*.cron`, `*.githubTrigger`, `*.slackTrigger`) | Overcut trigger (`custom_event` / schedule / PR/issue / `mention`) |
| integration nodes (Slack/GitHub/HTTP/Postgres/…) | `mcpServers[]` + `secrets[]` per `integration-mapping.md` |
| `Set`/`Function`/`IF`/`Merge` glue nodes | usually **drop**; an `IF` that gates the business path → a `flow` `condition` |
| a `Set` node or node parameter holding a per-environment constant (channel name, project key, branch, threshold) | `{{params.<key>}}` + `contextParameters` entry |
| n8n credentials | `secrets[]` by **name** (never values) |

---

## GitHub Actions

**Recognize:** YAML under `.github/workflows/` with `on:`, `jobs:`, `steps:`, `uses:`/`run:`.

**Map:** Most Actions content is CI plumbing (checkout, setup-node, cache, build, deploy) and should be **dropped** - Overcut is not a CI runner. Convert only jobs/steps that embed **SDLC business logic an agent should perform** (e.g. an AI review step, a triage/labeling script, a changelog generator).

| GitHub Actions | Overcut |
|---|---|
| `on: pull_request` | `pull_request_opened` (+ types → updated/merged) |
| `on: issues` / `issue_comment` | `issue_opened` / `issue_commented` |
| `on: schedule` (cron) | schedule trigger |
| `on: workflow_dispatch` | manual trigger |
| `on: repository_dispatch` / custom webhook | `custom_event` |
| a step that runs an LLM/agent action | `agent.run` (+ Agent) |
| `actions/checkout` | fold into `git.clone` |
| build/test/lint/deploy/cache/setup steps | **drop** unless the *decision logic* in them is the point |
| `secrets.*` used by a kept step | `secrets[]` by name |
| `vars.*`, `env:` constants, `workflow_dispatch.inputs` / `workflow_call.inputs` used by a kept step | `{{params.<key>}}` + `contextParameters` entry (the input `default` becomes the parameter `default`). Never a credential. |

---

## Existing skill / prompt / markdown folders

**Recognize:** a `SKILL.md` (already skill-shaped), or loose `.md`/`.txt`/`.prompt` files that are system prompts, playbooks, checklists, or role definitions.

**Map:**
- Already a `SKILL.md` → normalize to the `target-formats.md` frontmatter (ensure `name`, `description`; strip any non-Overcut fields) and copy the body, dropping framework references.
- A system-prompt file for one persona → an **Agent** `additionalInstructions` (and, if it contains a reusable checklist, also a **Skill**).
- A shared checklist/standard/playbook used by many → a **Skill**.

---

## Generic fallback (unknown framework)

When no recognizer matches, do not force a mapping. Read the file and ask three questions of its content:

1. **Is it a reusable body of knowledge** (checklist, standard, domain rules)? → **Skill**.
2. **Is it a persona/role definition** (system prompt, "you are…", role/goal)? → **Agent**.
3. **Is it an ordered pipeline** (do A, then B, then C; a DAG; a state machine)? → **Workflow** (`steps` + `flow`), with each meaningful stage an `agent.run`/`agent.session` and each dependency an edge.

Anything that is purely infrastructure, packaging, or framework wiring → **drop**, and list it under "Dropped as plumbing" in the manifest so the user can confirm nothing important was lost.

Across every framework, apply one more test to each constant you keep: **would a second team, repository, or environment want a different value?** If yes (branch names, reviewer lists, ticket project keys, Slack channels, naming conventions, thresholds), reference it as `{{params.<key>}}` and declare it in `contextParameters` instead of baking it into the instruction - see `target-formats.md` "Context parameters". If it is a credential, it is a secret, never a parameter.
