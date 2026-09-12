# overcut-skills

Official [Overcut](https://overcut.ai) skills for agentic coding tools, distributed as a plugin marketplace.

## Install

These are portable skills - each is a self-contained `SKILL.md` plus its references and scripts, under `plugins/*/skills/` (for example `plugins/overcut/skills/overcut-api/`). Install them with whatever plugin or skill mechanism your coding agent provides. Install commands are tool-specific and change over time, so follow your tool's own documentation for the current flow; the repo reference is `overcut-ai/overcut-skills`.

For example, in a tool that consumes this marketplace format (Claude Code):

```sh
/plugin marketplace add overcut-ai/overcut-skills
/plugin install overcut@overcut-skills
/plugin install overcut-importer@overcut-skills
```

Tools that don't use this marketplace format can point their "add skill / add plugin" flow at the skill directories directly.

Once installed, invoke a skill by name (however your tool surfaces skills - e.g. `overcut-api`, `convert-to-overcut`), or just ask your coding agent to work with your Overcut account and it will load the relevant skill automatically.

## What's included

| Plugin | Skill | What it does |
|--------|-------|--------------|
| `overcut` | `overcut-api` | Connect to the Overcut GraphQL API with a personal token to explore and manage workspaces, projects, workflows, agents, skills, MCP servers, runs, secrets, context parameters, the workspace library, repositories, and playbooks. |
| `overcut-importer` | `convert-to-overcut` | Convert an existing agent/automation framework (Argo Workflows, kagents, LangGraph, CrewAI, AutoGen, n8n, GitHub Actions, or an arbitrary skills/prompts folder) into Overcut-ready Skills, Agents, and Workflow definitions. Distills the SDLC business logic, drops framework plumbing, and writes a reviewable `out/` folder with a `MANIFEST.md`. Optionally hands off to `overcut-api` to import into a live project. |

## Authentication

The `overcut-api` skill needs a personal API token, generated in the Overcut web UI under **Workspace Settings → Security → API Tokens**. Export it before use:

```sh
export OVERCUT_API_TOKEN="<your-token>"
# Optional, defaults to production:
export OVERCUT_API_URL="https://server.overcut.ai/graphql"
```

The token inherits the permissions of the user who created it. Prefer a dedicated, least-privilege user. Never commit a token to this repo.

## Repository layout

```
overcut-skills/
├── .claude-plugin/
│   └── marketplace.json      # marketplace catalog (name: overcut-skills)
└── plugins/
    ├── overcut/                    # plugin (name: overcut)
    │   ├── .claude-plugin/plugin.json
    │   └── skills/
    │       └── overcut-api/        # the skill your coding agent invokes
    │           ├── SKILL.md
    │           ├── references/
    │           └── scripts/overcut-gql.sh
    └── overcut-importer/           # plugin (name: overcut-importer)
        ├── .claude-plugin/plugin.json
        └── skills/
            └── convert-to-overcut/ # framework → Overcut converter
                ├── SKILL.md
                ├── references/     # target-formats, source-frameworks, integration-mapping, output-layout
                ├── scripts/        # scaffold-output.sh, validate-output.sh
                └── assets/templates/
```
