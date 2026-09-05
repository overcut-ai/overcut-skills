---
name: convert-to-overcut
description: Convert an existing agent/automation framework - Argo Workflows, kagents, LangGraph, CrewAI, AutoGen, n8n, GitHub Actions, or an arbitrary skills/prompts folder - into Overcut-ready Skills, Agents, and Workflow definitions that import cleanly into an Overcut project. Use when a user has their own skill/agent/workflow files (YAML, JSON, prompt/markdown, code) and wants to migrate the SDLC business logic into Overcut without carrying the original orchestration framework. Triggers on "convert my skills/agents/workflows to Overcut", "migrate from Argo/kagents/LangGraph/CrewAI to Overcut", "import my framework into Overcut".
license: Apache-2.0
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Convert to Overcut

Take a customer's own agent/automation framework files and produce **Overcut-native artifacts** - Skills (`SKILL.md` bundles), Agent specs, and Workflow definitions - that carry only the organization's SDLC business logic, with the source framework's orchestration plumbing stripped away.

This is a **one-shot batch conversion**: you inventory the inputs, convert everything, write an output folder, and produce a `MANIFEST.md` that explains every decision for the user to review. Live import into an Overcut project is an **optional** last step.

## The core principle: distill, don't transliterate

The goal is **not** a 1:1 port of the source graph. It is to extract the *business logic* - what the organization actually wants an agent to do in its SDLC - and re-express it idiomatically for Overcut. Aggressively drop framework plumbing that Overcut handles for you or that has no Overcut equivalent:

- Kubernetes/pod/container/resource specs, retries, backoff, timeouts-as-infra, parallelism knobs, volume mounts, image refs, `serviceAccountName`, sidecars.
- Framework state machines, message-passing glue, checkpointer/memory backends, callback wiring, graph-compilation boilerplate.
- Anything whose only purpose is to make the *old* framework run.

Keep the durable knowledge: *when* something should happen (triggers), *what* an agent should do and how it should judge quality (instructions), *what order* work happens in (flow), and *which capabilities* it needs (tools/skills). If a step is 90% plumbing wrapping one sentence of real intent, keep the sentence.

## Read these references before converting

Load them as you need them - do not guess formats.

- `references/target-formats.md` - the **exact output shapes** for an Overcut Skill, Agent, and Workflow definition, derived from the Overcut data model. This is your compile target.
- `references/source-frameworks.md` - how to **recognize** each source framework and **map** its constructs to Overcut. Covers Argo/CronWorkflow, kagents, LangGraph, CrewAI, AutoGen, n8n, GitHub Actions, and a generic fallback for anything else.
- `references/integration-mapping.md` - map external tool/integration calls (Slack, GitHub, Jira, HTTP, databases, filesystem, git) to Overcut **built-in tools, MCP servers, and secrets**.
- `references/output-layout.md` - the `out/` directory layout and the `MANIFEST.md` spec.

## Procedure

### 1. Locate and inventory the inputs

Ask the user for the source directory if they did not give one. Then map the terrain:

```bash
# what am I looking at?
ls -R <source-dir> | head -200
```

Detect the framework(s) present using the recognizers in `references/source-frameworks.md` (e.g. `apiVersion: argoproj.io/*` + `kind: Workflow|CronWorkflow` = Argo; a `StateGraph(...)` in Python = LangGraph; `Crew(agents=..., tasks=...)` = CrewAI; a `SKILL.md` = an existing skill bundle). A repo may mix several - handle each with its own mapping. When nothing matches a known recognizer, use the **generic fallback**: read the file and extract intent directly.

Build an internal inventory: every source construct and what Overcut artifact it will become (a Skill, an Agent, a Workflow step, a trigger, or "dropped as plumbing").

### 2. Distill the business logic

For each source construct, write down the *intent* in plain language, framework-free. This is the hardest and most valuable step - spend real effort here. Pull instructions/prompts, role/goal/backstory text, comments, and step names into distilled statements of "what the org wants done and how it judges done-ness."

### 3. Map to Overcut artifacts

Using `references/target-formats.md` and `references/source-frameworks.md`:

- **Skills** - reusable, framework-free instruction bundles (review checklists, coding standards, domain playbooks) become `SKILL.md` folders.
- **Agents** - each distinct persona/role becomes an Agent spec: `name`, `description`, `baseAgentType`, `modelKey`, `additionalInstructions` (the distilled system prompt), `color`, `availableTools`, and links to Skills/MCP/secrets.
- **Workflows** - each pipeline becomes a Workflow `definition`: `steps` (with `action` = `git.clone` / `repo.identify` / `agent.run` / `agent.session`), `flow` (edges from the source dependencies), and `triggers`.

