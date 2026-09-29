# Tori Desk — Step 1 build plan (n8n + Postgres, all in Docker)

## 1. What we are building

```
Customer books on Playo
        │  Playo emails the owner's Gmail
        ▼
Owner's Gmail filter forwards ONLY Playo mail ──► <venue>-<token>@in.toridesk.com
        │  inbound provider (Postmark) POSTs JSON
        ▼
┌──────────────────────── n8n ─────────────────────────────────────────────────┐
│ [01 Inbound Email]  webhook → store raw email (PG) → 200 OK → route          │
│        │ playo email                 │ Gmail "confirm forwarding" email       │
│        ▼                             ▼                                        │
│ [02 Process Message]           code saved on venue + WhatsApp to Ravi         │
│   Groq LLM parser (strict JSON schema)                                         │
│   → tori.apply_parse()  ── ONE Postgres transaction ──────────────────────┐   │
│        booking + slots upsert · court/hours validation · clash check       │   │
│        · alerts · outbox rows (calendar + WhatsApp)                        │   │
│        │                                                                   │   │
│        ▼                                                                   │   │
│ [03 Dispatch Outbox]  (called right away + every 30 s for retries)        │   │
│   Google Calendar: create / update / delete / clash-mark (idempotent)     │   │
│   WhatsApp: booking card to tenant (owner), copy + ops alerts to Ravi     │   │
│   → tori.complete_job() (retry w/ backoff, dead-letter + alert)           │   │
│ [04 Monitor]  hourly: venues gone quiet, emails stuck, dead jobs          │   │
│ [05 Admin]    calendar test (onboarding), reprocess an email              │   │
└───────────────────────────────────────────────────────────────────────────────┘
```

Who sees what:

| Event | Tenant (venue owner) WhatsApp | Ravi (account manager) WhatsApp | Google Calendar |
|---|---|---|---|
| New booking | ✅ card | ✅ copy (pilot) | event created |
| Cancellation | ✅ | ✅ copy | event deleted |
| Clash (court already taken) | ✅ warning | ✅ alert, calls owner | both events marked ⚠ CLASH |
| Unreadable / invalid email | – | ✅ alert | ⚠ "Check Playo email" note |
| Gmail forwarding code (onboarding) | – | ✅ code, reads it out on the call | – |
| Calendar unshared / wrong ID | – | ✅ alert | – |
| Venue quiet > 24 h | – | ✅ alert | – |

## 2. Review of the Step 1 PDF — gaps and decisions

The plan is sound (thin, owner-light, Gmail filter + shared calendar). Things to fix before it goes live:

1. **Scope change: WhatsApp is in, not "not yet".** WhatsApp Cloud API can only send
   *business-initiated* messages with **pre-approved templates** (free text works only inside a
   24 h window after the recipient messaged you), and needs Meta Business verification.
   That is the longest lead-time item, so start it in week 1. Built with `WHATSAPP_MODE=text`
   (dev/mock) and `WHATSAPP_MODE=template` (prod).
2. **"Skip if booking ID seen" would drop every cancellation** (it has the same booking ID).
   Dedup must happen at two levels: the *email* (Message-ID / provider ID) and the *booking*
   (`UNIQUE(venue, playo_booking_id)` with a status machine). Cancellation arriving before the
   booking is handled (tombstone; the late confirmation stays cancelled).
3. **The Playo sender check alone is spoofable**, and `jpr1@in.toridesk.com` is guessable.
   Decisions: random token in every address (`jpr1-k7q2m9@…`), check Gmail's
   `X-Forwarded-For` matches the owner's Gmail, and the parser's booking ID must appear
   verbatim in the email. DKIM check is a later hardening step.
4. **The Gmail verification email is not from Playo**, so the pipeline in the PDF would drop it.
   It gets its own branch: code is extracted from the subject, saved on the venue and sent to Ravi.
5. **Never call Google inside the DB transaction.** Transactional outbox: commit booking +
   jobs together, then dispatch. Calendar event IDs are **deterministic** (`tori<slot uuid>`),
   so a retry can never create a duplicate (stronger than searching by `playoBookingId`,
   which is still written as a private extended property).
6. **Clash truth is Postgres, not the calendar.** Court rows are locked (`FOR UPDATE`) inside
   the transaction so two simultaneous bookings can't both miss each other. When one side is
   cancelled, the ⚠ is removed from the other. Walk-ins typed into the calendar are not seen
   yet (that is the "what comes next" item).
7. **Emails are messier than one slot.** One booking can cover several courts/hours;
   slots can cross midnight; a cancellation may cover some slots only; emails may omit the year.
   Parser returns `slots[]`; SQL converts local time → `timestamptz` in the venue's time zone;
   partial cancellations are supported; an ambiguous cancellation cancels **nothing** and
   alerts (a wrongly deleted event causes a double booking, which is worse than a phantom one).
8. **Unknown court / outside hours: don't drop it.** The booking is real on Playo, so the time
   is still blocked (⚠ in the title) and Ravi is alerted to fix the court mapping.
