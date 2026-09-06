# Integration mapping: external tools → Overcut

Source frameworks call external tools (files, shell, git, GitHub/GitLab, Jira/Linear, Slack, HTTP, databases). Overcut exposes these three ways. Map each detected call to one of them; when confidence is low, **don't fabricate** - record a TODO instead.

## The three Overcut capability surfaces

1. **Built-in agent tools** - native tool identifiers (snake_case) on an agent's `availableTools`, e.g. `read_file`, `run_terminal_cmd`, `create_pull_request`. They cover filesystem/code, the terminal, and the first-class providers (pull requests, tickets, chat channels, CI). They need **no MCP server and no secret** - the provider is connected at the project level (a repository, a git/ticket org, a Slack workspace). The authoritative, always-current list is the [Agent tools reference](https://docs.overcut.ai/docs/reference/tools#agent-tools-reference) - take identifiers from there, never from memory.
2. **Workflow step actions** - repo access is a *workflow step*, not an agent tool: `git.clone` / `repo.identify`. These are step `action`s in the workflow definition, never values in `availableTools`. An agent only sees code if a clone step ran before its step.
3. **MCP servers** - for external providers **without** a first-class built-in tool (Notion, Figma, Grafana, PostHog, Brave Search, Playwright, a custom HTTP/DB server). Installed in the project, assigned to an agent, gated by `allowedTools`; most need a **secret**. In output these are *recommendations* (`{ catalogKey, allowedTools, confidence }`) plus `secrets[]` by name - the user installs/assigns them later.

> **GitHub, GitLab, Jira, Linear, and Slack are NOT MCP.** Their actions are first-class built-in tools (`create_pull_request`, `read_ticket`, `post_channel_message`, …). Reserve MCP for providers the built-in catalog doesn't cover.

## Built-in tool categories (orientation - not the full list)

