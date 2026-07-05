# overcut-skills

Official [Overcut](https://overcut.ai) skills for [Claude Code](https://claude.com/claude-code), distributed as a plugin marketplace.

## Install

```sh
# 1. Add this marketplace
/plugin marketplace add overcut-ai/overcut-skills

# 2. Install a plugin
/plugin install overcut@overcut-skills
/plugin install overcut-importer@overcut-skills
```

Claude then invokes a skill as `/overcut:overcut-api` or `/overcut-importer:convert-to-overcut`, or automatically when you ask it to work with your Overcut account.

## What's included

| Plugin | Skill | What it does |
|--------|-------|--------------|
| `overcut` | `overcut-api` | Connect to the Overcut GraphQL API with a personal token to explore and manage workspaces, projects, workflows, agents, skills, MCP servers, runs, secrets, repositories, and playbooks. |
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
    │       └── overcut-api/        # the skill Claude invokes
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
