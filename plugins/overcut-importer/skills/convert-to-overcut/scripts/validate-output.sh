#!/usr/bin/env bash
#
# validate-output.sh - sanity-check a converted output folder before review/import.
#
# Usage:
#   validate-output.sh [out-dir]      # default: ./overcut-out
#
# Checks (mirroring Overcut's WorkflowDefinitionSchema / step-params schemas / GraphQL inputs):
#   skills/*/SKILL.md
#     - frontmatter with name + description; (warning) keys Overcut ignores (allowed-tools, ...)
#   agents/*.agent.json
#     - parses; has name, description, baseAgentType (legal enum, not InternalRepoIdentify),
#       additionalInstructions, modelKey; skills[] resolve to skills/
#     - (warning) modelKey still the <workspace-default> placeholder
#   workflows/*.workflow.json  (the importWorkflow artifact)
#     - _formatVersion "1.0.0"; workflow.name; workflow.definition; refs.agents[]
#     - steps: legal action, id matches ^[a-zA-Z0-9-]+$ and unique, name present,
#       instruction present on agent.run/agent.session,
#       agent.run params.agentId / agent.session params.agentIds + goal resolve via refs.agents,
#       git.clone params.repoFullName present, script.run params.script present
#     - flow: single linear chain - first edge from "", every step exactly one incoming edge,
#       at most one outgoing edge, no edge condition, all ids real
#     - triggers: >= 1; legal event; manual has slashCommand; scheduled has schedule.cronExpression
#       (max one); custom_event has customEvent.name; conditions (if any) is a {combinator, rules} group
#     - priority 1-100; timeoutMs >= 30000; statusUpdateMethod legal (not "none")
#     - refs.agents[].name resolve to an agent file
#     - (warning) an agent used after a git.clone with no filesystem/terminal tool in availableTools
#   context parameters (agents/*.agent.json contextParameters[], workflows refs.contextParameters[])
#     - declared keys are well-formed (error); (warning) key looks like a credential, no description
#     - (warning) every {{params.<key>}} referenced in additionalInstructions / the definition is declared
#   MANIFEST.md exists
#
# Exit non-zero if any error is found. Warnings do not fail the run.
#
set -euo pipefail

OUT_DIR="${1:-overcut-out}"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
[[ -d "$OUT_DIR" ]] || { echo "error: no such directory: $OUT_DIR" >&2; exit 2; }

OUT_DIR="$OUT_DIR" python3 - <<'PY'
import json, os, re, sys, glob

out = os.environ["OUT_DIR"]
errors, warnings = [], []
def err(m): errors.append(m)
def warn(m): warnings.append(m)

LEGAL_ACTIONS = {"git.clone", "repo.identify", "agent.run", "agent.session", "script.run", "ci.executeWorkflow"}
AGENT_ACTIONS = {"agent.run", "agent.session"}
LEGAL_BASE = {"CodeReview", "Custom", "ProductManager", "SeniorDeveloper", "TechWriter"}
INTERNAL_BASE = {"InternalRepoIdentify"}
LEGAL_EVENTS = {
    "pull_request_opened", "pull_request_edited", "pull_request_closed", "pull_request_merged",
    "pull_request_commented", "pull_request_reviewed", "pull_request_review_commented",
    "pull_request_labeled", "pull_request_unlabeled", "pull_request_assigned", "pull_request_unassigned",
    "issue_opened", "issue_edited", "issue_closed", "issue_commented", "issue_labeled", "issue_unlabeled",
    "issue_assigned", "issue_unassigned",
    "ci_workflow_queued", "ci_workflow_started", "ci_workflow_completed", "ci_workflow_failed",
    "ci_workflow_cancelled", "ci_workflow_timed_out",
    "mention", "channel_message", "thread_reply", "slash_command",
    "scheduled", "custom_event", "manual",
}
LEGAL_OPERATORS = {"equals", "contains", "notContains", "matches", "notEquals", "startsWith", "endsWith", "in", "notIn"}
LEGAL_STATUS = {"comment", "reuse_comment", "static_comment"}
STEP_ID_RE = re.compile(r"^[a-zA-Z0-9-]+$")
MODEL_PLACEHOLDER = "<workspace-default>"
SKILL_FM_KEYS = {"name", "description", "license"}
# built-in EnumTools that let an agent work on cloned code (filesystem + terminal)
CODE_TOOLS = {"read_file","write_file","edit_file","append_file","delete_file",
              "list_dir","create_directory","code_search","semantic_code_search","run_terminal_cmd"}
