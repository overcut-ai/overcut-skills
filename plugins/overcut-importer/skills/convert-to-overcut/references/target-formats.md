# Overcut target formats

The compile target. Every artifact you emit must match one of these three shapes so it imports cleanly via the `overcut-api` skill (`createSkill` / `createAgent` / `createWorkflow` / `importWorkflow`). Field names and enums below mirror the Overcut data model; when a required field has no source value, emit the documented **placeholder** and add a TODO to the `MANIFEST.md`.

---

## 1. Skill - a `SKILL.md` bundle in a git repo

An Overcut Skill is a versioned instruction bundle: a directory containing a `SKILL.md`, loaded from a connected git repo at a `path` + `ref`. It is **not** uploaded content - it lives in git, and `createSkill` registers a pointer to it. So conversion produces a folder the user commits to a repo.

**Output:** `out/skills/<kebab-name>/SKILL.md` (+ optional `references/` sub-files for anything long).

```markdown
---
name: <kebab-case-name>
description: <one line, third person, says what it does AND when to use it - this is what Overcut matches on>
license: Apache-2.0            # optional
allowed-tools: Read, Bash      # optional; only built-in tool names the skill needs
---

# <Human Title>

<Distilled, framework-free instructions: the checklist / standard / playbook the org
actually wants applied. No Argo/kagents/LangGraph vocabulary. Written as guidance to an
agent, not as a description of the old pipeline.>
```

Rules:
- `name` is kebab-case and unique within the project. `description` is the only field Overcut uses to decide relevance - make it specific and trigger-rich.
- Keep the body about **durable knowledge** (review criteria, coding standards, domain rules, definitions of done). Move orchestration ("then call step 3") into the *workflow*, not the skill.
- A Skill is reusable across agents. If two source agents share a checklist, emit **one** skill and link it from both.

**Registration** (done later, by the `overcut-api` skill): `createSkill(input: { projectId, name, path, ref, ... })` where `path` is the folder inside the connected repo. `createSkills` batches many.

---

## 2. Agent - a persona spec (`*.agent.json`)

An Overcut Agent is a configured LLM persona used inside workflow steps. Emit one JSON file per distinct role.

**Output:** `out/agents/<kebab-name>.agent.json`

```json
{
  "name": "billing-pr-reviewer",
  "description": "Reviews PRs that touch billing code for correctness, PCI, and rollout safety.",
  "baseAgentType": "CodeReview",
  "modelKey": "<workspace-default>",
  "additionalInstructions": "You are a senior reviewer for the billing domain. <distilled system prompt>",
  "color": "#4F46E5",
  "availableTools": ["filesystem", "git"],
  "skills": ["billing-review-checklist"],
  "mcpServers": [
    { "catalogKey": "github", "allowedTools": ["create_pr_comment"], "confidence": "high" }
  ],
  "secrets": ["GITHUB_TOKEN"],
  "contextParameters": [
    { "key": "base_branch", "description": "Branch PRs are compared against", "default": "main" }
  ]
}
```

Field reference:

| Field | Type | Notes |
|---|---|---|
| `name` | string | Unique in project. Kebab-case recommended. |
| `description` | string | One line; shown in the UI. |
| `baseAgentType` | enum | One of `CodeReview`, `Custom`, `ProductManager`, `SeniorDeveloper`, `TechWriter`, `InternalRepoIdentify`. Default `Custom`. |
| `modelKey` | string | A key from the workspace LLM registry. Placeholder `"<workspace-default>"`. |
| `additionalInstructions` | string | The agent's **system prompt** - the distilled role/goal/behavior. This is where most business logic lands. |
| `color` | string | Hex color for the UI. Any valid hex; pick a stable one per agent. |
| `availableTools` | string[] | **Built-in** tool names only (e.g. `filesystem`, `git`). NOT MCP tools. See `integration-mapping.md`. |
| `skills` | string[] | `name`s of skills (from `out/skills/`) to attach. Assigned via `assignSkillsToAgent`. |
| `mcpServers` | object[] | Recommendations, not live config: `{ catalogKey, allowedTools, confidence }`. Assigned via `assignMcpServersToAgent` after the server exists. |
| `secrets` | string[] | Secret **names** the agent needs. The user creates them; assigned by id via `setAgentSecrets`. Never a value. |
| `contextParameters` | object[] | Every `{{params.<key>}}` the `additionalInstructions` reference: `{ key, description, default? }`. Definitions the user creates (`createContextParameter`) **before** the agent, because `createAgent` rejects undefined keys. See "Context parameters" below. |

