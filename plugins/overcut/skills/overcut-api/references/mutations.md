# Write-operation catalog

The token can mutate anything its owner's permissions allow. **Always confirm with the user before any create / update / delete / commit / trigger.** Default to read-only.

Mutation names and argument *shapes* below are verified against the schema; the exact fields inside each `*Input` type vary, so when building a create/update payload, ask the user for the fields they want to set rather than guessing required ones.

**Getting exact input shapes.** Introspection is disabled on the **production** endpoint, but is often enabled on non-prod (staging / self-hosted) endpoints. When it's available, list a create input's fields directly instead of guessing:

```graphql
query { __type(name: "AgentCreateInput") {
  inputFields { name type { kind name ofType { kind name ofType { kind name } } } }
} }
```

When introspection is off, **mirror a live entity** in the same account: read an existing similar `agent` / `workflow` and copy its structure. This matters most for workflows - the input shape gives you field *names*, but only a real example gives you valid `action` strings (e.g. `agent.run`), the `params` contract (e.g. `{ agentId, agentEngine: "overcut" }`), the entry-step convention (`flow: [{ from: "", to: "<stepId>" }]`), and valid trigger `event` enum values.

**Two `*Input` shapes that are stable and easy to get wrong:**
- `project` on `createAgent` / `createWorkflow` is a **connect wrapper**, not a bare id: `project: { connect: { id: $pid } }`.
- `createProjectSecret` requires a non-null **`value`** at creation (plus `name`, `projectId`, `availableForAllExecutions`) - unlike secret *assignment*, a create cannot omit the value. Only ever send a value the user explicitly provided.

Run the same way as queries:

```bash
scripts/overcut-gql.sh -f mutation.graphql -v '{"id":"..."}'
```

---

## Two safety rules (non-negotiable)

1. **Workflow draft vs committed.** `updateWorkflow` / `importWorkflow` change the *draft*. Production keeps running the last *committed* version until `commitWorkflow`. So:
   - Never `commitWorkflow` silently - production traffic moves to the new version immediately. Show the user what changed and get explicit go-ahead.
   - Never `discardWorkflowChanges` without confirmation - it permanently throws away draft edits.
   - `restoreWorkflowVersion` only updates the draft; the user must `commitWorkflow` to make an old version live again.
2. **Secrets by reference only.** Assign/unassign secrets by id. Never read, request, or echo a secret value. `createProjectSecret` takes a value once at creation - only send a value the user explicitly provided.

---

## Workflows

| Mutation | Args | Notes |
|---|---|---|
| `createWorkflow` | `data: WorkflowCreateInput!` | new draft workflow in a project |
| `updateWorkflow` | `data, where` | edits the **draft** |
| `activateWorkflow` / `deactivateWorkflow` | `where: { id }` | on/off, independent of versioning |
| `commitWorkflow` | `data: CommitWorkflowInput!` | snapshot draft -> new live version. **Confirm first.** |
| `discardWorkflowChanges` | `data: DiscardWorkflowChangesInput!` | reset draft to committed. **Destructive - confirm.** |
| `restoreWorkflowVersion` | `data: RestoreWorkflowVersionInput!` | load an old version into the draft |
| `triggerWorkflowManually` | `data: ManualWorkflowTriggerInput!` | start a run now |
| `quitWorkflow` | `data: QuitWorkflowInput!` | stop an in-flight run |
| `importWorkflow` | `projectId, workflowId?, agentMapping?` | import from an exported artifact (updates draft if `workflowId` given) |
| `deleteWorkflow` | `where: { id }` | |
| `addWorkflowFromPlaybook` | `projectId, playbookKeys: [String!]!` | instantiate playbook template(s) |
| `triggerRetrospective` | `data: TriggerRetrospectiveInput!` | run auto-improve analysis |

**Trigger rules that fail non-obviously at create time:**
- A `{ event: manual }` trigger is rejected with "Manual triggers must have a slash command configured" - always pair it: `{ event: manual, slashCommand: { command: "/my-command", requireMention: false } }`.
- `schedule.cronExpression` runs in **UTC** - convert the user's local time and mention the DST drift when it matters.
- A schedule only fires the **committed** version. A freshly created workflow (draft only, never committed) is safe to leave `active` - the schedule has nothing to run.

```graphql
# Trigger a run. `repositoryId` is REQUIRED even for workflows that never touch code
# (pass any connected repo, e.g. the one the workflow clones).
# `useWorkingDraft: true` runs the DRAFT - the way to test without committing,
# which pairs with safety rule 1 (never commit before the user has seen a test run).
mutation ($wid: String!, $rid: String!) {
  triggerWorkflowManually(data: { workflowId: $wid, repositoryId: $rid, useWorkingDraft: true }) {
    success message runId
  }
}

# Commit the draft (ONLY after user confirmation)
mutation ($wid: String!) {
  commitWorkflow(data: { workflowId: $wid, commitMessage: "..." }) {
    id currentVersionId hasUnpublishedChanges
  }
}
```

`updateWorkflow` returns `UpdateWorkflowResult`, not a `Workflow` - select `{ validationErrors workflow { id hasUnpublishedChanges } }` and read `validationErrors` before assuming the draft is good.