PARAM_REF = re.compile(r"\{\{\{?\s*params\.([A-Za-z0-9_]+)")
PARAM_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
SECRETY = re.compile(r"(token|secret|password|passwd|api_?key|private_?key|credential)", re.I)

def check_context_parameters(f, where, declared_list, texts):
    """Declared keys (`where` names the list: contextParameters / refs.contextParameters) are
    well-formed and not credential-shaped; every {{params.x}} in `texts` is declared on this artifact."""
    declared = set()
    if declared_list is not None and not isinstance(declared_list, list):
        err(f"{f}: {where} must be an array of {{ key, description, default? }}"); declared_list = []
    for i, p in enumerate(declared_list or []):
        if not isinstance(p, dict) or not p.get("key"):
            err(f"{f}: {where}[{i}] needs a 'key'"); continue
        key = p["key"]
        if not PARAM_KEY.match(key):
            err(f"{f}: context parameter key '{key}' must match ^[A-Za-z_][A-Za-z0-9_]*$ (max 64 chars)")
        if not p.get("description"):
            warn(f"{f}: context parameter '{key}' has no description")
        if SECRETY.search(key):
            warn(f"{f}: context parameter '{key}' looks like a credential - parameters are plain text in prompts and logs; use secrets[] instead")
        declared.add(key)
    referenced = set()
    for t in texts:
        if isinstance(t, str):
            referenced.update(PARAM_REF.findall(t))
    for key in sorted(referenced - declared):
        warn(f"{f}: references {{{{params.{key}}}}} but does not declare it in {where} (createAgent / commitWorkflow reject undefined keys)")
    for key in sorted(declared - referenced):
        warn(f"{f}: declares context parameter '{key}' that nothing in this artifact references")

def walk_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from walk_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk_strings(v)

# ---- skills ----
skill_names = set()
for d in sorted(glob.glob(os.path.join(out, "skills", "*"))):
    if not os.path.isdir(d):
        continue
    md = os.path.join(d, "SKILL.md")
    if not os.path.isfile(md):
        err(f"skill '{os.path.basename(d)}': missing SKILL.md"); continue
    text = open(md, encoding="utf-8").read()
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.S)
    if not m:
        err(f"{md}: missing YAML frontmatter (--- ... ---)"); continue
    fm = m.group(1)
    def field(name):
        mm = re.search(rf"^{name}\s*:\s*(.+?)\s*$", fm, re.M)
        return mm.group(1).strip() if mm else None
    name = field("name"); desc = field("description")
    if not name: err(f"{md}: frontmatter missing 'name'")
    else: skill_names.add(name)
    if not desc: err(f"{md}: frontmatter missing 'description'")
    extra = {k for k in re.findall(r"^([A-Za-z_-]+)\s*:", fm, re.M)} - SKILL_FM_KEYS
    if extra:
        warn(f"{md}: frontmatter keys Overcut ignores: {sorted(extra)} (only name/description/license are read)")
    if not text[m.end():].strip():
        err(f"{md}: empty body")

# ---- agents ----
agent_names = set()
agent_tools = {}   # agent name -> set of built-in tool names it has
agent_docs = {}
for f in sorted(glob.glob(os.path.join(out, "agents", "*.agent.json"))):
    try:
        doc = json.load(open(f, encoding="utf-8"))
    except Exception as e:
        err(f"{f}: invalid JSON ({e})"); continue
    agent_docs[f] = doc
    for req in ("name", "description", "baseAgentType", "additionalInstructions", "modelKey"):
        if not doc.get(req):
            err(f"{f}: missing required field '{req}'")
    if doc.get("name"):
        agent_names.add(doc["name"])
        agent_tools[doc["name"]] = set(doc.get("availableTools") or [])
    bat = doc.get("baseAgentType")
    if bat in INTERNAL_BASE:
        err(f"{f}: baseAgentType '{bat}' is the built-in behind repo.identify - use Custom or another user type")
    elif bat and bat not in LEGAL_BASE:
        err(f"{f}: illegal baseAgentType '{bat}' (allowed: {sorted(LEGAL_BASE)})")
    if doc.get("modelKey") == MODEL_PLACEHOLDER:
        warn(f"{f}: modelKey is still '{MODEL_PLACEHOLDER}' - replace it with a key from llmModels before createAgent")
    for bad in ("filesystem", "git", "slack", "github", "jira"):
        if bad in (doc.get("availableTools") or []):
            err(f"{f}: '{bad}' is not a built-in tool identifier (see the Agent Tools Reference)")
    check_context_parameters(f, "contextParameters", doc.get("contextParameters"), [doc.get("additionalInstructions")])

