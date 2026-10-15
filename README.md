# Tori Desk · Step 1 — Playo / District emails → Postgres → Google Calendar + WhatsApp

Booking emails from Playo and District (by Zomato) are forwarded from the owner's Gmail to a per-venue address. n8n stores each
email, a Groq LLM reads it into strict JSON, and one Postgres transaction saves the booking,
checks for clashes (across platforms: a District booking can clash with a Playo one) and queues the side effects. A dispatcher then writes Google Calendar and sends
WhatsApp messages to the tenant (venue owner) and Ravi (account manager).

Plan, and the review of the Step 1 PDF: [docs/PLAN.md](docs/PLAN.md).
How it works, node by node: [Architecture.md](Architecture.md).

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
| Partner board (every partner request, live) | http://localhost:3001 (`BOARD_PORT`) |
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

`e2e.sh` covers 19 scenarios: new, duplicate and multi-court bookings, a clash and its
resolution, a District booking that clashes with a Playo booking (and its cancellation), unknown court, after-hours/midnight, HTML-only email, unreadable email, a newsletter,
a spoofed sender, the wrong forwarder, the Gmail forwarding code, a cancellation before its
booking, a reschedule, a Google 503 retry, an LLM outage, and the admin endpoints. With the mock
parser it takes about 1 minute (58 checks). Against real Groq it takes about 15 minutes, because
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
SELECT * FROM tori.v_latency_summary;             -- pilot metric: booking email → calendar
SELECT * FROM tori.v_outbox_health;               -- pending / dead jobs
UPDATE tori.alert SET acknowledged_at = now(), acknowledged_by = 'ravi' WHERE id = 42;
UPDATE tori.court SET aliases = aliases || 'Badminton Ct 2' WHERE venue_id = 1 AND name = 'Court 2';
SELECT tori.purge_raw_bodies(90);                 -- DPDP: drop email bodies after 90 days
SELECT * FROM tori.booking_source;                -- platforms and their sender regexes
```

## Booking platforms

Each platform is a row in `tori.booking_source` (`playo`, `district`). An email is a booking email
when its From address matches the row's `sender_regex`. The owner's Gmail filter must forward mail
from every platform the venue uses, for example `from:(playo.co OR district.in)`. Bookings are keyed by
`(venue, source, source_booking_id)`, so the same ID on two platforms never collides. Clash checks
run per court across all platforms.

District's sender domain (`district.in`) and email format are guesses, like Playo's were. Fix the
regex from the first real email:

```sql
UPDATE tori.booking_source SET sender_regex = '(^|[@.])district\.in$' WHERE code = 'district';
```

To add another platform, insert a row (`code`, `label`, `sender_regex`, `forwarded_from_regex`).
The parser prompt is told the platform's label. No workflow changes are needed.

## Onboarding a venue (the PDF's per-venue steps)

```bash
H="X-Tori-Admin-Key: $ADMIN_API_KEY"; J="content-type: application/json"
curl -H "$H" -H "$J" -d '{"tenant_name":"Ace Sports","owner_name":"…","owner_whatsapp":"+91…","account_manager_id":1,
  "slug":"ace-courts","name":"Ace Courts","owner_gmail":"owner@gmail.com","opens_at":"06:00","closes_at":"23:00",
  "courts":["Court A","Court B"]}' localhost:5678/webhook/admin/venues      # → forwarding address