`skills` / `mcpServers` / `secrets` / `contextParameters` are **link intents** the importer records - the agent is created after its parameters exist (`createAgent(data: AgentCreateInput)`), then the other links are applied. Keep them as names/keys, never ids (ids don't exist until creation).

### Choosing `baseAgentType`

Prefer `Custom` unless the source role is unmistakable. Only upgrade on a clear signal:

| Source role signal | `baseAgentType` |
|---|---|
| reviews code / PRs, comments on diffs | `CodeReview` |
| implements features, writes/edits code | `SeniorDeveloper` |
| writes specs, PRDs, product/planning docs | `ProductManager` |
| writes docs, changelogs, READMEs | `TechWriter` |
| resolves which internal repo a request targets | `InternalRepoIdentify` |
| anything else / ambiguous | `Custom` |

When you pick anything other than an obvious match, mark it TODO in the manifest.

---

## 3. Workflow - a definition (`*.workflow.json`)

An Overcut Workflow is a triggered, ordered set of steps. Emit the `definition` plus a light wrapper.

**Output:** `out/workflows/<kebab-name>.workflow.json`

```json
{
  "name": "billing-pr-review",
  "definition": {
    "name": "billing-pr-review",
    "priority": 50,
    "timeoutMs": 1800000,
    "statusUpdateMethod": "comment",
    "defaultModelKey": "<workspace-default>",
    "triggers": [
      { "event": "pull_request_opened", "conditions": { "TODO": "narrow by repo/path/label in the UI" } }
    ],
    "steps": [
      { "id": "identify", "name": "Identify repo", "action": "repo.identify", "params": {}, "stepMaxDurationMinutes": 5 },
      { "id": "clone",    "name": "Clone",          "action": "git.clone",    "params": {}, "stepMaxDurationMinutes": 5 },
      { "id": "review",   "name": "Review billing PR", "action": "agent.run",
        "instruction": "Review the PR diff against the billing review checklist, comparing against {{params.base_branch}}. Post findings as a PR comment and request review from {{params.billing_reviewers}}.",
        "params": { "agent": "billing-pr-reviewer" }, "stepMaxDurationMinutes": 20 }
    ],
    "flow": [
      { "from": "identify", "to": "clone" },
      { "from": "clone",    "to": "review" }
    ]
  },
  "agentRefs": { "billing-pr-reviewer": "billing-pr-reviewer" },
  "contextParameters": [
    { "key": "base_branch", "description": "Branch PRs are compared against", "default": "main" },
    { "key": "billing_reviewers", "description": "Reviewers to request on billing PRs; differs per team" }
  ]
}
```

### The definition shape

| Field | Notes |
|---|---|
| `steps[]` | Nodes. Each: `id` (unique), optional `name`, `action` (see below), optional `instruction` (agent prompt), free-form `params` (JSON), `stepMaxDurationMinutes`. |
| `flow[]` | Edges. Each: `from` (step id), `to` (step id), optional `condition`. **This** defines execution order - never rely on `steps[]` array order. Source DAG dependencies become these edges. |
| `triggers[]` | At least one required (logical OR). See below. |
| `priority` | 1-100, lower runs first. Default `50`. |
| `timeoutMs` | Whole-workflow timeout. |
| `statusUpdateMethod` | `comment` / `reuse_comment` / `static_comment`. Default `comment`. |
| `defaultModelKey` | Placeholder `"<workspace-default>"`. |

`agentRefs` is a helper map (step's `params.agent` name -> agent `name`) so a later `importWorkflow` can supply `agentMapping`. It is not part of `definition`. `contextParameters` is the same kind of helper for every `{{params.<key>}}` the definition references (see below).

### Context parameters - configuration that varies, without copying the workflow

Source pipelines carry values that differ per environment, team, or repository: a target branch, a reviewer list, a Jira project key, a naming convention, a threshold. Do **not** hardcode them into an `instruction`, and do not emit one workflow per variant. Overcut resolves `{{params.<key>}}` per run from the most specific value on the run's path (workspace default < project < repository < workflow < orchestration < agent), so one workflow serves every team.

Emit the reference in the template text (`instruction`, string `params`, an agent's `additionalInstructions`) and declare the key in the artifact's `contextParameters` list:

| Field | Notes |
|---|---|
| `key` | `snake_case`, `^[A-Za-z_][A-Za-z0-9_]*$`, max 64 chars. Workspace-unique and immutable once created, so pick a name that reads well outside this workflow (`base_branch`, not `branch`). |
| `description` | What the value means and who should override it. |
| `default` | Optional. The value the source used when it was the same for everyone. Omit it when every team must set its own value, and say so in the TODO. |

Rules:
- **A parameter is never a credential.** Values are plain text visible in prompts and logs. Tokens, keys and passwords stay `secrets[]` (`integration-mapping.md`).
- Declare every key you reference; the validator warns on undeclared `{{params.*}}`. The same key used by several artifacts is declared once per artifact that references it - the importer dedupes at creation.
- At import time the key must exist **before** `createAgent` (validated immediately) and before `commitWorkflow` (validated at commit). `references/output-layout.md` orders the import steps accordingly.
- Trigger-time data (PR number, author, ticket key) is `{{trigger.*}}`, not a parameter. Data produced by an earlier step is `{{outputs.<stepId>.*}}`. Parameters are for configuration only.

### The four - and only four - step actions

| `action` | Use for |
|---|---|
| `git.clone` | Clone a repo into the run workspace so later steps can read/modify code. |
| `repo.identify` | Resolve *which* repo to clone from the trigger context. Precedes `git.clone` when the repo isn't fixed. |
| `agent.run` | One agent, one short deterministic task (extract, comment, produce a result the next step consumes). Single execution thread. |
| `agent.session` | A built-in **coordinator** + one or more sub-agents for multi-turn / iterative work. `params` references sub-agent names. Use when the source is an iterative loop, a group chat, or a hierarchical crew. |

Hard rule: an agent step can only touch code if a `git.clone` ran before it. A code-modifying pipeline is almost always `repo.identify?` -> `git.clone` -> `agent.*`. If a source step reads/writes a repo, insert the clone chain even if the source didn't model it explicitly.

`agent.run` vs `agent.session`: one-shot deterministic task -> `agent.run`; loop / "keep going until done" / multi-agent conversation / hierarchical delegation -> `agent.session` (put the sub-agent names in `params`).

### Triggers

Each trigger: `event` (a `StandardizedEventType`), optional `conditions` (filter tree, narrowed in the UI), optional `slashCommand` / `schedule` / `customEvent` / `settings`. Map source triggers with `source-frameworks.md`; common normalized events:

- `pull_request_opened`, `pull_request_updated`, `pull_request_merged`, `pull_request_commented`
- `issue_opened`, `issue_commented`, `issue_labeled`, `issue_status_changed`
- `mention`, `slash_command`, `channel_message` (messaging)
- `custom_event` (needs `customEvent.name` = the workspace webhook slug)
- schedule (cron) - set `schedule`
- manual - `{ "event": "manual" }` (the placeholder when no source trigger exists)

When a source trigger's filter (repo/label/path/author) can't be expressed confidently, keep the `event` and leave `conditions` as a `{"TODO": "..."}` note for the user to finish in the trigger UI.

---

## Placeholders and TODOs - the contract

Output must import even when the source lacks required fields. Use exactly these placeholders and record each in the manifest:

| Missing | Placeholder | TODO text |
|---|---|---|
| model | `"<workspace-default>"` | "Set modelKey/defaultModelKey to a key from the workspace LLM registry." |
| baseAgentType (ambiguous) | `"Custom"` | "Confirm baseAgentType (inferred/defaulted)." |
| trigger | `[{ "event": "manual" }]` | "No source trigger found - define the real trigger." |
| trigger filter | `conditions: { "TODO": "..." }` | "Narrow the trigger conditions in the UI." |
| integration config | omit; list under Integrations | "Assign MCP server <x> + secret <y> to agent <z>." |
| a per-team / per-env value with no single source default | `{{params.<key>}}` + `contextParameters` entry without `default` | "Define context parameter `<key>` and set a value per project / repository before the first run." |

Never invent a real `modelKey`, secret value, MCP endpoint, repo path, or context parameter value the source did not contain.
