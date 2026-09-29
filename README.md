# Tori Desk · Step 1 — Playo emails → Postgres → Google Calendar + WhatsApp

Playo booking emails are forwarded from the owner's Gmail to a per-venue address. n8n stores each
email, a Groq LLM reads it into strict JSON, and one Postgres transaction saves the booking,
checks for clashes and queues the side effects. A dispatcher then writes Google Calendar and sends
WhatsApp messages to the tenant (venue owner) and Ravi (account manager).

Plan, and the review of the Step 1 PDF: [docs/PLAN.md](docs/PLAN.md).

## Run it

```bash
cp .env.example .env        # then set secrets; LLM_API_KEY = your Groq key
echo SEED_DEV=1 >> .env     # demo venue "Smash Arena", owner + Ravi WhatsApp numbers
docker compose up -d        # postgres → migrations → n8n bootstrap → n8n → owner account
```

| What | Where |
|---|---|
| n8n editor | http://localhost:5678 (login from `N8N_OWNER_EMAIL` / `N8N_OWNER_PASSWORD`) |
| Mock Google Calendar + WhatsApp inbox | http://localhost:8090 (only with `COMPOSE_PROFILES=mock`) |
| Postgres | `localhost:5433`, db `tori`, user `tori_app` |
| Inbound webhook (Postmark) | `POST /webhook/inbound/postmark`, basic auth `INBOUND_WEBHOOK_*` |
| Admin API | `POST /webhook/admin/{venues,calendar-test,reprocess}`, header `X-Tori-Admin-Key` |

`LLM_BASE_URL` picks the parser: `https://api.groq.com/openai/v1` (real) or
`http://mock-apis:8090/groq/openai/v1` (regex stand-in, fixture format only). Calendar and WhatsApp
go to the mock until their `*_BASE_URL` / keys in `.env` point at the real APIs.

## Try it

```bash
scripts/send-email.sh fixtures/emails/01-booking-new.json    # then watch http://localhost:8090
scripts/send-email.sh fixtures/emails/03-booking-clash.json  # both events turn ⚠️ CLASH
scripts/e2e.sh                                               # full suite (wipes booking data)
```

`e2e.sh` covers 17 scenarios: new, duplicate and multi-court bookings, a clash and its
resolution, unknown court, after-hours/midnight, HTML-only email, unreadable email, a newsletter,
a spoofed sender, the wrong forwarder, the Gmail forwarding code, a cancellation before its
booking, a reschedule, a Google 503 retry, an LLM outage, and the admin endpoints. With the mock
parser it takes about 1 minute (49 checks). Against real Groq it takes about 15 minutes, because
the free tier allows 8k tokens/min.

## How it fits together

| Workflow | Trigger | Does |
|---|---|---|
| 01 Inbound email | Postmark webhook | normalise → `tori.store_raw_message()` → 200 → route |
| 02 Parse + save booking | called by 01 / 04 / 05 | Groq (JSON schema) → `tori.apply_parse()` (**one transaction**) |
| 03 Dispatch calendar + WhatsApp | every 30 s + called | `tori.claim_jobs()` → Google / WhatsApp → `tori.complete_job()` |
| 04 Monitor | every minute | quiet venues, parser retries, stuck-email alerts |
| 05 Admin API | webhooks | create venue, calendar test (404/403 hints), reprocess an email |

The business rules live in Postgres ([db/migrations/002_functions.repeatable.sql](db/migrations/002_functions.repeatable.sql)).
The workflows only move data between systems. Calendar event IDs are deterministic, so a retry
can never create a duplicate event. WhatsApp jobs are deduplicated per event and recipient.

## Everyday ops (psql)

```sql
SELECT * FROM tori.v_open_alerts;                 -- what needs a human
SELECT * FROM tori.v_bookings ORDER BY starts_at; -- bookings as the calendar should show them
SELECT * FROM tori.v_latency_summary;             -- pilot metric: Playo email → calendar
SELECT * FROM tori.v_outbox_health;               -- pending / dead jobs
UPDATE tori.alert SET acknowledged_at = now(), acknowledged_by = 'ravi' WHERE id = 42;
UPDATE tori.court SET aliases = aliases || 'Badminton Ct 2' WHERE venue_id = 1 AND playo_name = 'Court 2';
SELECT tori.purge_raw_bodies(90);                 -- DPDP: drop email bodies after 90 days
```

## Onboarding a venue (the PDF's per-venue steps)

```bash
H="X-Tori-Admin-Key: $ADMIN_API_KEY"
curl -H "$H" -d '{"tenant_name":"Ace Sports","owner_name":"…","owner_whatsapp":"+91…","account_manager_id":1,
  "slug":"ace-courts","name":"Ace Courts","owner_gmail":"owner@gmail.com","opens_at":"06:00","closes_at":"23:00",
  "courts":["Court A","Court B"]}' localhost:5678/webhook/admin/venues      # → forwarding address
# owner adds the address in Gmail → Ravi gets the code on WhatsApp → reads it out (B2)
psql: UPDATE tori.venue SET calendar_id = '…@group.calendar.google.com' WHERE slug = 'ace-courts';
curl -H "$H" -d '{"venue":"ace-courts","action":"create"}' localhost:5678/webhook/admin/calendar-test
curl -H "$H" -d '{"venue":"ace-courts","action":"delete"}' localhost:5678/webhook/admin/calendar-test
psql: UPDATE tori.venue SET status = 'live' WHERE slug = 'ace-courts';   -- enables quiet alerts
```

## Editing workflows

Workflows can be edited in the n8n UI. Afterwards, run `scripts/export-workflows.sh` to write them
back to `n8n/workflows/` for Git. `docker compose up` re-imports and republishes on every start.
After a restart, n8n can keep serving the previously published version for about 20 s. Emails
that arrive during that window are not lost: they wait as `pending_parse` and workflow 04
retries them.

## Going live

1. Google Cloud: create the service account and its key, then set `GOOGLE_SERVICE_ACCOUNT_JSON_B64`, `GOOGLE_TOKEN_URI=https://oauth2.googleapis.com/token` and `GCAL_BASE_URL=https://www.googleapis.com/calendar/v3`.
2. Postmark inbound for `in.toridesk.com`: point it at `https://<host>/webhook/inbound/postmark` with basic auth, and set `WEBHOOK_URL`.
3. WhatsApp Cloud API: set `WHATSAPP_BASE_URL=https://graph.facebook.com/v21.0`, the token, and the phone number ID. Set `WHATSAPP_MODE=template` and get these templates approved, each with 3 body params: `tori_booking_new`, `tori_booking_updated`, `tori_booking_modified`, `tori_booking_cancelled`, `tori_clash`, `tori_alert`.
4. Set `COMPOSE_PROFILES=` (no mocks), put n8n behind HTTPS, and don't set `SEED_DEV`.
