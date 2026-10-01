#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

F=fixtures/emails
MOCK=http://localhost:8090
N8N=http://localhost:5678
pass=0; fail=0
REAL_LLM=0; [[ "$LLM_BASE_URL" == *mock-apis* ]] || REAL_LLM=1
SETTLE_SECONDS=$([ $REAL_LLM = 1 ] && echo 300 || echo 60)

sql() { docker compose exec -T postgres psql -U tori_app -d tori -tAq -c "$1"; }
send() { scripts/send-email.sh "$@" >/dev/null; }
admin() { curl -sS -H "X-Tori-Admin-Key: $ADMIN_API_KEY" -H 'content-type: application/json' -d "$2" "$N8N/webhook/admin/$1"; }
mock() { curl -sS "$MOCK/_state"; }
check() {
  if [ "$2" == "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"
  else fail=$((fail + 1)); echo "  FAIL $1"; echo "       expected: $3"; echo "       actual:   $2"; fi
}
settle() {
  for _ in $(seq 1 "$SETTLE_SECONDS"); do
    busy=$(sql "SELECT (SELECT count(*) FROM tori.raw_message WHERE status = 'pending_parse')
                     + (SELECT count(*) FROM tori.outbox o JOIN tori.venue v ON v.id = o.venue_id
                        WHERE o.status IN ('pending', 'running') AND o.next_attempt_at < now() + interval '5 seconds'
                          AND (o.kind NOT LIKE 'calendar.%' OR v.calendar_id IS NOT NULL))")
    [ "$busy" = "0" ] && return 0
    sleep 1
  done
  echo "  (timed out waiting for the pipeline)"
}
event_summary() { mock | python3 -c "
import json,sys; s=json.load(sys.stdin)
evs=[e for c in s['calendars'].values() for e in c if e.get('extendedProperties',{}).get('private',{}).get('playoBookingId')=='$1' and e['status']=='$2']
print(' | '.join(sorted(e['summary'] for e in evs)))"; }
wa_count() { mock | python3 -c "
import json,sys; s=json.load(sys.stdin); print(sum(1 for m in s['whatsapp'] if m['to']=='$1' and '$2' in m['text']))"; }

for _ in $(seq 1 60); do curl -sf "$N8N/healthz" >/dev/null && break; sleep 2; done
up=$(docker inspect -f '{{.State.StartedAt}}' "$(docker compose ps -q n8n)")
age=$(( $(date +%s) - $(date -d "$up" +%s) ))
[ "$age" -lt 40 ] && { echo "(n8n just started, waiting $((40 - age))s)"; sleep $((40 - age)); }

echo "== reset"
sql "TRUNCATE tori.outbox, tori.alert, tori.calendar_note, tori.booking_slot, tori.booking, tori.raw_message RESTART IDENTITY CASCADE;
     UPDATE tori.venue SET last_playo_email_at = NULL, forwarding_code = NULL, calendar_status = 'unknown';
     UPDATE tori.venue SET calendar_id = NULL WHERE id = 2;
     DELETE FROM tori.court WHERE venue_id > 2; DELETE FROM tori.venue WHERE id > 2;" >/dev/null
curl -sS -X POST "$MOCK/_reset" >/dev/null
OWNER=919000000001; RAVI=919000000099

echo "== new booking"
MSGID="<fixed-01@mail.playo.co>" PMID="pm-fixed-01" send $F/01-booking-new.json; settle
check "booking stored" "$(sql "SELECT status FROM tori.booking WHERE playo_booking_id = 'PLY-8Q2K7M'")" "confirmed"
check "event in calendar" "$(event_summary PLY-8Q2K7M confirmed)" "Court 2 · Playo · Rahul S."
check "owner got WhatsApp" "$(wa_count $OWNER 'New Playo booking')" "1"
check "Ravi got a copy" "$(wa_count $RAVI 'New Playo booking')" "1"
check "phone masked" "$(sql "SELECT customer_phone_masked FROM tori.booking WHERE playo_booking_id = 'PLY-8Q2K7M'")" "******3210"

echo "== duplicates"
res=$(MSGID="<fixed-01@mail.playo.co>" PMID="pm-fixed-01" scripts/send-email.sh $F/01-booking-new.json)
check "provider retry ignored" "$(echo "$res" | python3 -c 'import json,sys;print(json.load(sys.stdin)["reason"])')" "provider retry of a stored email"
MSGID="<fixed-01@mail.playo.co>" send $F/01-booking-new.json; settle
check "same Message-ID marked duplicate" "$(sql "SELECT count(*) FROM tori.raw_message WHERE status = 'duplicate'")" "1"
check "still one event, one owner message" "$(event_summary PLY-8Q2K7M confirmed)/$(wa_count $OWNER 'New Playo booking')" "Court 2 · Playo · Rahul S./1"

echo "== multi-court booking"
send $F/02-booking-multi.json; settle
check "two events" "$(event_summary PLY-5T1N4B confirmed)" "Court 1 · Playo · Neha K. | Court 3 · Playo · Neha K."
check "pay at venue = unpaid" "$(sql "SELECT payment_status FROM tori.booking WHERE playo_booking_id = 'PLY-5T1N4B'")" "unpaid"

echo "== clash"
send $F/03-booking-clash.json; settle
check "new event marked CLASH" "$(event_summary PLY-9C3X2Z confirmed)" "⚠️ CLASH · Court 2 · Playo · Arjun R."
check "existing event marked CLASH" "$(event_summary PLY-8Q2K7M confirmed)" "⚠️ CLASH · Court 2 · Playo · Rahul S."
check "clash alert" "$(sql "SELECT count(*) FROM tori.alert WHERE kind = 'clash'")" "1"
check "owner warned" "$(wa_count $OWNER 'Double booking')" "1"
check "Ravi alerted" "$(wa_count $RAVI 'Double booking')" "1"

echo "== cancellation resolves the clash"
send $F/04-cancel-first-booking.json; settle
check "cancelled event deleted" "$(event_summary PLY-8Q2K7M cancelled)" "⚠️ CLASH · Court 2 · Playo · Rahul S."
check "other event no longer CLASH" "$(event_summary PLY-9C3X2Z confirmed)" "Court 2 · Playo · Arjun R."
check "owner told" "$(wa_count $OWNER 'booking cancelled')" "1"

echo "== needs review"
send $F/05-booking-unknown-court.json; send $F/06-booking-late-night.json; settle
check "unknown court flagged" "$(event_summary PLY-7U6K1D confirmed)" "⚠️ CHECK · Court 9 · Playo · Vikram I."
check "after-hours slot flagged" "$(event_summary PLY-3M8R6T confirmed)" "⚠️ CHECK · Court 1 · Playo · Sana K."
check "midnight crossing" "$(sql "SELECT ends_at - starts_at FROM tori.booking_slot s JOIN tori.booking b ON b.id = s.booking_id WHERE playo_booking_id = 'PLY-3M8R6T'")" "01:00:00"
check "review alerts" "$(sql "SELECT count(*) FROM tori.alert WHERE kind = 'needs_review'")" "2"

echo "== HTML-only email"
send $F/07-booking-html-only.json; settle
check "parsed from HTML" "$(event_summary PLY-2H5J8K confirmed)" "Court 3 · Playo · Karan S."

echo "== unreadable email"
send $F/08-unreadable.json; settle
check "marked parse_failed" "$(sql "SELECT status FROM tori.raw_message WHERE subject = 'Booking Confirmed - Smash Arena'")" "parse_failed"
check "note in calendar" "$(mock | python3 -c "import json,sys; s=json.load(sys.stdin); print(sum(1 for c in s['calendars'].values() for e in c if e['summary']=='⚠️ Check Playo email' and 'date' in e['start']))")" "1"
check "Ravi alerted" "$(wa_count $RAVI 'Could not read a Playo email')" "1"

echo "== ignored / rejected"
send $F/09-newsletter.json; send $F/10-spoofed-sender.json; send $F/11-wrong-forwarder.json; settle
check "newsletter ignored" "$(sql "SELECT status FROM tori.raw_message WHERE subject LIKE 'Your weekly%'")" "ignored"
check "spoofed sender rejected" "$(sql "SELECT status FROM tori.raw_message WHERE from_address = 'bookings@playo-offers.com'")" "rejected"
check "wrong forwarder rejected" "$(sql "SELECT status FROM tori.raw_message WHERE subject LIKE '%PLY-6W4E2R'")" "rejected"
check "no booking from either" "$(sql "SELECT count(*) FROM tori.booking WHERE playo_booking_id IN ('PLY-FAKE01', 'PLY-6W4E2R')")" "0"

echo "== Gmail forwarding code (onboarding)"
send $F/12-gmail-verification.json; settle
check "code saved on venue" "$(sql "SELECT forwarding_code FROM tori.venue WHERE id = 1")" "583920147"
check "code sent to Ravi" "$(wa_count $RAVI '583920147')" "1"
check "not sent to owner" "$(wa_count $OWNER '583920147')" "0"

echo "== cancellation before booking"
send $F/13-cancel-before-booking.json; settle; send $F/14-booking-after-cancel.json; settle
check "stays cancelled" "$(sql "SELECT status FROM tori.booking WHERE playo_booking_id = 'PLY-4L0Z8W'")" "cancelled"
check "no event created" "$(event_summary PLY-4L0Z8W confirmed)" ""

echo "== reschedule"
send $F/15-reschedule-multi.json; settle
check "only the new slot is live" "$(sql "SELECT string_agg(court || ' ' || to_char(s.starts_at AT TIME ZONE 'Asia/Kolkata', 'DD HH24:MI'), ',') FROM tori.v_bookings s WHERE playo_booking_id = 'PLY-5T1N4B' AND slot_status = 'active'")" "Court 1 $(TZ=Asia/Kolkata date -d '+2 day' +%d) 19:00"
check "calendar matches" "$(event_summary PLY-5T1N4B confirmed)" "Court 1 · Playo · Neha K."

echo "== Google 503 is retried"
curl -sS -X POST "$MOCK/_faults" -d '{"calendar_fail_next": 1}' >/dev/null
send $F/16-booking-calendar-retry.json
slot_job="SELECT o.status || '/' || o.last_status FROM tori.outbox o JOIN tori.booking_slot s ON s.id::text = o.ref
          JOIN tori.booking b ON b.id = s.booking_id WHERE b.playo_booking_id = 'PLY-1R2E3T' ORDER BY o.id DESC LIMIT 1"
for _ in $(seq 1 "$SETTLE_SECONDS"); do [ -n "$(sql "$slot_job")" ] && break; sleep 1; done
check "first attempt failed" "$(sql "$slot_job")" "pending/503"
sql "UPDATE tori.outbox SET next_attempt_at = now() WHERE status = 'pending'" >/dev/null
for _ in $(seq 1 40); do [ -n "$(event_summary PLY-1R2E3T confirmed)" ] && break; sleep 1; done
check "event created on retry" "$(event_summary PLY-1R2E3T confirmed)" "Court 1 · Playo · Meera J."

if [ $REAL_LLM = 1 ]; then
  echo "== (LLM fault injection needs the mock parser, skipped)"
else
echo "== LLM unavailable -> retried via reprocess"
curl -sS -X POST "$MOCK/_faults" -d '{"llm_fail_next": 1}' >/dev/null
send $F/17-booking-llm-retry.json; sleep 4
raw=$(sql "SELECT id FROM tori.raw_message WHERE subject LIKE '%PLY-0A9S8D'")
check "waiting for retry" "$(sql "SELECT status || '/' || parse_attempts FROM tori.raw_message WHERE id = $raw")" "pending_parse/1"
res=$(admin reprocess "{\"raw_id\": $raw}")
check "reprocess applied it" "$(echo "$res" | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')" "applied"
settle
check "event created" "$(event_summary PLY-0A9S8D confirmed)" "Court 2 · Playo · Farhan A."
fi

echo "== admin: calendar test"
res=$(admin calendar-test '{"venue": "smash-arena", "action": "create"}')
check "create ok" "$(echo "$res" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["ok"], d["http_status"])')" "True 200"
res=$(admin calendar-test '{"venue": "smash-arena", "action": "delete"}')
check "delete ok" "$(echo "$res" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["ok"], d["http_status"])')" "True 204"
res=$(admin calendar-test '{"venue": "smash-arena-2"}')
check "no calendar yet -> 400" "$(echo "$res" | python3 -c 'import json,sys;print(json.load(sys.stdin)["error"])')" "venue smash-arena-2 has no calendar_id yet"
sql "UPDATE tori.venue SET calendar_id = 'forbidden-annexe@group.calendar.google.com' WHERE id = 2" >/dev/null
res=$(admin calendar-test '{"venue": "smash-arena-2"}')
check "403 explained" "$(echo "$res" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["http_status"], d["hint"])')" '403 Permission is not "Make changes to events"'

echo "== admin: create venue"
res=$(admin venues '{"tenant_id": 1, "slug": "ace-courts", "name": "Ace Courts", "opens_at": "06:00", "closes_at": "22:00", "courts": ["Court A", "Court B"]}')
check "forwarding address issued" "$(echo "$res" | python3 -c 'import json,sys,re;d=json.load(sys.stdin);print(bool(re.fullmatch(r"ace-courts-[0-9a-f]{8}@in\.toridesk\.com", d["inbound_address"])), d["courts"])')" "True 2"

settle
echo "== pilot metrics"
check "latency measured for every booking" "$(sql "SELECT count(*) = count(seconds_to_calendar) FROM tori.v_latency")" "t"
sql "SELECT 'median seconds inside Tori: ' || round(median_seconds_inside_tori::numeric, 1) FROM tori.v_latency_summary"
check "no dead jobs" "$(sql "SELECT count(*) FROM tori.outbox WHERE status = 'dead'")" "0"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
