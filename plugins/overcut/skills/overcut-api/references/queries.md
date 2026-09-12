# Read-query catalog

Every query below is verified against the Overcut GraphQL schema: real query names, real arguments, real field names. Run them with the helper:

```bash
scripts/overcut-gql.sh '<query>'
scripts/overcut-gql.sh -f query.graphql -v '{"id":"..."}'
```

Raw curl equivalent (if you are not using the helper):

```bash
curl -sS -X POST "$OVERCUT_API_URL" \
  -H "Authorization: Bearer $OVERCUT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"query { currentWorkspace { id name } }"}'
```

Conventions used by the schema:
- `where: WhereUniqueInput!` always means `{ id: String! }` - the single-entity lookups.
- `StringFilter` supports `{ equals, contains, startsWith, endsWith, in, not, mode }`.
- `DateTimeFilter` supports `{ equals, gte, lte, gt, lt }`.
- List queries that take `where`/`orderBy`/`skip`/`take` are paginated; default to a `take` of 20-50.

---

## Start here: workspace and projects

```graphql
# Your workspace, its projects, connections, and config flags
query {
  currentWorkspace {
    id
    name
    defaultModelKey
    autoImproveWorkflows
    hasClaudeApiKey
    timezone
    projects { id name description }
    gitOrganizations {
      id name provider url
      supportsRepositories supportsTickets
    }
    users { id }
  }
}
```

```graphql
# List / filter projects
query {
  projects(orderBy: { name: Asc }, take: 50) {
    id name description color repositoryAccessMode
    repositories { id name provider }
  }
}

# Single project
query ($id: String!) {
  project(where: { id: $id }) {
    id name description repositoryAccessMode
    repositories { id fullName provider useForCode useForTickets }
    mcpServers { id name }
  }
}
```

Other workspace-level reads: `workspaces`, `workspace(where:{id})`, `workspaceUsers`, `workspaceMembers`, `repositories(projectId, where, orderBy)`, `repository(where:{id})`.

---

## Workflows

```graphql
# List workflows in a project (where.projectId is a StringFilter)
query ($pid: String!) {
  workflows(
    where: { projectId: { equals: $pid } }
    orderBy: [{ name: Asc }]
    take: 50
  ) {
    id name active hasUnpublishedChanges
    currentVersionId
    currentVersion { id versionNumber committedAt commitMessage }
    updatedAt
  }
}
```

```graphql
# Single workflow with its draft definition
query ($id: String!) {
  workflow(where: { id: $id }) {
    id name active
    hasUnpublishedChanges currentVersionId
    # definition is a typed WorkflowDefinition object, not a scalar - it
    # requires subfield selection. See workflow-definition.md for the full shape.
    definition {
      name priority timeoutMs statusUpdateMethod defaultModelKey
      triggers { event conditions { __typename } slashCommand { __typename } schedule { __typename } }
      steps { id name action instruction params stepMaxDurationMinutes }
      flow { from to condition }
    }
    retroRunThreshold retroSampleSize
    secrets { id name }
  }
}
```

```graphql
# Version history
query ($id: String!) {
  workflowVersions(workflowId: $id) {
    id versionNumber commitMessage committedAt
    committedBy { id }
  }
}

# Which workflows have uncommitted draft changes
query ($pid: String!) {
  workflowsWithUnpublishedChanges(projectId: $pid) { id name }
}
```

The `definition` field is a typed `WorkflowDefinition` object (steps, action types, flow, triggers) - it requires subfield selection, not a bare scalar. To read or build it, see **`workflow-definition.md`**.

Related: `analyzeWorkflowDynamicParams(workflowId)`, `workflowDashboardStats(workflowId)`, `exportWorkflow(where:{id})` (returns an artifact you can re-import), `lastRetrospectiveRun(workflowId)`.

---

## Runs (execution history + debugging)

`WorkflowRunWhereInput` fields are plain scalars (not filters): `projectId`, `workflowId`, `status` (enum), `eventType`, `triggeredAt`, `startedAt`, `endedAt`, `runId`, `triggerObjectName/Number/Url`.

Status enum: `Running`, `Completed`, `Failed`, `OnHold`, `Skipped`, `Terminating`, `Timeout`.

