#!/usr/bin/env bash
# Travel partner matching, tested end to end in a throwaway stack. The live stack is not touched.
#   - Docker project "toritravel": its own volumes, ports 15433 (Postgres), 15678 (n8n), 18090 (mocks)
#   - real Groq (LLM_API_KEY from .env), mock WhatsApp + mock geocoder + fake Razorpay (mock-apis)
#   - the web app (ToriPay's /api/toripay/answer and payouts), port 13001
#   - workflow 06 is imported as a copy whose WhatsApp Trigger is a plain webhook (POST /webhook/wa-test)
# Runs the db/tests/*.sql scenarios, then scripts/travel_e2e.py, profile_e2e.py, name_e2e.py, mcp_e2e.py and referral_e2e.py
# (~8 minutes: Groq free-tier pacing).
#
#   scripts/travel-e2e.sh          run, then remove the stack
#   KEEP=1 scripts/travel-e2e.sh   leave it running afterwards (n8n UI: http://localhost:15678)
#   E2E_ONLY=profile scripts/travel-e2e.sh    run only the profile conversation
#   E2E_ONLY=referral scripts/travel-e2e.sh   run only the referral one (~1 minute, no LLM calls)
#   E2E_ONLY=name scripts/travel-e2e.sh       run only "Please confirm your name" (~2 minutes)
#   E2E_ONLY=mcp scripts/travel-e2e.sh        run only the voice agent's Tori tools (~2 minutes)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
T=$(mktemp -d)
LLM_KEY=$(grep '^LLM_API_KEY=' .env | cut -d= -f2- | tr -d "'\"")
[ -n "$LLM_KEY" ] || { echo "LLM_API_KEY missing in .env"; exit 1; }

mkdir -p "$T/n8n/workflows"
cp -r n8n/bootstrap "$T/n8n/"
cp n8n/workflows/0[789]-travel-*.json n8n/workflows/1[012]-travel-*.json "$T/n8n/workflows/"
python3 - n8n/workflows/06-whatsapp-bot.json "$T/n8n/workflows/06-test.json" <<'PY'
import json, sys
w = json.load(open(sys.argv[1]))
t = next(n for n in w['nodes'] if n['name'] == 'WhatsApp Trigger')
pos = t['position']
t.clear()
# Meta-shaped bodies (the voice relay posts those) are checked and unwrapped like the real WhatsApp Trigger
# does: a wrong x-hub-signature-256 is dropped silently, exactly as in production
t.update({'parameters': {'jsCode': '''const crypto = require('crypto');
const out = [];
for (const i of $input.all()) {
  const b = i.json.body;
  if (!(b && b.entry)) { out.push({ json: b }); continue; }
  const want = 'sha256=' + crypto.createHmac('sha256', $env.BOT_META_APP_SECRET || '').update(JSON.stringify(b)).digest('hex');
  if (!$env.BOT_META_APP_SECRET || i.json.headers['x-hub-signature-256'] !== want) continue;
  out.push({ json: { ...b.entry[0].changes[0].value, field: 'messages' } });
}
return out;'''},
          'id': '11111111-1111-4111-8111-111111111111', 'name': 'WhatsApp Trigger', 'type': 'n8n-nodes-base.code',
          'typeVersion': 2, 'position': pos})
w['nodes'].append({'parameters': {'httpMethod': 'POST', 'path': 'wa-test', 'options': {}},
                   'id': '22222222-2222-4222-8222-222222222222', 'name': 'Test inbound', 'type': 'n8n-nodes-base.webhook',
                   'typeVersion': 2, 'position': [pos[0] - 260, pos[1]], 'webhookId': '33333333-3333-4333-8333-333333333333'})
w['connections']['Test inbound'] = {'main': [[{'node': 'WhatsApp Trigger', 'type': 'main', 'index': 0}]]}
w['id'], w['name'] = 'toriWhatsAppTest', 'TEST 06 (webhook trigger)'
json.dump(w, open(sys.argv[2], 'w'))
PY

