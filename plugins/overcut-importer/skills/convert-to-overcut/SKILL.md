---
name: convert-to-overcut
description: Convert an existing agent/automation framework - Argo Workflows, kagents, LangGraph, CrewAI, AutoGen, n8n, GitHub Actions, or an arbitrary skills/prompts folder - into Overcut-ready Skills, Agents, and Workflow definitions that import cleanly into an Overcut project. Use when a user has their own skill/agent/workflow files (YAML, JSON, prompt/markdown, code) and wants to migrate the SDLC business logic into Overcut without carrying the original orchestration framework. Triggers on "convert my skills/agents/workflows to Overcut", "migrate from Argo/kagents/LangGraph/CrewAI to Overcut", "import my framework into Overcut".
license: Apache-2.0
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Convert to Overcut

Take a customer's own agent/automation framework files and produce **Overcut-native artifacts** - Skills (`SKILL.md` bundles), Agent specs, and Workflow definitions - that carry only the organization's SDLC business logic, with the source framework's orchestration plumbing stripped away.

This is a **one-shot batch conversion**: you inventory the inputs, convert everything, write an output folder, and produce a `MANIFEST.md` that explains every decision for the user to review. Live import into an Overcut project is an **optional** last step.

## The core principle: preserve the skills, redesign the orchestration

Conversion pulls two levers that point in opposite directions. Apply the right one to each layer.

### Skills - preserve, don't rewrite

A source skill / prompt / checklist / playbook is durable business knowledge the organization has already invested in. **Keep it as close to verbatim as possible.** Do not summarize it, "improve" its wording, re-order its steps, or trim instructions you personally think are redundant. Losing business logic is the single worst outcome of a conversion - when in doubt, keep the text and flag it in the manifest.

The only edits allowed on skill content are the minimum needed for it to load and run cleanly in Overcut:

- Rewrite references to the *old runtime* ("call the next node", "return to the supervisor", "emit to the queue") - Overcut owns orchestration, so those sentences would mislead the agent.
- Strip framework-specific wiring that has no meaning in Overcut (a LangChain tool-binding preamble, an Argo templating variable) **only** when leaving it in would confuse the agent. If it's harmless, keep it.
- Normalize the frontmatter to the Overcut `SKILL.md` shape (`name`, `description`).

**Splitting is encouraged; dropping is not.** It is often *better* to break one oversized or multi-topic skill into several focused skills - a 2,000-line "engineering handbook" becomes `pr-review-checklist`, `coding-standards`, and `release-playbook`. Splitting reorganizes content across files; every original instruction must survive somewhere. A skill split shows up in the manifest as one source → multiple skills.

### Agents & workflows - redesign toward Overcut best practice

The orchestration layer is where you *should* reshape. Do **not** transliterate the source graph 1:1. Read the customer's actual intent - what are they trying to accomplish? - and re-express it the way a well-authored Overcut project would, using **playbooks** (Overcut's own reference workflow templates) as your model of "good" (see below):

- **Break the goal into dedicated workflows.** One workflow per outcome/trigger ("review incoming PRs", "triage new issues", "cut a release") - not one monster workflow that does everything. If the source is a single sprawling graph, decompose it into the distinct jobs it was really performing.
- **Specialize the agents.** One agent = one responsibility with one clear persona. Split a source "do-everything" agent into focused agents (a reviewer, an implementer, a doc writer). A narrow agent with a sharp system prompt beats a generalist.
- **Assign skills to the right agent** - attach each skill only to the agent whose job uses it, not every skill to every agent.
- **Account for each agent's tools & MCP** - give an agent only the built-in `availableTools` and MCP servers its job requires, scoped via `allowedTools`, with the secrets that implies. A reviewer that only comments needs different capabilities than an implementer that writes code.

Aggressively drop pure plumbing in this layer - Overcut handles it or it has no equivalent:

- Kubernetes/pod/container/resource specs, retries, backoff, timeouts-as-infra, parallelism knobs, volume mounts, image refs, `serviceAccountName`, sidecars.
- Framework state machines, message-passing glue, checkpointer/memory backends, callback wiring, graph-compilation boilerplate.
- Anything whose only purpose is to make the *old* framework run.

Keep the durable orchestration intent: *when* something should happen (triggers), *what order* work happens in (flow), and *which capabilities* each agent needs. If a step is 90% plumbing wrapping one sentence of real intent, keep the sentence.

### Use playbooks as the pattern library

Overcut ships **playbooks** - pre-built, best-practice workflow templates (PR review, issue triage, release, and more). They are the reference for how a good Overcut workflow and its agents are shaped: which trigger to choose, how granular the steps are, where `agent.run` vs `agent.session` fits, and how agents are specialized. When shaping agents and workflows, mirror the structure of the closest playbook rather than inventing a shape.

