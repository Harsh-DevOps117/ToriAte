-- User profiles for the Tori WhatsApp bot (workflow 06): who someone is (age, gender, interests),
-- what the bot is waiting for from them, and every inbound message (deduplicated).
-- Tables only. The functions are in 006_profile_functions.repeatable.sql.
-- Locally: applied by db/migrate.sh to the `tori` database (public schema, next to partner_requests).
-- Supabase: run this file, then 006_profile_functions.repeatable.sql, in the SQL editor.
-- Safe to re-run.
--
-- Flow: a person's first partner request is saved before onboarding, as partner_requests.status =
-- 'pending_profile'. The bot asks for their profile; once it is complete the request is picked up
-- again (opened and matched, or the bot asks for what the request still lacks). The first message
-- is never lost and never has to be sent again.

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per WhatsApp number that has messaged the bot.
CREATE TABLE IF NOT EXISTS public.tori_users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone          text NOT NULL UNIQUE CHECK (phone ~ '^\+[1-9]\d{5,14}$'),  -- E.164, the lookup key
  name           text,                         -- what they told us, else the WhatsApp profile name
  birth_year     int CHECK (birth_year BETWEEN 1900 AND 2100),  -- from the age they gave, so it doesn't go stale
  gender         text CHECK (gender IN ('male', 'female', 'non_binary', 'other', 'prefer_not_to_say')),
  interests      text[],                       -- canonical activity names: {badminton, football}
  location       text,                         -- city / area; asked per request for now
  timezone       text NOT NULL DEFAULT 'Asia/Kolkata',
  profile_status text NOT NULL DEFAULT 'incomplete' CHECK (profile_status IN ('incomplete', 'complete')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tori_users_interests ON public.tori_users USING gin (interests);

-- What the bot is waiting for from each person: idle → awaiting_profile → idle.
CREATE TABLE IF NOT EXISTS public.tori_conversation_state (
  user_id            uuid PRIMARY KEY REFERENCES public.tori_users (id),
  state              text NOT NULL DEFAULT 'idle' CHECK (state IN ('idle', 'awaiting_profile')),
  pending_request_id uuid REFERENCES public.partner_requests (id) ON DELETE SET NULL,
  context            jsonb NOT NULL DEFAULT '{}',  -- request_complete, followup question, asks
  updated_at         timestamptz NOT NULL DEFAULT now()
);

-- Every inbound message (and the bot's profile questions). wa_message_id makes Meta's
-- redeliveries harmless: the second copy is not processed.
CREATE TABLE IF NOT EXISTS public.tori_messages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES public.tori_users (id),
  wa_message_id text UNIQUE,
  direction     text NOT NULL CHECK (direction IN ('in', 'out')),
  type          text,                          -- text, interactive, button, image …
  body          text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tori_messages_user ON public.tori_messages (user_id, created_at);

-- ─────────────────────────────────────────────────────────────────────────────
-- partner_requests (004) gains 'pending_profile': saved, waiting for the profile.
-- Like a draft it may still lack details, and it is never a match candidate.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.partner_requests'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) LIKE '%''draft''%'
  LOOP
    EXECUTE format('ALTER TABLE public.partner_requests DROP CONSTRAINT %I', c);
  END LOOP;
END $$;
ALTER TABLE public.partner_requests
  ADD CONSTRAINT partner_requests_status_ck
    CHECK (status IN ('draft', 'pending_profile', 'open', 'proposed', 'matched', 'cancelled', 'expired')),
  ADD CONSTRAINT partner_requests_complete_ck
    CHECK (status IN ('draft', 'pending_profile', 'cancelled', 'expired')
           OR (activity IS NOT NULL AND city IS NOT NULL AND area_key IS NOT NULL
               AND play_date IS NOT NULL AND window_start < window_end));

-- When a request first went live (open). The partner board (007) only shows requests that did:
-- drafts and parked requests that were dropped never appear. Set by a trigger (006_profile_functions).
ALTER TABLE public.partner_requests ADD COLUMN IF NOT EXISTS opened_at timestamptz;
UPDATE public.partner_requests SET opened_at = created_at
 WHERE opened_at IS NULL AND activity IS NOT NULL AND area_key IS NOT NULL AND window_start IS NOT NULL
   AND (status IN ('open', 'proposed', 'matched')
        OR id IN (SELECT request_a FROM public.partner_matches UNION SELECT request_b FROM public.partner_matches));

-- Phone numbers and profiles are personal data: keep them away from Supabase's anon /
-- authenticated REST API. n8n connects as the table owner, which RLS does not affect.
ALTER TABLE public.tori_users              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tori_conversation_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tori_messages           ENABLE ROW LEVEL SECURITY;