cat > "$T/test.env" <<EOF
COMPOSE_PROFILES=mock
TZ=Asia/Kolkata
POSTGRES_PASSWORD=pg-test
TORI_DB_PASSWORD=tori-test
N8N_DB_PASSWORD=n8n-test
N8N_ENCRYPTION_KEY=travel-e2e-throwaway-key-000000
N8N_HOST=localhost
WEBHOOK_URL=http://localhost:15678/
N8N_OWNER_EMAIL=test@example.com
N8N_OWNER_PASSWORD=TestPass123!
N8N_OWNER_FIRST_NAME=Test
N8N_OWNER_LAST_NAME=Run
INBOUND_WEBHOOK_USER=postmark
INBOUND_WEBHOOK_PASSWORD=x
ADMIN_API_KEY=x
LLM_BASE_URL=https://api.groq.com/openai/v1
LLM_API_KEY=$LLM_KEY
LLM_MODEL=openai/gpt-oss-120b
GOOGLE_TOKEN_URI=http://mock-apis:8090/google/token
GCAL_BASE_URL=http://mock-apis:8090/google/calendar/v3
WHATSAPP_BASE_URL=http://mock-apis:8090/whatsapp/v21.0
WHATSAPP_PHONE_NUMBER_ID=100000000000001
WHATSAPP_TOKEN=mock-token
WHATSAPP_MODE=text
WHATSAPP_TEMPLATE_LANG=en
BOT_ENABLED=0
BOT_WHATSAPP_PHONE_NUMBER_ID=100000000000002
BOT_WHATSAPP_TOKEN=mock-token
BOT_WHATSAPP_GRAPH_URL=http://mock-apis:8090/whatsapp/v19.0
TRAVEL_GEOCODER=nominatim
TRAVEL_GEOCODER_URL=http://mock-apis:8090/geocode/search
TRAVEL_GEOCODER_USER_AGENT=ToriWhatsAppBot/1.0-test
TRAVEL_MATCH_TEMPLATE=travel_match_found
TRAVEL_TRIP_FLOW_ID=mock-flow-1
TRAVEL_TRIP_FLOW_MODE=draft
BOARD_PUBLIC_URL=https://board.test
BOARD_WHATSAPP_NUMBER=15550001111
TORI_MCP_KEY=e2e-mcp-key
TORI_BOT_INBOUND_URL=http://n8n:5678/webhook/wa-test
BOT_RELAY_URL=http://localhost:5678/webhook/wa-test
BOT_META_APP_SECRET=e2e-test-app-secret
WALLET_API_KEY=e2e-wallet-key
WALLET_DEMO=1
TORI_WEB_URL=http://web:3000
RAZORPAY_KEY_ID=rzp_test_e2e
RAZORPAY_KEY_SECRET=e2e-key-secret
RAZORPAY_WEBHOOK_SECRET=e2e-webhook-secret
RAZORPAY_API_URL=http://mock-apis:8090/razorpay/v1
IFSC_API_URL=http://mock-apis:8090/ifsc
EOF
cat > "$T/override.yml" <<EOF
services:
  postgres:
    ports: !override ["127.0.0.1:15433:5432"]
  mock-apis:
    ports: !override ["127.0.0.1:18090:8090"]
  web:
    ports: !override ["127.0.0.1:13001:3000"]
  n8n-bootstrap:
    volumes: !override
      - n8ndata:/home/node/.n8n
      - $T/n8n:/opt/tori/n8n:ro,z
  n8n:
    ports: !override ["127.0.0.1:15678:5678"]
    volumes: !override
      - n8ndata:/home/node/.n8n
      - $T/n8n:/opt/tori/n8n:ro,z
EOF

DC=(docker compose -p toritravel --env-file "$T/test.env" -f docker-compose.yml -f "$T/override.yml")
cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then "${DC[@]}" down -v >/dev/null 2>&1 || true; rm -rf "$T"; fi
}
trap cleanup EXIT
"${DC[@]}" up -d --build --wait postgres mock-apis n8n web >/dev/null
until curl -sf http://localhost:15678/healthz >/dev/null; do sleep 2; done
sleep 5

echo "── SQL scenarios (db/tests/travel_matching.sql, user_profiles.sql, held_messages.sql, matching_v2.sql, joins.sql, wallet.sql, toripay.sql, referrals.sql, name_confirm.sql)"
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/travel_matching.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/user_profiles.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/held_messages.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/matching_v2.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/joins.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/wallet.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/toripay.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/referrals.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
docker exec -i toritravel-postgres-1 psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/name_confirm.sql 2>&1 \
  | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
status=0
if [ -z "${E2E_ONLY:-}" ]; then
  echo "── End to end (scripts/travel_e2e.py)"
  python3 "$ROOT/scripts/travel_e2e.py" || status=1
fi
if [ -z "${E2E_ONLY:-}" ] || [ "${E2E_ONLY:-}" = profile ]; then
  echo "── Profile onboarding end to end (scripts/profile_e2e.py)"
  python3 "$ROOT/scripts/profile_e2e.py" || status=1
fi
if [ -z "${E2E_ONLY:-}" ] || [ "${E2E_ONLY:-}" = name ]; then
  echo "── Name confirmation end to end (scripts/name_e2e.py)"
  python3 "$ROOT/scripts/name_e2e.py" || status=1
fi
if [ -z "${E2E_ONLY:-}" ] || [ "${E2E_ONLY:-}" = mcp ]; then
  echo "── Voice agent's Tori tools end to end (scripts/mcp_e2e.py)"
  python3 "$ROOT/scripts/mcp_e2e.py" || status=1
fi
if [ -z "${E2E_ONLY:-}" ] || [ "${E2E_ONLY:-}" = referral ]; then
  echo "── Referrals end to end (scripts/referral_e2e.py)"
  python3 "$ROOT/scripts/referral_e2e.py" || status=1
fi
exit $status