psql: UPDATE tori.venue SET calendar_id = '…@group.calendar.google.com' WHERE slug = 'ace-courts';
curl -H "$H" -H "$J" -d '{"venue":"ace-courts","action":"create"}' localhost:5678/webhook/admin/calendar-test
curl -H "$H" -H "$J" -d '{"venue":"ace-courts","action":"delete"}' localhost:5678/webhook/admin/calendar-test
psql: UPDATE tori.venue SET status = 'live' WHERE slug = 'ace-courts';   -- enables quiet alerts
```

## WhatsApp bot with partner matching (workflow 06)

`n8n/workflows/06-whatsapp-bot.json` is the Tori WhatsApp bot (booking menu, cab share) plus "Find a
partner": people message the bot in plain language ("football partner tomorrow 6 PM Indiranagar"), the
bot asks for anything missing, matches compatible requests, and connects two people once both tap
**Yes, connect**. Design: [plan/partner-matching-design.md](plan/partner-matching-design.md). Tables and
functions: [db/migrations/004_partner_matching.sql](db/migrations/004_partner_matching.sql).

It is imported on every `docker compose up` but only published when configured, because publishing points
the Meta app's webhook at this n8n. **If the same Meta app serves a live bot elsewhere, that bot stops
receiving messages while this one is published.**

1. Fill the `BOT_*` block in `.env`: phone number ID and access token (Meta → app → WhatsApp → API Setup),
   App ID and App secret (Meta → app → App settings → Basic), and `BOT_ENABLED=1`. Every phone you test
   with must be in API Setup's "To" list while the app is in development mode.
2. `scripts/bot-tunnel.sh`: starts a Cloudflare quick tunnel, puts its address into `WEBHOOK_URL` and
   restarts n8n, which publishes workflow 06 and registers the webhook with Meta. The address changes
   whenever the tunnel container restarts. Run the script again after that.
3. Message the bot's number. Runs show in n8n → Executions. Requests and matches are stored in
   `public.partner_requests` / `public.partner_matches`.

The workflow file holds no secrets: tokens are read from `$env.BOT_*`. It is generated from the n8n export
by `python3 plan/build_partner_workflow.py --local`.

**Google (optional).** With `TORI_GOOGLE_URL` and `TORI_GOOGLE_SECRET` set, the bot hands "connect google",
`gg_` button taps and free text to the ToriGoogle stack (`../ToriGoogle`, workflow 22). It answers for numbers
linked to a Google account (calendar, tasks, email, contacts, notes, Docs, Sheets, Slides, Drive). For
everything else, or when ToriGoogle is down, the bot carries on as before. Setup: see the WhatsApp section of
`../ToriGoogle/README.md`.

If the trigger won't register after a tunnel change (n8n log: "Workflow partially published"), Meta still had
the old address when n8n started. Run `scripts/bot-tunnel.sh` once more (it points Meta at the new address),
then `docker compose stop n8n && docker compose up -d` so n8n republishes. A quick tunnel can also expire
while its container keeps running (tunnel log: "Tunnel not found"):
`docker compose --profile tunnel up -d --force-recreate tunnel`, then run the script.

### Travel partner matching (workflows 07–12)

The same bot also finds travel companions: "Going from Jhunsi to Naini tomorrow around 6 PM, anyone
going the same way?". It asks for anything missing, geocodes both places, and matches people whose start
points are within 3 km, destinations within 5 km, and departures within 45 minutes. Both people must tap
**Yes, connect** before either sees the other's number. Design and rules: [Architecture.md §19](Architecture.md#19-travel-partner-matching-workflows-0712).

- Settings: the `TRAVEL_*` block in `.env` (defaults in [.env.example](.env.example)). The default
  geocoder is OpenStreetMap Nominatim; set `TRAVEL_GEOCODER_USER_AGENT` to something with a contact address.
- Workflows 07–12 are generated by `python3 plan/build_travel_workflows.py`; the rules are Postgres
  functions in `db/migrations/005_travel_functions.repeatable.sql`.
- Test without phones: `scripts/travel-e2e.sh` (throwaway stack, real Groq, mock WhatsApp + geocoder, ~5 min).
- Rows: `public.travel_intents`, `public.travel_matches`, logs in `public.travel_events`.

### User profiles before the first request

Before Tori looks for a partner, it needs to know who is asking. The first partner request from a number
without a complete profile is **saved first** (`partner_requests.status = 'pending_profile'`, so it is never
lost), then the bot asks for age, gender and the sports or activities they enjoy. One message or several
both work ("24, male" … "badminton and football"); the bot asks only for what is still missing. When the
profile is complete, the saved request goes live by itself and matching starts. If the request still lacks
details, the bot asks for them next, and if its time passed in the meantime, it asks for a new one.
Profile details in the first message ("I'm Priya, 27, female, need a badminton partner …") are used right away.

- Tables: `tori_users` (phone in E.164, name, birth year, gender, interests), `tori_conversation_state`
  (`idle` / `awaiting_profile`, the parked request) and `tori_messages` (every inbound message; a message ID
  Meta delivers twice is processed once). [db/migrations/006_user_profiles.sql](db/migrations/006_user_profiles.sql),
  functions in [006_profile_functions.repeatable.sql](db/migrations/006_profile_functions.repeatable.sql).
- Workflow 06: **Log inbound message** runs first for every message; the LLM call also extracts profile fields;
  **Partner route** has two more outputs, `profile` and `hold`.
- "Stop looking" also drops a parked request. Parked requests nobody finished expire after 7 days.
- Travel matching and the booking menu do not ask for a profile.
- Tests: `db/tests/user_profiles.sql` (32 SQL checks) and `scripts/profile_e2e.py` (real Groq, mock WhatsApp):
  `E2E_ONLY=profile scripts/travel-e2e.sh`.

### Profiles v2, profile cards and matching v2

Design: [plan/tori-matching-architecture.md](plan/tori-matching-architecture.md) (built on n8n + Postgres).

- **Onboarding, one question at a time:**
  1. name (one-tap button with the WhatsApp name), age, gender (buttons), interests;
  2. optionally an Instagram / LinkedIn link (link or @handle) and a photo, each with **Skip**;
  3. if they gave either: "Who can see your photo and link before you both agree to connect?" Anyone I match
     with / Only after both yes.

  Several answers in one message are all taken. Photos (JPG / PNG / WebP, ≤ 5 MB) are downloaded from WhatsApp
  and stored in `tori_user_photos`.
- **"About you" (recommended, optional):** the last onboarding step. People type a few lines about themselves
  or **send a voice note**. Voice notes are transcribed by Whisper (Groq `whisper-large-v3-turbo`, same key as
  the chat LLM; `TRANSCRIBE_BASE_URL` / `TRANSCRIBE_MODEL` override it). An LLM turns the text into a short
  summary for match cards (contact details are stripped), a skill level and extra interests (`tori_save_about`,
  [010_about.sql](db/migrations/010_about.sql)). The bot shows the summary back to them: "Here's what I'll share".
  The link question says Instagram profiles must be public.
- **Matching** (`match_partner_request`, 009):
  - same day, same sport (or a group in `compatible_activities`);
  - time ranges ≤ `time_gap_min` apart (default 120);
  - geocoded areas ≤ `radius_km` apart (default 3; areas are geocoded with workflow 08 and cached);
  - when either request isn't geocoded: same city and area name;
  - a beginner never meets an advanced player (a request without a level uses the profile's level from
    "about you");
  - among equally good candidates, the one with more interests in common wins.

  Settings live in `tori_settings`, e.g.
  `INSERT INTO tori_settings VALUES ('time_gap_min', '90') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;`
- **Consent is sequential:**
  1. the person who posted last gets the other's **card** (name, age, interests, time; photo and link only if the
     owner chose "anyone I match with") with **Interested** / **Not interested**;
  2. the other person is asked only after that, with the first person's card;
  3. when both say yes, both get the number (`wa.me`), the link and the photo.
- **Photos in messages** need the board to be public (`BOARD_PUBLIC_URL`, `scripts/board-tunnel.sh`): WhatsApp
  fetches them from `<board>/p/<random token>`. Without it, cards have no photo.
- Tests: `db/tests/matching_v2.sql` (22 checks) and `db/tests/user_profiles.sql`; the conversation in
  `scripts/profile_e2e.py`.

### Joining a game from the board

Every live request has a 4-character **join code** and a number of **spots** (`players_needed`; "need 3 more" when
posting, or **`spots 3`** later).
- The board shows each game's spots, **who joined** (first names) and a **Join** button. Join opens WhatsApp with
  `JOIN <code>` typed out, so the joiner's number is proven by WhatsApp itself; there is no website login.
- The bot sends the game's creator (the host) the joiner's card with **Accept / Decline**. Every joiner goes to the
  host. Someone without a profile is onboarded first; the join goes on afterwards.
- **Accept:** both get each other's `wa.me` link (plus link and photo per privacy). **Decline:** the joiner is told
  politely.
- When all spots are taken, the game is **Full** on the board and anyone still waiting is told. More spots reopen
  it; fewer spots than people already in fill it.
- A host outside the 24-hour window gets join requests when they next write, like match cards.
- SQL: [011_joins.sql](db/migrations/011_joins.sql), `011_joins.repeatable.sql`. Tests: `db/tests/joins.sql`
  (31 checks) and scenario 7 of `scripts/profile_e2e.py`.

### People outside WhatsApp's 24-hour window

WhatsApp only lets the bot message someone within 24 hours of their last message; after that only an
approved template gets through. When a match is found for someone who has been quiet longer, their offer
is **kept** (`public.tori_held_messages`) and sent the next time they message the bot, before the normal
reply. The other person is told "they'll see it the next time they check in". Every "Looking for a partner"
reply ends with *No word from me before you head out? Send any match? and I'll check*. "any match?" sends
anything kept and lists each live request (still looking / waiting for them / waiting for you).

- An offer kept for someone offline doesn't time out after 2 hours; the clock starts when they see it.
  Nothing is sent after the game time.
- With an approved template, set `PARTNER_MATCH_TEMPLATE=<name>` (4 body params: sport, name, when, area;
  quick replies Yes / No) and offers go out right away instead.
- SQL: [008_held_messages.sql](db/migrations/008_held_messages.sql) and its `.repeatable.sql`
  (which replaces `expire_partner_requests`). Tests: `db/tests/held_messages.sql`, scenario 8 of `scripts/profile_e2e.py`.

## Partner board (web/)

A web page listing every partner request people send on WhatsApp, newest games first, refreshing every
20 s. Filters: search (area, city, sport, name), sport, city, day (today, tomorrow, this weekend, next 7 days,
past), time of day, status and skill level. Each filter is in the URL, so a filtered view can be shared. Same
look as ToriGoogle's web app (fonts, colours, components). JSON: `GET /api/requests` takes the same parameters.

- `docker compose up -d` builds and starts it on http://localhost:3001. It reads the bot's database (this
  Postgres, or the `BOT_PG_*` one) over a read-only session.
- Only `public.v_partner_board` is read ([007_partner_board.repeatable.sql](db/migrations/007_partner_board.repeatable.sql)):
  first names, places and times. No phone numbers, message text or profile details, and only requests that went
  live (no drafts, nothing still waiting for a profile).
- Set `BOARD_WHATSAPP_NUMBER` to the bot's number to show **I'm in** on each card: it opens WhatsApp with a
  message describing the same game, so the bot's usual matching connects the two people once both say yes.
- Demo from a phone: `scripts/board-tunnel.sh` gives the board a temporary public address and puts it into
  `BOARD_PUBLIC_URL`. The bot then adds "👀 See who else is playing: <link>" (filtered to the sport and city)
  to its "Looking for a partner" reply and to the "hi" menu. Anyone with the link can see the board. The
  address changes when the `board-tunnel` container restarts: run the script again.
- Develop: `cd web && npm install && DATABASE_URL=postgres://tori_app:<TORI_DB_PASSWORD>@localhost:5433/tori npm run dev`.

