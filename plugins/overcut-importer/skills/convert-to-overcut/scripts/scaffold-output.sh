#!/usr/bin/env bash
#
# scaffold-output.sh - create the empty output tree for a conversion.
#
# Usage:
#   scaffold-output.sh [out-dir]      # default: ./overcut-out
#
# Creates <out-dir>/{skills,agents,workflows} and a MANIFEST.md stub (copied from
# the skill's assets/templates/ if present). Never overwrites an existing MANIFEST.md.
#
set -euo pipefail

OUT_DIR="${1:-overcut-out}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SCRIPT_DIR/../assets/templates"

mkdir -p "$OUT_DIR/skills" "$OUT_DIR/agents" "$OUT_DIR/workflows"

if [[ ! -f "$OUT_DIR/MANIFEST.md" ]]; then
  if [[ -f "$TPL_DIR/MANIFEST.md.template" ]]; then
    cp "$TPL_DIR/MANIFEST.md.template" "$OUT_DIR/MANIFEST.md"
  else
    printf '# Conversion manifest\n\n_(fill in: summary, mapping, dropped, TODOs, import steps)_\n' > "$OUT_DIR/MANIFEST.md"
  fi
  echo "created $OUT_DIR/MANIFEST.md"
else
  echo "kept existing $OUT_DIR/MANIFEST.md"
fi

echo "scaffolded: $OUT_DIR/{skills,agents,workflows}"