- If the sibling **`overcut-api`** skill is installed and the user is connected, list them live - `playbooks { key title description trigger priority }` - then fetch `playbook(<key>)` for the full template and model your output on the nearest match.
- Otherwise rely on the shapes in `references/target-formats.md`, which already encode the same patterns.

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

### 2. Separate business knowledge from orchestration

Classify every source construct into one of two buckets - they get opposite treatment:

- **Durable business knowledge** (a checklist, standard, prompt body, domain rule, playbook) → destined for a **Skill**. Plan to **preserve** it (see the core principle); note which oversized ones you'll split.
- **Orchestration** (who runs, in what order, on what trigger, with what tools) → destined for **Agents + Workflows**. Capture the *intent* framework-free and plan to **redesign** it around the customer's real goal and the closest playbook.

Understanding the customer's intent is the hardest and most valuable work here - spend real effort. Ask: what outcomes is this automation actually producing, and what distinct jobs hide inside the single graph they handed you?

### 3. Map to Overcut artifacts

Using `references/target-formats.md` and `references/source-frameworks.md`:

- **Skills** - preserve the source instruction bundles as `SKILL.md` folders. Split oversized or multi-topic ones into focused skills; strip only old-runtime references and framework wiring; **never drop business content**.
- **Agents** - one specialized persona per responsibility. Distill the role/goal/system-prompt into `additionalInstructions`, but split a multi-role source agent into several focused agents. Attach only the skills that agent uses, and only the `availableTools` / `mcpServers` / `secrets` its job requires. **Keep `availableTools` consistent with the instructions**: if the distilled prompt implies file/code/git work, populate `filesystem`/`git` (with a `git.clone` upstream) even when the source declared no tools - don't leave a `Custom` agent with `availableTools: []` whose instructions assume tools. See `references/integration-mapping.md` § "Implicit tool usage".
- **Workflows** - decompose the customer's goal into **dedicated workflows** (one outcome/trigger each), each modeled on the nearest playbook. Steps use `action` = `git.clone` / `repo.identify` / `agent.run` / `agent.session`; `flow` encodes order; `triggers` come from the source events.

**Integrations** (external tool calls): best-effort auto-map to Overcut built-in tools or a known MCP catalog entry per `references/integration-mapping.md`. When you can map with confidence, wire it in. When you cannot, do **not** fabricate config - record it as a TODO in the `MANIFEST.md`.

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

It verifies JSON parses, every `SKILL.md` has valid frontmatter (`name`, `description`), agents carry the required fields with a legal `baseAgentType`, and workflow steps use only the four legal `action` values with a `flow` that references real step ids. Fix anything it flags.

### 6. Review, then optionally import

Summarize for the user: what was produced, the mapping at a glance, and the open TODOs. Do **not** import automatically.

If the user then wants to push it into a live Overcut project, hand off to the **`overcut-api` skill** (in the sibling `overcut` plugin - it must be installed). Because Overcut Skills load from a **git repo** (`createSkill` points at a `path` + `ref`), the import order is:

1. Commit the `out/skills/` folders into a repo connected to the project; `createSkill` (or `createSkills`) pointing at each `path`.
2. `createAgent` per `*.agent.json`; then `assignSkillsToAgent`, `assignMcpServersToAgent`, `setAgentSecrets` for its links.
3. `createWorkflow` (or `importWorkflow` with `agentMapping`) per `*.workflow.json`. This edits the **draft** - the user commits it live via `commitWorkflow` after reviewing in the UI.

Never create secret values, `commitWorkflow`, or trigger runs without explicit user confirmation - the safety rules in the `overcut-api` skill's `references/mutations.md` apply.

## Boundaries

- This skill produces **artifacts and a plan**. It makes a best-effort first-pass decomposition - specialized agents and dedicated workflows modeled on playbooks - but it does not own SDLC strategy. Deep product-design questions (the ideal trigger, whether a further agent split pays off, workflow memory) belong to the built-in Overcut assistant in the web app - point the user there to refine.
- It **preserves skill business logic**; it does not rewrite, summarize, or trim it. If asked to "clean up" or condense the skill instructions themselves, decline - splitting into focused skills is the only restructuring it does, and no content is dropped.
- It does not invent integration credentials or MCP configuration it cannot verify - those become explicit TODOs.
- It converts business logic, not infrastructure. If asked to "keep the Argo retry/parallelism behavior," explain that Overcut owns execution semantics and only the intent transfers.