```graphql
# Recent runs for a project (or filter by workflowId / status)
query ($pid: String!) {
  workflowRuns(
    where: { projectId: $pid, status: Failed }
    orderBy: { startedAt: Desc }
    take: 25
  ) {
    id runId workflowId status statusMessage
    eventType triggerObjectName triggerObjectUrl
    startedAt endedAt duration
    # token totals are NESTED under `tokenUsage`, not fields of `consumption` directly
    consumption {
      tokenUsage { totalTokens inputTokens outputTokens cachedInputTokens cacheCreationTokens callCount }
      stepCount totalExecutionTimeMs totalProcessingTimeMs status
    }
  }
}
```

```graphql
# One run, drill into its steps
query ($id: String!) {
  workflowRun(where: { id: $id }) {
    id runId status statusMessage statusReason
    version startedAt endedAt duration
    steps { id status }
  }
}
```

```graphql
# Debug a failing step: its logs and agent sub-threads.
# Read `workflowRun.statusMessage` FIRST - it usually already names the cause.
# Do NOT pre-filter by `level: Error` here: a fatal error is sometimes logged at
# `Info` (e.g. "[Error: ...]"), so an Error-only filter can come back empty. Pull
# all levels and scan, or add `level: Error` only as a first pass you widen from.
query ($stepId: String!) {
  runStepLogs(where: { runStepId: $stepId }, take: 50) {
    level message agentName threadId contents { content }
  }
  runStepThreads(runStepId: $stepId) { threadId agentName isComplete logCount }
}
```

For the full run -> step -> log -> thread debugging funnel, the step status / log-level enums, and a root-cause classification table, see **`debugging-runs.md`**.

Also: `workflowRunsConsumption(...)` (token/credit usage per run), `runSteps(where:{runId,status})`, `runStep(where:{id})`, `runStepLog(where:{id})`, `consumptionSummary(projectId, startDate, endDate, groupBy)`, `dashboardStats(projectId, startDate, endDate)`.

---

## Agents

```graphql
# List agents in a project (AgentWhereInput: active is a plain Boolean; name/modelKey are StringFilters)
query ($pid: String!) {
  agents(
    where: { projectId: { equals: $pid }, active: true }
    orderBy: { name: Asc }
    take: 50
  ) {
    id name active baseAgentType modelKey description
    availableTools color
  }
}
```

```graphql
# Single agent with its skills, MCP servers, and secret references
query ($id: String!) {
  agent(where: { id: $id }) {
    id name baseAgentType modelKey
    additionalInstructions availableTools
    skills { id name slug }
    mcpServers { id name allowedTools }
    secrets { id name }
  }
}
```

---

## Skills

```graphql
# Skills registered in a project
query ($pid: String!) {
  skills(projectId: $pid, activeOnly: false) {
    id name slug description active
    path ref repositoryId lastSyncedAt
    repository { id name provider }
  }
}

# One skill + its live SKILL.md content
query ($id: String!) {
  skill(id: $id) { id name slug description path ref }
  skillContent(skillId: $id)        # returns the raw SKILL.md markdown
}
```

```graphql
# Discover skills available in a connected repo before registering them
query {
  browseSkillsInRepo(input: { repositoryId: "<repo-id>", projectId: "<pid>" }) {
    name slug description path
  }
}
# preview a SKILL.md from a repo path without registering:
# previewSkillContent(repositoryId, path, ref)
```

---

## MCP servers

```graphql
# MCP servers configured in a project
query ($pid: String!) {
  mcpServers(projectId: $pid, activeOnly: false) {
    id name active allowedTools config
    secrets { id }
  }
}

# Single MCP server
query ($id: String!) {
  mcpServer(id: $id) { id name active allowedTools config }
}
```

```graphql
# Browse the install-from-catalog options
query {
  mcpCatalogEntries { key name description category tags websiteUrl }
}
# mcpCatalogEntry(key) returns the full detail incl. required secrets + default config
```

---

## Project secrets (metadata only - values are never returned)

```graphql
query ($pid: String!) {
  projectSecrets(projectId: $pid) {
    id name hasValue availableForAllExecutions
    agentCount workflowCount
  }
}
# projectSecret(id) for a single one
```

