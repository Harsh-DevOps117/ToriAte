#!/usr/bin/env bash
# Give the local n8n a public HTTPS address (Cloudflare quick tunnel) so Meta can deliver
# WhatsApp messages to workflow 06, then restart n8n with that address as WEBHOOK_URL.
# The address changes every time the tunnel container starts: run this script again after that.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose --profile tunnel up -d tunnel

url=""
for _ in $(seq 1 30); do
  url=$(docker compose --profile tunnel logs tunnel 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  [ -n "$url" ] && break
  sleep 2
done
[ -n "$url" ] || { echo "no tunnel address in the cloudflared logs: docker compose --profile tunnel logs tunnel" >&2; exit 1; }

if grep -q "^WEBHOOK_URL=$url/\$" .env; then
  echo "WEBHOOK_URL already $url/"
else
  sed -i "s#^WEBHOOK_URL=.*#WEBHOOK_URL=$url/#" .env
  echo "WEBHOOK_URL=$url/ (restarting n8n so the WhatsApp Trigger registers it with Meta)"
  docker compose up -d
fi

set -a; . ./.env; set +a
echo
echo "n8n is public at $url"
if [ "${BOT_ENABLED:-0}" != 1 ] || [ -z "${BOT_META_APP_ID:-}" ]; then
  echo "Workflow 06 is not published yet: fill BOT_* in .env, set BOT_ENABLED=1, run this script again."
else
  echo "Workflow 06 is published. Message the bot's WhatsApp number; runs show in n8n → Executions."
fi
