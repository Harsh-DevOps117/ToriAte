#!/bin/sh
# One-shot, before n8n starts: credentials from .env, then import + publish every workflow.
# Safe to re-run: imports overwrite by id.
set -eu
DIR=/opt/tori/n8n
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

node "$DIR/bootstrap/make-credentials.js" > "$TMP/credentials.json"
n8n import:credentials --input="$TMP/credentials.json"

n8n import:workflow --separate --input="$DIR/workflows"
for f in "$DIR"/workflows/*.json; do
  id=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).id)' "$f")
  n8n publish:workflow --id="$id"
done
echo "bootstrap done"
