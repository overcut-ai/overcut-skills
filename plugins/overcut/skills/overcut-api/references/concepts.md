# Overcut concepts and data model

Read this before querying. Every operation in `queries.md` / `mutations.md` assumes this model.

## The nesting

```
Workspace                      (top-level tenant - one per API token)
├── Users / Teams / Roles      (who can do what)
├── Git Organizations          (connected GitHub / GitLab / Jira / etc.)
├── Repositories               (connected git repos - code and/or tickets)
├── LLM model registry         (which models agents may use; has a default)
└── Project                    (a workspace can have many)
    ├── Workflow                (automations - see below)
    │   └── Run                 (one execution of a workflow on a trigger event)
    │       └── Run Step        (one executed step, with logs + agent sub-threads)
    ├── Agent                   (a configured LLM persona used inside workflow steps)
    ├── Skill                   (a versioned instruction bundle from a git repo)
    ├── MCP Server              (external tool provider exposed to agents)
    └── Project Secret          (encrypted credential, referenced by id)
```

**Scoping cheat sheet** - this tells you which id you need for a given query:

| Entity | Scoped to | You query it with |
|---|---|---|
| Workspace, Repository, Git Organization, User, Team, LLM model | Workspace | (implicit - the token's workspace) |
| Workflow, Agent, MCP Server, Skill, Project Secret | Project | a `projectId` |
| Run, Run Step | Workflow | a `workflowId` (or `projectId`) |

## Containers

- **Workspace** - the top-level tenant. Owns users, teams, roles, billing/subscription, connected git/ticket organizations, the LLM model registry, and a default model. Your API token belongs to exactly one workspace. `currentWorkspace` returns it.
- **Project** - a container inside a workspace. Owns Agents, Workflows, MCP Servers, Skills, and Project Secrets. Almost all user-facing CRUD is project-scoped, so you pass a `projectId`.
- **Repository** - a connected git repo, used for code operations (`useForCode`) and/or ticket operations (`useForTickets`). Belongs to the workspace; many projects can include the same repo.

## Automation building blocks

- **Workflow** - an automation: a triggered, ordered set of steps. Has a **draft** state (what you edit) and a **committed** version (what runs in production). Can be active/inactive, manually triggered, exported, and imported. `hasUnpublishedChanges` is true when the draft differs from the latest committed version.
- **Step** - one node in a workflow. Has an `action` (e.g. `git.clone`, `repo.identify`, `agent.run`, `agent.session`), params, and (for agent steps) an instruction string. Lives inside the workflow's `definition`.
- **Trigger** - the event that starts a run (new PR, comment, slash command, schedule, manual, custom event). Filters narrow when it fires.
- **Run** - one execution of a workflow on a specific trigger event. Has a `status` (`Running`, `Completed`, `Failed`, `OnHold`, `Skipped`, `Terminating`, `Timeout`), timing, token `consumption`, and `steps`.
- **Run Step** - one executed step within a run, with its own logs (`runStepLogs`) and, for agent steps, sub-threads (`runStepThreads`). This is where you look to debug a failed run.

## Agents and their extensions

- **Agent** - a configured LLM persona used inside workflow steps. Configurable fields: `name`, `description`, `baseAgentType` (enum: `CodeReview`, `Custom`, `ProductManager`, `SeniorDeveloper`, `TechWriter`, `InternalRepoIdentify`), `modelKey`, `additionalInstructions` (its system prompt), `color`, `availableTools` (built-in tool identifiers in snake_case - e.g. `read_file`, `run_terminal_cmd`, `create_pull_request`, `read_ticket`, `post_channel_message`; there is no `filesystem` or `git` tool, git runs via `run_terminal_cmd`. Don't work from a memorized list - the authoritative, current catalog is the [Agent tools reference](https://docs.overcut.ai/docs/reference/tools#agent-tools-reference), see `mutations.md`), plus many-to-many links to Skills, MCP Servers, and Project Secrets.
- **Skill** - a versioned instruction bundle stored in a connected git repo (a directory containing a `SKILL.md`). Loaded at the configured `path` and `ref`. Assigned to agents to extend their behavior. `skillContent` fetches the live `SKILL.md` text.
- **MCP Server** - a Model Context Protocol server registered in the project. Exposes external tools to agents that have it assigned, for providers **without** a first-class built-in tool (e.g. Notion, Figma, Grafana, PostHog, Brave Search, Playwright, or a custom server). GitHub, GitLab, Jira, Linear, and Slack are **not** MCP - their actions are built-in `availableTools`. `allowedTools` restricts which of an MCP server's tools the agent may call. Installed from the Overcut catalog or as a custom server.
- **Project Secret** - an encrypted credential (API key, token) at project scope. Assigned **by id** to Agents, Workflows, or MCP Servers. The API never returns the value - only `hasValue` and usage counts.

## Catalogs

- **Playbook** - a pre-built, importable workflow template, identified by a kebab-case `key`. List with `playbooks`; import into a project with `addWorkflowFromPlaybook`.
- **MCP Catalog** - a curated list of installable MCP servers with default config and required-secret metadata. Browse with `mcpCatalogEntries` / `mcpCatalogEntry`.

## Two clarifications that trip people up

- An agent's `availableTools` is a list of **built-in** tool identifiers, *not* MCP tools (those arrive via assigned MCP Servers and their `allowedTools`). Take the identifiers from the live [Agent tools reference](https://docs.overcut.ai/docs/reference/tools#agent-tools-reference) rather than a memorized list - the catalog changes as Overcut adds tools. `Custom` agents start with an **empty** tool set, so every tool they need must be listed explicitly.
- "Skill" here (capital-S, the Overcut entity attached to agents) is different from a coding-agent skill like this one. This skill runs in your conversation; an Overcut Skill is attached to the user's agents and runs inside their workflows.
