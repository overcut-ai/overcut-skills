# Orchestrations

An **Orchestration** is a long-running, goal-driven supervisor that runs *workflows* on a tracked item (a GitHub/GitLab issue or PR, or a manual seed) until a goal is met. Where a Workflow is a fixed sequence of steps, an Orchestration decides - step by step - which allowed workflow to run next, and pauses for a human when it is unsure or hits a gate. (Historically called "missions" / "dynamic process".)

Two things to hold separate:

- **Orchestration** (the definition) - authored like a workflow, with the same **draft vs. committed** model: `hasUnpublishedChanges`, `currentVersion`, versions, `commit`/`discard`/`restore`. All the workflow safety rules in `mutations.md` apply here too.
- **OrchestrationInstance** (a run) - one per tracked item (`itemKey`, e.g. `Github:issue:overcut-ai/overcut-fork#1009`). It advances through **steps** (each step is a `WorkflowRun`) and produces **decisions**; it can sit in `WaitingForDecision` / `WaitingForHuman`, where a person resolves a decision or chats with a discussion agent.

---

## Read: authoring surface (mirrors Workflows)

```graphql
# List orchestrations in a project (OrchestrationWhereInput: id/name/projectId are StringFilters,
# createdAt/updatedAt/deletedAt are DateTimeFilters)
query ($pid: String!) {
  orchestrations(where: { projectId: { equals: $pid } }, orderBy: [{ name: Asc }], take: 50) {
    id name active hasUnpublishedChanges
    currentVersionId
    currentVersion { versionNumber committedAt commitMessage }
    updatedAt
  }
}

# Which have uncommitted draft edits
query ($pid: String!) { orchestrationsWithUnpublishedChanges(projectId: $pid) { id name } }

# Version history (definition on each version is a JSONObject snapshot)
query ($id: String!) {
  orchestrationVersions(orchestrationId: $id) {
    id versionNumber commitMessage committedAt committedById
  }
}
```

```graphql
# Single orchestration with its typed draft definition
query ($id: String!) {
  orchestration(where: { id: $id }) {
    id name active hasUnpublishedChanges currentVersionId
    definition {
      name goal instructions defaultModelKey
      allowedWorkflows { id name }                       # the workflows this orchestration may run
      entryTriggers {                                    # how a new instance starts
        event                                            # OrchestrationEntryEventType (issue_opened, pull_request_merged, manual, ...)
        firstWorkflowId                                  # workflow run first on entry
        conditions { __typename }                        # TriggerRule (same shape as workflow trigger rules)
        slashCommand { command requireMention }
      }
      gates {                                            # human-in-the-loop gates
        name description gateCompletion workflowIds
        chatAgent { workflowId maxDurationMinutes allowPreviousSessionAccess }
      }
      autoApprove { minConfidence }                      # proposals at/above this confidence auto-resolve
      limits { maxSteps maxActiveInstances maxRepeatsPerWorkflow idleTimeoutHours }
    }
  }
}
```

**`OrchestrationDefinition` fields:** `name`, `goal` (required - the objective), `instructions`, `defaultModelKey`, `allowedWorkflows: [{ id, name }]`, `entryTriggers: [...]`, `gates: [...]`, `autoApprove: { minConfidence }`, `limits: { maxSteps, maxActiveInstances, maxRepeatsPerWorkflow, idleTimeoutHours }`.

`OrchestrationEntryEventType` values: `manual`, `issue_opened|closed|edited|labeled|unlabeled|assigned|unassigned|commented`, `pull_request_opened|closed|merged|edited|labeled|unlabeled|assigned|unassigned|commented|reviewed|review_commented`.

---

## Read: runtime (Instances, Steps, Decisions)

`OrchestrationInstanceWhereInput` fields are plain scalars: `projectId`, `orchestrationId`, `orchestrationIdIn: [String!]`, `id`, `itemKey`, `status` (enum), `statusIn: [enum]`, `queuedAtGte`, `queuedAtLte`.

Status enum `EnumOrchestrationInstanceStatus`: `Queued`, `Active`, `WaitingForDecision`, `WaitingForHuman`, `Completed`, `Failed`, `Cancelled`.

