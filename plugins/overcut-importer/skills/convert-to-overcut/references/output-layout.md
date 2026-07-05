# Output layout and MANIFEST spec

The conversion writes one self-contained folder the user reviews, then optionally imports. Default location: `overcut-out/` in the current directory (override if the user names one). Scaffold it with `scripts/scaffold-output.sh <out-dir>`.

## Directory layout

```
<out-dir>/
├── MANIFEST.md                       # the review deliverable - read this first
├── skills/
│   └── <skill-name>/
│       ├── SKILL.md                  # one folder per Overcut Skill
│       └── references/               # optional, only if the skill body is long
├── agents/
│   └── <agent-name>.agent.json       # one file per Overcut Agent
└── workflows/
    └── <workflow-name>.workflow.json # one file per Overcut Workflow
```

Naming: kebab-case throughout, matching the `name` inside each artifact. Cross-references use these names (an agent's `skills: [...]` lists skill folder names; a workflow step's `params.agent` names an agent file). The validator checks these resolve.

## What goes in each file

- `skills/<name>/SKILL.md` - Skill format from `target-formats.md` §1. Valid frontmatter (`name`, `description` required), framework-free body.
- `agents/<name>.agent.json` - Agent spec from `target-formats.md` §2. Required: `name`, `description`, `baseAgentType`, `additionalInstructions`. Links (`skills`/`mcpServers`/`secrets`) by name.
- `workflows/<name>.workflow.json` - `{ name, definition, agentRefs }` from `target-formats.md` §3. Steps use only the four legal actions; `flow` references real step ids.

Use the templates in `assets/templates/` as the starting point for each.

## MANIFEST.md - required sections

The manifest is the contract with the reviewer. It must let them answer "is this faithful, and what do I still have to do?" without opening every file. Required sections, in order:

### 1. Summary
One paragraph: source frameworks detected, counts produced (`N skills, M agents, K workflows`), and the headline open items.

### 2. Source → target mapping
A table, one row per meaningful source construct:

| Source (file · construct) | Overcut artifact | Notes |
|---|---|---|
| `pipeline.yaml` · dag task `review` | workflow `billing-pr-review` step `review` (`agent.run`) | — |
| `agents/reviewer.yaml` · kagent | agent `billing-pr-reviewer` (`CodeReview`) | baseAgentType inferred |
| `checklists/billing.md` | skill `billing-review-checklist` | shared by 2 agents |

### 3. Dropped as plumbing
A bullet list of everything intentionally not carried over, each with a one-line reason (k8s specs, retries, build steps, state backends…). This is how the reviewer confirms nothing important was lost. **Always populate it** - "dropped nothing" is itself a claim worth stating.

### 4. TODOs
The action list, grouped. Every placeholder and every low-confidence decision lands here:
- **Placeholders to fill** - each `<workspace-default>` model, each inferred/defaulted `baseAgentType`, each manual-trigger placeholder.
- **Integrations to wire** - per agent: which MCP server + secret to assign (from `integration-mapping.md`), including low-confidence ones the converter refused to guess.
- **Secrets to create** - by name, never value. Flag any hardcoded credential found in the source (to create + rotate).
- **Trigger conditions to narrow** - any `conditions: { "TODO": ... }`.

### 5. Import steps
The exact ordered steps to push this into a live project via the `overcut-api` skill (Skills → Agents → Workflows; draft vs commit caveat). Mirror SKILL.md §6.

## Idempotence

Re-running the conversion overwrites the `<out-dir>` artifacts for the same names; it must not append duplicates or partially-written files. If the user edited files under `<out-dir>` by hand, warn before overwriting.
