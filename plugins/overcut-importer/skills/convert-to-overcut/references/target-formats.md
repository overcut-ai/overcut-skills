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

<The org's own instructions, preserved: the checklist / standard / playbook exactly as
they wrote it. Do NOT summarize or reword. Edit only to remove old-framework vocabulary
(Argo/kagents/LangGraph) and references to the old runtime, so it reads as guidance to an
agent rather than a description of the old pipeline.>
```

Rules:
- **Preserve the body.** Copy the source instructions faithfully; do not condense, reorder, or "improve" them. The only edits are removing old-runtime/framework wiring that would mislead the agent. When unsure whether a line is business logic or plumbing, keep it.
- **Split, don't trim.** If the source skill is oversized or spans several topics, break it into multiple focused `SKILL.md` folders - but every original instruction must survive in one of them.
- `name` is kebab-case and unique within the project. `description` is the only field Overcut uses to decide relevance - make it specific and trigger-rich.
- Keep the body about **durable knowledge** (review criteria, coding standards, domain rules, definitions of done). Move orchestration ("then call step 3") into the *workflow*, not the skill.
- A Skill is reusable across agents. If two source agents share a checklist, emit **one** skill and link it only from the agents that use it.

**Registration** (done later, by the `overcut-api` skill): `createSkill(input: { projectId, name, path, ref, ... })` where `path` is the folder inside the connected repo. `createSkills` batches many.

---

## 2. Agent - a persona spec (`*.agent.json`)

An Overcut Agent is a configured LLM persona used inside workflow steps. Emit one JSON file per distinct role.

**Specialize - one agent, one responsibility.** Model agents on the playbooks: each has a single sharp persona (a reviewer, an implementer, a doc writer, a triager), not a generalist that does everything. If a source agent wears several hats, split it into focused agents. Give each agent only the skills its job uses, and only the `availableTools` / `mcpServers` / `secrets` that responsibility requires - a reviewer that just comments needs less than an implementer that writes code.

**Give code agents their tools.** A Custom agent has **no** built-in tools by default (`availableTools: []` = it can touch nothing). If an agent's step runs after a `git.clone` it works on code, so populate `filesystem`/`git` - don't leave it empty just because the source declared no tool list. Record it as a MANIFEST TODO. See `integration-mapping.md` § "Assign built-in tools to code agents"; the validator warns when a post-clone agent has neither.

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
  "secrets": ["GITHUB_TOKEN"]
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

`skills` / `mcpServers` / `secrets` are **link intents** the importer records - the agent is created first with `createAgent(data: AgentCreateInput)`, then the links are applied. Keep them as names/keys, never ids (ids don't exist until creation).

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

**One workflow, one goal.** Don't port a sprawling source graph as a single workflow - decompose it into dedicated workflows, one per outcome/trigger (review PRs, triage issues, cut a release), each modeled on the nearest playbook. A tight, single-purpose workflow with a clear trigger is the target shape.

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
        "instruction": "Review the PR diff against the billing review checklist. Post findings as a PR comment.",
        "params": { "agent": "billing-pr-reviewer" }, "stepMaxDurationMinutes": 20 }
    ],
    "flow": [
      { "from": "identify", "to": "clone" },
      { "from": "clone",    "to": "review" }
    ]
  },
  "agentRefs": { "billing-pr-reviewer": "billing-pr-reviewer" }
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

`agentRefs` is a helper map (step's `params.agent` name -> agent `name`) so a later `importWorkflow` can supply `agentMapping`. It is not part of `definition`.

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

Never invent a real `modelKey`, secret value, MCP endpoint, or repo path.
