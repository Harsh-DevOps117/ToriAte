-- Travel partner matching for the Tori WhatsApp bot (workflow 06 → sub-workflows 07–12).
-- Tables only. The functions are in 005_travel_functions.repeatable.sql.
-- Locally: applied by db/migrate.sh to the `tori` database (public schema, next to partner_requests).
-- Supabase: run this file, then 005_travel_functions.repeatable.sql, in the SQL editor.
-- Safe to re-run: IF NOT EXISTS everywhere.
--
-- Privacy: coordinates and distances live only in these tables. Functions never return another
-- user's places, coordinates, distances or phone number before both people said yes.

-- One row per WhatsApp user who used travel matching. Everything else points at `id`, so logs
-- and match rows carry an opaque UUID instead of a phone number.
CREATE TABLE IF NOT EXISTS public.travel_users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa_id           text NOT NULL UNIQUE CHECK (wa_id ~ '^\d{6,15}$'),   -- WhatsApp number, digits only
  profile_name    text,                                                -- WhatsApp profile name
  last_message_at timestamptz,                                         -- WhatsApp 24-hour window
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- TravelIntent: "I'm going from X to Y on D around T". A DRAFT while the bot is still asking for
-- details, ACTIVE once complete and geocoded, MATCHED once connected with someone.
CREATE TABLE IF NOT EXISTS public.travel_intents (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES public.travel_users (id),
  status           text NOT NULL DEFAULT 'DRAFT'
                   CHECK (status IN ('DRAFT', 'ACTIVE', 'MATCHED', 'CANCELLED', 'EXPIRED')),
  source_text      text,                 -- as normalised by the LLM: "Jhunsi, Prayagraj"
  source_lat       double precision CHECK (source_lat BETWEEN -90 AND 90),
  source_lng       double precision CHECK (source_lng BETWEEN -180 AND 180),
  destination_text text,
  destination_lat  double precision CHECK (destination_lat BETWEEN -90 AND 90),
  destination_lng  double precision CHECK (destination_lng BETWEEN -180 AND 180),
  travel_date      date,                 -- India date
  departure_time   time,                 -- India time, approximate
  departure_at     timestamptz,          -- travel_date + departure_time in Asia/Kolkata
  version          int NOT NULL DEFAULT 1,  -- +1 every time the route, day or time changes
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz,          -- departure + grace; never matched after this
  CHECK (status IN ('DRAFT', 'CANCELLED', 'EXPIRED')
         OR (source_text IS NOT NULL AND source_lat IS NOT NULL AND source_lng IS NOT NULL
             AND destination_text IS NOT NULL AND destination_lat IS NOT NULL AND destination_lng IS NOT NULL
             AND travel_date IS NOT NULL AND departure_time IS NOT NULL
             AND departure_at IS NOT NULL AND expires_at IS NOT NULL))
);
-- one live request (draft or active) per user; "change my time to 7 PM" updates it
CREATE UNIQUE INDEX IF NOT EXISTS travel_intents_one_live
  ON public.travel_intents (user_id) WHERE status IN ('DRAFT', 'ACTIVE');
-- the matching pool: same day, then a box around the start point
CREATE INDEX IF NOT EXISTS travel_intents_pool
  ON public.travel_intents (travel_date, source_lat, source_lng) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS travel_intents_expiry
  ON public.travel_intents (expires_at) WHERE status IN ('DRAFT', 'ACTIVE');

