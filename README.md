# overcut-skills

Official [Overcut](https://overcut.ai) skills for [Claude Code](https://claude.com/claude-code), distributed as a plugin marketplace.

## Install

```sh
# 1. Add this marketplace
/plugin marketplace add overcut-ai/overcut-skills

# 2. Install the Overcut plugin
/plugin install overcut@overcut-skills
```

Claude then invokes the skill as `/overcut:overcut-api`, or automatically when you ask it to work with your Overcut account.

## What's included

| Plugin | Skill | What it does |
|--------|-------|--------------|
| `overcut` | `overcut-api` | Connect to the Overcut GraphQL API with a personal token to explore and manage workspaces, projects, workflows, agents, skills, MCP servers, runs, secrets, repositories, and playbooks. |

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
    └── overcut/              # the installable plugin (name: overcut)
        ├── .claude-plugin/
        │   └── plugin.json
        └── skills/
            └── overcut-api/  # the skill Claude invokes
                ├── SKILL.md
                ├── references/
                └── scripts/overcut-gql.sh
```