Take identifiers from the [Agent tools reference](https://docs.overcut.ai/docs/reference/tools#agent-tools-reference) - it is the source of truth and grows as Overcut adds tools. Don't hardcode this list into your output; use it to recognize which *category* a source call maps to, then copy the exact identifiers from the reference. The categories, with a couple of examples each:

- **Filesystem** - `read_file`, `edit_file`, `list_dir` (also `write_file`, `append_file`, `delete_file`, `create_directory`)
- **Code** - `code_search`, `semantic_code_search`, `run_terminal_cmd`, `explore_codebase`
- **Tickets** - `read_ticket`, `create_ticket`, `add_comment_to_ticket`, `list_tickets`, …
- **Pull requests** - `create_pull_request`, `read_pull_request`, `add_comment_to_pull_request`, `merge_pull_request`, …
- **Code review** - `get_pull_request_diff`, `submit_review`, `add_pull_request_review_thread`, …
- **CI/CD** - `list_pr_ci_runs`, `get_ci_run_logs`, `retry_ci_workflow`, …
- **Chat channels** - `post_channel_message`, `read_channel_messages`, `add_channel_message_reaction`, …
- **Scratchpad / memory** (auto-injected) - `write_scratchpad`, `read_scratchpad`, `memory_write`, `memory_recall`, `update_status`

There is **no** `filesystem` or `git` tool - git runs through `run_terminal_cmd`. Emit only real identifiers from the reference; if a needed capability isn't there, record a TODO rather than inventing a name.

## Mapping table

| Source tool / call pattern | Overcut mapping | Secret? |
|---|---|---|
| read/write/list local files, workspace paths | `availableTools`: `read_file` / `write_file` / `edit_file` / `append_file` / `list_dir` / `create_directory` / `delete_file` as used | no |
| search code / grep / semantic search | `availableTools`: `code_search`, `semantic_code_search` | no |
| shell / exec, running git, tests, lint, build | `availableTools`: `run_terminal_cmd` **and** a `git.clone` step upstream when it touches the repo | no (uses the connected repo) |
| clone/checkout a repo | `git.clone` **step action** (+ `repo.identify` if the repo comes from the trigger) | no |
| open/read/comment/create/merge PRs, reviews (GitHub/GitLab/Bitbucket) | `availableTools`: the `*_pull_request` / `submit_review` / `*_review_thread*` tools used | no (repo connected to the project) |
| Jira / Linear / ClickUp issues | `availableTools`: `read_ticket`, `add_comment_to_ticket`, `get_ticket_metadata`, `get_ticket_attachments` | no (ticket org connected) |
| Slack post/notify/read channel | `availableTools`: `post_channel_message`, `read_channel_messages`, `add_channel_message_reaction` | no (Slack connected) — MCP `slack` only if the built-ins don't cover it |
| Notion / Figma / Grafana / PostHog / Brave / Playwright | MCP server for that provider (`allowedTools` scoped to what's used) | provider token |
| generic HTTP request / REST call / webhook out | MCP `http`/`fetch` if the endpoint is known; else TODO | maybe (API key) |
| incoming webhook that *starts* the flow | not a tool - a `custom_event` **trigger** (`customEvent.name` = webhook slug) | dispatcher-side |
| Postgres / MySQL / Mongo / SQL query | MCP database server for that engine | connection secret |
| vector DB / embeddings / RAG store | usually **drop** (retrieval plumbing) unless it encodes business data the agent must query → MCP + TODO | maybe |
| email / SMS / PagerDuty / notifications | MCP if a catalog entry exists; else TODO | provider token |
| cloud SDK (AWS/GCP/Azure), kubectl, docker | almost always **drop** (infra, not SDLC business logic) | — |
| unknown / bespoke internal API | **do not guess** → TODO under Integrations | — |

## Give code agents their tools

A Custom agent is created with **no** tools - `availableTools: []` means it can touch nothing. Source frameworks usually leave tool usage implicit in the prompt, so copying only a declared list ships an agent whose instructions assume file/repo access it never got.

**Rule: an agent that works on code needs the filesystem/terminal tools.** Use the workflow as the signal, not the prompt wording: an `agent.run`/`agent.session` step placed after a `git.clone` operates on the cloned repo, so give its agent the code tools it uses - at least `read_file`, and typically `edit_file`/`write_file`, `list_dir`, `code_search`, and `run_terminal_cmd`. An agent that only produces text (triage, summary, a channel post) needs none of them.

- Ensure a `git.clone` (with `repo.identify` upstream when the repo comes from the trigger) precedes any agent step that reads or writes code.
- Add the specific filesystem/terminal tools the agent uses to its `availableTools`, and record it as a MANIFEST TODO for the reviewer to confirm.
- A provider action (PR comment, ticket update, channel post) is a **built-in tool** (see the reference above) - not MCP, not a secret.

`validate-output.sh` warns when an agent used after a `git.clone` has no filesystem/terminal tool - treat that as the prompt to apply this rule.

## Confidence and the auto-map rule

Attach a `confidence` to every MCP recommendation:

- **high** - a well-known provider with an obvious catalog entry and a clear secret (Notion, Postgres, PostHog). Emit the recommendation and the `secrets[]` name.
- **low** - bespoke/unknown endpoint, ambiguous provider, or unclear scope. **Do not** emit config. Write a TODO: *"Agent `<x>` called `<tool>` - assign an MCP server + secret, or a built-in tool, to cover it."*

Either way the agent stays importable: built-in tools work immediately; MCP recommendations and secrets are applied by the user afterward.

## Secrets - names only, never values

Every secret is referenced by **name** in `secrets[]` and created by the user later (`createProjectSecret` takes a value once, only if the user supplies it). Never read, echo, copy, or invent a secret value - even if the source file hardcodes one. If a source file contains a hardcoded credential, **do not carry it into the output**; instead add a TODO: *"Source hardcoded a credential for `<tool>` - create it as a project secret `<NAME>` and rotate the leaked value."*

## `availableTools` vs MCP - the classic mixup

`availableTools` holds **built-in** tool identifiers from the [Agent tools reference](https://docs.overcut.ai/docs/reference/tools#agent-tools-reference) (e.g. `read_file`, `run_terminal_cmd`, `create_pull_request`). It is **not** where MCP tools go. MCP tools arrive via an assigned MCP server and its `allowedTools`, and only for providers the built-in tools don't cover. Never put a bare provider name (`slack`, `github`, `git`, `filesystem`) into `availableTools` - those are not tool names.