---

## Context parameters (`{{params.<key>}}` values)

```graphql
# Definitions visible to a project: workspace-level ones plus the project's own.
# Omit `where` to list every definition in the workspace.
query ($pid: String!) {
  contextParameters(where: { projectId: $pid }) {
    id key description
    defaultValue          # null = no default: a run referencing the key with no override fails at preparation
    projectId projectName # null projectId = workspace-level
    overrideCount
  }
}
# contextParameter(id) adds `values { id scope scopeId scopeName value updatedAt updatedBy }` - every override of one key
```

```graphql
# What one entity resolves to, key by key, and who overrides it.
# scope: PROJECT | REPOSITORY | WORKFLOW | ORCHESTRATION | AGENT; scopeId = that entity's id
query ($scope: EnumContextParameterScope!, $id: String!) {
  contextParameterEffectiveValues(scope: $scope, scopeId: $id) {
    parameter { id key defaultValue }
    localValue                                   # this entity's own override, null = inherits
    inheritedValue                               # what it gets if it sets nothing
    inheritedFrom { label scope scopeId name }   # null when it is the definition default
    overriddenBy { label scope scopeId name }    # more specific scopes that already win for runs including this entity
  }
}
# contextParameterValues(scope, scopeId) returns only the overrides the entity itself holds
```

```graphql
# Will this workflow's runs resolve every key it references? Same check the Playground shows.
# Manual-run path only (project, repository, workflow) - orchestration and agent overrides do not appear.
query ($wid: String!, $rid: String) {
  contextParameterResolutionPreview(workflowId: $wid, repositoryId: $rid, useWorkingDraft: true) {
    key
    status          # Resolved | Unresolved (no value on the path, no default) | Unknown (key not defined)
    value
    source { label scope scopeId name }
  }
}
```

Run this before `commitWorkflow` on any draft that references `{{params.*}}`: commit rejects `Unknown` keys, and `Unresolved` keys fail every run at preparation (`statusReason: ContextParameterUnresolved`). A run's resolved map is on the run itself: `workflowRun { resolvedContextParameters }` gives `{ run: { key: value }, agents: { agentId: { key: value } } }`.

---

## Workspace library (shared items and templates)

```graphql
# The one library project of the workspace (created on first access). Its id is the
# `projectId` you pass to every project-scoped list query to see shared items.
query { libraryProject { id name kind } }     # kind: Library; standard projects are kind: Standard
```

```graphql
# Then reuse the normal project-scoped queries with the library id:
query ($lib: String!) {
  workflows(where: { projectId: { equals: $lib } }) { id name currentVersionId }   # templates
  agents(where: { projectId: { equals: $lib } }) { id name }                       # shared by reference
  mcpServers(projectId: $lib, activeOnly: false) { id name }
  skills(projectId: $lib, activeOnly: false) { id name }
  projectSecrets(projectId: $lib) { id name hasValue availableForAllExecutions }
}
```

```graphql
# What a template references, before installing it. `committed: true` shows exactly what
# installLibraryWorkflow will copy (it always copies the last committed version) and
# fails when the template was never committed.
query ($id: String!) {
  exportWorkflow(where: { id: $id }, committed: true) { fileName json }
}
# json = { _formatVersion, workflow: { name, definition }, refs: { agents: [{ id, name }] } }
# exportOrchestration(where, committed: true) -> refs.workflows lists every workflow the template routes to
```

Reading rules: a template is never active and never runs; `installLibraryWorkflow` / `installLibraryOrchestration` (see `mutations.md`) copy it into a *standard* project. A library agent referenced by a template needs no mapping on install; a project-owned agent does. See `concepts.md` for the by-reference vs by-copy split.

---

## Playbooks (importable workflow templates)

```graphql
query {
  playbooks { key title description trigger priority lastUpdatedAt }
}
# playbook(key) returns the full template artifact
```

---

## Git organizations & repositories

```graphql
# Repos available to a project
query ($pid: String!) {
  repositories(projectId: $pid, orderBy: { name: Asc }) {
    id name fullName provider organizationName
    useForCode useForTickets repoUrl active
  }
}
# remoteGitRepositories(where: { ... }) lists repos in a connected org not yet added
```
