#!/usr/bin/env bash
#
# validate-output.sh - sanity-check a converted output folder before review/import.
#
# Usage:
#   validate-output.sh [out-dir]      # default: ./overcut-out
#
# Checks:
#   - every skills/*/SKILL.md has frontmatter with name + description
#   - every agents/*.agent.json parses and has name, description, baseAgentType (legal enum),
#     additionalInstructions; links reference real skills
#   - (warning) an agent used after a git.clone but with no filesystem/git in availableTools
#   - every workflows/*.workflow.json parses; steps use only the 4 legal actions with unique ids;
#     flow edges reference real step ids; params.agent names resolve to an agent file
#   - MANIFEST.md exists
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

LEGAL_ACTIONS = {"git.clone", "repo.identify", "agent.run", "agent.session"}
LEGAL_BASE = {"CodeReview","Custom","ProductManager","SeniorDeveloper","TechWriter","InternalRepoIdentify"}
CODE_TOOLS = {"filesystem", "git"}  # built-in tools an agent needs to work on cloned code

# ---- skills ----
skill_names = set()
skill_dirs = sorted(glob.glob(os.path.join(out, "skills", "*")))
for d in skill_dirs:
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

# ---- agents ----
agent_names = set()
agent_tools = {}   # agent name -> set of built-in tool names it has
agent_files = sorted(glob.glob(os.path.join(out, "agents", "*.agent.json")))
agent_docs = {}
for f in agent_files:
    try:
        doc = json.load(open(f, encoding="utf-8"))
    except Exception as e:
        err(f"{f}: invalid JSON ({e})"); continue
    agent_docs[f] = doc
    for req in ("name","description","baseAgentType","additionalInstructions"):
        if not doc.get(req):
            err(f"{f}: missing required field '{req}'")
    if doc.get("name"):
        agent_names.add(doc["name"])
        agent_tools[doc["name"]] = set(doc.get("availableTools") or [])
    bat = doc.get("baseAgentType")
    if bat and bat not in LEGAL_BASE:
        err(f"{f}: illegal baseAgentType '{bat}' (allowed: {sorted(LEGAL_BASE)})")

# resolve agent -> skill links after all skills known
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
    d = doc.get("definition")
    if not isinstance(d, dict):
        err(f"{f}: missing 'definition' object"); continue
    steps = d.get("steps") or []
    if not steps:
        err(f"{f}: definition has no steps")
    ids = []
    for s in steps:
        sid = s.get("id")
        if not sid: err(f"{f}: a step is missing 'id'"); continue
        ids.append(sid)
        act = s.get("action")
        if act not in LEGAL_ACTIONS:
            err(f"{f}: step '{sid}' has illegal action '{act}' (allowed: {sorted(LEGAL_ACTIONS)})")
        if act in ("agent.run","agent.session"):
            ag = (s.get("params") or {}).get("agent")
            if ag and ag not in agent_names:
                warn(f"{f}: step '{sid}' references agent '{ag}' not found in agents/")
    dup = {i for i in ids if ids.count(i) > 1}
    if dup: err(f"{f}: duplicate step ids: {sorted(dup)}")
    idset = set(ids)
    for e in d.get("flow") or []:
        for end in ("from","to"):
            if e.get(end) not in idset:
                err(f"{f}: flow edge {end}='{e.get(end)}' references unknown step id")
    trig = d.get("triggers")
    if not trig:
        err(f"{f}: definition has no triggers (use [{{\"event\":\"manual\"}}] as a placeholder)")

    # code-tool check: an agent step downstream of a git.clone works on cloned code,
    # so its agent needs filesystem/git. Reachability over the flow graph, not prompt text.
    adj = {}
    for e in d.get("flow") or []:
        adj.setdefault(e.get("from"), []).append(e.get("to"))
    reachable, stack = set(), [s.get("id") for s in steps if s.get("action") == "git.clone"]
    while stack:
        n = stack.pop()
        for m in adj.get(n, []):
            if m not in reachable:
                reachable.add(m); stack.append(m)
    for s in steps:
        if s.get("action") in ("agent.run","agent.session") and s.get("id") in reachable:
            ag = (s.get("params") or {}).get("agent")
            if ag and ag in agent_names and not (agent_tools.get(ag, set()) & CODE_TOOLS):
                warn(f"{f}: step '{s.get('id')}' runs after a git.clone but its agent '{ag}' has no "
                     f"filesystem/git in availableTools - it cannot access the cloned code. Add the "
                     f"built-in tools it needs.")

# ---- manifest ----
if not os.path.isfile(os.path.join(out, "MANIFEST.md")):
    err("MANIFEST.md is missing at the output root")

for w in warnings: print(f"WARN  {w}")
for e in errors:  print(f"ERROR {e}")
print(f"\n{len(skill_names)} skills, {len(agent_names)} agents, {len(wf_files)} workflows checked "
      f"- {len(errors)} error(s), {len(warnings)} warning(s)")
sys.exit(1 if errors else 0)
PY
