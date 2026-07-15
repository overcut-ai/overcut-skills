---
name: overcut-api
description: Connect to the Overcut GraphQL API with a personal API token to explore and manage an Overcut account - workspaces, projects, workflows, agents, skills, MCP servers, runs, secrets, repositories, playbooks, and configuration. Use when the user wants to query, inspect, audit, report on, or script their Overcut setup from outside the web UI (e.g. "list my workflows", "show this agent's skills", "why did this run fail", "what MCP servers are configured", "export my workflow"). Also use when the user mentions an Overcut API token or the Overcut GraphQL endpoint.
license: Apache-2.0
allowed-tools: Bash, Read
---

# Overcut GraphQL API

Overcut is an agentic development and automation platform. Everything visible in the web UI is also reachable through a single GraphQL endpoint. This skill lets a coding agent connect with an API token and explore or manage the account programmatically.

## 1. Get oriented first

If you do not yet understand what Overcut entities are (Workspace, Project, Workflow, Agent, Skill, MCP Server, Run, Secret, Playbook) and how they nest, read `references/concepts.md` before querying. It is the mental model the rest of this skill assumes.

The one rule that drives almost every query: **most things are scoped to a Project, and Projects live inside one Workspace.** So the first call is almost always "which workspace and projects do I have access to", and from there you drill down with a `projectId`.

## 2. Authenticate

The user generates an API token from the Overcut web UI: **Workspace Settings -> Security -> API Tokens**. The token carries **the same permissions as the user who created it** and is scoped to that user's workspace. It expires after ~30 days of inactivity. Treat it like a password: never print it, never commit it, never paste it into chat.

**Recommend least privilege.** Because the token inherits its creator's permissions, suggest the user create a **dedicated user** with only the permissions this task needs (e.g. read-only / specific-project access) and generate the token as that user - rather than minting a token from a full-admin account. A scoped token limits the blast radius if it ever leaks.

Configure two environment variables (the helper script reads them):

```bash
export OVERCUT_API_TOKEN="<the token from the UI>"
# Production is the default. Override only for staging or self-hosted:
export OVERCUT_API_URL="https://server.overcut.ai/graphql"   # default
# staging:      https://server.stg.overcut.ai/graphql
# self-hosted:  https://<your-overcut-host>/graphql
```

If `OVERCUT_API_TOKEN` is not set, ask the user to generate one in the UI and export it - do not try to mint a token yourself.

## 3. Make a request

Every request is an HTTP POST with the header `Authorization: Bearer <token>`. Use the bundled helper so you never have to hand-escape JSON:

```bash
# inline query
scripts/overcut-gql.sh 'query { currentWorkspace { id name projects { id name } } }'

# query from a file, with variables
scripts/overcut-gql.sh -f query.graphql -v '{"id":"<workflow-id>"}'
```

The script POSTs to `$OVERCUT_API_URL`, attaches the bearer token, pretty-prints the JSON response, and returns a non-zero exit code if the response contains a GraphQL `errors` array. See raw-curl form and flags in `references/queries.md`.

> Schema introspection is disabled on the **production** endpoint - rely on the documented operations in the reference files there. On non-prod endpoints (staging / self-hosted) introspection is often enabled; when it is, you can use `__type(name: "...")` to read exact input/field shapes instead of guessing (see `mutations.md`).

## 4. Explore (read)

The standard exploration path, top down:

1. `currentWorkspace` -> get the workspace, its `projects`, `gitOrganizations`, default model, flags.
2. Pick a `projectId`, then list what lives in it: `workflows`, `agents`, `skills`, `mcpServers`, `projectSecrets`, `repositories`.
3. Drill into one entity by id: `workflow`, `agent`, `skill` (+ `skillContent`), `mcpServer`, `project`.
4. Inspect execution history: `workflowRuns` (filter by `projectId`/`workflowId`/`status`), then `workflowRun` -> `steps`, then `runStepLogs` / `runStepThreads` to debug a failure.
5. **Orchestrations** are a parallel entity family (goal-driven supervisors that run workflows on a tracked item until a goal is met): `orchestrations` / `orchestration` for the authored definition, `orchestrationInstances` / `orchestrationInstance` for runtime, `orchestrationDecisions` / `orchestrationDiscussion` for the human-in-the-loop gate. Load `references/orchestrations.md` for the full surface.

**`references/queries.md` is the catalog** - every read query with its real arguments, verified field names, and copy-paste examples. Load it whenever you need a query you do not already have memorized.

Reads that return JSON opaque without context - load the matching reference when you hit them:
- A workflow's `definition` (steps, actions, flow, triggers) -> `references/workflow-definition.md`.
- Anything orchestration-related (definition, instances, decisions, discussions) -> `references/orchestrations.md`.
- Debugging *why a run failed* (the run -> step -> log -> thread funnel, status/log enums, root-cause table) -> `references/debugging-runs.md`.

