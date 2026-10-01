#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=/tmp/tori-export
docker compose exec -T n8n sh -c "rm -rf $tmp && mkdir -p $tmp && n8n export:workflow --all --separate --pretty --output=$tmp >/dev/null"
for id in toriInboundEmail:01-inbound-email toriProcessEmail:02-parse-and-save toriDispatchJobs:03-dispatch-outbox \
          toriMonitorVenue:04-monitor toriAdminHookApi:05-admin-api; do
  docker compose exec -T n8n cat "$tmp/${id%%:*}.json" | python3 -c '
import json, sys
w = json.load(sys.stdin)
keep = ("id", "name", "description", "nodes", "connections", "settings", "pinData", "tags")
json.dump({k: w[k] for k in keep if k in w} | {"active": False}, sys.stdout, indent=2, ensure_ascii=False)
print()' > "n8n/workflows/${id##*:}.json"
  echo "exported ${id##*:}"
done