## Editing workflows

Workflows can be edited in the n8n UI. Afterwards, run `scripts/export-workflows.sh` to write them
back to `n8n/workflows/` for Git. `docker compose up` re-imports and republishes on every start.
After a restart, n8n can keep serving the previously published version for about 20 s. Emails
that arrive during that window are not lost: they wait as `pending_parse` and workflow 04
retries them.

## Going live

1. Google Cloud: create the service account and its key, then set `GOOGLE_SERVICE_ACCOUNT_JSON_B64`, `GOOGLE_TOKEN_URI=https://oauth2.googleapis.com/token` and `GCAL_BASE_URL=https://www.googleapis.com/calendar/v3`.
2. Postmark inbound for `in.toridesk.com`: point it at `https://<host>/webhook/inbound/postmark` with basic auth, and set `WEBHOOK_URL`.
3. WhatsApp Cloud API: set `WHATSAPP_BASE_URL=https://graph.facebook.com/v21.0`, the token, and the phone number ID. Set `WHATSAPP_MODE=template` and get these templates approved, each with 3 body params and wording that doesn't name a platform (the params carry it, e.g. `District ID DST-…`): `tori_booking_new`, `tori_booking_updated`, `tori_booking_modified`, `tori_booking_cancelled`, `tori_clash`, `tori_alert`.
4. Set `COMPOSE_PROFILES=` (no mocks), put n8n behind HTTPS, and don't set `SEED_DEV`.
