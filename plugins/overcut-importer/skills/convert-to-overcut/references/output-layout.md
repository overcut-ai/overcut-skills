# Output layout and MANIFEST spec

The conversion writes one self-contained folder the user reviews, then optionally imports. Default location: `overcut-out/` in the current directory (override if the user names one). Scaffold it with `scripts/scaffold-output.sh <out-dir>`.

## Directory layout

```
<out-dir>/
├── MANIFEST.md                       # the review deliverable - read this first
├── skills/
│   └── <skill-name>/
│       ├── SKILL.md                  # one folder per Overcut Skill (folder name = slug)
│       └── references/               # optional, only if the skill body is long
├── agents/
│   └── <agent-name>.agent.json       # one file per Overcut Agent
└── workflows/
    └── <workflow-name>.workflow.json # one import artifact per Overcut Workflow
```

Naming: kebab-case throughout, matching the `name` inside each artifact. Cross-references use these names: an agent's `skills: [...]` lists skill folder names; a workflow's `refs.agents[].name` names an agent file, and its `refs.agents[].id` is the placeholder used in step `params.agentId` / `params.agentIds`. The validator checks these resolve.

## What goes in each file

- `skills/<name>/SKILL.md` - Skill format from `target-formats.md` §1. Frontmatter `name` + `description` required (`license` optional; nothing else is read). Body preserved from the source.
- `agents/<name>.agent.json` - Agent spec from `target-formats.md` §2. Required: `name`, `description`, `baseAgentType`, `additionalInstructions`, `modelKey` (placeholder allowed). Links (`skills`/`mcpServers`/`secrets`/`contextParameters`) by name.
- `workflows/<name>.workflow.json` - the `importWorkflow` artifact from `target-formats.md` §3: `{ _formatVersion: "1.0.0", workflow: { name, definition }, refs: { agents } }`. Steps use only the legal actions with the right `params`; `flow` is a linear chain from `""`; every step agent id appears in `refs.agents`; every `{{params.<key>}}` in the definition is declared in `refs.contextParameters`.

Use the templates in `assets/templates/` as the starting point for each.

## MANIFEST.md - required sections

The manifest is the contract with the reviewer. It must let them answer "is this faithful, and what do I still have to do?" without opening every file. Required sections, in order:

### 1. Summary
One paragraph: source frameworks detected, counts produced (`N skills, M agents, K workflows`), and the headline open items.

### 2. Source -> target mapping
A table, one row per meaningful source construct. One source can map to **several** targets - a split skill or a decomposed graph produces multiple rows; make the split explicit so the reviewer can confirm nothing was lost:

| Source (file / construct) | Overcut artifact | Notes |
|---|---|---|
| `pipeline.yaml` / dag task `review` | workflow `billing-pr-review` step `review` (`agent.run`) | - |
| `pipeline.yaml` / dag task `run-tests` | workflow `billing-pr-review` step `tests` (`script.run`) | deterministic shell, no agent needed |
| `pipeline.yaml` / full graph | workflows `billing-pr-review` + `release-cut` | decomposed into 2 dedicated per-goal workflows |
| `pipeline.yaml` / parallel tasks `lint` + `security-scan` | workflow `billing-pr-review` step `checks` (`agent.session`, 2 sub-agents) | Overcut has no parallel branches; fan-out became a coordinated session |
| `agents/all-in-one.yaml` / kagent | agents `billing-pr-reviewer` (`CodeReview`) + `billing-implementer` (`SeniorDeveloper`) | split one multi-role agent into specialized agents |
| `handbook.md` (2,000 lines) | skills `pr-review-checklist` + `coding-standards` + `release-playbook` | split oversized skill; content preserved, none dropped |
| `checklists/billing.md` | skill `billing-review-checklist` | attached only to the reviewer agent |

### 3. Dropped as plumbing
A bullet list of everything intentionally not carried over, each with a one-line reason (k8s specs, retries, build steps, state backends...). This is how the reviewer confirms nothing important was lost. **Always populate it** - "dropped nothing" is itself a claim worth stating.

### 4. TODOs
The action list, grouped. Every placeholder and every low-confidence decision lands here:
- **Placeholders to fill** - each agent `modelKey: <workspace-default>` (must become a real `llmModels` key before `createAgent`), each inferred/defaulted `baseAgentType`, each manual slash-command stand-in trigger, each `git.clone` whose repository source was guessed.
- **Integrations to wire** - per agent: built-in provider tools to confirm (PRs/tickets/channels need the provider connected to the project), and any MCP server + secret to assign (from `integration-mapping.md`), including low-confidence ones the converter refused to guess.
- **Built-in tools for code agents** - any filesystem/terminal `availableTools` (`read_file`, `edit_file`, `run_terminal_cmd`, ...) the converter added because the agent runs after a `git.clone`; the reviewer confirms them.
- **Secrets to create** - by name, never value. Flag any hardcoded credential found in the source (to create + rotate).
- **Context parameters to define** - every distinct `key` across all artifacts' context parameter lists, with its description, the default carried from the source (or "no default - set per project/repository"), and which artifacts reference it. Recommend workspace-level unless the key is clearly specific to one project.
- **Trigger conditions to narrow** - every trigger whose source filter could not be expressed as a rule group and was therefore omitted.

### 5. Import steps
The exact ordered steps to push this into a live project via the `overcut-api` skill (Context parameters -> Skills -> Agents -> Workflows; `importWorkflow` with `agentMapping`; draft vs commit caveat). Parameters go first because `createAgent` and `commitWorkflow` reject undefined keys. Mirror SKILL.md §6.

## Idempotence

Re-running the conversion overwrites the `<out-dir>` artifacts for the same names; it must not append duplicates or partially-written files. If the user edited files under `<out-dir>` by hand, warn before overwriting.