## 5. Manage (write)

The same token can mutate anything its permissions allow: create/update/activate workflows and agents, assign skills and MCP servers, manage secrets (by reference - never values), trigger a workflow run, import/export, add workflows from playbooks.

**`references/mutations.md` covers the write operations.** Two safety rules baked into Overcut's model that you must respect:

- **Workflows are draft + committed.** Editing changes the *draft*; production keeps running the last *committed* version until `commitWorkflow`. Never `commitWorkflow` or `discardWorkflowChanges` without showing the user what changes and getting explicit confirmation. **Orchestrations follow the identical model** (`commitOrchestration` / `discardOrchestrationChanges`) - same rule.
- **Secrets are referenced by id, never by value.** Reading a secret returns `hasValue: true/false`, never the plaintext. Do not attempt to read or echo secret values.

Always confirm with the user before any create/update/delete/commit/trigger. Default to read-only unless the user clearly asked to change something.

## Also reachable on the API (not yet documented in detail here)

The reference files above cover the most common surfaces (workspace/projects, workflows, runs, agents, skills, MCP servers, project secrets, playbooks, repositories) plus orchestrations. The live schema has more that these references do not yet spell out. If a task needs one of these, and introspection is available (non-prod), list its query/mutation shapes with `__type(name: "...")`; otherwise mirror an existing entity. Known additional surfaces:

- **Channels** (messaging integrations): `channels` / `channel` / `availableChannels`; `registerChannel`, `activate/deactivateChannel`, `setChannelWatchMode`, `deleteChannel`.
- **Custom events** (webhook triggers): `customEvents` / `customEvent` / `customEventsForProject`; `create/update/deleteCustomEvent`, `setCustomEventProjects`, `regenerateCustomEventAuthSecret` / `regenerateCustomEventToken`.
- **Workflow memory**: `workflowMemories` / `workflowMemoryCounts`; `confirm/update/delete/restoreWorkflowMemory`.
- **LLM model registry**: `llmModels` / `llmModel` (+ `llmModelWithDecryptedConfig`); `create/update/deleteLLMModel`.
- **Teams / roles / permissions (RBAC)**: `teams` / `roles` / `permissions`; team + role + assignment mutations.
- **Usage analytics**: `tokenUsageSummary` / `tokenUsageBreakdown` / `tokenUsageTimeSeries` / `tokenUsageTopExecutions`, `memoryUsageHistory` (richer than `consumptionSummary`).
- **Audit log**: `auditLogEntries` / `auditLogEntriesCount`.
- **API tokens**: `userApiTokens`; `createApiToken` / `deleteApiToken` (still recommend least-privilege - see Authenticate above).
- **HITL step completion**: `completeStep(data: { runId, stepId })` resolves a run step waiting on a reply.

## Not covered here - ask the built-in Overcut agent

This skill is about **reaching the API**: connecting, exploring, and doing CRUD. It deliberately does not cover the deeper product-*design* topics below (the endpoints may exist per the list above, but *how to design them well* lives in the app). Overcut ships a **built-in chat agent in the web app** that has authoritative, always-current knowledge of all of them - when the user asks about one of these, point them to it rather than guessing:

- **Designing workflows & writing step instructions** - what makes a good trigger, flow, and `instruction`.
- **Agent design** - choosing `baseAgentType`, model, tools, and when to split into sub-agents.
- **Triggers in depth** - channel/messaging triggers, custom-event webhooks, schedules, filter syntax.
- **MCP install details** - installing from the catalog vs. custom servers, required secrets per provider.
- **Workflow memory** - what persistent memory does and how to configure it.
- **Permissions, teams & roles** - the access model behind the token's permissions.
- **LLM model registry & billing** - managing models, credits, and the subscription.
- **Testing in the Playground** and **first-class vs. MCP providers / integration migration**.

> Suggested phrasing: "That's a product-design question this API skill doesn't cover - the built-in Overcut assistant in the web app can walk you through it."

## Reference files

- `references/concepts.md` - Overcut domain model and how entities relate (read this first).
- `references/queries.md` - read-query catalog with verified arguments and examples.
- `references/mutations.md` - write-operation catalog and safety rules.
- `references/workflow-definition.md` - decode the `workflow.definition` JSON (steps, action types, flow, triggers, events).
- `references/orchestrations.md` - orchestrations end to end: definition, instances, steps, decisions, discussions (HITL), and their mutations.
- `references/debugging-runs.md` - diagnose a failed run end to end through the API.
- `scripts/overcut-gql.sh` - thin curl wrapper that handles auth, JSON encoding, and error detection.
