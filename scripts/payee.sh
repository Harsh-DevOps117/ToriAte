#!/usr/bin/env bash
# ToriPay admin: add or change the businesses people can pay with "tori pay gym 500".
#   scripts/payee.sh add payee.json      add / update one (see below); the account number goes to RazorpayX only
#   scripts/payee.sh find gym            search, as the bot does
#   scripts/payee.sh owed                what Tori owes each business (not yet in their bank)
#   scripts/payee.sh settle fitzone-hsr "NEFT UTR123"   you paid it by bank transfer: mark it settled
# payee.json: { "handle": "fitzone-hsr", "display_name": "FitZone Gym", "category": "gym", "city": "Bangalore",
#   "area": "HSR Layout", "aliases": ["fitzone"], "owner_wa": "+91 98765 00001", "account_holder": "FITZONE FITNESS PVT LTD",
#   "ifsc": "HDFC0001234", "account_number": "50100123451234", "commission_bps": 0 }
# Uses TORI_ADMIN_KEY from .env and the web app on BOARD_PORT (default 3001). Delete payee.json afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY=$(grep '^TORI_ADMIN_KEY=' .env | cut -d= -f2- | tr -d "'\"")
PORT=$(grep '^BOARD_PORT=' .env | cut -d= -f2- | tr -d "'\"" || true)
WEB="${TORI_WEB:-http://localhost:${PORT:-3001}}"
[ -n "$KEY" ] || { echo "TORI_ADMIN_KEY missing in .env"; exit 1; }
api() { curl -sS -H "x-tori-admin: $KEY" -H 'content-type: application/json' "$@"; echo; }
case "${1:-}" in
  add)    api -X POST "$WEB/api/admin/payees" --data-binary @"${2:?payee.json}" ;;
  find)   api "$WEB/api/admin/payees?q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${2:?word}")" ;;
  owed)   api "$WEB/api/admin/payees/owed" ;;
  settle) api -X POST "$WEB/api/admin/payees/settle" \
            -d "$(python3 -c 'import json, sys; print(json.dumps({"handle": sys.argv[1], "reference": sys.argv[2]}))' "${2:?handle}" "${3:?reference}")" ;;
  *)      sed -n 2,10p "$0"; exit 1 ;;
esac
