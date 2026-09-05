# Debugging a failed run

Procedure for diagnosing why a workflow run failed, entirely through the GraphQL API. Logs are voluminous, so funnel from run -> step -> logs -> threads, narrowing at each level.

> All status and log-level enums are **PascalCase** (`Failed`, `Completed`, `Error`...). The API rejects ALL-CAPS.

## The funnel

**1. Find the run.** If the user gave a `runId` (correlation id seen in chat/Slack) rather than the internal id, resolve it first:

```graphql
query ($pid: String!) {
  workflowRuns(where: { projectId: $pid, status: Failed }, orderBy: { startedAt: Desc }, take: 10) {
    id runId workflowId status statusReason statusMessage
    triggerObjectName triggerObjectNumber triggerObjectUrl startedAt
  }
}
# filter by runId or workflowId in `where` to pin a specific one
```

**2. Read the run** - the headline cause is often right here:

```graphql
query ($id: String!) {
  workflowRun(where: { id: $id }) {
    id runId status statusMessage statusReason
    version                       # which committed version ran (see versioning)
    triggerObjectName triggerObjectUrl
    steps { id stepId action status duration }
  }
}
```

- `statusMessage` is the single highest-signal field - it usually already names the failing step and the error (e.g. `"Step discuss failed: [Error: CoordinatorNode requires agentConfig in state]"`). Read it before you touch any logs; you often don't need to go deeper.
- `statusReason` (`EnumWorkflowRunStatusReason`: `ContextParameterUnresolved`, `Infrastructure`, `InsufficientCredits`, `MaxConcurrency`) explains run-level aborts before you even read logs. A run aborted at *preparation* (before any pod) has `status: Failed` with **no failed step** - the funnel stops here.
- `resolvedContextParameters` (select it when the workflow uses `{{params.*}}`) is the map the run actually used: `{ run: { key: value }, agents: { agentId: { key: value } } }`. Compare it with what the user expected before blaming an instruction.
- `version` tells you which committed version was running - a fix only takes effect on runs that start *after* a new commit.
- In `steps`, find the one with `status: Failed`.

**3. Read the failing step:**

```graphql
query ($stepId: String!) {
  runSteps(where: { runId: "<runId>", status: Failed }) {
    id stepId action status output     # `output` holds structured failure info when present
  }
}
# or runStep(where: { id }) for a known step id
```

`EnumRunStepStatus`: `Pending`, `Ready`, `Running`, `InSession`, `WaitingForExternal`, `WaitingForReply`, `Completed`, `Failed`, `Canceled`, `Terminating`.

**4. Read the logs.** Prefer pulling all levels and scanning the tail - severity is unreliable:

```graphql
query ($stepId: String!) {
  runStepLogs(where: { runStepId: $stepId }, take: 50) {
    level message agentName threadId messageType createdAt
    contents { content }
  }
}
```

`EnumLogLevel`: `Debug`, `Info`, `Warning`, `Error`. **Do not trust `level: Error` as a filter to find the cause** - fatal errors are sometimes emitted at `Info` (the message text starts with `[Error: ...]` even though `level` is `Info`), so an Error-only query can return an empty set on a run that clearly failed. Pull all levels; if the volume is too high, use `level: Error` only as a first pass and always widen when it comes back empty.

**5. For `agent.session` steps, split by sub-agent thread.** These steps fan out into threads; `agent.run` steps have a single implicit thread.

```graphql
query ($stepId: String!) {
  runStepThreads(runStepId: $stepId) { threadId agentName isComplete logCount }
}
# then re-query runStepLogs with where: { runStepId, threadId } for the failing thread
```

## Classify the root cause

| Symptom in logs / output | Likely cause | Where to look / fix (via API) |
|---|---|---|
| `git.clone` failed: auth / not found | repo not connected, wrong purpose, or missing secret | `repositories` query; `projectSecrets` |
| Agent step: "missing secret" / 401 / 403 | secret unassigned or empty | `projectSecrets` (`hasValue`), `setAgentSecrets` / `setWorkflowSecrets` |
| Agent step: "tool not available" / "MCP server X not found" | MCP server not assigned to the agent, or inactive, or tool not in `allowedTools` | `agent.mcpServers`, `mcpServer.allowedTools`, `assignMcpServersToAgent` |
| Agent step: wrong output / wrong procedure | weak `instruction` or a missing Skill | `workflow.definition.steps[].instruction`; `agent.skills` |
| Agent step: timed out | step/workflow timeout too low, or model too slow | `definition.timeoutMs`, `step.stepMaxDurationMinutes`, `agent.modelKey` |
| `repo.identify` returned nothing | trigger context lacked repo info, or logic is wrong | `triggerObject*` on the run; the step `instruction` |
| `statusReason: InsufficientCredits` | workspace out of credits | billing / `currentWorkspace.subscription` |
| `statusReason: ContextParameterUnresolved`, no failed step, `statusMessage` names a key | a referenced `{{params.<key>}}` has no override on the run's path and no default | `contextParameterResolutionPreview(workflowId, repositoryId)` shows the key and status; fix with `updateContextParameter` (add a default) or `setContextParameterValue` at a scope on the path |
| Agent used the wrong branch / convention / reviewer list | a more specific scope (often an `ORCHESTRATION` override) won the resolution | `workflowRun.resolvedContextParameters`; `contextParameterEffectiveValues(scope: WORKFLOW, scopeId)` -> `overriddenBy` |
| `commitWorkflow` / `createAgent` / `updateAgent` error "Unknown context parameter: params.x" | key never defined, or defined project-level in a different project | `contextParameters(where: { projectId })`; `createContextParameter` (workspace-level if shared) |
| Step succeeded but next step broke | output-contract drift between steps | compare producing step `output` vs consuming step `instruction` |

## Stats

```graphql
query ($wid: String!) { workflowDashboardStats(workflowId: $wid) { __typename } }
```

`workflowRunsConsumption(where: {...})` gives per-run token/credit/runtime breakdowns, and `consumptionSummary(projectId, startDate, endDate, groupBy)` aggregates usage over a window.

## Propose a fix safely

When the fix is a workflow change, remember it edits the **draft** - it won't affect new runs until `commitWorkflow` (see `mutations.md` safety rules). Always confirm the diagnosis and the fix with the user before mutating.