---

## Agents

| Mutation | Args |
|---|---|
| `createAgent` | `data: AgentCreateInput!` |
| `updateAgent` | `data: AgentUpdateInput!, where: { id }` |
| `duplicateAgent` | `where: { id }, name` |
| `activateAgent` / `deactivateAgent` | `where: { id }` |
| `deleteAgent` | `where: { id }` |
| `assignSkillsToAgent` | `input: AssignSkillsToAgentInput!` |
| `assignMcpServersToAgent` | `input: AssignMcpServersToAgentInput!` |
| `setAgentSecrets` | `agentId, secretIds: [String!]!` |

```graphql
# Attach skills to an agent
mutation ($aid: String!, $skills: [String!]!) {
  assignSkillsToAgent(input: { agentId: $aid, skillIds: $skills }) {
    id skills { id name }
  }
}
```

**`availableTools`** takes built-in tool identifiers in snake_case (`read_file`, `post_channel_message`, ...). The canonical catalog lives in the docs: [Agent tools reference](https://docs.overcut.ai/docs/reference/tools#agent-tools-reference) - copy identifiers from there exactly (unknown names may be accepted silently by older servers, and a typo'd tool simply never appears in runs). Two non-obvious facts:
- The `Custom` base type ships with an **empty** default tool set - list every tool the agent needs explicitly. Other base types carry implicit defaults on top of whatever you pass.
- Channel messaging (Slack) is built in via `post_channel_message` - no Slack MCP server needed. On scheduled runs there is no trigger channel to default to, so the instruction must pass an explicit `channelId`.

---

## Skills

| Mutation | Args |
|---|---|
| `createSkill` | `input: CreateSkillInput!` |
| `createSkills` | `projectId, inputs: [CreateSkillInput!]!` |
| `updateSkill` | (id + input) |
| `deleteSkill` | `id` |

---

## MCP servers

| Mutation | Args | Notes |
|---|---|---|
| `createMcpServer` | `input: CreateMcpServerInput!` | `config` is JSON - shapes below |
| `updateMcpServer` | `id, input: UpdateMcpServerInput!` | |
| `deleteMcpServer` | `id` | returns `McpServer` - select subfields (`{ id }`) |

`config` must contain **either** `command` (stdio) **or** `url` (remote), never both. `${SECRET_NAME}` placeholders anywhere in the config - env values, headers, args, partial strings included - resolve at run time from the pod's env; attach the secrets via `secretIds` so they're injected. `allowedTools: []` means unrestricted; a non-empty list filters. Server `name` must not contain `__` (reserved for tool namespacing).

```jsonc
// stdio (the catalog pattern)
{ "command": "npx", "args": ["-y", "@vendor/some-mcp-server"],
  "env": { "SOME_API_KEY": "${SOME_API_KEY}" } }

// remote (Streamable HTTP / SSE) - natively supported
{ "url": "https://mcp.example.com/mcp",
  "headers": { "Authorization": "Bearer ${SOME_API_KEY}" } }
```

**For remote MCP servers, use the native `url` config - NOT an `mcp-remote` npx bridge.** In a headless run `mcp-remote` responds to any 401 by starting an interactive browser OAuth flow that hangs until the runner's fixed 30s MCP bootstrap timeout, surfacing only as "bootstrap timed out" with zero tools. The native config fails fast with the real HTTP error instead. (npx cold-starts also eat into the same 30s budget.)

---

## Projects

| Mutation | Args |
|---|---|
| `createProject` | `data: ProjectCreateInput!` |
| `updateProject` | `data, where` |
| `deleteProject` | `where: { id }` |

---

## Project secrets

| Mutation | Args | Notes |
|---|---|---|
| `createProjectSecret` | `input: CreateProjectSecretInput!` | value sent once, only if user provided it; `""` is accepted - see placeholder flow |
| `toggleSecretAvailability` | `id, available: Boolean!` | flips `availableForAllExecutions` |
| `deleteProjectSecret` | `id` | returns Boolean |
| `setWorkflowSecrets` | `workflowId, secretIds: [String!]!` | assign by id |
| `setAgentSecrets` | `agentId, secretIds: [String!]!` | assign by id |

Constraints: `name` must match `^[A-Z][A-Z0-9_]+$`; `value` max 10KB. `deleteProjectSecret` returns a bare Boolean (no subfields).

**Placeholder flow - the way to wire secrets without the value ever entering the conversation:** create the secret with `value: ""`, have the user paste the real value in the web UI (Project -> Secrets), and verify readiness via `hasValue` / `updatedAt` - never by asking for the value. If a config embeds the secret in a larger string (e.g. an `Authorization` header), decide up front whether the secret holds the full string or just the credential, and tell the user exactly which format to paste - a mismatch (e.g. a bearer token saved without its `Bearer ` prefix) fails only at run time as an auth error.

---

## Repositories

| Mutation | Args |
|---|---|
| `activateRepository` / `deactivateRepository` | `where: { id }` |
| `triggerRepositoryIndex` | `data: TriggerRepositoryIndexInput!` |
