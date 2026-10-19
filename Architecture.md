# Tori Desk · Step 1 — Architecture

This document explains how Tori Desk Step 1 is built: what runs where, how a booking email turns
into a Google Calendar event and WhatsApp messages, what every n8n node does, and why it was built
this way. For the review of the original Step 1 PDF and the open business questions, see
[docs/PLAN.md](docs/PLAN.md). For day-to-day commands, see [README.md](README.md).

The same Docker stack also runs a second, separate system: the **Tori WhatsApp bot** (workflow 06),
where people chat with Tori directly, including the "Find a partner" feature. Sections 1–17 describe
the booking-email pipeline. [Section 18](#18-the-whatsapp-bot-and-partner-matching-workflow-06)
describes the bot, [section 19](#19-travel-partner-matching-workflows-0712) travel matching, and
[section 20](#20-profiles-cards-joins-and-the-board) what was added in October 2026: profiles, profile
cards, radius matching, saved messages, the partner board and joining games.

## Contents

1. [The problem in one paragraph](#1-the-problem-in-one-paragraph)
2. [The big picture](#2-the-big-picture)
3. [Design principles](#3-design-principles)
4. [Containers and startup order](#4-containers-and-startup-order)
5. [Data model](#5-data-model)
6. [Workflow 01 · Inbound email](#6-workflow-01--inbound-email)
7. [Workflow 02 · Parse + save booking](#7-workflow-02--parse--save-booking)
8. [Workflow 03 · Dispatch calendar + WhatsApp](#8-workflow-03--dispatch-calendar--whatsapp)
9. [Workflow 04 · Monitor](#9-workflow-04--monitor)
10. [Workflow 05 · Admin API](#10-workflow-05--admin-api)
11. [Postgres functions reference](#11-postgres-functions-reference)
12. [Lifecycles (state machines)](#12-lifecycles-state-machines)
13. [Failure handling](#13-failure-handling)
14. [Security and privacy](#14-security-and-privacy)
15. [Mock APIs and testing](#15-mock-apis-and-testing)
16. [Repository map](#16-repository-map)
17. [What changed when District was added](#17-what-changed-when-district-was-added)
18. [The WhatsApp bot and partner matching (workflow 06)](#18-the-whatsapp-bot-and-partner-matching-workflow-06)
19. [Travel partner matching (workflows 07–12)](#19-travel-partner-matching-workflows-0712)
20. [Profiles, cards, joins and the board](#20-profiles-cards-joins-and-the-board)
21. [Tori Wallet](#21-tori-wallet)
22. [ToriPay](#22-toripay)

---

## 1. The problem in one paragraph

A sports venue sells court time on booking platforms (Playo, District by Zomato). Each platform
emails the venue owner when a booking is made, changed or cancelled. The owner also sells walk-in
slots. If a court is sold twice (two platforms, or a platform and a walk-in), the venue has a
double booking. Tori Desk reads those emails automatically, puts every booking into the venue's
shared Google Calendar within seconds, warns about clashes, and keeps the owner (the "tenant") and
Tori's account manager (Ravi) informed on WhatsApp.

## 2. The big picture

```mermaid
flowchart TD
    P[Playo / District] -->|booking email| G[Owner's Gmail]
    G -->|filter forwards only platform mail| PM[Postmark inbound<br/>venue-token@in.toridesk.com]
    PM -->|POST JSON| W01

    subgraph n8n
      W01[01 Inbound email] -->|action = parse| W02[02 Parse + save booking]
      W01 -->|action = dispatch| W03
      W02 -->|kick| W03[03 Dispatch calendar + WhatsApp]
      W04[04 Monitor<br/>every minute] -->|retry stuck emails| W02
      W04 --> W03
      W05[05 Admin API] --> W02
      W05 --> W03
      T30[every 30 s] --> W03
    end

    W02 <-->|read email / save in one transaction| DB[(Postgres<br/>schema tori)]
    W01 <-->|store raw email| DB
    W03 <-->|claim jobs / complete jobs| DB
    W04 <--> DB
    W05 <--> DB

    W02 -->|strict JSON schema| LLM[Groq LLM]
    W03 --> GC[Google Calendar]
    W03 --> WA[WhatsApp Cloud API]
```

In words:

1. The owner's Gmail forwards platform emails to a per-venue address such as
   `smash-arena-k7q2m9ab@in.toridesk.com`.
2. Postmark receives the email and POSTs it as JSON to n8n.
3. **Workflow 01** stores the raw email in Postgres first, answers Postmark with HTTP 200, then
   decides what to do with it.
4. **Workflow 02** asks a Groq LLM to read the email into strict JSON, then calls one Postgres
   function, `tori.apply_parse()`, which saves the booking, checks for clashes and queues all
   side effects (calendar writes, WhatsApp messages, alerts) in a single transaction.
5. **Workflow 03** picks up the queued jobs and talks to Google Calendar and WhatsApp, retrying on
   failure.
6. **Workflow 04** watches for problems (quiet venues, emails stuck waiting for the parser).
7. **Workflow 05** is a small admin HTTP API for onboarding and fixing things.

## 3. Design principles

These decisions shape everything below. Each one exists because the simpler version breaks in a
specific, realistic way.

| Principle | What it means here | What it prevents |
|---|---|---|
| **Store first, then think** | 01 writes the raw email to Postgres before anything else, and only then replies 200. | Losing an email if the LLM, Google or n8n itself fails mid-way. Any email can be reprocessed later. |
| **Business rules live in Postgres** | n8n workflows only move data between systems. Validation, clash detection, message wording and retry policy are SQL functions in [002_functions.repeatable.sql](db/migrations/002_functions.repeatable.sql). | Logic spread across dozens of n8n nodes that can't be tested or reviewed as code. One transaction can do everything atomically. |
| **Transactional outbox** | `apply_parse()` never calls Google or WhatsApp. It inserts rows into `tori.outbox` in the same transaction as the booking. Workflow 03 sends them afterwards. | A booking saved but its calendar event never created (or the reverse), and slow HTTP calls holding database locks. |
| **Idempotent everywhere** | Emails are deduplicated by provider ID and Message-ID. Bookings are unique per `(venue, source, booking ID)`. Calendar event IDs are deterministic (`tori` + slot UUID). WhatsApp jobs have a dedupe key per event and recipient. | Duplicate calendar events or duplicate WhatsApp messages when anything is retried. |
| **Postgres is the source of truth for clashes** | Clashes are computed from `booking_slot` rows with the court rows locked (`FOR UPDATE`), not by reading the calendar. | Two bookings for the same court arriving at the same moment both missing each other. |
| **Never guess, never silently drop** | If the parser is unsure, the booking still blocks the calendar (marked ⚠️ CHECK) and Ravi is alerted. If an email can't be read, a "⚠️ Check Playo email" note goes into the calendar. An ambiguous cancellation cancels nothing. | A dropped booking or a wrongly deleted event, both of which cause real double bookings. |
| **Jobs read current state, not a snapshot** | A calendar job only holds a slot ID. When 03 claims it, `build_request()` builds the event from the slot's state *at that moment*. | Sending a stale event (e.g. creating an event for a booking that was cancelled while the job waited). |
| **Same workflows for dev and prod** | All external URLs come from `.env`. The mock server imitates Google, WhatsApp and Groq. | "Works in dev" workflows that differ from production. |

## 4. Containers and startup order

Defined in [docker-compose.yml](docker-compose.yml). `docker compose up -d` starts them in this order:

```mermaid
flowchart LR
    PG[postgres] --> MIG[db-migrate<br/>one-shot]
    MIG --> BOOT[n8n-bootstrap<br/>one-shot]
    BOOT --> N8N[n8n]
    N8N --> OWN[n8n-owner<br/>one-shot]
    N8N --> TUN[tunnel<br/>profile: tunnel]
    MOCK[mock-apis<br/>profile: mock]
```

| Service | Image | Runs | What it does |
|---|---|---|---|
| `postgres` | postgres:17-alpine | always | Holds two databases: `tori` (the app, owned by role `tori_app`) and `n8n` (n8n's own state, owned by role `n8n`). On first start, [db/init/00-create-databases.sh](db/init/00-create-databases.sh) creates both roles and databases. Exposed only on `127.0.0.1:5433`. The healthcheck waits until the `n8n` database exists. |
| `db-migrate` | postgres:17-alpine | once, then exits | Runs [db/migrate.sh](db/migrate.sh). Applies versioned migrations (`001_…`, `003_…`, `004_…`) exactly once each, then re-applies `*.repeatable.sql` files whenever their checksum changes. Applied files are tracked in `tori_meta.migration`. With `SEED_DEV=1` it also loads [db/seed/dev_seed.sql](db/seed/dev_seed.sql) (demo venue "Smash Arena", owner, Ravi). |
| `n8n-bootstrap` | n8nio/n8n:2.41.3 | once, then exits | Runs [n8n/bootstrap/bootstrap.sh](n8n/bootstrap/bootstrap.sh): creates the credentials from `.env` ([make-credentials.js](n8n/bootstrap/make-credentials.js)), imports all workflows from `n8n/workflows/`, and publishes (activates) each one. Workflow 06 is published only when `BOT_ENABLED=1` and the `BOT_META_*` values are set (see [section 18](#18-the-whatsapp-bot-and-partner-matching-workflow-06)). Runs on every `up`, so the Git copy of the workflows always wins. |
| `n8n` | n8nio/n8n:2.41.3 | always | The workflow engine and editor UI on `127.0.0.1:5678`. Reads env vars for API URLs. `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` lets nodes read `$env`. `NODE_FUNCTION_ALLOW_BUILTIN=crypto` lets the Google Calendar node sign JWTs. Executions are pruned after 14 days. |
| `n8n-owner` | n8nio/n8n:2.41.3 | once, then exits | Runs [setup-owner.js](n8n/bootstrap/setup-owner.js): creates the n8n owner login from `N8N_OWNER_*`, or does nothing if one exists. |
| `mock-apis` | node:22-alpine | only with `COMPOSE_PROFILES=mock` | [mock-apis/server.js](mock-apis/server.js): fake Google OAuth + Calendar, WhatsApp Graph API and Groq parser, plus a live dashboard on `127.0.0.1:8090`. See [section 15](#15-mock-apis-and-testing). |
| `tunnel` | cloudflare/cloudflared:2026.9.3 | only with profile `tunnel` | A Cloudflare quick tunnel that gives n8n a public `https://…trycloudflare.com` address, so Meta can deliver WhatsApp messages to workflow 06. Started by [scripts/bot-tunnel.sh](scripts/bot-tunnel.sh), which also writes the address into `WEBHOOK_URL`. |

### n8n credentials (created by bootstrap)

| ID | Name | Type | Used by |
|---|---|---|---|
| `toriPostgres0001` | Tori DB | Postgres | every Postgres node |
| `toriInboundAuth1` | Inbound email webhook (basic auth) | HTTP basic auth | 01 · Postmark inbound |
| `toriAdminApiKey1` | Admin webhook key | header `X-Tori-Admin-Key` | 05 · all three webhooks |
| `toriGroqApiKey01` | Groq API key | header `Authorization: Bearer …` | 02 · Groq · read email |
| `toriWhatsAppTokn` | WhatsApp Cloud API token | header `Authorization: Bearer …` | 03 · WhatsApp · send |
| `xzG9f2LEMKhGXmqg` | Postgres account | Postgres | 06 · all Postgres nodes (defaults to this repo's `tori` database; `BOT_PG_*` can point it elsewhere) |
| `toriWhatsAppHdr1` | WhatsApp Cloud API | header `Authorization: Bearer …` | 06 · partner-matching send nodes (only when `BOT_WHATSAPP_TOKEN` is set) |
| `80D44U2jieTOLmHl` | WhatsApp OAuth account | Meta App ID + App secret | 06 · WhatsApp Trigger (only when `BOT_META_APP_ID/SECRET` are set) |
| `23Tzwnj8bHd9gRZ3` | Supabase account | Supabase URL + service key | 06 · older booking / cab-share nodes (only when `BOT_SUPABASE_*` are set) |

Workflow 06's credential IDs are the ones from the n8n Cloud instance it was exported from, so the
nodes find their credentials without edits.

Google Calendar is not an n8n credential. The service-account key is passed to the `n8n`
container as `GOOGLE_SERVICE_ACCOUNT_JSON_B64` and the Code node signs its own JWT (see
[section 8](#8-workflow-03--dispatch-calendar--whatsapp)).

## 5. Data model

Everything lives in schema `tori`. Tables are created in [001_schema.sql](db/migrations/001_schema.sql)
and adjusted for multiple platforms in [003_booking_sources.sql](db/migrations/003_booking_sources.sql).

```mermaid
erDiagram
    staff ||--o{ tenant : "account manager of"
    tenant ||--o{ venue : owns
    venue ||--o{ court : has
    venue ||--o{ raw_message : receives
    booking_source ||--o{ raw_message : "sent by"
    booking_source ||--o{ booking : "came from"
    venue ||--o{ booking : has
    booking ||--o{ booking_slot : "one per court + time range"
    court ||--o{ booking_slot : "blocked by"
    raw_message ||--o| calendar_note : "unreadable →"
    venue ||--o{ alert : raises
    venue ||--o{ outbox : "jobs for"
```

| Table | One row is | Key columns and rules |
|---|---|---|
| `setting` | a tunable value | `inbound_domain`, `gmail_verification_sender`, `parse_max_attempts` (3), `review_past_days` (2), `review_future_days` (180). Read with `tori.cfg(key)`. |
| `booking_source` | a booking platform | `code` (`playo`, `district`), `label`, `sender_regex` (From address must match), `forwarded_from_regex` (for emails the owner forwarded by hand). Adding a platform = inserting a row. |
| `staff` | a Tori person (Ravi) | WhatsApp number, `copy_bookings` (gets a copy of every booking message), `is_ops_default` (receives alerts when a tenant has no account manager). |
| `tenant` | a customer business | owner name + WhatsApp, `notify_owner`, `account_manager_id → staff`. |
| `venue` | a physical venue | `inbound_address` (unique, with random token), `owner_gmail`, `calendar_id`, `timezone`, `opens_at`/`closes_at`, `status` (`onboarding`/`live`/`paused`), `calendar_status` (`unknown`/`ok`/`error`), `quiet_alert_hours`, `forwarding_code`, `last_booking_email_at`. |
| `court` | a court at a venue | `name` as the platform writes it, optional `display_name`, `aliases[]` (e.g. "Badminton Court 2" → Court 2). |
| `raw_message` | every inbound email, ever | full payload, headers, bodies, `kind`, `source`, `status`, `parse_result`, `parse_attempts`. Unique on `(provider, provider_message_id)`. |
| `booking` | one platform booking | unique on `(venue_id, source, source_booking_id)`, `status` `confirmed`/`cancelled`, customer name, **masked** phone, amount, payment status, first/last email that touched it. |
| `booking_slot` | one court for one continuous time range | `[starts_at, ends_at)` as `timestamptz`, `court_id` (null if unknown court), `review_reasons[]`, `clash_with[]` (other slot IDs), `gcal_event_id` (deterministic), `calendar_state`, `first_synced_at` (for the latency metric). GiST index on `(court_id, time range)` for fast overlap checks. |
| `calendar_note` | an all-day "⚠️ Check Playo email" note | created when an email can't be read, resolved (deleted from the calendar) when it is later reprocessed successfully. |
| `alert` | something a human must look at | `kind`, `severity` (`info`/`warn`/`critical`), message, `dedupe_key` (unique, so the same problem alerts once), `acknowledged_at`. |
| `outbox` | one side effect to perform | `kind` (`calendar.sync_slot`, `calendar.note`, `calendar.test`, `whatsapp.send`), `ref` (slot/note ID), `payload`, `status`, `attempts`/`max_attempts`, `next_attempt_at`, `locked_until` (lease), last request/response. Only one *pending* job per `(kind, ref)`. |

### Views for operations

| View | Shows |
|---|---|
| `v_open_alerts` | unacknowledged alerts, newest first |
| `v_bookings` | every slot as the calendar should show it, in venue local time |
| `v_latency` / `v_latency_summary` | seconds from the email's `Date` header to the event first appearing in the calendar (median, p95), per venue. This is the pilot's headline metric. |
| `v_outbox_health` | job counts per kind and status (spot `dead` jobs) |

## 6. Workflow 01 · Inbound email

File: [n8n/workflows/01-inbound-email.json](n8n/workflows/01-inbound-email.json) · ID `toriInboundEmail`

**Job:** accept every email Postmark sends, make it durable, acknowledge fast, and route it.

```mermaid
flowchart LR
    A[Postmark inbound] --> B[Normalize email] --> C[Store raw email] --> D[Reply 200 to provider] --> E{Route}
    E -->|parse| F[Parse + save booking 02]
    E -->|dispatch| G[Send WhatsApp now 03]
    E -->|ignore| H[Ignored stored + alerted]
```

| Node | Type | What it does |
|---|---|---|
| **About** | Sticky note | In-editor summary of the workflow. |
| **Postmark inbound** | Webhook | `POST /webhook/inbound/postmark`, protected by basic auth (`INBOUND_WEBHOOK_USER/PASSWORD`). Response mode is "respond via node", so Postmark gets its answer from *Reply 200* later, not immediately. |
| **Normalize email** | Code (per item) | Turns Postmark's JSON into Tori's provider-neutral shape. It lower-cases header names into a map; extracts plain addresses from `From`/`To`; picks the inbound address from `OriginalRecipient` → `X-Forwarded-To` → `To`; reads Gmail's `X-Forwarded-For` (which Gmail account forwarded it); converts HTML to text when there is no text body (strips scripts/styles, turns `<br>`/`</p>`/`</tr>` into newlines, decodes entities including `₹`); parses the `Date` header; and drops attachment contents (keeps only their metadata). Output: `{ raw: {...} }`. |
| **Store raw email** | Postgres | `SELECT tori.store_raw_message($1::jsonb)`. Stores the email and classifies it (see below). Returns `{ raw_id, action, reason }` where `action` is `parse`, `dispatch` or `ignore`. |
| **Reply 200 to provider** | Respond to Webhook | Answers Postmark with `200 { ok, raw_id, action, reason }`. This happens **after** the email is safely in Postgres and **before** any slow work (LLM, Google), so Postmark never times out and never retries needlessly. If storing failed, no 200 is sent and Postmark retries, which is what we want. |
| **Route** | Switch (expression) | Output 0 when `action = 'parse'`, 1 when `'dispatch'`, 2 otherwise. |
| **Parse + save booking (02)** | Execute Workflow | Calls workflow 02 with `raw_id`. Does **not** wait for it to finish. |
| **Send WhatsApp now (03)** | Execute Workflow | Used for the Gmail forwarding-code email: `store_raw_message` has already queued a WhatsApp alert to Ravi, so this runs the dispatcher right away instead of waiting up to 30 s. Does not wait. |
| **Ignored (stored + alerted)** | No-op | End of the line for duplicates, unknown addresses, wrong senders and wrong forwarders. The email is stored and, where useful, an alert was raised. |

### What `tori.store_raw_message()` decides

All in one transaction, with an advisory lock on `(venue, Message-ID)` so two copies of the same
email arriving at once can't both pass the duplicate check.

1. **Find the venue** by inbound address.
2. **Classify the email** (`kind`):
   - From `forwarding-noreply@google.com` → `gmail_verification`.
   - From matches a `booking_source.sender_regex` → `booking_email` (and `source` = that platform).
   - From is the owner's own Gmail **and** the body contains a forwarded "From: …playo…" line →
     `manual_forward` (the owner forwarded an email by hand).
   - Anything else → `other`.
3. **Insert** into `raw_message`. Then, in order:

| Situation | Status | Alert | `action` |
|---|---|---|---|
| Same Postmark `MessageID` already stored (provider retry) | – (existing row) | – | `ignore` |
| Same `Message-ID` header already received for this venue | `duplicate` | – | `ignore` |
| Inbound address matches no venue | `rejected` | `unknown_address` (once a day per address) | `ignore` |
| Gmail forwarding confirmation | `applied` | `forwarding_code` with the code, to Ravi | `dispatch` |
| Sender is not a booking platform | `rejected` | `unknown_sender` (once a day per sender) | `ignore` |
| Booking email forwarded by a Gmail account other than `venue.owner_gmail` | `rejected` | `wrong_forwarder` (critical) | `ignore` |
| Otherwise | `pending_parse` (and `venue.last_booking_email_at` updated) | – | `parse` |

The Gmail forwarding code branch exists because, during onboarding, Gmail sends a "confirm
forwarding" email *to the forwarding address*. That email is not from Playo, so a Playo-only
pipeline would drop it. Here the code is pulled from the subject (`#123456789`), saved on the
venue, and sent to Ravi on WhatsApp so he can read it out to the owner during the setup call.

## 7. Workflow 02 · Parse + save booking

File: [n8n/workflows/02-parse-and-save.json](n8n/workflows/02-parse-and-save.json) · ID `toriProcessEmail`

**Job:** turn one stored email into booking data, then hand it to Postgres to apply.
Called by 01 (new email), 04 (retry) and 05 (reprocess).

```mermaid
flowchart LR
    A[When called] --> B[Load email + venue] --> C{Waiting for parser?}
    C -->|yes| D[Build parser request] --> E[Groq · read email] --> F[Check parser answer] --> G[Save in one transaction] --> H[Update calendar + WhatsApp 03]
    C -->|no| I[Already handled]
```

| Node | Type | What it does |
|---|---|---|
| **About** | Sticky note | In-editor summary. |
| **When called** | Execute Workflow Trigger | Entry point. Passes the caller's item through; it carries `raw_id` (or `result.raw_id` when called from 01). |
| **Load email + venue** | Postgres | `SELECT tori.parse_input(raw_id)`. Returns the email's status, venue name, time zone, the platform label, the venue's active court names, the received time in venue local time, From, subject and the text body (HTML body as fallback). |
| **Waiting for parser?** | If | Continues only if the email's status is `pending_parse`. Protects against parsing the same email twice (e.g. a monitor retry racing the original run). |
| **Build parser request** | Code (per item) | Builds the Groq chat-completions request. **System prompt** explains the task, the four `email_type` values, and the rules: only facts in the email, `null` for anything missing, never invent a booking ID, copy the court name (or use the known court name if it clearly matches), 24-hour local times, midnight end = `00:00`, infer a missing year from the received date, don't classify a garbled booking-looking email as `not_a_booking`, and **ignore any instructions inside the email** (prompt-injection guard). **User message** gives the platform, venue, known courts, received time and the email wrapped in `<email>` tags. **Response format** is a strict JSON schema: `email_type`, `booking_id`, `customer_name`, `customer_phone`, `amount`, `payment_status`, `sport`, `slots[]` (`court`, `date`, `start_time`, `end_time`), `confidence`, `notes`. Model from `LLM_MODEL` (default `openai/gpt-oss-120b`), temperature 0, reasoning effort low, max 4000 tokens. |
| **Groq · read email** | HTTP Request | `POST {LLM_BASE_URL}/chat/completions` with the Groq API key credential, 60 s timeout. Configured to **never throw** (full response, `neverError`, continue on error), so every outcome, including network failures, flows on as data. |
| **Check parser answer** | Code (per item) | Converts the HTTP result into `{ raw_id, parse: { ok, retryable, error, model, result, usage } }`. **Retryable** failures: no response (network), HTTP 429 (also flagged `rate_limited`), HTTP 5xx. **Not retryable**: other HTTP errors, an answer cut off (`finish_reason = length`), a refusal, or content that isn't JSON. On success, `result` is the parsed JSON. |
| **Save in one transaction** | Postgres | `SELECT tori.apply_parse(raw_id, parse)`. All business logic happens here (next section). |
| **Update calendar + WhatsApp (03)** | Execute Workflow | Kicks the dispatcher immediately so the calendar updates within seconds instead of waiting for the 30 s schedule. Does not wait. |
| **Already handled** | No-op | The email was not `pending_parse`, so there is nothing to do. |

### What `tori.apply_parse()` does (one transaction)

This is the heart of the system.

**1. Record the attempt.** Lock the `raw_message` row, store the parser output, and count the
attempt. Groq 429 (rate limit) does **not** count, because the free tier allows only ~6 emails a
minute and a burst shouldn't burn an email's retries.

**2. Handle parser failure.**
- Retryable and under `parse_max_attempts` (3) → stays `pending_parse`, `action = retry_later`.
  Workflow 04 will try again.
- Otherwise → `mark_unreadable()`: status `parse_failed`, an all-day **"⚠️ Check Playo email"**
  note is queued for the calendar, and a critical `unreadable` alert goes to Ravi.

**3. Guard rails on the parser's answer.** Each failure below goes to `mark_unreadable()`:
- `not_a_booking` with less than high confidence, but the subject says booking / booked /
  cancelled / rescheduled → treated as unreadable, not ignored. (Found in testing against real
  Groq: a garbled booking email was classed as not a booking.)
- `email_type` missing or unknown.
- No booking ID.
- The booking ID does not appear **verbatim** in the subject or body (whitespace ignored). This
  catches hallucinated IDs.

A genuine `not_a_booking` (newsletter, payout) → status `ignored`, nothing else.

**4. Convert slots.** For each slot from the parser:
- Local date + time → `timestamptz` in the venue's time zone. If the end is not after the start,
  the slot crosses midnight and the end moves to the next day.
- Match the court with `match_court()`: normalise both names (lower-case, drop punctuation and
  leading zeros, so "Court 02" = "court2"), compare against `name`, `display_name` and `aliases`,
  then fall back to a unique suffix match.
- Attach **review reasons** (the slot is still saved): `unknown_court`, `outside_hours` (handles
  venues that close after midnight), `odd_duration` (< 15 min or > 12 h), `in_past` (> 2 days
  before receipt), `far_future` (> 180 days after), `low_confidence`.
- Slots with an unparseable date/time are counted as `unparsed`.

**5a. Cancellation** (`booking_cancelled`):
- Booking never seen → insert it as a **cancelled tombstone**, info alert (no WhatsApp). If the
  confirmation arrives later (emails out of order), it stays cancelled.
- No slots listed → cancel all active slots of the booking.
- Slots listed → match each to an existing slot by start time and court. If **any** listed slot
  can't be matched, or any was unparseable, **nothing is cancelled** and a critical
  `cancel_mismatch` alert is raised. A wrongly deleted event causes a double booking, which is
  worse than a stale one.
- For each cancelled slot: mark it cancelled, recompute clashes (the other side loses its ⚠️),
  queue a calendar job (which will delete the event).
- Booking status becomes `cancelled` only if no active slots remain (partial cancellations are
  supported).
- WhatsApp "❌ booking cancelled" to the owner (and Ravi if `copy_bookings`).

**5b. New, repeated or changed booking** (`booking_confirmed` / `booking_modified`):
- No readable slots → unreadable.
- Upsert the booking on `(venue, source, booking ID)`. New values fill in, but never overwrite
  known values with `null`/`unknown`. The customer phone is stored **masked** (`******3210`).
- If the booking is already cancelled → stop (`already_cancelled`).
- **Lock the affected court rows** (`SELECT … FOR UPDATE`, in ID order to avoid deadlocks). Any
  other transaction booking the same courts waits here, so two simultaneous bookings always see
  each other.
- `booking_modified`: active slots not in the new set are cancelled (the parser is told to return
  the complete new set).
- Upsert each slot on `(booking, court_key, starts_at)`. A new slot gets a fresh UUID and its
  calendar event ID `tori<uuid without dashes>`. A repeated confirmation email doesn't change
  existing slots; a modification does.
- For each new or modified slot: `refresh_clashes()` finds active slots on the same court, from
  a **different booking** (any platform), whose time ranges overlap. Both sides get each other in
  `clash_with`, and calendar jobs are queued for both.
- WhatsApp booking card to the owner (and Ravi): `✅ New`, `➕ Slots added` or `🔁 Booking changed`,
  with venue, slots (each marked ⚠️ CLASH if relevant), customer short name ("Priya N."), amount,
  payment status and platform ID.
- For each **new** clash pair: a critical `clash` alert to Ravi and a "⚠️ Double booking"
  WhatsApp to the owner naming both bookings ("booked first" / "new"). Both use the same
  dedupe key built from the sorted slot pair, so a pair alerts once.
- If any slot has review reasons or slots were unparseable: a `needs_review` alert explaining why.

**6. Finish.** Status `applied`, resolve any earlier "Check email" note for this email (so a
successful reprocess removes it from the calendar), and return a summary
(`action`, `new_slots`, `cancelled_slots`, `clashes`, `needs_review`).

## 8. Workflow 03 · Dispatch calendar + WhatsApp

File: [n8n/workflows/03-dispatch-outbox.json](n8n/workflows/03-dispatch-outbox.json) · ID `toriDispatchJobs`

**Job:** perform the side effects queued in `tori.outbox`, safely and repeatably.

```mermaid
flowchart LR
    T1[Every 30 seconds] --> C[Claim due jobs]
    T2[When called] --> C
    C --> S{Channel}
    S -->|gcal| G[Google Calendar] --> D[Complete job]
    S -->|whatsapp| B[Build WhatsApp message] --> W[WhatsApp · send] --> K[Check WhatsApp answer] --> D
```

| Node | Type | What it does |
|---|---|---|
| **About** | Sticky note | In-editor summary. |
| **Every 30 seconds** | Schedule Trigger | Picks up retries (whose backoff has expired) and anything a kick missed. |
| **When called** | Execute Workflow Trigger | Lets 01, 02, 04 and 05 run the dispatcher immediately. |
| **Claim due jobs** | Postgres | `SELECT job FROM tori.claim_jobs(25)`. Takes up to 25 due jobs and leases them for 2 minutes. Returns one item per job, already containing the exact request to send. Details below. |
| **Channel** | Switch (expression) | Output 0 for `channel = 'gcal'`, output 1 for WhatsApp. |
| **Google Calendar** | Code (all items at once) | Gets **one** OAuth access token for the whole batch: builds a JWT (RS256, scope `calendar.events`) signed with the service-account private key from `GOOGLE_SERVICE_ACCOUNT_JSON_B64`, and exchanges it at `GOOGLE_TOKEN_URI`. With no key configured (dev), it generates a throwaway RSA key the mock accepts. Then for each job: **upsert** = `POST events` with the deterministic event ID; if Google answers **409** (already exists), `PUT` to that ID instead. Success = HTTP 200. **delete** = `DELETE events/{id}`; 200, 204, **404 and 410 all count as success** (already gone). A token failure marks every job in the batch as a retryable failure. A thrown error (network) is retryable. Each job outputs `{ job_id, result: { ok, status, body, error } }`; on success `body` keeps only `id`, `status`, `htmlLink`. |
| **Build WhatsApp message** | Code (per item) | Builds the Cloud API body. Phone number reduced to digits. `WHATSAPP_MODE=text` (dev) sends `job.text` as a plain text message. `WHATSAPP_MODE=template` (prod) sends approved template `tori_<event>` (e.g. `tori_booking_new`, `tori_clash`, `tori_alert`) in `WHATSAPP_TEMPLATE_LANG`, with the job's 3 params as body parameters (single-lined, max 1000 chars). URL = `{WHATSAPP_BASE_URL}/{WHATSAPP_PHONE_NUMBER_ID}/messages`. |
| **WhatsApp · send** | HTTP Request | POSTs the body with the WhatsApp token credential, 20 s timeout. Never throws (full response, continue on error). |
| **Check WhatsApp answer** | Code (per item) | Normalises into `{ job_id, result }`. 2xx = ok (keeps the WhatsApp message ID). Retryable = no response, 429 or 5xx. Other 4xx = not retryable (e.g. bad template or number). |
| **Complete job** | Postgres | `SELECT tori.complete_job(job_id, result)`. Records the outcome and decides retry / done / dead. Details below. |

Why WhatsApp messages are built in Postgres but sent from n8n: the wording depends on booking
data (and must be identical across retries), but the HTTP call must happen outside the
transaction. The message text and template params are computed once in `apply_parse()` and stored
in the job's payload.

### `tori.claim_jobs()` — safe to run in parallel

- Selects jobs that are `pending` and due (`next_attempt_at <= now()`), or `running` with an
  **expired lease** (n8n crashed mid-job, so the job is picked up again).
- Skips calendar jobs for venues with no `calendar_id` yet (they wait, not fail).
- Never runs two jobs for the same `(kind, ref)` at once (e.g. two updates of the same slot).
- Uses `FOR UPDATE SKIP LOCKED`, so the 30 s schedule and a kick running together take different
  jobs.
- Marks them `running`, increments `attempts`, sets `locked_until = now() + 2 min`.
- Calls `build_request()` for each job, which reads the **current** state:
  - `calendar.sync_slot`: slot active and booking confirmed → `upsert` with the full event from
    `slot_event()`; otherwise → `delete`.
  - `calendar.note`: active → `upsert` an all-day red note; resolved → `delete`.
  - `calendar.test`: a "✅ Tori test event — connected" event next hour (or its deletion).
  - `whatsapp.send`: recipient, event, text and params from the payload.

**The calendar event** (`slot_event()`): title `Court 2 · District · Priya N.`, prefixed with
`⚠️ CLASH · ` (red, colour 11) or `⚠️ CHECK · ` (yellow, colour 5) when relevant. The description
holds the platform booking ID, amount, payment, masked phone, sport, received time, clash/check
explanation, and a note that edits are overwritten. The start and end are local times with the
venue's time zone. Reminders are off. The platform, booking ID, slot ID and venue ID are stored as
private extended properties.

### `tori.complete_job()` — retry policy

| Outcome | What happens |
|---|---|
| Success | Job `done`. Calendar slot/note `calendar_state` → `synced` or `deleted`; slot gets `htmlLink`, `calendar_synced_at` and (first time only) `first_synced_at` for the latency metric. Venue `calendar_status` → `ok`. |
| Calendar 401 / 403 / 404 | Venue `calendar_status` → `error`. Critical `calendar_error` alert with a plain-language hint (404: wrong calendar ID or not shared; 403: sharing permission isn't "Make changes to events"), at most once per venue per day. Treated as **retryable**, because the owner may fix the sharing. |
| Retryable failure, attempts left | Back to `pending` with exponential backoff: 1, 2, 4, 8 … minutes, capped at 1 hour. If a newer pending job for the same slot already exists, this one is marked `failed` ("superseded") instead, since the newer one will carry the latest state. |
| Out of attempts, or not retryable | `dead`. Critical `job_dead` alert (calendar jobs notify Ravi on WhatsApp; a dead WhatsApp job is only recorded, to avoid a loop of failing WhatsApp alerts about WhatsApp). |
| `calendar.test` failure | Never retried, ends as `failed` with no alert (the admin is looking at the result). |

Max attempts: 8 for calendar jobs (about 2 hours of retries), 5 for WhatsApp, 1 for calendar tests.

## 9. Workflow 04 · Monitor

File: [n8n/workflows/04-monitor.json](n8n/workflows/04-monitor.json) · ID `toriMonitorVenue`

**Job:** find problems nobody would otherwise notice, and retry emails waiting for the parser.

```mermaid
flowchart LR
    A[Every minute] --> B[Check venues + stuck emails]
    B --> C[Emails to retry] --> D[Retry parse 02]
    B --> E[Send alerts 03]
```

| Node | Type | What it does |
|---|---|---|
| **Every minute** | Schedule Trigger | Runs once a minute. |
| **Check venues + stuck emails** | Postgres | `SELECT tori.check_monitors()`. Three checks, all deduplicated through alert keys: (1) **Quiet venue**: a `live` venue with no booking email for `quiet_alert_hours` (default 24, per venue because small venues are naturally quiet) → `quiet` alert, at most once a day, suggesting the owner's Gmail filter broke. (2) **Retry list**: up to 5 emails still `pending_parse` and older than 1 minute. (3) **Parser stuck**: an email `pending_parse` for over 30 minutes → critical `parser_stuck` alert ("check the Groq key/quota"), once per email. Returns `{ quiet_alerts, retry_raw_ids }`. |
| **Emails to retry** | Code (all items) | Turns the `retry_raw_ids` array into one item per email, `{ raw_id }`. |
| **Retry parse (02)** | Execute Workflow | Runs workflow 02 for each email and **waits** for it, so retries go one after another and stay under Groq's rate limit. |
| **Send alerts (03)** | Execute Workflow | Kicks the dispatcher so new monitor alerts reach Ravi's WhatsApp immediately. Does not wait. |

This is also what makes n8n restarts safe: an email that arrives while n8n is reloading
workflows stays `pending_parse` and is picked up here within a minute.

## 10. Workflow 05 · Admin API

File: [n8n/workflows/05-admin-api.json](n8n/workflows/05-admin-api.json) · ID `toriAdminHookApi`

**Job:** three HTTP endpoints for onboarding and repair. All require header
`X-Tori-Admin-Key: $ADMIN_API_KEY`. In each, the Postgres node has an **error output**: if the
SQL function raises an exception (bad input), the error goes to a node that answers HTTP 400
`{ ok: false, error }`.

### `POST /webhook/admin/venues` — create a venue

```mermaid
flowchart LR
    A[POST admin/venues] --> B[Create venue]
    B -->|ok| C[Venue created 200]
    B -->|error| D[Venue error 400]
```

| Node | Type | What it does |
|---|---|---|
| **POST admin/venues** | Webhook (header auth) | Receives the venue JSON. |
| **Create venue** | Postgres | `tori.create_venue(body)`. Validates the slug (2–31 chars `a-z 0-9 -`), creates the tenant if no `tenant_id` is given, generates the inbound address `<slug>-<8 random hex>@in.toridesk.com`, inserts the venue (status `onboarding`) and its courts in order. |
| **Venue created** | Respond to Webhook | `200 { ok: true, venue_id, tenant_id, inbound_address, courts }`. The inbound address is what the owner puts into their Gmail forwarding. |
| **Venue error** | Respond to Webhook | `400 { ok: false, error }`. |

### `POST /webhook/admin/calendar-test` — check calendar sharing

Body `{ "venue": "<slug or id>", "action": "create" | "delete" }`. This is step 5 of the PDF's
onboarding: prove Tori can write to the owner's calendar while on the call with them.

```mermaid
flowchart LR
    A[POST admin/calendar-test] --> B[Queue calendar test]
    B -->|ok| C[Run dispatcher 03] --> D[Let a parallel run finish] --> E[Read result] --> F[Calendar test result 200]
    B -->|error| G[Calendar test error 400]
```

| Node | Type | What it does |
|---|---|---|
| **POST admin/calendar-test** | Webhook (header auth) | Receives the request. |
| **Queue calendar test** | Postgres | `tori.enqueue_calendar_test(venue, action)`. Fails (→ 400) if the venue doesn't exist, has no `calendar_id` yet, or the action is invalid. Queues a `calendar.test` job (1 attempt only) with event ID `toritest<venue id>`. |
| **Run dispatcher (03)** | Execute Workflow | Runs the dispatcher and **waits**. Always outputs an item, even if 03 returns nothing. |
| **Let a parallel run finish** | Wait (2 s) | The 30-second scheduled run of 03 may have claimed the test job instead of this call. Waiting 2 s lets that run finish. |
| **Read result** | Postgres | `tori.job_result(job_id)`: status, HTTP status, error, calendar link, and a **hint**: "OK — ask the owner to confirm they see the event", "Wrong calendar ID, or the calendar is shared with the wrong email" (404), "Permission is not 'Make changes to events'" (403), or "Still running — call again". |
| **Calendar test result** | Respond to Webhook | `200 { ok: status = 'done', ...result }`. |
| **Calendar test error** | Respond to Webhook | `400 { ok: false, error }`. |

### `POST /webhook/admin/reprocess` — parse an email again

Body `{ "raw_id": 123 }`. Used after fixing the cause of a failure: adding a court alias, fixing a
platform's sender regex, updating the owner's Gmail, or after a Groq outage.

```mermaid
flowchart LR
    A[POST admin/reprocess] --> B[Reset email]
    B -->|ok| C[Parse again 02] --> D[Email status] --> E[Reprocess result 200]
    B -->|error| F[Reprocess error 400]
```

| Node | Type | What it does |
|---|---|---|
| **POST admin/reprocess** | Webhook (header auth) | Receives `raw_id`. |
| **Reset email** | Postgres | `tori.reset_for_reprocess(raw_id)`. Refuses emails with no venue, Gmail verification emails and duplicates. Re-checks the sender against the **current** `booking_source` regexes (so fixing a regex rescues a rejected email), then sets status `pending_parse` with attempts reset to 0. If the sender is still not a platform, it stays `rejected`. |
| **Parse again (02)** | Execute Workflow | Runs workflow 02 and **waits**. If the reset was refused, 02's *Waiting for parser?* check simply stops. |
| **Email status** | Postgres | Reads the email's final status, reason and parsed result. |
| **Reprocess result** | Respond to Webhook | `200 { ok: true, raw_id, status, reason, parsed }`. |
| **Reprocess error** | Respond to Webhook | `400 { ok: false, error }` (e.g. unknown `raw_id`). |

Because bookings, slots, calendar event IDs and WhatsApp dedupe keys are all idempotent,
reprocessing an email that was already applied is safe.

## 11. Postgres functions reference

All in [002_functions.repeatable.sql](db/migrations/002_functions.repeatable.sql). This file is
"repeatable": `migrate.sh` re-applies it whenever it changes, after all versioned migrations.

| Function | Called by | Purpose |
|---|---|---|
| `store_raw_message(jsonb)` | 01 | Store, deduplicate, classify, route an inbound email. |
| `parse_input(raw_id)` | 02 | Everything the LLM prompt needs. |
| `apply_parse(raw_id, parse)` | 02 | Validate and apply a parse result; queue all side effects. One transaction. |
| `claim_jobs(limit, lease)` | 03 | Lease due outbox jobs and build their requests from current state. |
| `complete_job(job_id, result)` | 03 | Record the result; done / retry with backoff / dead + alert. |
| `check_monitors()` | 04 | Quiet venues, retry list, stuck-parser alerts. |
| `create_venue(jsonb)` | 05 | Onboard a venue with a random-token inbound address. |
| `enqueue_calendar_test(venue, action)` | 05 | Queue a one-shot calendar write test. |
| `job_result(job_id)` | 05 | Calendar-test outcome with a human hint. |
| `reset_for_reprocess(raw_id)` | 05 | Put an email back into `pending_parse`. |
| `purge_raw_bodies(days)` | manual / cron | Delete email bodies, headers and payloads older than N days (DPDP). |
| `mark_unreadable(raw_id, reason)` | internal | Status `parse_failed`, "Check email" calendar note, critical alert. |
| `refresh_clashes(slot_id)` | internal | Recompute a slot's `clash_with` on both sides; queue calendar updates for every slot whose clash state changed. |
| `slot_event(slot_id)` | internal | Build the Google Calendar event JSON for a slot. |
| `build_request(outbox)` | internal | Turn a job into a concrete HTTP action from current state. |
| `notify(venue, audience, event, text, params, dedupe)` | internal | Queue WhatsApp jobs. Audience `booking` → owner + account manager if `copy_bookings`; `owner` → owner only; `ops` → account manager, or `is_ops_default` staff if none. Recipients deduplicated by number. |
| `raise_alert(...)` | internal | Insert a deduplicated alert; optionally notify ops on WhatsApp. |
| `enqueue_calendar(kind, venue, ref, payload)` | internal | Queue a calendar job, merging with an existing pending job for the same ref. |
| `resolve_notes(raw_id)` | internal | Mark this email's "Check email" note resolved (deletes it from the calendar). |
| `match_court`, `court_key` | internal | Fuzzy-but-safe court name matching. |
| `source_for_sender`, `source_label` | internal | Platform lookup from `booking_source`. |
| `mask_phone`, `short_name`, `fmt_slot`, `reason_text`, `cfg` | internal | Formatting and settings helpers. |

## 12. Lifecycles (state machines)

### `raw_message.status`

```mermaid
stateDiagram-v2
    [*] --> received
    received --> duplicate: same Message-ID
    received --> rejected: unknown address / sender / forwarder
    received --> applied: Gmail forwarding code
    received --> pending_parse: booking email
    pending_parse --> pending_parse: retryable parser error (attempts < 3)
    pending_parse --> applied: saved
    pending_parse --> ignored: not a booking
    pending_parse --> parse_failed: unreadable
    parse_failed --> pending_parse: admin reprocess
    rejected --> pending_parse: admin reprocess (sender now matches)
    applied --> pending_parse: admin reprocess
```

### `outbox.status`

```mermaid
stateDiagram-v2
    [*] --> pending
    pending --> running: claim_jobs (lease 2 min)
    running --> running: lease expired, re-claimed
    running --> done: success
    running --> pending: retryable, backoff 1m..1h
    running --> failed: superseded by newer job / calendar test failed
    running --> dead: out of attempts or not retryable
```

### `booking_slot`

`active` → `cancelled` (by a cancellation or a modification). `calendar_state`:
`pending` → `synced` (event written) → `deleted` (event removed). `clash_with` is updated on
both sides whenever either slot changes.

## 13. Failure handling

| Failure | Behaviour |
|---|---|
| n8n down when Postmark POSTs | No 200 → Postmark retries delivery. |
| n8n crashes after storing, before parsing | Email stays `pending_parse` → workflow 04 retries within a minute. |
| Groq rate limit (429) | Email waits; the attempt isn't counted. Retried every minute. Alert after 30 min. |
| Groq down (5xx / network) | Up to 3 counted attempts, then "Check email" note + alert. |
| LLM answers garbage / hallucinated ID / cut off | Not retried; unreadable path. Never saved as a guess. |
| Unknown court, odd hours, low confidence | Saved anyway (the time is really sold), event titled ⚠️ CHECK, `needs_review` alert. |
| Cancellation that can't be matched | Nothing removed, critical alert. |
| Cancellation before its booking | Tombstone; the late confirmation stays cancelled. |
| Google 5xx / network | Retry with backoff, up to 8 attempts, then dead + alert. |
| Calendar unshared / wrong ID | Venue marked `calendar_status = error`, daily alert, keeps retrying for when the owner re-shares. |
| Calendar event already exists (409) | Overwritten with PUT (same deterministic ID). |
| Event to delete already gone (404/410) | Counted as success. |
| n8n crashes while a job is `running` | Lease expires after 2 min, job is re-claimed. |
| WhatsApp 5xx | Retry up to 5 times. |
| Owner's Gmail filter breaks | Quiet-venue alert after `quiet_alert_hours`. |

## 14. Security and privacy

- **Unguessable addresses.** Every inbound address carries 8 random hex characters
  (`smash-arena-k7q2m9ab@…`), so nobody can feed fake bookings by guessing it.
- **Sender check + forwarder check.** The From address must match a platform regex, and if Gmail's
  `X-Forwarded-For` is present it must contain the venue's `owner_gmail`. (DKIM verification is a
  later hardening step.)
- **LLM output is verified.** The booking ID must appear verbatim in the email, dates must be in a
  plausible window, durations sane. The prompt tells the model to ignore instructions inside the
  email.
- **Authenticated webhooks.** Inbound: basic auth. Admin: `X-Tori-Admin-Key` header.
- **Local-only ports.** Postgres, n8n and the mock bind to `127.0.0.1`. Production should put n8n
  behind HTTPS.
- **PII minimisation (DPDP Act).** The calendar and WhatsApp only ever see the masked phone
  (`******3210`) and a short customer name ("Priya N."). Raw emails contain full PII, so
  `tori.purge_raw_bodies(90)` clears bodies, headers and payloads after 90 days.
- **Secrets** live in `.env` (git-ignored) and become n8n credentials at bootstrap. The Google
  service-account key is passed as an env var, never committed.

## 15. Mock APIs and testing

### Mock server

[mock-apis/server.js](mock-apis/server.js) runs with `COMPOSE_PROFILES=mock`. It behaves like the
real APIs closely enough that the workflows are identical in dev and prod:

| Path | Imitates | Notes |
|---|---|---|
| `POST /google/token` | Google OAuth token endpoint | Checks the JWT is RS256 with the right scope and times. |
| `/google/calendar/v3/…` | Google Calendar events API | Requires a token it issued. Validates event IDs (`[a-v0-9]{5,1024}`), returns 409 on duplicate IDs, 404/410 on missing/deleted events. Calendar IDs containing `missing` return 404, which simulates an unshared calendar. |
| `/whatsapp/v21.0/{phone}/messages` | WhatsApp Cloud API | Checks the bearer token and body. |
| `/groq/openai/v1/chat/completions` | Groq | A regex parser that understands the fixture formats only. Use real Groq to test real emails. |
| `GET /` | – | Live dashboard: calendar events (clash in red, check in yellow) and WhatsApp messages per recipient. |
| `GET /_state`, `POST /_reset` | – | Inspect / clear everything the mock received. |
| `POST /_faults` | – | Inject failures: `{"calendar_fail_next": 1}` (503), `whatsapp_fail_next` (500), `llm_fail_next`. |

`LLM_BASE_URL` decides which parser is used; Calendar and WhatsApp go to the real APIs once their
`*_BASE_URL` and keys in `.env` point there.

### Fixtures and end-to-end tests

- [fixtures/emails/](fixtures/emails/) holds Postmark-shaped JSON emails (01–19). Placeholders
  such as `{{DATE1}}`, `{{PMID}}`, `{{MSGID}}` are filled in by
  [scripts/send-email.sh](scripts/send-email.sh), which POSTs a fixture to the inbound webhook
  exactly as Postmark would.
- [scripts/e2e.sh](scripts/e2e.sh) wipes booking data, sends every fixture through the real
  webhook, waits for the pipeline to settle (no `pending_parse` emails, no due outbox jobs), and
  asserts both the database and what the mock received. It covers 19 scenarios (58 checks):
  new / duplicate / multi-court bookings, a clash and its resolution, a District booking clashing
  with a Playo one and its cancellation, unknown court, late-night slot, HTML-only email,
  unreadable email, newsletter, spoofed sender, wrong forwarder, Gmail forwarding code,
  cancellation before booking, reschedule, Google 503 retry, LLM outage, and the admin endpoints.
  About 1 minute with the mock parser; about 15 minutes with real Groq on the free tier.

### Editing workflows

Edit in the n8n UI, then run [scripts/export-workflows.sh](scripts/export-workflows.sh). It exports
the 5 workflows by their fixed IDs, keeps only the portable fields, and writes them back to
`n8n/workflows/` for Git. The next `docker compose up` re-imports and republishes them.

## 16. Repository map

```
.
├── docker-compose.yml          # all services, env wiring, startup order
├── .env.example                # every setting; copy to .env
├── Architecture.md             # this file
├── README.md                   # run it, try it, everyday ops, going live
├── docs/PLAN.md                # build plan + review of the Step 1 PDF
├── db/
│   ├── init/00-create-databases.sh       # roles + databases (first start only)
│   ├── migrate.sh                         # tracked migrations, repeatables last
│   ├── migrations/001_schema.sql          # tables, indexes
│   ├── migrations/002_functions.repeatable.sql  # all business logic + views
│   ├── migrations/003_booking_sources.sql # multi-platform (Playo + District)
│   ├── migrations/004_partner_matching.sql # WhatsApp bot: partner requests + matches
│   ├── migrations/005_travel_matching.sql  # WhatsApp bot: travel intents, matches, blocks, reports, events
│   ├── migrations/005_travel_functions.repeatable.sql # travel matching rules (section 19)
│   ├── migrations/006_user_profiles.sql   # users, conversation state, inbound log (section 20)
│   ├── migrations/006_profile_functions.repeatable.sql # onboarding, profiles, photos, "about you"
│   ├── migrations/007_partner_board.repeatable.sql     # v_partner_board: what the public board may show
│   ├── migrations/008_held_messages*.sql  # messages kept for people outside the 24-hour window
│   ├── migrations/009_*.sql               # profiles v2 + matching v2 (radius, time gap, consent, cards)
│   ├── migrations/010_about.sql           # "about you" (typed or voice note)
│   ├── migrations/011_joins*.sql          # join codes, host approval, spots
│   ├── tests/travel_matching.sql          # SQL scenario tests for travel matching
│   ├── tests/{user_profiles,held_messages,matching_v2,joins}.sql  # SQL scenario tests (section 20)
│   └── seed/dev_seed.sql                  # demo venue, owner, Ravi
├── n8n/
│   ├── bootstrap/bootstrap.sh             # credentials + import + publish
│   ├── bootstrap/make-credentials.js      # credentials JSON from env
│   ├── bootstrap/setup-owner.js           # n8n login account
│   ├── workflows/01…05-*.json             # the five email-pipeline workflows
│   ├── workflows/06-whatsapp-bot.json     # separate WhatsApp bot + partner matching (sections 18, 20)
│   └── workflows/07…12-travel-*.json      # travel partner matching sub-workflows (section 19)
├── web/                        # partner board (Next.js): requests, filters, Join, photos for cards
├── mock-apis/server.js         # fake Google, WhatsApp (+ media), Groq, geocoder + dashboard
├── mock-apis/fixtures/         # a real spoken voice note for the Whisper test
├── fixtures/emails/*.json      # test emails
├── plan/                       # WhatsApp bot: designs (partner matching, tori-matching-architecture) + build scripts
└── scripts/
    ├── send-email.sh           # POST one fixture to the webhook
    ├── e2e.sh                  # full end-to-end suite
    ├── bot-tunnel.sh           # public HTTPS tunnel for the WhatsApp bot, points Meta at it
    ├── board-tunnel.sh         # public HTTPS tunnel for the board (card photos, bot links)
    ├── travel-e2e.sh           # bot tests in a throwaway stack (+ travel_e2e.py, profile_e2e.py)
    └── export-workflows.sh     # n8n UI → Git
```

## 17. What changed when District was added

District (by Zomato) was added as a second booking platform (migration
[003_booking_sources.sql](db/migrations/003_booking_sources.sql), October 2026). The main reason:
a Playo booking and a District booking for the same court and hour are a real double booking that
neither platform can see.

- Platforms moved from settings into the new **`booking_source`** table (`playo`, `district`).
  Adding a third platform is one `INSERT`, with no workflow changes.
- `raw_message` gained `source`; its `kind` values became platform-neutral (`booking_email`,
  `manual_forward`).
- `booking` gained `source`; `playo_booking_id` → `source_booking_id`; uniqueness is now
  `(venue, source, source_booking_id)`, so the same ID on two platforms can't collide.
- `court.playo_name` → `name`; `venue.last_playo_email_at` → `last_booking_email_at`.
- The LLM prompt is told which platform sent the email. Calendar titles, WhatsApp text, alerts and
  the "Check … email" note name the platform.
- **Clash detection was already per court, not per platform**, so cross-platform clashes work
  without special code. Fixtures 18 (District clashes with Playo, using a court alias) and 19
  (District cancellation clears the clash) prove it.
- `migrate.sh` now applies `*.repeatable.sql` after all versioned migrations, so functions see
  the renamed columns.

District's sender domain (`district.in`) and email format are guesses until a real District email
arrives. Fix the regex with one `UPDATE tori.booking_source …` (see the README).

## 18. The WhatsApp bot and partner matching (workflow 06)

### 18.1 What it is

[n8n/workflows/06-whatsapp-bot.json](n8n/workflows/06-whatsapp-bot.json) is the Tori WhatsApp bot.
People message Tori's WhatsApp number directly. The bot shows a service menu, takes venue bookings and
payments (Supabase + Razorpay), runs cab sharing, and now **finds partners**: someone types "I want a
partner to play football tomorrow at 6 PM in Indiranagar" and the bot finds another person with a
compatible request and connects them once both agree.

It shares nothing with workflows 01–05 except the Docker stack, the n8n instance and the Postgres server.

- **Where it came from:** the bot was built in an n8n Cloud instance. Its export (with hardcoded
  tokens) is kept out of Git in `plan/`.
- **How the file is made:** [plan/build_partner_workflow.py](plan/build_partner_workflow.py) adds the
  partner-matching nodes and writes this file with `--local`. Every token and key becomes an `$env.BOT_*`
  expression, every Graph API URL uses `$env.BOT_WHATSAPP_PHONE_NUMBER_ID`, and pinned test data is
  dropped, so the file holds no secrets.
- **Full design**, including the review of the original workflow and its known bugs:
  [plan/partner-matching-design.md](plan/partner-matching-design.md).

### 18.2 How messages reach it

```mermaid
flowchart LR
    U[User's WhatsApp] -->|message| N[Bot number<br/>e.g. +1 555 148-8874]
    N --> W[WhatsApp Business Account<br/>subscribed_apps: tori]
    W --> A[Meta app 'tori'<br/>webhook: messages]
    A -->|HTTPS| T[cloudflared tunnel<br/>…trycloudflare.com]
    T --> X[n8n · WhatsApp Trigger<br/>workflow 06]
    X -->|Graph API /messages| U
```

All four links must be in place, or messages silently go nowhere:

1. **Bot number → WhatsApp Business Account (WABA).** For a Meta test number this exists already.
2. **WABA → app.** The app must be in the WABA's `subscribed_apps`. For a test number this is not
   automatic: `POST /{waba-id}/subscribed_apps` with the bot token adds it (done once per WABA).
3. **App → webhook URL.** The n8n WhatsApp Trigger sets this itself when the workflow is published,
   using the app ID and secret. The URL is `WEBHOOK_URL` + `/webhook/<trigger webhookId>/webhook`.
4. **Webhook URL → n8n.** `WEBHOOK_URL` must be public HTTPS. Locally that is the Cloudflare quick tunnel.

[scripts/bot-tunnel.sh](scripts/bot-tunnel.sh) handles links 3 and 4:

- starts the `tunnel` container;
- reads its address from the logs;
- writes it into `WEBHOOK_URL`;
- runs `docker compose up -d`, which re-runs bootstrap and restarts n8n, and the trigger re-registers
  with Meta.

A quick tunnel's address changes whenever the container restarts, so run the script again after a
reboot.

**Publishing workflow 06 moves the Meta app's webhook to this n8n.** If the same app also serves a live
bot elsewhere, that bot stops receiving messages. That's why bootstrap publishes workflow 06 only when
`BOT_ENABLED=1`.

While the app is in development mode, a test number can only send to the (at most 5) numbers in the
app's recipient list: Meta → app → WhatsApp → "Step 1. Try it out" → Recipient.

### 18.3 Configuration (`.env`)

| Variable | Meaning |
|---|---|
| `BOT_WHATSAPP_PHONE_NUMBER_ID` | the bot number's phone number ID (Graph API sender) |
| `BOT_WHATSAPP_TOKEN` | access token for that number. A temporary token lasts 24 h; use a System User token for longer. |
| `BOT_META_APP_ID`, `BOT_META_APP_SECRET` | the Meta app, for the WhatsApp Trigger credential |
| `BOT_ENABLED` | `1` = publish workflow 06 |
| `BOT_PG_HOST/PORT/DATABASE/USER/PASSWORD/SSL` | the bot's database. Empty = this repo's Postgres, database `tori`, user `tori_app`. |
| `BOT_SUPABASE_URL`, `BOT_SUPABASE_SERVICE_KEY` | only for the older booking / cab-share paths, which read Supabase directly |

> **Updated in October 2026.** Section 20 changed several things described below: matching now uses a
> radius and a 2-hour window (not exact areas and ±30 minutes), the person who posted last is asked first
> with a profile card (not both at once), a first request waits for a profile, offers for people outside
> the 24-hour window are saved instead of needing a template, and the board can join a game directly.
> The node tables below still describe the original structure.

### 18.4 Routing

The original bot does not route through an AI agent. Its `AI Agent` node is disconnected and disabled.
Every message goes through a large keyword / button-ID `Switch` (17 rules, first match wins, outputs
bound by index). Partner matching plugs into that without reordering any rule:

```
WhatsApp Trigger
   │
Partner button? ──yes──► button branch (accept / decline)
   │ no
Switch (existing)
   ├─ out 2  "🎯Partner for an Activity" (menu tap) ──► Ask partner details
   ├─ out 15 free text (not a bare greeting) ─────────► partner branch
   └─ all other outputs: unchanged (menu, bookings, cab share, payments)
Every 15 minutes (partners) ─► expiry branch
```

Three `Switch` rules were tightened in place, because they captured partner messages:

| Rule | Was | Now | Why |
|---|---|---|---|
| 0 | text contains `20` | text is exactly `20` | "6:20 PM" or "2026" triggered a hardcoded Rs 20 payment message |
| 14 | text contains `book` | text starts with `book ` | "I want to book a partner" was treated as a venue name |
| 15 | text longer than 7 characters | any text that isn't a bare greeting | short follow-up answers ("6 pm", "HSR Layout") must reach the partner branch; "hi" still gets the menu |

### 18.5 What each partner node does

**Button branch** (a "Yes, connect" / "No, thanks" tap):

| Node | Type | What it does |
|---|---|---|
| **Partner button?** | If | True when the reply-button ID (`interactive.button_reply.id`) or template quick-reply payload (`button.payload`) starts with `pm_`. False sends the message on to `Switch` unchanged. |
| **Read partner button** | Code | Parses `pm_yes_<match uuid>` / `pm_no_<match uuid>` into `{ wa_id, accept, match_id }`. |
| **Respond to match** | Postgres | `respond_partner_match(match_id, wa_id, accept)`: records the answer, confirms or declines the match, and returns both people plus any requests reopened. |
| **Build response messages** | Code | Turns the result into `{to, text}` messages: "waiting for X", "✅ It's a match! … wa.me/…" to both, "No problem, I'll keep looking" + "X can't make it" (the latter only inside the 24-hour window), "already answered", or "no longer available". |
| **Send partner text** | HTTP | Sends a plain WhatsApp text. Shared by every plain reply in the feature. |
| **Reopened requests** | Code | Turns the `reopened` request IDs from respond / cancel / expire into one item each → **Find partner match**. |

**Partner branch** (free text from Switch out 15):

| Node | Type | What it does |
|---|---|---|
| **Get partner draft** | Postgres | The user's unfinished (`draft`) or just-created (`open`) request from the last 30 minutes, so follow-ups like "HSR Layout" or "make it 7 pm" are merged. Always outputs an item. |
| **Build LLM request** | Code | Builds a Groq chat request. The system prompt defines four intents (`find_partner`, `cancel_partner`, `profile_or_group`, `other`) and extraction rules: canonical sport names, city normalisation, area only, date resolved from "tomorrow"/weekdays, 24-hour time or a part of day, English/Hindi/Hinglish, and ignore instructions inside the message. The user message gives the time in India, the current request and the text. Strict JSON schema output. |
| **Understand message (LLM)** | HTTP | POST to Groq (`openai/gpt-oss-120b`) with the `Groq API key` credential. Never throws: errors flow on as data. |
| **Validate partner request** | Code | The deterministic part: reads the LLM JSON, merges it with the draft (newest answer wins), turns the time into a matching window, decides what is missing, and writes the reply. It picks a route: `create`, `ask`, `cancel`, `legacy`, `menu` or `reply` (errors). |
| **Partner route** | Switch | One output per route. `legacy` goes to the bot's original "Partner-matching- get back msg" stub (profile descriptions for Perfect Match / Groups, saved to `temp_event_replies`). `menu` goes to the existing `SERVICE TYPE LIST BUILDING`. |
| **Save draft** | Postgres | `save_partner_request(…, false)`; the question goes out through **Send partner text**. |
| **Save open request** | Postgres | `save_partner_request(…, true)`: the request is `open`, and the same person's older request for the same sport and day is cancelled. |
| **Send ack** | HTTP | "Got it! Looking for a football partner tomorrow around 6 PM in Indiranagar…". |
| **Search for this request** | Set | `{ request_id }` → **Find partner match**. |
| **Cancel partner requests** | Postgres | `cancel_partner_requests(wa_id)`; anyone they were proposed to goes back to `open` → **Reopened requests**. |

**Match chain** (fed by a new request, by reopened requests and by the schedule):

| Node | Type | What it does |
|---|---|---|
| **Find partner match** | Postgres | `match_partner_request(request_id)`: returns the proposed pair, or `null`. |
| **Match found?** | If | `null` ends here: the request stays `open` and the ack already told the user to wait. |
| **Build match messages** | Code | One message per person, each naming the other: first name, day, time, area. It also checks whether that person's last message was under 23 hours ago. |
| **Inside 24h window?** | If | Yes → **Send match buttons** (interactive reply buttons `pm_yes_<id>` / `pm_no_<id>`). No → **Send match template** (`partner_match_found` with quick-reply payloads), because WhatsApp only allows approved templates outside the 24-hour window. |

**Other:**
- **Ask partner details** replaces the old age/education prompt on the menu's "🎯Partner for an Activity".
- **Every 15 minutes (partners)** → **Expire partner requests** → **Reopened requests**.

### 18.6 Data model and functions

[db/migrations/004_partner_matching.sql](db/migrations/004_partner_matching.sql) creates two tables in
the `public` schema of the `tori` database. The same file runs unchanged on Supabase. The revokes for
Supabase's `anon` / `authenticated` roles apply only where those roles exist.

| Table | One row is | Key columns |
|---|---|---|
| `partner_requests` | one "find me someone" | `wa_id`, `profile_name`, `status`, `activity`, `city`, `area` + `area_key` (lower-case letters/digits, so "Indira Nagar" = "Indiranagar"), `play_date`, `time_exact` or `part_of_day`, `time_label`, `window_start`/`window_end`, `skill_level`, `players_needed`, `notes`, `raw_text`, `last_message_at` |
| `partner_matches` | one proposed pair | `request_a` (the request whose search found the pair), `request_b`, `wa_a`, `wa_b`, `a_response`, `b_response`, `status`; a unique index on the unordered request pair |

Both tables have row-level security enabled. Phone numbers are personal data, and on Supabase this keeps
them out of the public REST API. n8n connects as the table owner.

| Function | Does |
|---|---|
| `save_partner_request(wa_id, name, fields, complete)` | continue the 30-minute draft or start one; on complete → `open`, and cancel the person's older request for the same sport and day |
| `match_partner_request(request_id)` | find and propose the best partner (rules below), set both requests `proposed`, return both sides |
| `respond_partner_match(match_id, wa_id, accept)` | first answer per side only; both yes → `confirmed` (a request that needs more players reopens); any no → `declined`, both reopen |
| `cancel_partner_requests(wa_id)` | "stop looking": cancel the person's requests and reopen whoever they were proposed to |
| `expire_partner_requests()` | proposals unanswered for 2 h, or whose game time passed → `expired`; the side that said yes reopens, the side that didn't answer leaves; past requests and stale drafts expire |

**Matching rules** (`match_partner_request`, original version; [20.4](#204-matching-v2) replaces it):

- same sport, same city, same `area_key` and same date;
- time windows overlap;
- the candidate is `open` and in the future;
- not the same person;
- not beginner vs advanced;
- these two requests were never paired before;
- these two people didn't decline each other in the last 7 days.

**Time windows:**
- An exact time is ±30 minutes. So 6:00 and 6:30 match, and 6:00 and 7:00 don't.
- A part of day is a fixed window: morning 06–11, afternoon 12–16, evening 16–20, night 19–23.

**Ranking:** the closest midpoint wins, then the oldest request.

**Concurrency:** an advisory lock per (sport, city, date) serialises searches. Two people posting at the
same second always find each other, and a waiting request can never be proposed to two people at once.

**Request lifecycle:**

```mermaid
stateDiagram-v2
    [*] --> draft: details missing
    [*] --> open: complete
    draft --> open: follow-up completes it
    open --> proposed: match found
    proposed --> matched: both said yes
    proposed --> open: declined / partner didn't answer / needs more players
    proposed --> expired: didn't answer in 2 h
    open --> cancelled: "stop looking" or replaced by a newer request
    draft --> expired: 30 min without an answer
    open --> expired: time passed
```

### 18.7 Testing

- **Without WhatsApp:** the build was run end to end in a throwaway n8n with a fake WhatsApp API, a
  scratch database and real Groq. That covered:
  - match + both accept, double tap, decline + re-match, stale buttons;
  - a follow-up question, Hinglish, "8:20 PM", "hi" still giving the menu, and profile text going to the
    old stub;
  - cancel, the 24-hour template path and the 15-minute expiry.
- **With phones:** follow [README.md](README.md) → "WhatsApp bot with partner matching". Each message is
  one run in n8n → Executions. Rows are in `public.partner_requests` and `public.partner_matches`.

### 18.8 Known limits

- ~~Areas must match exactly~~: fixed, areas are geocoded and matched within a radius ([20.4](#204-matching-v2)).
  Don't ask users for a location pin in this flow: Switch rule 13 sends every location message into cab share.
- ~~The template must be approved~~: without `PARTNER_MATCH_TEMPLATE`, offers for people outside the
  24-hour window are saved and sent when they next write ([20.6](#206-people-outside-the-24-hour-window)).
- **Everything outside partner matching is still the original bot.** Booking, payments and cab share
  need Supabase locally (`BOT_SUPABASE_*`). Several of those paths have bugs: see section 10 of the
  design doc.

---

## 19. Travel partner matching (workflows 07–12)

### 19.1 What it is

People tell the bot where and when they are going ("Jhunsi to Naini tomorrow around 6"). They book
their own Uber, auto, train or flight; Tori only finds someone travelling a similar route at a similar
time and, **after both people agree**, shares their WhatsApp numbers. It is a stranger-matching
system, so the backend knows exact places and the users never do.

| Layer | Does | Never does |
|---|---|---|
| LLM (the existing call in workflow 06) | intent (`travel_partner`, `travel_cancel`, `travel_consent`, `travel_block`, `travel_report`), extracts source / destination / date / time, reads yes/no | distances, eligibility, consent state, contact sharing, expiry, dedupe |
| n8n (07–12) | orchestration: geocoding calls, branching, rendering and sending messages, schedules | business rules |
| Postgres (`005_travel_functions.repeatable.sql`) | identity, validation, distances, matching, ranking, consent, blocks, rate limits, expiry, what may be shown to whom | – |

### 19.2 Flow

```mermaid
flowchart TD
    WA[WhatsApp Trigger] --> TB{Travel button?<br/>tm_yes / tm_no / tm_block}
    TB -->|yes| A07
    TB -->|no| PB[Partner button? → Switch → LLM<br/>existing workflow 06]
    PB -->|intent travel_*| A07[07 assistant]
    A07 -->|dedupe by message ID| R{route}
    R -->|details| V[Validate: merge with draft,<br/>ask only for missing fields]
    V -->|complete| G[08 geocode ×2<br/>cache → Nominatim / Google]
    G --> S[travel_activate_intent]
    S --> N[11 notify: ack]
    N -.async.-> M[09 find matches]
    R -->|yes / no / block / report| C[10 consent]
    R -->|cancel| X[travel_cancel_intent]
    M --> N2[11 notify: offer to requester]
    C --> N3[11 notify] -.re-match.-> M
    SW[12 sweep every 10 min] --> N4[11 notify] -.re-match.-> M
```

1. **Collect.** Workflow 06's LLM call now also returns a `travel` object and five `travel_*` intents.
   It is told the person's own unfinished travel request (`travel_context()`), so "Jhunsi to Naini"
   or "yes" continues the right conversation. 07 merges the new fields into the draft and asks only for
   what is missing ("Where will you be starting from? What time are you planning to leave?"). A time
   with no day means today if it is still ahead; past dates/times and > 30 days ahead are asked again.
2. **Geocode.** 08 normalises the place text and checks `travel_geocode_cache`. On a miss it calls the
   provider in `TRAVEL_GEOCODER`. Zero results → "I couldn't find …"; top results more than 25 km apart
   → "There's more than one Civil Lines. Which city?"; provider down → "send it again in a minute".
3. **Save.** `travel_activate_intent()` creates the ACTIVE TravelIntent, or updates the person's
   existing one (version + 1, stale matches closed, anyone already asked is told it is withdrawn).
   It enforces the rate limit and refuses past trips. The ack is sent *before* matching starts.
4. **Match (async, both directions).** 09 calls `travel_find_matches()` for every new or changed
   request. It searches the ACTIVE pool, so a request that waited with nobody (A) is found by the
   next compatible one (B). The requester (B here) is asked first.
5. **Consent.** B taps *Yes* → `USER_A_ACCEPTED` (the match's "A" side is the requester), A is asked.
   A taps *Yes* → `CONNECTED`, both get the other's first name + `wa.me` link. Either *No* → `DECLINED`,
   the requester gets the next candidate, the declined pair is never proposed again.
6. **Sweep.** 12 expires unanswered matches (2 h), trips 30 min after departure, drafts after 3 h.
   If the requester said yes and the other side never answered, the requester is told and re-matched.

### 19.3 Matching rules (`travel_find_matches`)

A candidate must be ACTIVE, departing in the future, not the same person, and:

- start points ≤ `TRAVEL_MAX_SOURCE_DISTANCE_KM` (3) apart and destinations ≤
  `TRAVEL_MAX_DESTINATION_DISTANCE_KM` (5), by haversine distance on stored lat/lng;
- same travel date and departure times ≤ `TRAVEL_MAX_TIME_DIFFERENCE_MINUTES` (45) apart;
- not blocked by either person, not already paired with this request (answered or ignored), and the two
  people did not decline each other in the last 7 days.

The search runs in SQL: a bounding box on indexed lat/lng columns first, exact distances second, so
the table is never pulled into n8n. The local Postgres has no PostGIS; the same query works on
Supabase. Eligible candidates are ranked by `travel_match_score()`:
`100 × (w_s·(1 − src_km/3) + w_d·(1 − dst_km/5) + w_t·(1 − minutes/45)) / (w_s + w_d + w_t)` with weights
from `TRAVEL_SCORE_WEIGHT_*` (0.4 / 0.4 / 0.2). Up to `TRAVEL_MAX_MATCH_CANDIDATES` (3) are kept per
request and shown **one at a time**. A per-day advisory lock serialises searches, so two people posting
at the same moment always find each other once, never twice. A partial unique index stops duplicate
live matches for the same pair.

### 19.4 Privacy and safety controls

| Control | Where |
|---|---|
| Before both say yes, messages say only "a nearby area", "a similar destination" and the other trip's time rounded to 15 min. No name, place, distance or number. | `travel_notification()` returns nothing else; wording in 11 · *Render message* |
| Phone number + first name only when `status = CONNECTED` **and** both consents are true | `travel_notification()` |
| The matcher returns only `{ matchFound, matchId }`; the LLM never receives another user's data | `travel_find_matches()`, 09 · *Result*, `travel_context()` |
| Only the two people in a match can act on it, and B only after being asked (no forged button IDs) | `travel_respond()` |
| Block (button on the connected message, or "block this person") and report ("report this user …"): never matched again; the other person isn't told | `travel_blocks`, `travel_reports`, `travel_respond()` |
| Rate limit: 5 new/changed requests per hour, 15 per day (stops probing by moving a pin around); the ack is the same whether or not someone exists | `travel_activate_intent()`, `travel_load_request()` |
| WhatsApp redeliveries handled once (message ID) | `travel_begin_message()` |
| Logs (`travel_events`) hold UUIDs and codes only, never numbers, coordinates, places or message text | all functions |
| RLS on every table, functions revoked from Supabase's anon / authenticated roles | 005 migrations |

### 19.5 Data model

| Table | Holds |
|---|---|
| `travel_users` | `wa_id` ↔ opaque `id`, profile name, `last_message_at` (24-hour window) |
| `travel_intents` | TravelIntent: texts, lat/lng, date, time, `departure_at`, `status` DRAFT/ACTIVE/MATCHED/CANCELLED/EXPIRED, `version`, `expires_at`. One live (DRAFT/ACTIVE) per user |
| `travel_matches` | TravelMatch: both intents and users, distances, minutes, score, `status` PENDING/USER_A_ACCEPTED/USER_B_ACCEPTED/CONNECTED/DECLINED/EXPIRED/BLOCKED, both consents, `offered_at`, `b_asked_at`, `close_reason`, `expires_at` |
| `travel_blocks`, `travel_reports` | user-level blocks; reports for human review (`reviewed_at`) |
| `travel_geocode_cache` | place text → lat/lng, per provider, 90 days, not linked to users |
| `travel_inbound_messages` | processed WhatsApp message IDs (7 days) |
| `travel_events` | domain events + structured logs (180 days) |

`USER_B_ACCEPTED` is accepted by the schema but never produced: the requester (A) is always asked first.

Events (`travel_events.event`): `travel.intent.created / updated / cancelled / expired / duplicate /
rate_limited`, `travel.geocode.success / failure`, `travel.match.candidate_found / found / rejected /
offered / accepted / declined / connected / expired / blocked`, `travel.consent.received / rejected`,
`travel.report.created`, `travel.notification.sent / failed / skipped`, `travel.message.duplicate`,
`travel.sweep`.

### 19.6 Configuration

All `TRAVEL_*` variables are listed with their defaults in [.env.example](.env.example) and passed
to n8n by `docker-compose.yml`. Empty means the default in `travel_cfg()`. Matching values are read by
the database on every call, so changing one needs only `docker compose up -d` (no SQL edit).

- **Geocoding:** `TRAVEL_GEOCODER=nominatim` (default; OpenStreetMap's public server allows about
  1 request/second and requires an identifying `TRAVEL_GEOCODER_USER_AGENT`, so use a self-hosted or
  commercial Nominatim-compatible endpoint via `TRAVEL_GEOCODER_URL` for real volume) or `google`
  (`TRAVEL_GEOCODER_KEY`).
- **WhatsApp template** for people outside the 24-hour window: submit a *Utility* template, e.g.
  `travel_match_found`, body *"Hi 👋 We found someone travelling a similar route around {{1}} {{2}}.
  Would you like to connect?"*, quick replies *Yes, connect* / *No thanks*, then set
  `TRAVEL_MATCH_TEMPLATE`. Until then, such requests are skipped and logged as
  `travel.notification.skipped` (the match then times out and the requester hears so).
- `BOT_WHATSAPP_GRAPH_URL` overrides the Graph API base (tests point it at mock-apis).

### 19.7 Testing

`scripts/travel-e2e.sh` brings up a throwaway stack (project `toritravel`, other ports, own volumes;
the live stack is untouched) with real Groq and the mock WhatsApp API + mock geocoder, then runs:

- `db/tests/travel_matching.sql`: 41 SQL assertions. They cover both-direction discovery, the distance
  and time limits, dedupe, consent order, contact gating, double taps, decline then next candidate, update
  invalidation, the candidate cap, block, rate limit, past trips and expiry.
- `scripts/travel_e2e.py`: 30 checks through the real workflows. They cover the §22 example conversation
  (missing details → ask → match → both accept → links), no leakage before consent, redelivered webhooks,
  an ambiguous + unknown place, update, cancel, a typed "no thanks", block, report, the sports flow
  still working, and logs free of numbers and coordinates.

Also verified by hand in that stack: a geocoder outage and the consent timeout through the 12 schedule
(requester told, then offered the next candidate).

### 19.8 Known limits

- **One live travel request per person.** A new route while one is open replaces it ("Updated ✅").
- **No WhatsApp groups or masked relay:** the WhatsApp Cloud API integration here can't create groups,
  so contact is shared as `wa.me` links, and only after both people say yes.
- **Location pins are not used:** Switch rule 13 sends every location message into the old cab-share
  flow. That flow (pin → `intent_pool` → `match_tori_intent`) is left untouched but should be retired:
  it shares numbers with no consent and has the bugs listed in the partner-matching design doc.
- Questions and confirmations are fixed templates chosen by code (no second LLM call, which also keeps
  within Groq's free-tier tokens per minute); the LLM still does intent, extraction and yes/no.
- The travel tables must exist wherever workflow 06's Postgres credential points (run both 005 files on
  Supabase too), because 06 reads `travel_context()` for every free-text message.

---

## 20. Profiles, cards, joins and the board

Added in October 2026 on top of section 18. Same shape as before: **n8n moves data, Postgres decides**.
Every rule below is a SQL function (one transaction per call); workflow 06 is still generated by
[plan/build_partner_workflow.py](plan/build_partner_workflow.py). The longer design, including the
Express backend that is planned but not built, is [plan/tori-matching-architecture.md](plan/tori-matching-architecture.md).

### 20.1 What changed

| Area | Before | Now |
|---|---|---|
| First request | matched straight away | saved as `pending_profile`; the bot asks for a profile one question at a time, then the request resumes by itself |
| Profile | WhatsApp name only | name, age, gender, interests, Instagram/LinkedIn (must be public), photo, "about you" (typed or **voice note**), privacy choice |
| Matching | same area name, ±30 min windows | geocoded areas within **3 km**, time ranges within **2 h**, skill levels, shared interests; settings in a table |
| Consent | both people asked at once, first name only | the person who posted last sees a **profile card** first; the other is asked only after they say Interested |
| Outside WhatsApp's 24-hour window | needed an approved template | the card is **saved** and sent the next time the person writes; "any match?" checks |
| Board | — | `web/`: every live game, filters, who joined, **Join** button |
| Joining | — | `JOIN <code>` → the host accepts or declines; the host sets the number of **spots** |
| Inbound messages | — | every message logged once; a redelivered message ID is dropped |

### 20.2 How a message flows now

The nodes in front of the big `Switch`, in order:

```
WhatsApp Trigger
  → Log inbound message      tori_log_inbound: create the user, log the message, drop redeliveries
  → New message?             stops on a duplicate
  ├→ Take held messages      tori_take_held: cards saved for this person go out first (20.6)
  → Google? → Travel button? → Partner button? (pm_ taps, 18.5)
  → Join message?            "JOIN <code>" or pj_ Accept/Decline taps (20.8)
  → Profile input?           pf_ onboarding buttons, photos, voice notes (20.3)
  → Switch (section 18.4)    free text → Get partner draft → LLM → Validate partner request → Partner route
```

`Partner route` now has 12 outputs: create, ask, cancel, legacy, menu, reply, travel, **profile**, **hold**,
**status**, **about**, **spots**. Complete requests (create, and hold when the request is complete) are
geocoded first by calling workflow 08 (`toriTravelGeocod`, cached) before they are saved.

### 20.3 Profiles and onboarding

Steps, asked one at a time (`tori_profile_missing` returns what is left):

1. **name**: one-tap button with the WhatsApp first name, or typed;
2. **age**, **gender** (buttons), **interests**;
3. **Instagram / LinkedIn** (optional, Skip): a link or `@handle`, normalised by `tori_normalize_social`;
   the question says Instagram profiles must be public;
4. **photo** (optional, Skip): JPG / PNG / WebP up to 5 MB, downloaded from the Graph API and stored in
   `tori_user_photos`;
5. **about you** (optional, recommended, Skip): typed, or a **voice note** transcribed by Whisper (Groq
   `whisper-large-v3-turbo`, retried 3 times). An LLM call turns it into a short summary (contact details
   stripped), a skill level and extra interests (`tori_save_about`);
6. **privacy** (only if they gave a link or photo): "Anyone I match with" / "Only after both yes".

**Voice notes, anywhere.** Every voice note is downloaded and transcribed. At the "about you" step the
transcript is the answer. Anywhere else, **Relay voice as text** posts it back to this workflow's own
WhatsApp Trigger as a text message from the same person. The body is signed with `BOT_META_APP_SECRET`,
because the trigger checks Meta's `x-hub-signature-256`, and the message ID is the voice note's plus
`.voice`. A spoken request, profile answer, "any match?" or `JOIN` code is therefore handled exactly like
a typed one. `BOT_RELAY_URL` overrides the target; the tests post to their own webhook.

Several answers in one message are all taken. A profile complete under older rules is asked only the new
steps (the context computes the status from the steps left, not from the stored flag). When the profile is
complete, the parked request opens (or the bot asks for its missing details), and a pending board join
(20.8) is sent on.

### 20.4 Matching v2

`match_partner_request` (redefined in `009_matching_v2.repeatable.sql`). A candidate must:

- be on the same date and `open`, not the same person, not a pair already proposed, not a pair that
  declined each other in the last 7 days;
- be the same sport, or in a group listed in `compatible_activities`;
- have time ranges at most `time_gap_min` apart (an exact time is a point, "evening" is 16–20);
- be within `radius_km` when both areas are geocoded, or have the same city and area name when not;
- not be beginner vs advanced (the request's level, else the profile's level from "about you").

**Best candidate:** nearest, then closest in time, then most interests in common, then the oldest
request. **Settings:** defaults in `tori_cfg()`, overridden by rows in `tori_settings` (`time_gap_min` 120,
`radius_km` 3, `compatible_activities` `[]`).

**Sequential consent** (`respond_partner_match`, redefined):

```mermaid
sequenceDiagram
  actor B as Searcher (posted last, side a)
  participant T as Tori
  actor A as Waiting (side b)
  T->>B: A's card [Interested] [Not interested]
  B->>T: Interested
  T->>A: B's card (or saved, 20.6)
  A->>T: Interested
  T->>B: ✅ wa.me link, link, photo
  T->>A: ✅ wa.me link, link, photo
```

If the searcher says no, the waiting person never hears about it. Expiry (`expire_partner_requests`,
redefined in 008) gives 2 hours from when the card was **seen** (`offered_at`); a side that was never asked
goes back into the pool.

### 20.5 Cards and privacy

`tori_match_view` / `tori_person_card` decide what each side may see:

| | Before both say yes | After |
|---|---|---|
| First name, age, interests, level, about, area, time | shown | shown |
| Photo, Instagram / LinkedIn | only if the owner chose "Anyone I match with" | shown |
| WhatsApp number | never | `wa.me` link |

Photos reach WhatsApp as an image header fetched from the board: `<BOARD_PUBLIC_URL>/p/<random token>`.
Without a public board address, cards go out without photos.

### 20.6 People outside the 24-hour window

WhatsApp allows free-form replies only within 24 hours of the user's last message. `last_message_at` is
refreshed by any inbound message. A card or update for someone outside the window goes to
`tori_held_messages` (`tori_hold_message`, `tori_hold_join`) instead of being sent, and is delivered
by **Take held messages** the next time they write. "any match?" re-sends anything still unanswered.
A held card doesn't time out before it has been seen and is never sent after the game. Every
"Looking for a partner" reply tells people to send "any match?" before they head out. Setting
`PARTNER_MATCH_TEMPLATE` to an approved template sends offers right away instead.

### 20.7 The partner board (`web/`)

Next.js 16 app, built and started by `docker compose up` (port `BOARD_PORT`, default 3001). It reads only
`v_partner_board`, in read-only transactions:

- first name, sport, place, time, level, spots, **who joined** (first names), status: Looking /
  Confirming / Full;
- never numbers, ages, photos or message text;
- filters for search, sport, city, day, time of day, status and level, kept in the URL; refreshes every 20 s;
- `GET /api/requests` returns the same as JSON; `GET /p/<token>` serves card photos.

`scripts/board-tunnel.sh` gives it a public address and sets `BOARD_PUBLIC_URL`. The bot then links to it,
filtered to the sport and city.

### 20.8 Joining a game

```mermaid
sequenceDiagram
  actor J as Joiner (board)
  participant T as Tori
  actor H as Host
  J->>T: Join → WhatsApp "JOIN K7Q2"
  Note over T: no profile → onboarding first, then the join goes on
  T->>H: joiner's card (n/spots joined) [Accept] [Decline]
  H->>T: Accept
  T->>H: ✅ joiner is in + wa.me
  T->>J: ✅ host said yes + wa.me
```

- Every live request gets a 4-character join code (`tori_stamp_opened` → `tori_new_join_code`). The
  joiner's number is proven by WhatsApp itself; the board has no login.
- Every joiner goes to the host. **Spots** = `players_needed`: "need 3 more" when posting, or `spots N`
  later (`tori_set_spots`).
- Filled = accepted joins + confirmed matches. When it reaches the spots, the game is Full and waiting
  joiners are told. More spots reopen it; fewer spots than people already in fill it.
- `tori_request_join` returns requested, needs_profile, unknown, own, closed, full, already_pending,
  already_joined or declined_before. `tori_answer_join` handles Accept / Decline and is idempotent.

### 20.9 Data model

| Table | One row is |
|---|---|
| `tori_users` | a person: phone (E.164), name + `name_source`, birth year, gender, interests, social link, privacy, about (text, source, summary), skill level, `profile_status` |
| `tori_user_photos` | a profile photo (bytes, random token) |
| `tori_conversation_state` | what the bot waits for: `idle` / `awaiting_profile`, the parked request, a pending join code |
| `tori_messages` | an inbound message (unique `wa_message_id`) or a bot profile reply |
| `tori_held_messages` | a message kept for someone outside the 24-hour window |
| `tori_settings` | a matching setting |
| `partner_joins` | one person asking to join one game (unique per person and game) |
| `partner_requests` | + `opened_at`, `lat`/`lng`, `join_code`, status `pending_profile` |
| `partner_matches` | + `offered_at` |

### 20.10 Concurrency and capacity (measured)

On a scratch database, with parallel sessions:

| Test | Result |
|---|---|
| 40 people post the same game at once | 20 pairs; no request in two matches, no self-match |
| 30 joiners, 3 spots, the host accepts all 30 at once (3 runs) | exactly 3 accepted, 27 "full", 0 errors |
| 2,000 posts + match searches, 20 in parallel | ≈ 250 per second on a laptop |

How it's safe:
- Matching takes an advisory lock per date, plus `FOR UPDATE` on the candidate.
- Joins lock the game row first, then the join. The first version locked the other way round and
  deadlocked under this test.
- Answers only count when the row is still `pending`.
- Unique keys stop duplicates: inbound message ID, request pair, one join per person and game.

The real limits today are outside Postgres:
- the **Groq free tier** (≈ 8k tokens/min): one typed message costs ≈ 2,300 tokens, so ≈ 3 typed messages
  a minute; taps and photos don't use the LLM;
- the **Meta test number** (5 recipients) and temporary access tokens;
- a single n8n process on a laptop, behind quick tunnels.

Two quick messages from the same person are processed in parallel by n8n. The data stays consistent, but
the second reply may not know about the first.

### 20.11 Configuration (`.env`)

| Variable | Meaning |
|---|---|
| `BOARD_WHATSAPP_NUMBER` | the bot's number, for the board's Join / Post buttons |
| `BOARD_PUBLIC_URL` | the board's public address (set by `scripts/board-tunnel.sh`): bot links and card photos |
| `BOARD_PORT` | the board's local port (3001) |
| `PARTNER_MATCH_TEMPLATE` | an approved template for offers outside the 24-hour window; empty = save them |
| `TRANSCRIBE_BASE_URL`, `TRANSCRIBE_MODEL` | Whisper endpoint and model; empty = Groq `whisper-large-v3-turbo` with `LLM_API_KEY` |
| `BOT_RELAY_URL` | where transcribed voice notes are posted back as text; empty = this n8n's WhatsApp Trigger |

### 20.12 Testing

- SQL scenarios, rolled back after each run:
  - `db/tests/user_profiles.sql`: 50 checks;
  - `held_messages.sql`: 20;
  - `matching_v2.sql`: 26;
  - `joins.sql`: 31.
- End to end: `E2E_ONLY=profile scripts/travel-e2e.sh` runs a throwaway stack with real Groq and Whisper,
  a mock WhatsApp (with media downloads) and a mock geocoder. It covers onboarding with a real voice note,
  cards with photos, sequential consent, cancel, redelivery, offline people, and a full join scenario
  (accept, decline, spots, Full).

### 20.13 Known limits

- No location-ambiguity buttons: an area that doesn't geocode falls back to matching on the area name.
- No profile editing after onboarding, and no report / block for partner matches (travel has them).
- The board is public and has no login: anyone with the address sees first names, places and times.
- Card photos depend on the board's public address; quick tunnels change after a restart.
- The Express backend in the design doc is not built; n8n + SQL functions do its job.

---

## 21. Tori Wallet

Prepaid credits (1 credit = ₹1), added through Razorpay and spent with one tap. Design notes and the
compliance questions are kept locally in `payment.md` (not in Git).

```mermaid
flowchart LR
  U["WhatsApp: add credits"] --> BOT["n8n 06: wallet_issue_link"]
  BOT -->|"one-time link (15 min)"| W["web /wallet/login → /wallet"]
  W -->|"POST /api/wallet/topups"| RZ["Razorpay Orders + Checkout"]
  RZ -->|"handler: signature"| V["/api/wallet/topups/verify"]
  RZ -->|"payment.captured / order.paid"| WH["/api/razorpay/webhook"]
  V & WH -->|"fetch + capture payment, wallet_credit_topup (once)"| PG[("Postgres ledger")]
  BS["Booking system"] -->|"POST /webhook/wallet/charge"| BOT2["n8n 06: [Pay ₹X] [Cancel]"]
  BOT2 -->|"tap: wallet_pay_charge"| PG
```

**Ledger:**

| Table | One row is |
|---|---|
| `wallet_accounts` | `user:<id>` per person, plus `tori:razorpay` (money received) and `tori:sales` (credits spent) |
| `wallet_journal` | one movement: top-up, charge, refund or adjustment, with a unique idempotency key |
| `wallet_postings` | its legs, in paise, summing to 0 |
| `wallet_topups` | one add-credits payment (`rzp_order_id`, `rzp_payment_id`) |
| `wallet_charges` | one one-tap payment request |
| `wallet_links`, `wallet_sessions` | hashed one-time links and web sessions |
| `razorpay_events` | every webhook, stored before processing |

**Rules** (SQL, one transaction each): `wallet_post` is the only way money moves.
- It is idempotent, and it locks the person's account row.
- It refuses unbalanced entries and negative balances.
- `wallet_credit_topup` credits only if the amount equals the order's, and only once.
- `wallet_pay_charge` checks the owner, status, expiry and balance under the same lock.

Measured: 25 parallel ₹100 payments from a ₹1,000 wallet gave exactly 10 paid and 15 "insufficient", with
the balance at 0. The same webhook delivered 20 times at once credited once.

**Security:**
- The key secret is only in the web container. Signatures (`order|payment` with the key secret; the raw
  webhook body with the webhook secret) are compared in constant time.
- Amounts come from our rows, never the browser. The payment is re-fetched from Razorpay before
  crediting.
- The board's own queries stay read-only; only `wallet_*` calls use a read-write transaction.
- The session cookie is httpOnly, SameSite=Lax, and secure behind HTTPS.

---

## 22. ToriPay

People pay a gym, turf or coach from their Tori Wallet over WhatsApp: "tori pay gym 500". It extends §21.
The money is collected once (the wallet top-up), held as wallet credit, and paid out to the business's bank
through RazorpayX.

```mermaid
flowchart LR
  T["Team: scripts/payee.sh add"] -->|"POST /api/admin/payees"| X1["RazorpayX contact + fund account"]
  T --> PY[("payees: IFSC, last 4, fund account id")]
  U["WhatsApp: tori pay gym 500"] --> BOT["n8n 06 §16: toripay_bot"]
  BOT -->|"shortcut, else search; list if several"| C["[Pay ₹500] [Cancel]"]
  C -->|"tap: toripay_confirm"| L[("ledger: user −500, payee +net, tori:revenue +fee")]
  BOT -->|"POST /api/payouts/execute"| PO["web: RazorpayX payout (idempotent)"]
  PO -->|"payout.processed / failed / reversed"| WH["/api/razorpayx/webhook: payout_settled"]
  WH -->|"settled: payee → tori:payouts · failed: refund in full"| L
```

**Tables** (`013_payees.sql`):

| Table | One row is |
|---|---|
| `payees` | a verified business: `handle`, name, category, area, aliases, owner's WhatsApp, account holder, IFSC, last 4 digits, RazorpayX contact and fund account ids, `commission_bps`, `verified` / `suspended` |
| `user_payees` | a person's shortcut: (`user_id`, `nickname`) → payee |
| `payee_payments` | one "tori pay": amount, commission, status `pending → paid → processing → settled`, or `cancelled` / `expired` / `failed`; `rzp_payout_id` |

The ledger gains one `payee:<id>` account per business (what Tori owes it) and `tori:revenue`,
`tori:payouts`. A payment posts user −amount, payee +net, revenue +commission. A payout posts
payee −net, `tori:payouts` +net. A failed payout reverses everything, so the person gets the full amount
back.

**Functions** (`013_payees.repeatable.sql`):
- `payee_upsert`, `payee_search`;
- `toripay_resolve` (shortcut | one | many | none), `user_payee_set` / `_list` / `_remove`;
- `toripay_start` (a 15-minute request), `toripay_confirm` (locks the wallet; checks the owner, status,
  expiry, suspension and balance; saves the shortcut), `toripay_cancel`;
- `payout_details`, `payout_mark`, `payout_settled` (idempotent; `manual:<payment>` for bank transfers),
  `payees_owed`, `payee_settle_manual`;
- `toripay_bot`: the bot's single entry point, which returns what to reply.

**Adding a payee on WhatsApp** (`014_own_payees.sql`): an unknown name under "tori pay" starts a draft
(`toripay_drafts`, one per person, 30 minutes).

```mermaid
sequenceDiagram
  participant P as Person
  participant B as n8n 06
  participant W as web /api/toripay/answer
  participant X as RazorpayX
  P->>B: tori pay coach 300
  B->>P: What's it called?
  Note over B: Log inbound message returns toripay_step → every text goes to W
  P->>B: name, IFSC, holder, account number
  B->>W: each answer (x-tori-key)
  W->>W: IFSC directory lookup · toripay_draft_answer (hash + last 4 for the number)
  P->>B: account number again
  B->>W: answer
  W->>W: toripay_draft_check (hash matches?)
  W->>X: contact + fund account (the number)
  W->>W: toripay_draft_finish: payee (added_by), shortcut, toripay_start
  W-->>B: confirm
  B->>P: ✅ Saved · [Pay ₹300]
```

- `payees.added_by` set = private to that person: `payee_search` skips it, and `toripay_start` and
  `user_payee_set` refuse anyone else.
- "✏️ Change bank details" re-runs the draft against the same payee.
- The draft stores `sha256(user_id:number)` and the last 4 digits, never the number.
- `tori_log_inbound` writes "[bank account number]" for digits typed at the account steps.
- `Google?` skips messages while a draft is open.

**Payouts:**
- `executePayout` sends only a `paid` payment that has a fund account, when `RAZORPAYX_ACCOUNT_NUMBER` is
  set. `X-Payout-Idempotency` is the payment's reference, so a retry never pays twice.
- On any error the payment stays owed and a later call retries it.
- If the webhook arrives before `payout_mark`, it is matched through the payout's `reference_id`.
- With payouts off, the team works from `payees_owed` and settles by bank transfer.

**Security:**
- Only the team's `TORI_ADMIN_KEY` can add a public business or change its bank details. The bot's
  `WALLET_API_KEY` can only ask for a payout of a payment that is already paid, or add or change a
  private payee for the person in the conversation.
- Self-added payees are not verified by the team: the confirm message says "added by you", and the
  person checks the bank, branch and last 4 digits themselves. (RazorpayX account validation, a penny
  drop, can be added once payouts are activated.)
- The account number is never stored or logged by Tori.
- People can only pay verified businesses, and the confirm message shows the bank, the last 4 digits and
  the holder's name before the tap.

**Measured:** 40 parallel confirms (20 payments of ₹100, each tapped twice) from a ₹1,000 wallet gave exactly
10 paid, 10 "already paid" and 20 "insufficient". The balance ended at 0 and the ledger stayed balanced.

**Open:**
- RazorpayX payouts must be activated on the account; contacts and fund accounts already work.
- Commission, GST and TCS treatment need a CA's view; see `payment.md` §2.
