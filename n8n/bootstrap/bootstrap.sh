#!/bin/sh
set -eu
DIR=/opt/tori/n8n
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

node "$DIR/bootstrap/make-credentials.js" > "$TMP/credentials.json"
n8n import:credentials --input="$TMP/credentials.json"

n8n import:workflow --separate --input="$DIR/workflows"
for f in "$DIR"/workflows/*.json; do
  id=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).id)' "$f")
  # Publishing the WhatsApp bot points the Meta app's webhook at this n8n, so only do it when asked to
  if [ "$id" = toriWhatsAppBot1 ] && { [ "${BOT_ENABLED:-0}" != 1 ] || [ -z "${BOT_META_APP_ID:-}" ]; }; then
    echo "workflow 06 (WhatsApp bot) imported but not published: set BOT_ENABLED=1 and BOT_META_* in .env"
    continue
  fi
  n8n publish:workflow --id="$id"
done
echo "bootstrap done"
