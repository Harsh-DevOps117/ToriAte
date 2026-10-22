#!/usr/bin/env bash
# Tori Wallet end to end (scripts/wallet_e2e.py): a scratch Postgres with every migration, the mock server
# (fake Razorpay and RazorpayX) and the web app, all on localhost. Nothing touches the live stack or real Razorpay.
#   scripts/wallet-e2e.sh            run, then clean up
#   KEEP=1 scripts/wallet-e2e.sh     leave them running (web on :3121)
set -euo pipefail
cd "$(dirname "$0")/.."
PG=tori-wallet-e2e
export WALLET_E2E_PG=$PG WALLET_E2E_WEB=http://localhost:3121 WALLET_E2E_MOCK=http://localhost:18191
export RAZORPAY_KEY_ID=rzp_test_e2e RAZORPAY_KEY_SECRET=e2e-key-secret RAZORPAY_WEBHOOK_SECRET=e2e-webhook-secret
export WALLET_API_KEY=e2e-wallet-key TORI_ADMIN_KEY=e2e-admin-key RAZORPAYX_ACCOUNT_NUMBER=7878780080316316
LOG=$(mktemp -d)

# stop whatever listens on these ports: killing the backgrounded subshell leaves next-server running
free_ports() {
  for port in 3121 18191; do
    for pid in $(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$pid" 2>/dev/null || true; done
  done
}
cleanup() {
  if [ "${KEEP:-0}" != 1 ]; then
    free_ports
    [ -n "${WEB_PID:-}" ] && kill "$WEB_PID" 2>/dev/null || true
    [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
    docker rm -f "$PG" >/dev/null 2>&1 || true
    rm -rf "$LOG"
  fi
}
trap cleanup EXIT
free_ports

docker rm -f "$PG" >/dev/null 2>&1 || true
docker run -d --name "$PG" -e POSTGRES_PASSWORD=x -e POSTGRES_USER=tori_app -e POSTGRES_DB=tori \
  -p 127.0.0.1:15499:5432 postgres:17-alpine >/dev/null
until docker logs "$PG" 2>&1 | grep -q "PostgreSQL init process complete"; do sleep 1; done
until docker exec "$PG" pg_isready -q -U tori_app 2>/dev/null; do sleep 1; done
sleep 1
for f in $(ls db/migrations/*.sql | grep -v '\.repeatable\.sql$') db/migrations/*.repeatable.sql; do
  docker exec -i "$PG" psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 --single-transaction < "$f" >/dev/null 2>&1 \
    || { echo "migration failed: $f"; exit 1; }
done
for t in wallet toripay referrals; do
  echo "── SQL scenarios (db/tests/$t.sql)"
  docker exec -i "$PG" psql -q -U tori_app -d tori -v ON_ERROR_STOP=1 < db/tests/$t.sql 2>&1 | grep -E 'ok:|FAIL|ERROR' | sed 's/^psql:[^ ]* //'
done

PORT=18191 node mock-apis/server.js > "$LOG/mock.log" 2>&1 & MOCK_PID=$!
(cd web && npx next build >/dev/null 2>&1)
(cd web && DATABASE_URL=postgres://tori_app:x@localhost:15499/tori RAZORPAY_API_URL=$WALLET_E2E_MOCK/razorpay/v1 \
   npx next start -p 3121 > "$LOG/web.log" 2>&1) & WEB_PID=$!
until curl -sf -o /dev/null http://localhost:3121/wallet; do sleep 1; done
echo "── Wallet over HTTP (scripts/wallet_e2e.py)"
python3 scripts/wallet_e2e.py