```graphql
# Instances for a project (or filter by orchestrationId / status)
query ($pid: String!) {
  orchestrationInstances(
    where: { projectId: $pid, statusIn: [WaitingForHuman, WaitingForDecision] }
    orderBy: { lastActivityAt: Desc }
    take: 25
  ) {
    id orchestrationName itemKey status statusReason
    stepCount triggerObjectName triggerObjectNumber triggerObjectUrl
    queuedAt startedAt endedAt lastActivityAt
  }
}

# Counts by status for a project (or one orchestration)
query ($pid: String!) { orchestrationInstanceCounts(projectId: $pid) { __typename } }
```

```graphql
# One instance: context, steps (each is a WorkflowRun), decisions, links
query ($id: String!) {
  orchestrationInstance(where: { id: $id }) {
    id orchestrationName orchestrationVersionNumber itemKey
    status statusReason context contextUpdatedAt
    startedAt endedAt lastActivityAt
    latestStep { id sequence workflowName runStatus }
    steps {                              # OrchestrationStep
      id sequence workflowId workflowName
      runId runStatus decidedBy decisionId
      result startedAt endedAt
      run { id status statusMessage }    # drill into the underlying run (see debugging-runs.md)
    }
    decisions {                          # OrchestrationDecision (see below)
      id sequence status pendingReason proposedAction
    }
    links { id url title relation addedBy linkedInstanceId createdAt }   # related issues/PRs/instances
  }
}
```

`OrchestrationStep.decidedBy` (`EnumOrchestrationDecidedBy`): `EntryTrigger`, `Rule`, `Supervisor`, `Human`.

### Decisions (the human-in-the-loop gate)

Each time the supervisor wants to act (run a workflow, complete, park, cancel) it records an `OrchestrationDecision`. If it can't auto-approve, the decision is `Pending` with a `pendingReason` and waits for a human.

```graphql
# Pending decisions across a project (OrchestrationDecisionWhereInput: projectId, instanceId, status, pendingReason, id)
query ($pid: String!) {
  orchestrationDecisions(where: { projectId: $pid, status: Pending }, orderBy: { createdAt: Desc }, take: 25) {
    id instanceId sequence status
    pendingReason pendingReasonDetail
    proposedAction proposedBy proposedByStepId
    proposedWorkflowId proposedWorkflowName
    confidence rationale
    onBehalfOf
    resolvedBy resolvedByUserId resolvedAt resolutionNote
    proposals                          # JSON: the full set of candidate actions the supervisor weighed
    createdAt updatedAt
  }
}
```

Decision enums:
- `status` (`EnumOrchestrationDecisionStatus`): `Pending`, `Resolved`.
- `proposedAction` / `outcome` (`EnumOrchestrationDecisionOutcome`): `Route` (run a workflow), `Complete`, `Park`, `Cancelled`.
- `pendingReason` (`EnumOrchestrationPendingReason`): `HumanGate`, `LowConfidence`, `NoProposal`, `CapReached`, `RunFailed`, `Stalled`.
- `proposedBy` (`EnumOrchestrationProposedBy`): `WorkflowAgent`, `Supervisor`, `System`, `EntryTrigger`, `Human`.
- `resolvedBy` (`EnumOrchestrationResolvedBy`): `Human`, `Rule`, `Supervisor`.

### Discussion (HITL chat about a pending decision)

When a human opens a chat on a gated instance, a discussion agent runs. The discussion is keyed by **instanceId** (not decisionId).

```graphql
query ($iid: String!) {
  orchestrationDiscussion(instanceId: $iid) {
    instanceId instanceStatus isOpen
    pendingDecisionId openChatDecisionId openChatRunId openChatExpiresAt
    agentState
    transcript { author kind title text timestamp }   # OrchestrationDiscussionEntry
  }
}
```

