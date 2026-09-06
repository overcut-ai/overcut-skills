# Overcut target formats

The compile target. Every artifact you emit must match one of these three shapes so it imports cleanly via the `overcut-api` skill (`createSkill` / `createAgent` / `importWorkflow`). Field names, enums, and validation rules below mirror the Overcut data model (`WorkflowDefinitionSchema`, the step-params schemas, and the GraphQL inputs). When a required field has no source value, emit the documented **placeholder** and add a TODO to the `MANIFEST.md`.

---

## 1. Skill - a `SKILL.md` bundle in a git repo

An Overcut Skill is a versioned instruction bundle: a directory containing a `SKILL.md`, loaded from a connected git repo at a `path` + `ref`. It is **not** uploaded content - it lives in git, and `createSkill` registers a pointer to it. So conversion produces a folder the user commits to a repo.

**Output:** `out/skills/<kebab-name>/SKILL.md` (+ optional `references/` sub-files for anything long).

```markdown
---
name: <kebab-case-name>
description: <one line, third person, says what it does AND when to use it - this is what Overcut matches on>
license: Apache-2.0            # optional
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
- **Frontmatter: Overcut reads only `name`, `description`, and `license`.** The folder name becomes the skill `slug`. Any other key (`allowed-tools`, `version`, `tags`, a coding-agent's `metadata`) is ignored by Overcut - strip it so the file does not suggest behavior it cannot have.
- `name` is unique within the project. `description` is the only field Overcut uses to decide relevance - make it specific and trigger-rich.
- Keep the body about **durable knowledge** (review criteria, coding standards, domain rules, definitions of done). Move orchestration ("then call step 3") into the *workflow*, not the skill.
- A Skill is reusable across agents. If two source agents share a checklist, emit **one** skill and link it only from the agents that use it.

**Registration** (done later, by the `overcut-api` skill), once the folders are committed to a repo connected to the project:

```graphql
# discover what is in the repo (returns slug, name, description, path, alreadyRegistered)
browseSkillsInRepo(input: { repositoryId, ref, path? })
# register one
createSkill(input: { projectId, repositoryId, slug, path, ref, name, description })
# or many at once
createSkills(projectId, inputs: [CreateSkillInput!])
```

`repositoryId` and `slug` (the folder name) are **required**; `path` is the folder inside the repo; `ref` is the branch/tag (optional, defaults to the repo default branch).

---

## 2. Agent - a persona spec (`*.agent.json`)

An Overcut Agent is a configured LLM persona used inside workflow steps. Emit one JSON file per distinct role.

**Specialize - one agent, one responsibility.** Model agents on the playbooks: each has a single sharp persona (a reviewer, an implementer, a doc writer, a triager), not a generalist that does everything. If a source agent wears several hats, split it into focused agents. Give each agent only the skills its job uses, and only the `availableTools` / `mcpServers` / `secrets` that responsibility requires - a reviewer that just comments needs less than an implementer that writes code.

**Give code agents their tools.** A Custom agent has **no** tools by default (`availableTools: []` = it can touch nothing). A `git.clone` step only puts the repository into the run workspace; whether the agent can *read or change* it is decided by its `availableTools`. So if an agent's step runs after a `git.clone`, populate the filesystem/terminal tools it uses (`read_file`, `edit_file`, `list_dir`, `code_search`, `run_terminal_cmd`, ...) - don't leave it empty just because the source declared no tool list. Record it as a MANIFEST TODO. `availableTools` holds built-in tool identifiers only; PR/ticket/channel actions are built-in tools too (not MCP). See `integration-mapping.md` for the categories and the authoritative [Agent Tools Reference](https://docs.overcut.ai/docs/reference/tools); the validator warns when a post-clone agent has no filesystem/terminal tool.

**Output:** `out/agents/<kebab-name>.agent.json`

```json
{
  "name": "billing-pr-reviewer",
  "description": "Reviews PRs that touch billing code for correctness, PCI, and rollout safety.",
  "baseAgentType": "CodeReview",
  "modelKey": "<workspace-default>",
  "additionalInstructions": "You are a senior reviewer for the billing domain. <distilled system prompt>",
  "color": "#4F46E5",
  "availableTools": ["read_file", "code_search", "read_pull_request", "get_pull_request_diff", "add_comment_to_pull_request"],
  "skills": ["billing-review-checklist"],
  "mcpServers": [],
  "secrets": []
}
```

(PRs are a first-class provider, so the reviewer uses built-in `*_pull_request` tools - no MCP, no secret. `mcpServers` is only for providers the built-in catalog doesn't cover, e.g. `{ "catalogKey": "notion", "allowedTools": ["search"], "confidence": "high" }` with a `secrets` entry.)

Field reference:

| Field | Type | Notes |
|---|---|---|
| `name` | string | Unique in project. Kebab-case recommended. |
| `description` | string | One line; shown in the UI. |
| `baseAgentType` | enum | One of `CodeReview`, `Custom`, `ProductManager`, `SeniorDeveloper`, `TechWriter`. Default `Custom`. (`InternalRepoIdentify` is also in the enum but is the built-in behind `repo.identify` - never emit it for a user agent.) |
| `modelKey` | string | A key from the workspace LLM registry (`llmModels` query). **Required and non-blank at `createAgent`** - the placeholder `"<workspace-default>"` is for the artifact only and must be replaced before import (see Placeholders). |
| `additionalInstructions` | string | The agent's **system prompt** - the distilled role/goal/behavior. This is where most business logic lands. |
| `color` | string | Hex color for the UI. Any valid hex; pick a stable one per agent. |
| `availableTools` | string[] | **Built-in** `EnumTools` names only (e.g. `read_file`, `run_terminal_cmd`, `create_pull_request`). No `filesystem`/`git`/bare provider names, and NOT MCP tools. See the catalog in `integration-mapping.md`. |
| `skills` | string[] | `name`s of skills (from `out/skills/`) to attach. At import they become `skillIds` on `createAgent` (or `assignSkillsToAgent` later). |
| `mcpServers` | object[] | Recommendations, not live config: `{ catalogKey, allowedTools, confidence }`. Once the server exists they become `mcpServerIds` on `createAgent` / `assignMcpServersToAgent`. |
| `secrets` | string[] | Secret **names** the agent needs. The user creates them; assigned by id via `setAgentSecrets(agentId, secretIds)`. Never a value. |

`skills` / `mcpServers` / `secrets` are **link intents** the importer records - the agent is created with `createAgent(data: AgentCreateInput)` (which already accepts `skillIds` and `mcpServerIds`), and secrets are attached afterwards. Keep them as names/keys, never ids (ids don't exist until creation).

### Choosing `baseAgentType`

Prefer `Custom` unless the source role is unmistakable. Only upgrade on a clear signal:

| Source role signal | `baseAgentType` |
|---|---|
| reviews code / PRs, comments on diffs | `CodeReview` |
| implements features, writes/edits code | `SeniorDeveloper` |
| writes specs, PRDs, product/planning docs | `ProductManager` |
| writes docs, changelogs, READMEs | `TechWriter` |
| anything else / ambiguous | `Custom` |

When you pick anything other than an obvious match, mark it TODO in the manifest.

---

## 3. Workflow - an import artifact (`*.workflow.json`)

An Overcut Workflow is a triggered, ordered set of steps. Emit it as the **import artifact** that `importWorkflow` accepts (the same shape `exportWorkflow` and `playbook(key).artifact` produce), so the file goes in unchanged.

**One workflow, one goal.** Don't port a sprawling source graph as a single workflow - decompose it into dedicated workflows, one per outcome/trigger (review PRs, triage issues, cut a release), each modeled on the nearest playbook. A tight, single-purpose workflow with a clear trigger is the target shape.

**Output:** `out/workflows/<kebab-name>.workflow.json`

```json
{
  "_formatVersion": "1.0.0",
  "workflow": {
    "name": "billing-pr-review",
    "definition": {
      "name": "billing-pr-review",
      "priority": 5,
      "timeoutMs": 1800000,
      "statusUpdateMethod": "comment",
      "triggers": [
        {
          "event": "pull_request_opened",
          "conditions": {
            "combinator": "and",
            "rules": [
              { "field": "context.pullRequest.draft", "operator": "equals", "value": false }
            ]
          }
        },
        {
          "event": "manual",
          "slashCommand": { "command": "review-billing", "requireMention": false }
        }
      ],
      "steps": [
        { "id": "clone", "name": "Clone repository", "action": "git.clone",
          "params": { "repoFullName": "{{trigger.repository.fullName}}", "cloneOptions": { "depth": 1 } },
          "stepMaxDurationMinutes": 10 },
        { "id": "review", "name": "Review billing PR", "action": "agent.run",
          "instruction": "Review the PR diff against the billing review checklist. Post findings as a PR comment.",
          "params": { "agentId": "billing-pr-reviewer-agent-id" },
          "stepMaxDurationMinutes": 20 }
      ],
      "flow": [
        { "from": "", "to": "clone" },
        { "from": "clone", "to": "review" }
      ]
    }
  },
  "refs": {
    "agents": [
      { "id": "billing-pr-reviewer-agent-id", "name": "billing-pr-reviewer" }
    ]
  }
}
```

### The artifact wrapper

| Field | Notes |
|---|---|
| `_formatVersion` | Always `"1.0.0"`. |
| `workflow.name` | Display name. Kebab-case, matches the file name. |
| `workflow.definition` | The definition (below). |
| `refs.agents[]` | `{ id, name }` for every agent the steps reference. `id` is a **placeholder** you invent (`<agent-name>-agent-id`), used verbatim in `params.agentId` / `params.agentIds`; `name` is the `name` of a file in `out/agents/`. At import, `importWorkflow(agentMapping: [{ from: <placeholder>, to: <real agent id> }])` rewrites them. |

### The definition shape

| Field | Notes |
|---|---|
| `name` | Required. |
| `steps[]` | Nodes. Each: `id` (unique, `^[a-zA-Z0-9-]+$` - hyphens, no underscores), `name` (**required**), `action` (see below), `params` (shape depends on `action`), `instruction` (**required** for `agent.run` / `agent.session`), optional `stepMaxDurationMinutes` (>= 1). |
| `flow[]` | Edges `{ from, to }`. **A single linear chain**: the first edge has `from: ""`, every step appears exactly once as a `to`, and each step has at most one outgoing edge. There is **no `condition`** on an edge and **no parallel branches** - Overcut runs steps strictly one at a time. For concurrent or branching work use one `agent.session` step with several sub-agents. |
| `triggers[]` | At least one (logical OR). See below. |
| `priority` | Integer 1-100, **lower runs first**. Default `5`. Playbooks use 1-10. |
| `timeoutMs` | Whole-workflow timeout in ms. Minimum `30000`. |
| `statusUpdateMethod` | `comment` (default) / `reuse_comment` / `static_comment`. (`none` exists internally for silent system workflows and is rejected on import - never emit it.) |
| `defaultModelKey` | Optional. **Omit it** to use the workspace default - do not emit a placeholder string here. |
| `machineTierKey` | Optional. `standard` (default) / `large` / `xlarge`. Set only when the source clearly needed a big build/test box. |

### Step actions and their `params`

| `action` | `params` | Use for |
|---|---|---|
| `git.clone` | `{ repoFullName, branch?, cloneOptions? }` - `repoFullName` is **required**: a literal `org/repo`, `{{trigger.repository.fullName}}` when the trigger carries a repo, or `{{outputs.<repo-identify-step-id>}}` after `repo.identify`. `cloneOptions: { depth, singleBranch, sparseCheckout, submodules, ... }`. | Put a repo into the run workspace so later steps can read/modify code. |
| `repo.identify` | `{ maxResults?, minConfidence?, identificationHints? }` (`{}` is valid - defaults 1 / 0.2). | Resolve *which* repo to clone from the trigger context (a ticket, a chat message). Precedes `git.clone` when the repo isn't fixed and the trigger doesn't name one. |
| `agent.run` | `{ agentId, agentEngine? }` + step-level `instruction`. `agentId` is a `refs.agents[].id` placeholder. | One agent, one bounded task (extract, comment, produce a result the next step consumes). |
| `agent.session` | `{ agentIds[], goal, exitCriteria?: { timeLimit: { maxDurationMinutes }, userSignals?: { explicit: [] } }, listenToComments?, keepSessionOpenForComments?, agentEngine?, coordinatorModelKey? }` + step-level `instruction`. | A built-in **coordinator** + one or more sub-agents for multi-turn / iterative / parallel work. Use when the source is a loop, a group chat, a hierarchical crew, or a fan-out. |
| `script.run` | `{ script, cwd?, env?, timeoutSeconds? }` - inline bash; `cwd` relative to the workspace (e.g. the cloned repo folder); `env` values may use `{{expressions}}`; write JSON to `$OC_OUTPUT_FILE` for structured output. | A **deterministic** shell step (run tests, lint, a build, a script the source ran in a container) that needs no LLM judgment. |
| `ci.executeWorkflow` | `{ repoFullName, workflowId, ref?, inputs?, waitForCompletion? }` | Kick an external CI pipeline (GitHub Actions workflow file, etc.) and optionally wait for it. |

`agentEngine` is `overcut` (default) or `claude`. Leave it out unless the source explicitly ran on Claude Code and the user wants that harness.

Hard rule: an agent can only work on code if a `git.clone` ran before its step **and** its `availableTools` include the filesystem/terminal tools. A code-modifying pipeline is `repo.identify?` -> `git.clone` -> `agent.*`. If a source step reads/writes a repo, insert the clone even if the source didn't model it explicitly.

`agent.run` vs `agent.session` vs `script.run`: one-shot task needing judgment -> `agent.run`; loop / "keep going until done" / multi-agent conversation / hierarchical delegation / parallel sub-tasks -> `agent.session` (sub-agents in `agentIds`, the outcome in `goal`); a fixed command with no judgment -> `script.run`.

### Template expressions

`instruction`, `git.clone.repoFullName`, `script.run.env` values, and `agent.session.goal` are Mustache templates:

- `{{trigger.*}}` - the normalized trigger context: `{{trigger.repository.fullName}}`, `{{trigger.pullRequest.headBranch}}`, `{{trigger.issue.title}}`, `{{trigger.issue.number}}`, `{{trigger.actor.login}}`, `{{trigger.triggerObjectUrl}}` ... (see the [Event Context](https://docs.overcut.ai/docs/reference/event-context) reference).
- `{{outputs.<stepId>}}` - the output of an earlier step (what `repo.identify` resolved, what a `script.run` wrote to `$OC_OUTPUT_FILE`).

Use them instead of hardcoding repo names from the source.

### Triggers

Each trigger: `event` (a `StandardizedEventType`), optional `conditions`, and one event-specific block. The valid events:

| Family | `event` values |
|---|---|
| Pull requests | `pull_request_opened`, `pull_request_edited` (also fires on new commits pushed), `pull_request_closed`, `pull_request_merged`, `pull_request_commented`, `pull_request_reviewed`, `pull_request_review_commented`, `pull_request_labeled`, `pull_request_unlabeled`, `pull_request_assigned`, `pull_request_unassigned` |
| Issues / tickets | `issue_opened`, `issue_edited`, `issue_closed`, `issue_commented`, `issue_labeled`, `issue_unlabeled`, `issue_assigned`, `issue_unassigned` |
| CI | `ci_workflow_queued`, `ci_workflow_started`, `ci_workflow_completed`, `ci_workflow_failed`, `ci_workflow_cancelled`, `ci_workflow_timed_out` |
| Messaging | `mention`, `channel_message`, `thread_reply`, `slash_command` |
| Time | `scheduled` - **requires** `schedule: { cronExpression, scheduleContextSettings?: { type: "Single" \| "PerRepository", repositorySelector? } }`; at most one per workflow |
| Webhook in | `custom_event` - **requires** `customEvent: { name }` = the workspace custom-event slug |
| Manual | `manual` - **requires** `slashCommand: { command, requireMention }`; `slashCommand` is only legal on `manual` |

Rules the importer enforces (the validator checks them too):

- `manual` **must** carry a `slashCommand`. A bare `{ "event": "manual" }` is rejected. The placeholder when the source has no trigger is `{ "event": "manual", "slashCommand": { "command": "<workflow-name>", "requireMention": false } }`.
- `conditions`, when present, is a strict rule group: `{ "combinator": "and" | "or", "rules": [ { "field", "operator", "value" } | <nested group> ] }`. Operators: `equals`, `notEquals`, `contains`, `notContains`, `startsWith`, `endsWith`, `matches`, `in`, `notIn`. Fields used by the playbooks: `context.trigger.label`, `context.pullRequest.draft`, `context.pullRequest.baseBranch`, `context.trigger.commitAdded`, `context.ciWorkflow.isPullRequest`. **No free-form keys** - when you can't express the source filter confidently, **omit `conditions`** and add a TODO; never emit `{ "TODO": ... }`.
- Optional `settings: { delaySeconds }` on any trigger.

---

## Placeholders and TODOs - the contract

Output must import even when the source lacks required fields. Use exactly these placeholders and record each in the manifest:

| Missing | Placeholder | TODO text |
|---|---|---|
| agent model | `"modelKey": "<workspace-default>"` in the `.agent.json` | "Replace `<workspace-default>` with a key from `llmModels` before `createAgent` (the field is required and validated)." |
| workflow model | omit `defaultModelKey` | none needed - null means workspace default |
| baseAgentType (ambiguous) | `"Custom"` | "Confirm baseAgentType (inferred/defaulted)." |
| trigger | `[{ "event": "manual", "slashCommand": { "command": "<workflow-name>", "requireMention": false } }]` | "No source trigger found - define the real trigger (the manual slash command is a stand-in)." |
| trigger filter | omit `conditions` | "Narrow the trigger conditions in the UI (repo/label/path/author)." |
| repo for `git.clone` | `{{trigger.repository.fullName}}` if the trigger carries a repo, else a `repo.identify` step + `{{outputs.<id>}}` | "Confirm the repository source for step `<id>`." |
| agent id in a step | `<agent-name>-agent-id` + matching `refs.agents` entry | none - `importWorkflow(agentMapping)` resolves it |
| integration config | omit; list under Integrations | "Assign MCP server <x> + secret <y> to agent <z>." |

Never invent a real `modelKey`, secret value, MCP endpoint, or repo path.
