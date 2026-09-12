# Decoding a workflow definition

The `workflow` query returns a `definition` object (the editable draft). Committed versions carry the same shape under `workflowVersions[].definition`. This file explains that structure so you can read or build it.

```graphql
query ($id: String!) {
  workflow(where: { id: $id }) {
    id name active
    definition {
      name priority timeoutMs statusUpdateMethod defaultModelKey
      triggers { event conditions { __typename } slashCommand { __typename } schedule { __typename } }
      steps { id name action instruction params stepMaxDurationMinutes }
      flow { from to condition }
    }
  }
}
```

## Shape

- **`steps`** - the nodes. Each `WorkflowStep` has `id`, optional `name`, an `action` (string, see below), an optional `instruction` (the prompt, for agent steps), free-form `params` (JSON), and `stepMaxDurationMinutes`.
- **`flow`** - the edges. Each `StepConnection` has `from` (step id), `to` (step id), and an optional `condition`. This is what orders the steps; do not assume the `steps` array order is the execution order.
- **`triggers`** - an array (logical OR); at least one is required. See triggers below.
- Workflow-level knobs: `priority` (1-100, lower runs first), `timeoutMs`, `statusUpdateMethod` (`comment` / `reuse_comment` / `static_comment`), `defaultModelKey`.

## The step action types

| `action` | What it does |
|---|---|
| `git.clone` | Clone a repo into the run workspace so later steps can read/modify code. |
| `repo.identify` | Resolve *which* repo to clone from the trigger context (used before `git.clone` when the repo isn't fixed). |
| `agent.run` | Run one agent for a short, deterministic, one-shot task (extract data, post a comment, produce a result the next step consumes). |
| `agent.session` | Run a built-in **coordinator** plus one or more sub-agents for a multi-turn / iterative task. The coordinator is automatic; the step's `params` reference the sub-agent ids. |
| `script.run` | Run inline bash deterministically with no agent: `params.script` (fixed text), optional `cwd`, `env` (values may use `{{expressions}}`), `timeoutSeconds`. Structured output is JSON the script writes to `$OC_OUTPUT_FILE`. |

Reading rules that explain otherwise-confusing definitions:
- `git.clone` / `repo.identify` are **step actions**, not agent tools. An agent step can only touch code if a `git.clone` step ran before it. So a code-modifying workflow almost always looks like `repo.identify?` -> `git.clone` -> `agent.*`.
- An `agent.run` step has a single implicit execution thread; an `agent.session` step fans out into sub-agent threads (relevant when debugging runs - see `debugging-runs.md`).

## Template expressions

Step `instruction` strings and string `params` are Handlebars templates rendered at dispatch time. Three namespaces appear in definitions:

| Expression | Resolves to |
|---|---|
| `{{trigger.<path>}}` | the normalized trigger event, e.g. `{{trigger.pullRequest.headBranch}}`, `{{trigger.repository.fullName}}` |
| `{{outputs.<stepId>.<path>}}` | a previous step's output (an agent's plain-text reply is `{{outputs.<stepId>.message}}`; a `script.run` step's JSON is under `.output.<field>`) |
| `{{params.<key>}}` | a **context parameter** resolved for this run (see `concepts.md`) - the most specific value on the path `workspace default < project < repository < workflow < orchestration < agent`. Also valid in agent `additionalInstructions`. `script.run` steps additionally get every referenced key as the env var `OC_PARAM_<KEY>` (upper case). |

`{{{ }}}` (triple braces) disables HTML escaping - use it when passing agent prose or code between steps. Every `{{params.<key>}}` must name a defined parameter: `commitWorkflow` rejects unknown keys, and a run whose key has no value on its path fails at preparation with `statusReason: ContextParameterUnresolved`. Preview with `contextParameterResolutionPreview` (`queries.md`) before committing.

## Triggers

Each `WorkflowTrigger` has:
- **`event`** (`StandardizedEventType`) - the normalized event, e.g. `pull_request_opened`, `issue_opened`, `mention`, `custom_event`.
- **`conditions`** (`TriggerRule`) - React-Query-Builder-style filter tree that narrows when the event actually fires the workflow (by repo, label, author, path, channel, etc.).
- **`slashCommand`** - settings when the trigger is a `/command` typed in a PR/issue comment or chat channel.
- **`schedule`** - cron details for time-based triggers.
- **`customEvent`** - required when `event === "custom_event"`: binds to a named workspace webhook (the `name` is the event's workspace-unique **slug**, not its id).
- **`settings`** - e.g. `delaySeconds` (a debounce / edit-grace delay before the run starts).

### Event sources (depends on which providers the workspace has connected)

- **Git events** - PR opened/updated/merged/closed/commented, push, review submitted.
- **Ticket events** - issue created/updated/commented/labeled/status-changed (Jira, GitHub Issues, Linear, Azure DevOps).
- **Messaging events** - chat-channel `mention`, `slash_command`, `channel_message` (Slack today).
- **Schedule** - cron-style.
- **Manual** - triggered from the Playground UI or via `triggerWorkflowManually`.
- **Custom events** - a third party POSTs to a per-event webhook URL; the dispatcher authenticates and fires the workflow if the `customEvent.name` slug matches.

### Top-level event fields (every event, when you inspect a run)

These four live at the **top level** of a normalized event (not under `context`): `source` (`EnumGitProvider` - `Github`, `GitLab`, `Bitbucket`, `AzureDevOps`, `Jira`, `Linear`, `ClickUp`, `Slack`), `eventType` (the normalized name), `id`, `timestamp`. Repository/actor/issue/PR/channel details live under `context.*`.

The web UI's trigger field picker is the source of truth for the exact filterable fields per event family.