9. **LLM guard rails (Groq, `openai/gpt-oss-120b`).** Strict JSON schema; booking ID must be
   present in the source text; dates must be within −2 d … +180 d of receipt;
   15 min ≤ duration ≤ 12 h; refusals / truncation → "unreadable" path, never a guess. A garbled
   email with a booking-like subject is never silently classed "not a booking" (prompt rule +
   SQL safety net) — found in testing against real Groq.
   **Groq free tier = 8 000 tokens/min ≈ 6 emails/min.** A 429 keeps the email waiting (not
   counted as a failed attempt); workflow 04 retries every minute and alerts Ravi after 30 min.
   Before onboarding more than a couple of venues, move the key to Groq's paid Dev tier.
10. **Latency metric needs the original send time.** We keep the email `Date` header
    (≈ when Playo sent it) and `calendar_synced_at`; `tori.v_latency` gives the median.
11. **24 h quiet alert will be noisy** for small venues — threshold is per venue.
12. **Calendar access lost (403/404)** → venue marked `calendar_status=error`, Ravi alerted
    once a day, job retried with backoff (owner might re-share), then dead-lettered.
13. **Data (DPDP Act).** Calendar/WhatsApp only get masked phone (`******3210`); raw emails
    hold full PII → purge bodies after 90 days (`tori.purge_raw_bodies()`). Service-account
    key lives in a secret, never in Git (as the PDF says).

Open questions for the business side (defaults chosen, easy to change):
- Real Playo sender domain(s) and email format — default regex `(^|[@.])playo\.(co|io|club|in)$`.
  The fixtures are modelled guesses; confirm both from the pilot's real emails (week 1).
- Does Ravi want a copy of every booking, or only alerts? Default: every booking during the pilot (`staff.copy_bookings`).
- WhatsApp provider — built for Meta Cloud API; Interakt/Gupshup/Twilio need only the HTTP node changed.

## 3. Components (docker compose)

| Service | Image | Purpose |
|---|---|---|
| `postgres` | postgres:17-alpine | DB `tori` (app, schema `tori`) and DB `n8n` (n8n's own state) |
| `db-migrate` | postgres:17-alpine | one-shot, applies `db/migrations/*.sql` (tracked, idempotent) |
| `n8n-bootstrap` | n8n | one-shot: creates credentials from `.env`, imports + publishes workflows |
| `n8n` | n8nio/n8n:2.41.3 | the workflows, UI on :5678 |
| `mock-apis` | node:22-alpine | dev only (`COMPOSE_PROFILES=mock`): fake Google OAuth + Calendar, WhatsApp Graph, Groq LLM parser. Everything it receives is visible at :8090 |

Switching from mocks to real services = change URLs/keys in `.env`; the workflows are identical.

## 4. Data model (schema `tori`)

- `staff` — Tori people (Ravi): WhatsApp number, `copy_bookings`.
- `tenant` — the customer business: owner name + WhatsApp, `account_manager_id → staff`.
- `venue` — inbound address, owner Gmail, calendar ID, time zone, hours, status, calendar status, forwarding code, quiet threshold.
- `court` — Playo court name exactly as Playo writes it + aliases.
- `raw_message` — every inbound email (payload, headers, bodies), kind, status, parse result.
- `booking` — one per `(venue, playo_booking_id)`, status confirmed/cancelled.
- `booking_slot` — court + `[starts_at, ends_at)`, clash links, review reasons, deterministic calendar event ID, calendar sync state.
- `calendar_note` — "⚠ Check Playo email" notes for unreadable emails.
- `alert` — internal alerts, deduplicated.
- `outbox` — calendar + WhatsApp jobs: status, attempts, backoff, lease, last request/response.

Key functions (each call = one transaction): `store_raw_message`, `apply_parse`, `claim_jobs`,
`complete_job`, `check_monitors`, `create_venue`, `enqueue_calendar_test`, `reset_for_reprocess`.

## 5. Build order

1. Compose + Postgres schema + mock APIs.
2. Workflows 01 → 02 → 03, then 04/05.
3. Fixtures (Postmark-shaped JSON) for booking, multi-slot, cancellation, clash, unknown court,
   unreadable, duplicate, spoofed sender, Gmail verification.
4. `scripts/e2e.sh` drives all fixtures through the real webhook and asserts DB + mock state.

## 6. Going live (per the PDF's week plan)

1. Google Cloud: project, Calendar API, service account + JSON key → `GOOGLE_SERVICE_ACCOUNT_JSON_B64`.
2. Postmark inbound domain `in.toridesk.com` (MX) → webhook `https://<host>/webhook/inbound/postmark`
   with basic auth from `.env`.
3. `LLM_API_KEY` (Groq) + `LLM_BASE_URL=https://api.groq.com/openai/v1`, WhatsApp token + phone number ID + approved templates.
4. `COMPOSE_PROFILES=` (no mocks), point the `*_BASE_URL` vars at the real APIs, put n8n behind HTTPS.
5. Per venue: `SELECT tori.create_venue(...)`, the owner call, `/webhook/admin/calendar-test`.