**Integrations** (external tool calls): best-effort auto-map to Overcut built-in tools or a known MCP catalog entry per `references/integration-mapping.md`. When you can map with confidence, wire it in. When you cannot, do **not** fabricate config - record it as a TODO in the `MANIFEST.md`.

**Configuration that varies** (a target branch, reviewer list, ticket project key, channel, threshold - anything a second team, repo, or environment would set differently): do not hardcode it into an instruction and do not emit one workflow per variant. Reference it as `{{params.<key>}}` and declare the key in the artifact's `contextParameters` (with the source's value as `default` when there was one). Overcut resolves it per run by scope. Credentials are never parameters - they stay `secrets[]`. See `references/target-formats.md` "Context parameters" and the sorting table in `references/integration-mapping.md`.

**Required-but-missing fields**: emit valid **placeholders** and flag each one as a TODO. Never silently guess. Standard placeholders:
- `baseAgentType`: `Custom` unless the role name clearly implies another enum value.
- `modelKey` / `defaultModelKey`: `"<workspace-default>"`.
- `triggers`: a single manual trigger `[{ "event": "manual" }]` when the source has no clear event.

The output must stay **importable** even with placeholders in it.

### 4. Emit the output folder

Scaffold and write the output tree with `scripts/scaffold-output.sh` and the templates in `assets/templates/`. Follow `references/output-layout.md` exactly. Write one `SKILL.md` per skill, one `*.agent.json` per agent, one `*.workflow.json` per workflow, and a top-level `MANIFEST.md`.

The `MANIFEST.md` is the deliverable the user reviews. It must contain: the source→target mapping table, everything dropped as plumbing (and why), every TODO (placeholders, unmapped integrations, secrets to create), and the exact next steps to import.

### 5. Validate

Run the checker before declaring done:

```bash
scripts/validate-output.sh <out-dir>
```

It verifies JSON parses, every `SKILL.md` has valid frontmatter (`name`, `description`), agents carry the required fields with a legal `baseAgentType`, workflow steps use only the four legal `action` values with a `flow` that references real step ids, and every `{{params.<key>}}` an artifact references is declared in its `contextParameters` with a well-formed, non-credential key. Fix anything it flags.

### 6. Review, then optionally import

Summarize for the user: what was produced, the mapping at a glance, and the open TODOs. Do **not** import automatically.

If the user then wants to push it into a live Overcut project, hand off to the **`overcut-api` skill** (in the sibling `overcut` plugin - it must be installed). Because Overcut Skills load from a **git repo** (`createSkill` points at a `path` + `ref`) and because agents and commits validate `{{params.*}}` keys, the import order is:

1. `createContextParameter` for every key in the manifest's "Context parameters to define" (dedupe across artifacts; keys are workspace-unique, so reuse an existing key with the same meaning instead of creating a near-duplicate). Where the source had different values per team/repo, `setContextParameterValue` at that scope.
2. Commit the `out/skills/` folders into a repo connected to the project; `createSkill` (or `createSkills`) pointing at each `path`.
3. `createAgent` per `*.agent.json`; then `assignSkillsToAgent`, `assignMcpServersToAgent`, `setAgentSecrets` for its links.
4. `createWorkflow` (or `importWorkflow` with `agentMapping`) per `*.workflow.json`. This edits the **draft** - run `contextParameterResolutionPreview(workflowId, useWorkingDraft: true)` to confirm every key resolves, then the user commits it live via `commitWorkflow` after reviewing in the UI.

Never create secret values, `commitWorkflow`, or trigger runs without explicit user confirmation - the safety rules in the `overcut-api` skill's `references/mutations.md` apply.

## Boundaries

- This skill produces **artifacts and a plan**; it does not design SDLC strategy. Deep product-design questions (what makes a good trigger, when to split agents, workflow memory) belong to the built-in Overcut assistant in the web app - point the user there.
- It does not invent integration credentials or MCP configuration it cannot verify - those become explicit TODOs.
- It converts business logic, not infrastructure. If asked to "keep the Argo retry/parallelism behavior," explain that Overcut owns execution semantics and only the intent transfers.
