#!/usr/bin/env bash
# Give the local n8n a public HTTPS address (Cloudflare quick tunnel) so Meta can deliver
# WhatsApp messages and calls to workflow 06, then restart n8n with that address as WEBHOOK_URL.
# The address changes every time the tunnel container starts: run this script again after that.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose --profile tunnel up -d tunnel

# only the current run's logs: earlier runs of the container left their (dead) addresses in there too
since=$(docker inspect -f '{{.State.StartedAt}}' "$(docker compose --profile tunnel ps -q tunnel)")
url=""
for _ in $(seq 1 30); do
  url=$(docker compose --profile tunnel logs --since "$since" tunnel 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
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
  exit 0
fi

# Point the Meta app's webhook at this address. n8n's WhatsApp Trigger won't replace a subscription
# that has a different URL (an old tunnel), and doesn't call Meta on a plain restart, so do it here.
# Meta checks the URL with a GET challenge that the trigger answers (verify token = trigger node ID).
until curl -sf http://localhost:5678/healthz >/dev/null; do sleep 2; done
sleep 10  # let n8n register the trigger's webhook route
read -r node_id hook_id < <(python3 -c "
import json; w = json.load(open('n8n/workflows/06-whatsapp-bot.json'))
t = next(n for n in w['nodes'] if n['name'] == 'WhatsApp Trigger'); print(t['id'], t['webhookId'])")
callback="${url}/webhook/${hook_id}/webhook"
# a new quick-tunnel name takes a while to resolve; Meta fails with "Failed to resolve host" before that
for _ in $(seq 1 40); do
  curl -sf -o /dev/null "$url/healthz" && break
  sleep 3
done
# After a restart n8n sometimes serves the trigger's POST route but not the GET route Meta verifies
# with (404); a full stop / start fixes it.
check="http://localhost:5678/webhook/${hook_id}/webhook?hub.mode=subscribe&hub.challenge=1&hub.verify_token=${node_id}"
if ! curl -sf -o /dev/null "$check"; then
  echo "WhatsApp Trigger not answering Meta's check yet: restarting n8n once more"
  docker compose stop n8n && docker compose up -d n8n
  until curl -sf http://localhost:5678/healthz >/dev/null; do sleep 2; done
  sleep 12
fi
app_token="${BOT_META_APP_ID}|${BOT_META_APP_SECRET}"
result=$(curl -s -X POST "https://graph.facebook.com/v19.0/${BOT_META_APP_ID}/subscriptions" \
  --data-urlencode "object=whatsapp_business_account" --data-urlencode "callback_url=$callback" \
  --data-urlencode "verify_token=$node_id" --data-urlencode 'fields=["messages","calls"]' \
  --data-urlencode "include_values=true" --data-urlencode "access_token=$app_token")
case "$result" in
  *'"success":true'*) echo "Meta webhook → $callback" ;;
  *) echo "Could not point the Meta webhook at $callback: $result" >&2; exit 1 ;;
esac

# The bot can't reply with an expired token (temporary tokens from API Setup last 24 hours)
token_check=$(curl -s "https://graph.facebook.com/v19.0/${BOT_WHATSAPP_PHONE_NUMBER_ID}?fields=display_phone_number" \
  -H "Authorization: Bearer ${BOT_WHATSAPP_TOKEN}")
case "$token_check" in
  *'"error"'*) echo "WARNING: BOT_WHATSAPP_TOKEN is not valid (expired?), so the bot can't reply: $token_check" >&2 ;;
esac
echo "Workflow 06 is published. Message the bot's WhatsApp number; runs show in n8n → Executions."
