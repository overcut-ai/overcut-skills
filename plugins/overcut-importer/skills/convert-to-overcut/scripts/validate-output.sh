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
#   - every workflows/*.workflow.json parses; steps use only the 4 legal actions with unique ids;
#     flow edges reference real step ids; params.agent names resolve to an agent file
#   - every {{params.<key>}} referenced in an agent's additionalInstructions or a workflow's
#     definition is declared in that artifact's contextParameters (warning); declared keys
#     are well-formed (error); a declared key that looks like a credential is flagged (warning)
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
PARAM_REF = re.compile(r"\{\{\{?\s*params\.([A-Za-z0-9_]+)")
PARAM_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
SECRETY = re.compile(r"(token|secret|password|passwd|api_?key|private_?key|credential)", re.I)

def check_context_parameters(f, doc, texts):
    """Declared keys are well-formed and not credential-shaped; every {{params.x}} in
    `texts` is declared on this artifact."""
    declared = set()
    for i, p in enumerate(doc.get("contextParameters") or []):
        if not isinstance(p, dict) or not p.get("key"):
            err(f"{f}: contextParameters[{i}] needs a 'key'"); continue
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
        warn(f"{f}: references {{{{params.{key}}}}} but does not declare it in contextParameters (createAgent / commitWorkflow reject undefined keys)")
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
    if doc.get("name"): agent_names.add(doc["name"])
    bat = doc.get("baseAgentType")
    if bat and bat not in LEGAL_BASE:
        err(f"{f}: illegal baseAgentType '{bat}' (allowed: {sorted(LEGAL_BASE)})")
    check_context_parameters(f, doc, [doc.get("additionalInstructions")])

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
    check_context_parameters(f, doc, list(walk_strings(d)))

# ---- manifest ----
if not os.path.isfile(os.path.join(out, "MANIFEST.md")):
    err("MANIFEST.md is missing at the output root")

for w in warnings: print(f"WARN  {w}")
for e in errors:  print(f"ERROR {e}")
print(f"\n{len(skill_names)} skills, {len(agent_names)} agents, {len(wf_files)} workflows checked "
      f"- {len(errors)} error(s), {len(warnings)} warning(s)")
sys.exit(1 if errors else 0)
PY
