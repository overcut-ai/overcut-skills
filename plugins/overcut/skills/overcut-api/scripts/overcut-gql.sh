#!/usr/bin/env bash
#
# overcut-gql.sh - thin curl wrapper for the Overcut GraphQL API.
#
# Handles bearer auth, safe JSON encoding of the query + variables, pretty-prints
# the response, and exits non-zero if the response contains a GraphQL `errors` array.
#
# Env:
#   OVERCUT_API_TOKEN  (required)  personal API token generated in the Overcut UI
#   OVERCUT_API_URL    (optional)  GraphQL endpoint, default https://server.overcut.ai/graphql
#
# Usage:
#   overcut-gql.sh 'query { currentWorkspace { id name } }'
#   overcut-gql.sh -f query.graphql
#   overcut-gql.sh -f query.graphql -v '{"id":"abc123"}'
#   echo 'query { workspaces { id } }' | overcut-gql.sh -
#
set -euo pipefail

API_URL="${OVERCUT_API_URL:-https://server.overcut.ai/graphql}"
QUERY=""
VARS="{}"

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)  [[ -f "${2:-}" ]] || die "query file not found: ${2:-}"; QUERY="$(cat "$2")"; shift 2 ;;
    -v|--vars)  VARS="${2:-}"; shift 2 ;;
    -u|--url)   API_URL="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    -)          QUERY="$(cat)"; shift ;;
    *)          QUERY="$1"; shift ;;
  esac
done

[[ -n "${OVERCUT_API_TOKEN:-}" ]] || die "OVERCUT_API_TOKEN is not set. Generate a token in the Overcut UI (Settings -> API Tokens) and export it."
[[ -n "$QUERY" ]] || die "no query provided. Pass it as an argument, via -f <file>, or on stdin with -."

# Build the request body with proper JSON escaping. Prefer jq, fall back to python3.
if command -v jq >/dev/null 2>&1; then
  BODY="$(jq -nc --arg q "$QUERY" --argjson v "$VARS" '{query:$q, variables:$v}')"
elif command -v python3 >/dev/null 2>&1; then
  BODY="$(QUERY="$QUERY" VARS="$VARS" python3 -c 'import json,os; print(json.dumps({"query":os.environ["QUERY"],"variables":json.loads(os.environ["VARS"])}))')"
else
  die "need either jq or python3 installed to encode the request body."
fi

RESP="$(curl -sS -X POST "$API_URL" \
  -H "Authorization: Bearer ${OVERCUT_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$BODY")"

# Pretty-print and detect GraphQL errors.
if command -v jq >/dev/null 2>&1; then
  echo "$RESP" | jq .
  if echo "$RESP" | jq -e '.errors and (.errors | length > 0)' >/dev/null 2>&1; then
    exit 1
  fi
else
  echo "$RESP"
  case "$RESP" in *'"errors"'*) exit 1 ;; esac
fi
