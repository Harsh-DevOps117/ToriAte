-- Partner matching (MVP) for the Tori WhatsApp bot (workflow 06).
-- Locally: applied by db/migrate.sh to the `tori` database (public schema).
-- Supabase: run this file once in the SQL editor (same project as intent_pool / user_sessions).
-- Safe to re-run: tables use IF NOT EXISTS, functions use CREATE OR REPLACE.

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per "I want someone to play X with". Starts as a draft while the bot
-- asks for missing details, becomes 'open' when complete.
CREATE TABLE IF NOT EXISTS public.partner_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa_id           text NOT NULL,                      -- WhatsApp number, digits only
  profile_name    text,                               -- WhatsApp profile name
  status          text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'open', 'proposed', 'matched', 'cancelled', 'expired')),
  activity        text,                               -- canonical: football, badminton, table_tennis …
  city            text,                               -- canonical lower-case: bangalore
  area            text,                               -- as the user wrote it: Indiranagar
  area_key        text,                               -- normalised for matching: indiranagar
  play_date       date,                               -- India date
  time_exact      time,                               -- 18:00 when a clock time was given
  part_of_day     text CHECK (part_of_day IN ('morning', 'afternoon', 'evening', 'night')),
  time_label      text,                               -- for messages: "around 6 PM", "in the evening"
  window_start    timestamptz,                        -- matching window
  window_end      timestamptz,
  skill_level     text CHECK (skill_level IN ('beginner', 'intermediate', 'advanced')),
  players_needed  int NOT NULL DEFAULT 1 CHECK (players_needed BETWEEN 1 AND 10),
  notes           text,
  raw_text        text,                               -- every message that built this request
  last_message_at timestamptz NOT NULL DEFAULT now(), -- for the WhatsApp 24-hour window
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (status IN ('draft', 'cancelled', 'expired')
         OR (activity IS NOT NULL AND city IS NOT NULL AND area_key IS NOT NULL
             AND play_date IS NOT NULL AND window_start < window_end))
);
CREATE INDEX IF NOT EXISTS partner_requests_open
  ON public.partner_requests (activity, city, play_date) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS partner_requests_user
  ON public.partner_requests (wa_id, status, updated_at);

-- One row per proposed pair. Both sides must say yes.
CREATE TABLE IF NOT EXISTS public.partner_matches (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_a   uuid NOT NULL REFERENCES public.partner_requests (id),  -- the request that triggered the search
  request_b   uuid NOT NULL REFERENCES public.partner_requests (id),  -- the request that was waiting
  wa_a        text NOT NULL,
  wa_b        text NOT NULL,
  a_response  text CHECK (a_response IN ('yes', 'no')),
  b_response  text CHECK (b_response IN ('yes', 'no')),
  status      text NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'confirmed', 'declined', 'expired')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  decided_at  timestamptz,
  CHECK (request_a <> request_b)
);
-- the same two requests can only ever be proposed once
CREATE UNIQUE INDEX IF NOT EXISTS partner_matches_pair
  ON public.partner_matches (least(request_a, request_b), greatest(request_a, request_b));
CREATE INDEX IF NOT EXISTS partner_matches_people
  ON public.partner_matches (least(wa_a, wa_b), greatest(wa_a, wa_b));

-- Phone numbers are personal data: keep these tables away from the anon / authenticated
-- REST API. n8n connects as the table owner, which is not affected by RLS.
ALTER TABLE public.partner_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_matches  ENABLE ROW LEVEL SECURITY;

-- ─────────────────────────────────────────────────────────────────────────────
-- save_partner_request: create or continue the user's request
-- p = the "fields" object built by the n8n node "Validate partner request"
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.save_partner_request(p_wa_id text, p_name text, p jsonb, p_complete boolean)
RETURNS public.partner_requests
LANGUAGE plpgsql AS $$
DECLARE
  r public.partner_requests;