`transcript` entries have a `kind` of `event` (system-recorded step outcome), `human` (a user comment), `agent` (the discussion agent's reply), or `system` (session open/close + supervisor questions). `author` is null for `event`/`system` entries.

### Dashboard / graph

```graphql
# Aggregate stats over a window (dates required)
query ($id: String!, $pid: String!, $from: DateTime!, $to: DateTime!) {
  orchestrationDashboardStats(orchestrationId: $id, projectId: $pid, startDate: $from, endDate: $to) { __typename }
}
# Visual graph of an orchestration (nodes/edges of workflows + gates)
query ($id: String!) { orchestrationGraph(where: { id: $id }) { __typename } }
```

---

## Write

Same safety rules as workflows (`mutations.md`): create/update touch the **draft**; production instances keep running the last **committed** version until `commitOrchestration`. Confirm with the user before any create / update / commit / discard / restore / delete, and before resolving a decision on their behalf.

| Mutation | Args | Notes |
|---|---|---|
| `createOrchestration` | `data: OrchestrationCreateInput!` | new draft in a project |
| `updateOrchestration` | `data: OrchestrationUpdateInput!, where: { id }` | edits the **draft** |
| `commitOrchestration` | `data: CommitOrchestrationInput!` | snapshot draft -> live version. **Confirm first.** |
| `discardOrchestrationChanges` | `data: DiscardOrchestrationChangesInput!` | reset draft to committed. **Destructive - confirm.** |
| `restoreOrchestrationVersion` | `data: RestoreOrchestrationVersionInput!` | load an old version into the draft |
| `activateOrchestration` / `deactivateOrchestration` | `where: { id }` | on/off, independent of versioning |
| `deleteOrchestration` | `where: { id }` | |
| `openOrchestrationDiscussion` / `closeOrchestrationDiscussion` | `instanceId: String!` | start / end a HITL chat on an instance |
| `sendOrchestrationDiscussionMessage` | `instanceId: String!, message: String!` | post a human message into the discussion |

**Verified input shapes:**
- `OrchestrationCreateInput`: `name: String!`, `project: WhereParentIdInput!` (the `{ connect: { id } }` wrapper - see `mutations.md`), `definition: OrchestrationDefinitionInput!`, `color: String`.
- `OrchestrationUpdateInput`: `name`, `definition`, `color` (all optional; sends a partial draft update).
- `CommitOrchestrationInput`: `orchestrationId: String!`, `message: String!`.
- `DiscardOrchestrationChangesInput`: `orchestrationId: String!`.
- `RestoreOrchestrationVersionInput`: `orchestrationId: String!`, `versionId: String!`.
- `OrchestrationDefinitionInput` mirrors the read shape: `name`, `goal`, `instructions`, `defaultModelKey`, `allowedWorkflows: [...]`, `entryTriggers: [...]`, `gates: [...]`, `autoApprove: { minConfidence }`, `limits: { maxSteps, maxActiveInstances, maxRepeatsPerWorkflow, idleTimeoutHours }`.

As with workflows, the definition input's *shape* is known but the valid entry `event` values, gate wiring, and `allowedWorkflows` ids are best copied from an **existing orchestration** in the same account - read one's `definition` and mirror it.

```graphql
# Open a discussion, then post a message (both keyed by instanceId)
mutation ($iid: String!, $msg: String!) {
  openOrchestrationDiscussion(instanceId: $iid) { instanceId isOpen openChatRunId }
}
mutation ($iid: String!, $msg: String!) {
  sendOrchestrationDiscussionMessage(instanceId: $iid, message: $msg) {
    instanceId transcript { author kind text }
  }
}
```

> There is **no** "resolve this decision" mutation exposed directly here - a human resolves a pending decision through the discussion (chat -> the agent records the resolution) or in the UI. Do not fabricate a decision-resolution call; drive it via the discussion, or point the user to the web app.

---

## Debugging a stuck instance

1. `orchestrationInstance` -> read `status` + `statusReason`. `WaitingForHuman` / `WaitingForDecision` means it's parked on a decision, not broken.
2. Look at `decisions` for the `Pending` one; its `pendingReason` tells you why (`HumanGate`, `LowConfidence`, `NoProposal`, `CapReached`, `RunFailed`, `Stalled`).
3. If a `step` failed, follow `step.run` into the normal run -> step -> log funnel in `debugging-runs.md`.
4. `Stalled` / `CapReached` usually points at `limits` (e.g. `maxSteps`, `idleTimeoutHours`) in the definition.