for f, doc in agent_docs.items():
    for sk in doc.get("skills", []) or []:
        if sk not in skill_names:
            warn(f"{f}: references skill '{sk}' not found in skills/ (create it or fix the name)")

# ---- workflows ----
wf_files = sorted(glob.glob(os.path.join(out, "workflows", "*.workflow.json")))
for f in wf_files:
    try:
        doc = json.load(open(f, encoding="utf-8"))
    except Exception as e:
        err(f"{f}: invalid JSON ({e})"); continue

    if doc.get("_formatVersion") != "1.0.0":
        err(f"{f}: _formatVersion must be \"1.0.0\" (importWorkflow artifact)")
    wf = doc.get("workflow")
    if not isinstance(wf, dict):
        err(f"{f}: missing 'workflow' object ({{ name, definition }})"); continue
    if not wf.get("name"):
        err(f"{f}: workflow.name is missing")
    d = wf.get("definition")
    if not isinstance(d, dict):
        err(f"{f}: missing 'workflow.definition' object"); continue
    if not d.get("name"):
        err(f"{f}: definition.name is missing")

    refs = doc.get("refs") or {}
    ref_agents = refs.get("agents")
    if not isinstance(ref_agents, list):
        err(f"{f}: refs.agents must be an array of {{ id, name }}"); ref_agents = []
    ref_ids = {}
    for r in ref_agents:
        rid, rname = (r or {}).get("id"), (r or {}).get("name")
        if not rid or not rname:
            err(f"{f}: refs.agents entry needs both id and name: {r}"); continue
        ref_ids[rid] = rname
        if rname not in agent_names:
            err(f"{f}: refs.agents '{rname}' has no matching agents/*.agent.json")

    # steps
    steps = d.get("steps") or []
    if not steps:
        err(f"{f}: definition has no steps")
    ids = []
    step_agent = {}   # step id -> agent name(s)
    for s in steps:
        sid = s.get("id")
        if not sid:
            err(f"{f}: a step is missing 'id'"); continue
        ids.append(sid)
        if not STEP_ID_RE.match(sid):
            err(f"{f}: step id '{sid}' must match ^[a-zA-Z0-9-]+$ (no underscores/spaces)")
        if not s.get("name"):
            err(f"{f}: step '{sid}' is missing 'name' (required)")
        act = s.get("action")
        p = s.get("params")
        if act not in LEGAL_ACTIONS:
            err(f"{f}: step '{sid}' has illegal action '{act}' (allowed: {sorted(LEGAL_ACTIONS)})"); continue
        if not isinstance(p, dict):
            err(f"{f}: step '{sid}' ({act}) needs a 'params' object"); p = {}
        smd = s.get("stepMaxDurationMinutes")
        if smd is not None and (not isinstance(smd, (int, float)) or smd < 1):
            err(f"{f}: step '{sid}' stepMaxDurationMinutes must be >= 1")
        if "agent" in p:
            err(f"{f}: step '{sid}' uses params.agent - the field is params.agentId (agent.run) / params.agentIds (agent.session)")
        if act in AGENT_ACTIONS and not s.get("instruction"):
            err(f"{f}: step '{sid}' ({act}) is missing 'instruction' (required)")
        if act == "agent.run":
            aid = p.get("agentId")
            if not aid:
                err(f"{f}: step '{sid}' agent.run needs params.agentId")
            elif aid not in ref_ids:
                err(f"{f}: step '{sid}' params.agentId '{aid}' is not declared in refs.agents")
            else:
                step_agent[sid] = [ref_ids[aid]]
        elif act == "agent.session":
            aids = p.get("agentIds")
            if not isinstance(aids, list) or not aids:
                err(f"{f}: step '{sid}' agent.session needs a non-empty params.agentIds array")
            else:
                names = []
                for aid in aids:
                    if aid not in ref_ids:
                        err(f"{f}: step '{sid}' params.agentIds entry '{aid}' is not declared in refs.agents")
                    else:
                        names.append(ref_ids[aid])
                step_agent[sid] = names
            if not p.get("goal"):
                err(f"{f}: step '{sid}' agent.session needs params.goal")
        elif act == "git.clone":
            if not p.get("repoFullName"):
                err(f"{f}: step '{sid}' git.clone needs params.repoFullName "
                    f"(\"org/repo\", \"{{{{trigger.repository.fullName}}}}\", or \"{{{{outputs.<repo-identify-step>}}}}\")")
        elif act == "script.run":
            if not p.get("script"):
                err(f"{f}: step '{sid}' script.run needs params.script")
            cwd = p.get("cwd")
            if cwd and (cwd.startswith("/") or ".." in cwd.split("/")):
                err(f"{f}: step '{sid}' script.run cwd must be relative to the workspace (no leading '/' or '..')")
        elif act == "ci.executeWorkflow":
            for req in ("repoFullName", "workflowId"):
                if not p.get(req):
                    err(f"{f}: step '{sid}' ci.executeWorkflow needs params.{req}")
    dup = {i for i in ids if ids.count(i) > 1}
    if dup: err(f"{f}: duplicate step ids: {sorted(dup)}")
    idset = set(ids)

    # flow: single linear chain, first edge from ""
    flow = d.get("flow")
    if not isinstance(flow, list):
        err(f"{f}: definition.flow must be an array"); flow = []
    incoming, outgoing = {}, {}
    for e in flow:
        fr, to = e.get("from"), e.get("to")
        if e.get("condition") not in (None, ""):
            err(f"{f}: flow edge {fr!r}->{to!r} has a condition - Overcut flow edges cannot be conditional")
        if fr != "" and fr not in idset:
            err(f"{f}: flow edge from='{fr}' references unknown step id")
        if to not in idset:
            err(f"{f}: flow edge to='{to}' references unknown step id"); continue
        incoming[to] = incoming.get(to, 0) + 1
        outgoing[fr] = outgoing.get(fr, 0) + 1
    if steps and flow:
        if outgoing.get("", 0) != 1:
            err(f"{f}: flow must have exactly one starting edge with from \"\" (found {outgoing.get('', 0)})")
        for sid in ids:
            n = incoming.get(sid, 0)
            if n == 0: err(f"{f}: step '{sid}' is never reached by flow (needs exactly one incoming edge)")
            if n > 1:  err(f"{f}: step '{sid}' has {n} incoming edges - flow must be a single linear chain")
            if outgoing.get(sid, 0) > 1:
                err(f"{f}: step '{sid}' has {outgoing[sid]} outgoing edges - Overcut has no parallel branches; "
                    f"use one agent.session with several sub-agents instead")
    elif steps and not flow:
        err(f"{f}: definition.flow is empty - chain the steps starting with {{\"from\": \"\", \"to\": \"{ids[0]}\"}}")

    # triggers
    trig = d.get("triggers")
    if not isinstance(trig, list) or not trig:
        err(f"{f}: definition.triggers must be a non-empty array "
            f"(placeholder: [{{\"event\":\"manual\",\"slashCommand\":{{\"command\":\"<name>\",\"requireMention\":false}}}}])")
        trig = []
    if "trigger" in d:
        err(f"{f}: legacy single 'trigger' field is not accepted - use 'triggers'")
    n_sched = 0
    def check_rule(node, path):
        if not isinstance(node, dict):
            err(f"{f}: {path} must be an object"); return
        if "combinator" in node or "rules" in node:
            if node.get("combinator") not in ("and", "or"):
                err(f"{f}: {path}.combinator must be 'and' or 'or'")
            if not isinstance(node.get("rules"), list):
                err(f"{f}: {path}.rules must be an array")
            else:
                for i, r in enumerate(node["rules"]):
                    check_rule(r, f"{path}.rules[{i}]")
            extra = set(node) - {"combinator", "rules"}
            if extra:
                err(f"{f}: {path} group has unexpected keys {sorted(extra)}")
        else:
            if not node.get("field"):
                err(f"{f}: {path} leaf needs 'field'")
            if node.get("operator") not in LEGAL_OPERATORS:
                err(f"{f}: {path} operator '{node.get('operator')}' is not one of {sorted(LEGAL_OPERATORS)}")
            extra = set(node) - {"field", "operator", "value"}
            if extra:
                err(f"{f}: {path} leaf has unexpected keys {sorted(extra)} (no free-form/TODO keys - omit conditions instead)")
    for i, t in enumerate(trig):
        ev = (t or {}).get("event")
        path = f"triggers[{i}]"
        if ev not in LEGAL_EVENTS:
            err(f"{f}: {path} event '{ev}' is not a StandardizedEventType"); continue
        sc = t.get("slashCommand")
        if ev == "manual":
            if not isinstance(sc, dict) or not sc.get("command") or "requireMention" not in sc:
                err(f"{f}: {path} manual trigger requires slashCommand {{ command, requireMention }}")
        elif sc:
            err(f"{f}: {path} slashCommand is only allowed on manual triggers")
        if ev == "scheduled":
            n_sched += 1
            if not (t.get("schedule") or {}).get("cronExpression"):
                err(f"{f}: {path} scheduled trigger requires schedule.cronExpression")
        if ev == "custom_event" and not (t.get("customEvent") or {}).get("name"):
            err(f"{f}: {path} custom_event trigger requires customEvent.name")
        if t.get("customEvent") and ev != "custom_event":
            err(f"{f}: {path} customEvent is only allowed when event is custom_event")
        if t.get("conditions") is not None:
            c = t["conditions"]
            if not isinstance(c, dict) or "combinator" not in c:
                err(f"{f}: {path}.conditions must be a rule group {{ combinator, rules }} - omit it when unsure")
            else:
                check_rule(c, f"{path}.conditions")
    if n_sched > 1:
        err(f"{f}: at most one scheduled trigger per workflow")

    # definition-level fields
    pr = d.get("priority")
    if pr is not None and (not isinstance(pr, int) or pr < 1 or pr > 100):
        err(f"{f}: priority must be an integer 1-100 (lower runs first; default 5)")
    tm = d.get("timeoutMs")
    if tm is not None and (not isinstance(tm, (int, float)) or tm < 30000):
        err(f"{f}: timeoutMs must be >= 30000")
    sm = d.get("statusUpdateMethod")
    if sm is not None and sm not in LEGAL_STATUS:
        err(f"{f}: statusUpdateMethod '{sm}' not in {sorted(LEGAL_STATUS)} ('none' is internal-only)")
    if d.get("defaultModelKey") == MODEL_PLACEHOLDER:
        err(f"{f}: defaultModelKey must not be the placeholder - omit it to use the workspace default")

    # code-tool check: an agent step downstream of a git.clone works on cloned code,
    # so its agent needs a filesystem/terminal tool. Reachability over the flow chain, not prompt text.
    adj = {}
    for e in flow:
        adj.setdefault(e.get("from"), []).append(e.get("to"))
    reachable, stack = set(), [s.get("id") for s in steps if s.get("action") == "git.clone"]
    while stack:
        n = stack.pop()
        for m in adj.get(n, []):
            if m not in reachable:
                reachable.add(m); stack.append(m)
    for s in steps:
        sid = s.get("id")
        if s.get("action") in AGENT_ACTIONS and sid in reachable:
            for ag in step_agent.get(sid, []):
                if ag in agent_names and not (agent_tools.get(ag, set()) & CODE_TOOLS):
                    warn(f"{f}: step '{sid}' runs after a git.clone but its agent '{ag}' has no "
                         f"filesystem/terminal tool in availableTools (read_file, edit_file, code_search, "
                         f"run_terminal_cmd, ...) - it cannot access the cloned code. Add the tools it needs.")

    check_context_parameters(f, "refs.contextParameters", refs.get("contextParameters"), list(walk_strings(d)))

# ---- manifest ----
if not os.path.isfile(os.path.join(out, "MANIFEST.md")):
    err("MANIFEST.md is missing at the output root")

for w in warnings: print(f"WARN  {w}")
for e in errors:  print(f"ERROR {e}")
print(f"\n{len(skill_names)} skills, {len(agent_names)} agents, {len(wf_files)} workflows checked "
      f"- {len(errors)} error(s), {len(warnings)} warning(s)")
sys.exit(1 if errors else 0)
PY
