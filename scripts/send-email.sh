#!/usr/bin/env bash
# Post a fixture to the inbound webhook exactly like Postmark would.
#   scripts/send-email.sh fixtures/emails/01-booking-new.json
# Placeholders: {{DATE1}} = tomorrow, {{DATE2}} = day after, {{MSGID}}/{{PMID}} unique per send
# (set MSGID=... to resend the "same" email), {{NOW_RFC}} = now.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

fixture=${1:?usage: send-email.sh <fixture.json>}
url=${INBOUND_URL:-http://localhost:5678/webhook/inbound/postmark}
uuid() { cat /proc/sys/kernel/random/uuid; }
msgid=${MSGID:-"<$(uuid)@mail.playo.co>"}

payload=$(sed \
  -e "s/{{DATE1}}/$(TZ=Asia/Kolkata date -d '+1 day' '+%a, %d %b %Y')/g" \
  -e "s/{{DATE2}}/$(TZ=Asia/Kolkata date -d '+2 day' '+%a, %d %b %Y')/g" \
  -e "s/{{NOW_RFC}}/$(TZ=Asia/Kolkata date -R)/g" \
  -e "s/{{PMID}}/${PMID:-$(uuid)}/g" \
  -e "s/{{MSGID}}/${msgid}/g" \
  "$fixture")

curl -sS -u "$INBOUND_WEBHOOK_USER:$INBOUND_WEBHOOK_PASSWORD" -H 'content-type: application/json' \
  --data-binary "$payload" "$url"
echo
