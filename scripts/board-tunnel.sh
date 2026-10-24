#!/usr/bin/env bash
# Give the partner board (web/) a temporary public HTTPS address (Cloudflare quick tunnel) for demos,
# put it into BOARD_PUBLIC_URL and restart n8n, so the bot's replies and menu link to it.
# The address changes whenever the board-tunnel container restarts: run this script again after that.
# Anyone with the address sees the board (first names, places and times; never phone numbers).
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose --profile tunnel up -d board-tunnel

# only the current run's logs: earlier runs of the container left their (dead) addresses in there too
since=$(docker inspect -f '{{.State.StartedAt}}' "$(docker compose --profile tunnel ps -q board-tunnel)")
url=""
for _ in $(seq 1 30); do
  url=$(docker compose --profile tunnel logs --since "$since" board-tunnel 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  [ -n "$url" ] && break
  sleep 2
done
[ -n "$url" ] || { echo "no tunnel address in the cloudflared logs: docker compose --profile tunnel logs board-tunnel" >&2; exit 1; }

# a new quick-tunnel name takes a little while to resolve
for _ in $(seq 1 30); do
  curl -sf -o /dev/null "$url/api/requests" && break
  sleep 3
done
curl -sf -o /dev/null "$url/api/requests" || echo "WARNING: $url does not answer yet; try it in a minute" >&2

if grep -q "^BOARD_PUBLIC_URL=$url\$" .env; then
  echo "BOARD_PUBLIC_URL already $url"
else
  if grep -q '^BOARD_PUBLIC_URL=' .env; then
    sed -i "s#^BOARD_PUBLIC_URL=.*#BOARD_PUBLIC_URL=$url#" .env
  else
    printf '\n# partner board public address (scripts/board-tunnel.sh)\nBOARD_PUBLIC_URL=%s\n' "$url" >> .env
  fi
  echo "BOARD_PUBLIC_URL=$url (restarting n8n so the bot links to it)"
  docker compose up -d n8n

  # After a restart n8n sometimes serves the WhatsApp Trigger's POST route but not the GET route Meta
  # verifies with; a full stop / start fixes it.
  set -a; . ./.env; set +a
  if [ "${BOT_ENABLED:-0}" = 1 ]; then
    read -r node_id hook_id < <(python3 -c "
import json; w = json.load(open('n8n/workflows/06-whatsapp-bot.json'))
t = next(n for n in w['nodes'] if n['name'] == 'WhatsApp Trigger'); print(t['id'], t['webhookId'])")
    check="http://localhost:5678/webhook/${hook_id}/webhook?hub.mode=subscribe&hub.challenge=1&hub.verify_token=${node_id}"
    for attempt in 1 2; do
      until curl -sf http://localhost:5678/healthz >/dev/null; do sleep 2; done
      sleep 12
      curl -sf -o /dev/null "$check" && break
      [ "$attempt" = 1 ] && { echo "WhatsApp Trigger not answering Meta's check yet: restarting n8n once more"; docker compose stop n8n; docker compose up -d n8n; }
    done
    curl -sf -o /dev/null "$check" || echo "WARNING: the WhatsApp Trigger still doesn't answer Meta's check: run scripts/bot-tunnel.sh" >&2
  fi
fi

echo
echo "Partner board is public at $url"

# the voice agent's Tori tools live on the board (/api/mcp): point Vapi at the new address
scripts/vapi-mcp.sh || echo "WARNING: couldn't update the voice agent's Tori tools: run scripts/vapi-mcp.sh" >&2
