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

```graphql
# Trigger a run
mutation ($wid: String!) {
  triggerWorkflowManually(data: { workflowId: $wid }) { __typename }
}

# Commit the draft (ONLY after user confirmation)
mutation ($wid: String!) {
  commitWorkflow(data: { workflowId: $wid, commitMessage: "..." }) {
    id currentVersionId hasUnpublishedChanges
  }
}
```

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

| Mutation | Args |
|---|---|
| `createMcpServer` | `input: CreateMcpServerInput!` |
| `updateMcpServer` | `id, input: UpdateMcpServerInput!` |
| `deleteMcpServer` | `id` |

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
| `createProjectSecret` | `input: CreateProjectSecretInput!` | value sent once, only if user provided it |
| `toggleSecretAvailability` | `id, available: Boolean!` | flips `availableForAllExecutions` |
| `deleteProjectSecret` | `id` | returns Boolean |
| `setWorkflowSecrets` | `workflowId, secretIds: [String!]!` | assign by id |
| `setAgentSecrets` | `agentId, secretIds: [String!]!` | assign by id |

---

## Repositories

| Mutation | Args |
|---|---|
| `activateRepository` / `deactivateRepository` | `where: { id }` |
| `triggerRepositoryIndex` | `data: TriggerRepositoryIndexInput!` |
