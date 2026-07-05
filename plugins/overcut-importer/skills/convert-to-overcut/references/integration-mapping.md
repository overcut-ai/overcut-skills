# Integration mapping: external tools → Overcut

Source frameworks call external tools (filesystem, git, Slack, GitHub, Jira, HTTP, databases). Overcut exposes capabilities three ways. Map each detected tool call to one of them; when confidence is low, **don't fabricate** - record a TODO instead.

## The three Overcut capability surfaces

1. **Built-in tools** - a fixed set of native tool names on an agent's `availableTools` (e.g. `filesystem`, `git`). These need no config or secret.
2. **Step actions** - repo access is a *workflow step*, not an agent tool: `git.clone` / `repo.identify`. An agent only sees code if a clone step ran first.
3. **MCP servers** - external providers (Slack, GitHub API, Jira, Postgres, HTTP, Notion, …) installed in the project and assigned to an agent, gated by `allowedTools`. Most need a **secret**. In output these are *recommendations* (`{ catalogKey, allowedTools, confidence }`) plus `secrets[]` by name - the user installs/assigns them later.

## Mapping table

| Source tool / call pattern | Overcut mapping | Secret? |
|---|---|---|
| read/write local files, workspace paths | `availableTools: ["filesystem"]` | no |
| shell/exec of git; commit/branch/diff | `availableTools: ["git"]` **and** a `git.clone` step upstream | no (uses the connected repo) |
| clone/checkout a repo | `git.clone` step (+ `repo.identify` if repo comes from the trigger) | no |
| open/comment on PRs, create PRs, labels, GitHub API | MCP `github` (`allowedTools` scoped to what's used) - or, if it's just reacting to git events, prefer native triggers + `git` | `GITHUB_TOKEN` |
| GitLab / Bitbucket / Azure DevOps repo ops | MCP for that provider, else native git triggers | provider token |
| Jira / Linear / ClickUp issues | MCP for that provider | provider token |
| Slack post/notify/read channel | MCP `slack` (`allowedTools` = the methods used) | `SLACK_TOKEN` |
| generic HTTP request / REST call / webhook out | MCP `http`/`fetch` if the endpoint is known; else TODO | maybe (API key) |
| incoming webhook that *starts* the flow | not a tool - a `custom_event` **trigger** (`customEvent.name` = webhook slug) | dispatcher-side |
| Postgres / MySQL / Mongo / SQL query | MCP database server for that engine | connection secret |
| vector DB / embeddings / RAG store | usually **drop** (retrieval plumbing) unless it encodes business data the agent must query → MCP + TODO | maybe |
| email / SMS / PagerDuty / notifications | MCP if a catalog entry exists; else TODO | provider token |
| cloud SDK (AWS/GCP/Azure), kubectl, docker | almost always **drop** (infra, not SDLC business logic) | — |
| unknown / bespoke internal API | **do not guess** → TODO under Integrations | — |

## Confidence and the auto-map rule

Attach a `confidence` to every MCP recommendation:

- **high** - a well-known provider with an obvious catalog entry and a clear secret (Slack, GitHub, Jira, Postgres). Emit the recommendation and the `secrets[]` name.
- **low** - bespoke/unknown endpoint, ambiguous provider, or unclear scope. **Do not** emit config. Write a TODO: *"Agent `<x>` called `<tool>` - assign an MCP server + secret, or a built-in tool, to cover it."*

Either way the agent stays importable: built-in tools work immediately; MCP recommendations and secrets are applied by the user afterward.

## Secrets - names only, never values

Every secret is referenced by **name** in `secrets[]` and created by the user later (`createProjectSecret` takes a value once, only if the user supplies it). Never read, echo, copy, or invent a secret value - even if the source file hardcodes one. If a source file contains a hardcoded credential, **do not carry it into the output**; instead add a TODO: *"Source hardcoded a credential for `<tool>` - create it as a project secret `<NAME>` and rotate the leaked value."*

## `availableTools` vs MCP - the classic mixup

`availableTools` is the list of **built-in** tool names (like `filesystem`, `git`). It is **not** where MCP tools go. MCP tools arrive via an assigned MCP server and its `allowedTools`. Never put a provider name (`slack`, `github`) into `availableTools`.
