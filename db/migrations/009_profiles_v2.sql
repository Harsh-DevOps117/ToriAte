-- Profiles v2 and matching v2 (plan/tori-matching-architecture.md). Tables only; the functions are in
-- 006_profile_functions.repeatable.sql (onboarding), 008_held_messages.repeatable.sql and
-- 009_matching_v2.repeatable.sql (matching, consent, cards).
--
-- Onboarding asks one thing at a time: name, age, gender, interests, then optionally an Instagram or
-- LinkedIn link and a photo, then who may see those before both people say yes.

ALTER TABLE public.tori_users
  ADD COLUMN IF NOT EXISTS name_source   text NOT NULL DEFAULT 'whatsapp'
                                          CHECK (name_source IN ('whatsapp', 'user')),   -- 'user' = they told us or confirmed it
  ADD COLUMN IF NOT EXISTS social_kind   text CHECK (social_kind IN ('instagram', 'linkedin')),
  ADD COLUMN IF NOT EXISTS social_url    text,
  ADD COLUMN IF NOT EXISTS skipped       text[] NOT NULL DEFAULT '{}',   -- optional steps they skipped: social, photo
  ADD COLUMN IF NOT EXISTS privacy       jsonb NOT NULL DEFAULT '{"photo": "after", "social": "after"}',
  ADD COLUMN IF NOT EXISTS privacy_set_at timestamptz;

-- Profile photos, served to WhatsApp by the board (web/, GET /p/<token>) so they can be a message
-- header. The token is random and only ever put into messages for a matched person.
CREATE TABLE IF NOT EXISTS public.tori_user_photos (
  token      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL UNIQUE REFERENCES public.tori_users (id),
  mime       text NOT NULL CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  bytes      bytea NOT NULL CHECK (octet_length(bytes) BETWEEN 1 AND 5242880),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Where the request is: the geocoded area (workflow 08), for radius matching. NULL = not geocoded:
-- matched on city + area name instead.
ALTER TABLE public.partner_requests
  ADD COLUMN IF NOT EXISTS lat double precision CHECK (lat BETWEEN -90 AND 90),
  ADD COLUMN IF NOT EXISTS lng double precision CHECK (lng BETWEEN -180 AND 180);

-- Matching settings, editable without a deploy (defaults in public.tori_cfg()):
--   INSERT INTO tori_settings VALUES ('time_gap_min', '90') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
CREATE TABLE IF NOT EXISTS public.tori_settings (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tori_user_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tori_settings    ENABLE ROW LEVEL SECURITY;