BEGIN
  -- continue this user's draft from the last 30 minutes, or start a new request
  SELECT * INTO r FROM public.partner_requests
   WHERE wa_id = p_wa_id AND status = 'draft' AND updated_at > now() - interval '30 minutes'
   ORDER BY updated_at DESC LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.partner_requests (wa_id) VALUES (p_wa_id) RETURNING * INTO r;
  END IF;

  UPDATE public.partner_requests SET
    profile_name    = coalesce(p_name, profile_name),
    activity        = p ->> 'activity',
    city            = p ->> 'city',
    area            = p ->> 'area',
    area_key        = p ->> 'area_key',
    play_date       = (p ->> 'play_date')::date,
    time_exact      = (p ->> 'time_exact')::time,
    part_of_day     = p ->> 'part_of_day',
    time_label      = p ->> 'time_label',
    window_start    = (p ->> 'window_start')::timestamptz,
    window_end      = (p ->> 'window_end')::timestamptz,
    skill_level     = p ->> 'skill_level',
    players_needed  = coalesce((p ->> 'players_needed')::int, 1),
    notes           = p ->> 'notes',
    raw_text        = concat_ws(E'\n', raw_text, p ->> 'raw_text'),
    status          = CASE WHEN p_complete THEN 'open' ELSE 'draft' END,
    last_message_at = now(),
    updated_at      = now()
  WHERE id = r.id
  RETURNING * INTO r;

  IF p_complete THEN
    -- one live request per person, activity and day: the newest one wins
    UPDATE public.partner_requests SET status = 'cancelled', updated_at = now()
     WHERE wa_id = p_wa_id AND id <> r.id AND status IN ('draft', 'open')
       AND activity = r.activity AND play_date = r.play_date;
  END IF;
  RETURN r;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- match_partner_request: find the best open partner and propose the pair.
-- Returns NULL when there is nobody, otherwise both sides' details.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.match_partner_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  me      public.partner_requests;
  other   public.partner_requests;
  v_match uuid;
BEGIN
  SELECT * INTO me FROM public.partner_requests WHERE id = p_request_id;
  IF NOT FOUND OR me.status <> 'open' OR me.window_end <= now() THEN
    RETURN NULL;
  END IF;

  -- One search at a time per activity, city and day. Two people posting at the same
  -- moment are serialised here, so they always see each other (no missed match, no deadlock).
  PERFORM pg_advisory_xact_lock(hashtext(me.activity || '|' || me.city || '|' || me.play_date::text));
  SELECT * INTO me FROM public.partner_requests WHERE id = p_request_id FOR UPDATE;
  IF me.status <> 'open' THEN
    RETURN NULL;
  END IF;

  SELECT r.* INTO other
    FROM public.partner_requests r
   WHERE r.status = 'open'
     AND r.id <> me.id
     AND r.wa_id <> me.wa_id                                    -- never yourself
     AND r.activity = me.activity                               -- same sport
     AND r.city = me.city
     AND r.area_key = me.area_key                               -- same area (MVP)
     AND r.play_date = me.play_date
     AND r.window_start < me.window_end
     AND me.window_start < r.window_end                         -- time windows overlap
     AND r.window_end > now()
     AND NOT coalesce((r.skill_level, me.skill_level) IN (('beginner', 'advanced'), ('advanced', 'beginner')), false)
     AND NOT EXISTS (                                           -- these two requests were never paired
           SELECT 1 FROM public.partner_matches pm
            WHERE least(pm.request_a, pm.request_b) = least(me.id, r.id)
              AND greatest(pm.request_a, pm.request_b) = greatest(me.id, r.id))
     AND NOT EXISTS (                                           -- these two people did not decline each other this week
           SELECT 1 FROM public.partner_matches pm
            WHERE least(pm.wa_a, pm.wa_b) = least(me.wa_id, r.wa_id)
              AND greatest(pm.wa_a, pm.wa_b) = greatest(me.wa_id, r.wa_id)
              AND pm.status = 'declined' AND pm.created_at > now() - interval '7 days')
   ORDER BY abs(extract(epoch FROM (r.window_start + (r.window_end - r.window_start) / 2)
                                 - (me.window_start + (me.window_end - me.window_start) / 2))),
            r.created_at
   LIMIT 1
   FOR UPDATE OF r;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.partner_matches (request_a, request_b, wa_a, wa_b)
  VALUES (me.id, other.id, me.wa_id, other.wa_id)
  RETURNING id INTO v_match;
  UPDATE public.partner_requests SET status = 'proposed', updated_at = now() WHERE id IN (me.id, other.id);

  RETURN jsonb_build_object(
    'match_id', v_match,
    'activity', me.activity,
    'play_date', me.play_date,
    'a', jsonb_build_object('wa_id', me.wa_id, 'name', me.profile_name, 'area', me.area,
                            'time_label', me.time_label, 'last_message_at', me.last_message_at),
    'b', jsonb_build_object('wa_id', other.wa_id, 'name', other.profile_name, 'area', other.area,
                            'time_label', other.time_label, 'last_message_at', other.last_message_at));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- respond_partner_match: a "Yes, connect" / "No, thanks" tap. Idempotent.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.respond_partner_match(p_match_id uuid, p_wa_id text, p_accept boolean)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  m          public.partner_matches;
  ra         public.partner_requests;
  rb         public.partner_requests;
  v_changed  boolean := false;
  v_reopened uuid[] := '{}';
  v_answer   text := CASE WHEN p_accept THEN 'yes' ELSE 'no' END;