-- TravelMatch: one proposed pair. A = the request whose search found the match (asked first),
-- B = the request that was already waiting (asked only after A says yes).
CREATE TABLE IF NOT EXISTS public.travel_matches (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  travel_intent_a         uuid NOT NULL REFERENCES public.travel_intents (id),
  travel_intent_b         uuid NOT NULL REFERENCES public.travel_intents (id),
  user_a                  uuid NOT NULL REFERENCES public.travel_users (id),
  user_b                  uuid NOT NULL REFERENCES public.travel_users (id),
  intent_a_version        int NOT NULL,
  intent_b_version        int NOT NULL,
  source_distance_km      numeric(8, 3) NOT NULL,   -- backend only, never sent to anyone
  destination_distance_km numeric(8, 3) NOT NULL,
  time_difference_minutes int NOT NULL,
  match_score             numeric(5, 2) NOT NULL,   -- 0–100, travel_match_score()
  status                  text NOT NULL DEFAULT 'PENDING'
                          CHECK (status IN ('PENDING', 'USER_A_ACCEPTED', 'USER_B_ACCEPTED', 'CONNECTED',
                                            'DECLINED', 'EXPIRED', 'BLOCKED')),
  user_a_consent          boolean,
  user_b_consent          boolean,
  offered_at              timestamptz,   -- when A was asked; NULL = a ranked candidate not shown yet
  b_asked_at              timestamptz,   -- when B was asked (after A said yes)
  connected_at            timestamptz,
  close_reason            text,          -- declined_by_a / declined_by_b / timeout / intent_updated /
                                         -- intent_cancelled / superseded / blocked / reported
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  expires_at              timestamptz NOT NULL,
  CHECK (travel_intent_a <> travel_intent_b),
  CHECK (user_a <> user_b)
);
-- the same two requests can never have two live matches at once
CREATE UNIQUE INDEX IF NOT EXISTS travel_matches_live_pair
  ON public.travel_matches (least(travel_intent_a, travel_intent_b), greatest(travel_intent_a, travel_intent_b))
  WHERE status IN ('PENDING', 'USER_A_ACCEPTED', 'USER_B_ACCEPTED', 'CONNECTED');
CREATE INDEX IF NOT EXISTS travel_matches_intent_a ON public.travel_matches (travel_intent_a, status);
CREATE INDEX IF NOT EXISTS travel_matches_intent_b ON public.travel_matches (travel_intent_b, status);
CREATE INDEX IF NOT EXISTS travel_matches_people
  ON public.travel_matches (least(user_a, user_b), greatest(user_a, user_b));
CREATE INDEX IF NOT EXISTS travel_matches_expiry
  ON public.travel_matches (expires_at) WHERE status IN ('PENDING', 'USER_A_ACCEPTED', 'USER_B_ACCEPTED');

-- "block this person": never match these two users again (checked in both directions)
CREATE TABLE IF NOT EXISTS public.travel_blocks (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_user_id uuid NOT NULL REFERENCES public.travel_users (id),
  blocked_user_id uuid NOT NULL REFERENCES public.travel_users (id),
  match_id        uuid REFERENCES public.travel_matches (id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (blocker_user_id, blocked_user_id),
  CHECK (blocker_user_id <> blocked_user_id)
);

-- "report this user": for a human to review. A report also blocks.
CREATE TABLE IF NOT EXISTS public.travel_reports (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id uuid NOT NULL REFERENCES public.travel_users (id),
  reported_user_id uuid NOT NULL REFERENCES public.travel_users (id),
  match_id         uuid REFERENCES public.travel_matches (id),
  reason           text,
  reviewed_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- Geocoding results, so the same place is looked up once. Not linked to any user.
CREATE TABLE IF NOT EXISTS public.travel_geocode_cache (
  query_key  text PRIMARY KEY,           -- "<provider>:<normalised place text>"
  provider   text NOT NULL,
  lat        double precision NOT NULL,
  lng        double precision NOT NULL,
  label      text,                       -- the provider's name for the place (debugging only)
  created_at timestamptz NOT NULL DEFAULT now()
);

-- WhatsApp redelivers webhooks; each message ID is handled once
CREATE TABLE IF NOT EXISTS public.travel_inbound_messages (
  message_id  text PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES public.travel_users (id),
  received_at timestamptz NOT NULL DEFAULT now()
);

-- Domain events and structured logs. IDs only: no phone numbers, coordinates, places or message text.
CREATE TABLE IF NOT EXISTS public.travel_events (
  id         bigserial PRIMARY KEY,
  event      text NOT NULL,              -- travel.intent.created, travel.match.found, travel.notification.sent …
  user_id    uuid,
  intent_id  uuid,
  match_id   uuid,
  details    jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS travel_events_user ON public.travel_events (user_id, event, created_at);
CREATE INDEX IF NOT EXISTS travel_events_time ON public.travel_events (created_at);

-- Phone numbers and locations: keep every table away from Supabase's anon / authenticated REST API.
-- n8n connects as the table owner, which RLS does not affect.
ALTER TABLE public.travel_users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_intents          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_matches          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_blocks           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_reports          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_geocode_cache    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_inbound_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.travel_events           ENABLE ROW LEVEL SECURITY;