BEGIN
  SELECT * INTO m FROM public.partner_matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR p_wa_id NOT IN (m.wa_a, m.wa_b) THEN
    RETURN jsonb_build_object('state', 'unknown', 'reopened', '[]'::jsonb);
  END IF;

  -- the tap is a message from this person: their 24-hour window is open again
  UPDATE public.partner_requests SET last_message_at = now()
   WHERE id IN (m.request_a, m.request_b) AND wa_id = p_wa_id;

  IF m.status = 'pending' THEN
    -- only the first answer per side counts (double taps change nothing)
    IF p_wa_id = m.wa_a AND m.a_response IS NULL THEN
      UPDATE public.partner_matches SET a_response = v_answer WHERE id = m.id RETURNING * INTO m;
      v_changed := true;
    ELSIF p_wa_id = m.wa_b AND m.b_response IS NULL THEN
      UPDATE public.partner_matches SET b_response = v_answer WHERE id = m.id RETURNING * INTO m;
      v_changed := true;
    END IF;

    IF m.a_response = 'no' OR m.b_response = 'no' THEN
      UPDATE public.partner_matches SET status = 'declined', decided_at = now() WHERE id = m.id RETURNING * INTO m;
      WITH r AS (
        UPDATE public.partner_requests SET status = 'open', updated_at = now()
         WHERE id IN (m.request_a, m.request_b) AND status = 'proposed' AND window_end > now()
        RETURNING id)
      SELECT coalesce(array_agg(id), '{}') INTO v_reopened FROM r;
    ELSIF m.a_response = 'yes' AND m.b_response = 'yes' THEN
      UPDATE public.partner_matches SET status = 'confirmed', decided_at = now() WHERE id = m.id RETURNING * INTO m;
      -- a request that needs more players goes back into the pool
      UPDATE public.partner_requests r
         SET status = CASE WHEN (SELECT count(*) FROM public.partner_matches pm
                                  WHERE pm.status = 'confirmed' AND r.id IN (pm.request_a, pm.request_b))
                                >= r.players_needed THEN 'matched' ELSE 'open' END,
             updated_at = now()
       WHERE r.id IN (m.request_a, m.request_b);
      SELECT coalesce(array_agg(id), '{}') INTO v_reopened FROM public.partner_requests
       WHERE id IN (m.request_a, m.request_b) AND status = 'open';
    END IF;
  END IF;

  SELECT * INTO ra FROM public.partner_requests WHERE id = m.request_a;
  SELECT * INTO rb FROM public.partner_requests WHERE id = m.request_b;
  RETURN jsonb_build_object(
    'state', m.status,
    'changed', v_changed,
    'accepted', p_accept,
    'responder', CASE WHEN p_wa_id = m.wa_a THEN 'a' ELSE 'b' END,
    'activity', ra.activity,
    'play_date', ra.play_date,
    'reopened', to_jsonb(v_reopened),
    'a', jsonb_build_object('wa_id', ra.wa_id, 'name', ra.profile_name, 'area', ra.area,
                            'time_label', ra.time_label, 'last_message_at', ra.last_message_at),
    'b', jsonb_build_object('wa_id', rb.wa_id, 'name', rb.profile_name, 'area', rb.area,
                            'time_label', rb.time_label, 'last_message_at', rb.last_message_at));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- cancel_partner_requests: "stop looking" / "cancel"
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cancel_partner_requests(p_wa_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  m          record;
  v_other    uuid;
  v_reopened uuid[] := '{}';
BEGIN
  -- the other side of any pending proposal goes back into the pool
  FOR m IN
    UPDATE public.partner_matches
       SET status = 'declined', decided_at = now(),
           a_response = CASE WHEN wa_a = p_wa_id THEN 'no' ELSE a_response END,
           b_response = CASE WHEN wa_b = p_wa_id THEN 'no' ELSE b_response END
     WHERE status = 'pending' AND p_wa_id IN (wa_a, wa_b)
    RETURNING *
  LOOP
    v_other := CASE WHEN m.wa_a = p_wa_id THEN m.request_b ELSE m.request_a END;
    UPDATE public.partner_requests SET status = 'open', updated_at = now()
     WHERE id = v_other AND status = 'proposed' AND window_end > now();
    IF FOUND THEN
      v_reopened := v_reopened || v_other;
    END IF;
  END LOOP;

  UPDATE public.partner_requests SET status = 'cancelled', updated_at = now()
   WHERE wa_id = p_wa_id AND status IN ('draft', 'open', 'proposed');
  RETURN jsonb_build_object('reopened', to_jsonb(v_reopened));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- expire_partner_requests: called every 15 minutes by the n8n schedule
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.expire_partner_requests()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_reopened uuid[];
BEGIN
  -- proposals not answered within 2 hours, or whose game time has passed
  WITH stale AS (
    UPDATE public.partner_matches pm SET status = 'expired', decided_at = now()
     WHERE pm.status = 'pending'
       AND (pm.created_at < now() - interval '2 hours'
            OR EXISTS (SELECT 1 FROM public.partner_requests r
                        WHERE r.id IN (pm.request_a, pm.request_b) AND r.window_end < now()))
    RETURNING pm.*),
  -- whoever said yes goes back into the pool; whoever did not answer leaves it
  sides AS (
    SELECT request_a AS id, a_response = 'yes' AS keep FROM stale
    UNION ALL
    SELECT request_b, b_response = 'yes' FROM stale),
  upd AS (
    UPDATE public.partner_requests r
       SET status = CASE WHEN s.keep AND r.window_end > now() THEN 'open' ELSE 'expired' END,
           updated_at = now()
      FROM sides s
     WHERE r.id = s.id AND r.status = 'proposed'
    RETURNING r.id, r.status)
  SELECT coalesce(array_agg(id) FILTER (WHERE status = 'open'), '{}') INTO v_reopened FROM upd;

  -- requests whose time has passed, and drafts nobody finished
  UPDATE public.partner_requests SET status = 'expired', updated_at = now()
   WHERE (status IN ('open', 'proposed') AND window_end < now())
      OR (status = 'draft' AND updated_at < now() - interval '30 minutes');

  RETURN jsonb_build_object('reopened', to_jsonb(v_reopened));
END $$;

-- Supabase exposes public functions over REST to anyone with the anon key.
-- These must only be called by n8n (Postgres credential). The anon / authenticated roles
-- exist only on Supabase, so they are revoked only where they exist.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.save_partner_request(text, text, jsonb, boolean)',
    'public.match_partner_request(uuid)',
    'public.respond_partner_match(uuid, text, boolean)',
    'public.cancel_partner_requests(text)',
    'public.expire_partner_requests()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
