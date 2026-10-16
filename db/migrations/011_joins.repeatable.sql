-- Joining a specific game (board Join button → WhatsApp "JOIN <code>" → the host accepts or declines).
-- Tables: 011_joins.sql. Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).
--
-- A game's spots = partner_requests.players_needed (1–10). Filled = accepted joins + confirmed matches.
-- When filled reaches spots the request is 'matched' (Full on the board) and pending joins are told so.

-- ─────────────────────────────────────────────────────────────────────────────
-- Join codes: 4 characters, no look-alikes (0/O, 1/I/L), unique among all requests
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_new_join_code()
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
BEGIN
  LOOP
    SELECT string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') INTO c
      FROM generate_series(1, 4);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.partner_requests WHERE join_code = c);
  END LOOP;
  RETURN c;
END $$;

-- the join code is stamped by tori_stamp_opened (006) when a request first goes live; older ones get one here
UPDATE public.partner_requests SET join_code = public.tori_new_join_code()
 WHERE join_code IS NULL AND opened_at IS NOT NULL;

-- How many people a game has: accepted joins + confirmed matches
CREATE OR REPLACE FUNCTION public.tori_request_filled(p_request_id uuid)
RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT (SELECT count(*) FROM public.partner_joins WHERE request_id = p_request_id AND status = 'accepted')::int
       + (SELECT count(*) FROM public.partner_matches
           WHERE status = 'confirmed' AND p_request_id IN (request_a, request_b))::int;
$$;

-- A person's card for someone deciding about them (offer: by their privacy choice) and once in
-- touch (connected: + number, link, photo). Same fields as tori_match_view (009).
CREATE OR REPLACE FUNCTION public.tori_person_card(p_wa_id text, p_area text, p_time_label text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'wa_id', p_wa_id,
    'last_message_at', (SELECT max(m.created_at) FROM public.tori_messages m
                         WHERE m.user_id = u.id AND m.direction = 'in'),
    'offer', jsonb_strip_nulls(jsonb_build_object(
      'name', nullif(split_part(trim(coalesce(u.name, '')), ' ', 1), ''),
      'age', CASE WHEN u.birth_year IS NOT NULL THEN extract(year FROM now() AT TIME ZONE coalesce(u.timezone, 'Asia/Kolkata'))::int - u.birth_year END,
      'interests', to_jsonb(u.interests), 'area', p_area, 'time_label', p_time_label,
      'about', u.about_summary, 'skill', u.skill_level, 'social_kind', u.social_kind,
      'social_url', CASE WHEN u.privacy ->> 'social' = 'before' THEN u.social_url END,
      'photo_token', CASE WHEN u.privacy ->> 'photo' = 'before' THEN ph.token END,
      'has_social', u.social_url IS NOT NULL, 'has_photo', ph.token IS NOT NULL)),
    'connected', jsonb_strip_nulls(jsonb_build_object(
      'name', nullif(split_part(trim(coalesce(u.name, '')), ' ', 1), ''),
      'wa_id', p_wa_id, 'area', p_area, 'time_label', p_time_label,
      'social_kind', u.social_kind, 'social_url', u.social_url, 'photo_token', ph.token)))
  FROM (SELECT 1) one
  LEFT JOIN public.tori_users u ON u.phone = '+' || p_wa_id
  LEFT JOIN public.tori_user_photos ph ON ph.user_id = u.id;
$$;

CREATE OR REPLACE FUNCTION public.tori_request_brief(r public.partner_requests)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('id', r.id, 'code', r.join_code, 'activity', r.activity, 'play_date', r.play_date,
                            'time_label', r.time_label, 'area', r.area, 'city', r.city,
                            'spots', r.players_needed, 'filled', public.tori_request_filled(r.id));
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_request_join: "JOIN <code>" from WhatsApp. state:
--   requested       → join saved; send the host the joiner's card (host, joiner below)
--   needs_profile   → the joiner has no complete profile: onboarding first, the join resumes after (006)
--   unknown / own / closed / full / already_pending / already_joined / declined_before
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_request_join(p_wa_id text, p_name text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u      public.tori_users;
  r      public.partner_requests;
  j      public.partner_joins;
  v_code text := upper(trim(coalesce(p_code, '')));
BEGIN
  u := public.tori_user(p_wa_id, p_name);
  SELECT * INTO r FROM public.partner_requests WHERE join_code = v_code FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unknown', 'code', v_code);
  END IF;
  IF r.wa_id = p_wa_id THEN
    RETURN jsonb_build_object('state', 'own', 'request', public.tori_request_brief(r));
  END IF;
  IF r.window_end <= now() OR r.status NOT IN ('open', 'proposed', 'matched') THEN
    RETURN jsonb_build_object('state', 'closed', 'request', public.tori_request_brief(r));
  END IF;

  SELECT * INTO j FROM public.partner_joins WHERE request_id = r.id AND joiner_wa = p_wa_id;
  IF FOUND AND j.status = 'pending' THEN
    RETURN jsonb_build_object('state', 'already_pending', 'request', public.tori_request_brief(r));
  ELSIF FOUND AND j.status = 'accepted' THEN
    RETURN jsonb_build_object('state', 'already_joined', 'request', public.tori_request_brief(r),
                              'host', public.tori_person_card(r.wa_id, r.area, r.time_label));
  ELSIF FOUND AND j.status = 'declined' THEN
    RETURN jsonb_build_object('state', 'declined_before', 'request', public.tori_request_brief(r));
  END IF;
  IF public.tori_request_filled(r.id) >= r.players_needed THEN
    RETURN jsonb_build_object('state', 'full', 'request', public.tori_request_brief(r));
  END IF;

  -- no complete profile yet: onboarding first (006 picks the join up again when it's done)
  IF cardinality(public.tori_profile_missing(u)) > 0 THEN
    UPDATE public.tori_conversation_state
       SET state = 'awaiting_profile', updated_at = now(),
           context = context || jsonb_build_object('join_code', v_code)
     WHERE user_id = u.id;
    RETURN public.tori_save_profile(p_wa_id, '{}')
           || jsonb_build_object('state', 'needs_profile', 'request', public.tori_request_brief(r));
  END IF;

  INSERT INTO public.partner_joins (request_id, joiner_wa) VALUES (r.id, p_wa_id)
  ON CONFLICT (request_id, joiner_wa) DO UPDATE SET status = 'pending', created_at = now(), decided_at = NULL
  RETURNING * INTO j;
  RETURN jsonb_build_object('state', 'requested', 'join_id', j.id, 'request', public.tori_request_brief(r),
                            'host', public.tori_person_card(r.wa_id, r.area, r.time_label),
                            'joiner', public.tori_person_card(p_wa_id, r.area, r.time_label));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_answer_join: the host's Accept / Decline. Idempotent. When the game fills up, the other pending
-- joins become 'full' (their joiners are listed in full_joiners, to be told).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_answer_join(p_host_wa text, p_join_id uuid, p_accept boolean)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  j       public.partner_joins;
  r       public.partner_requests;
  v_full  text[] := '{}';
  v_state text;
BEGIN
  -- lock order: the game first, then the join (as tori_request_join), so taps on several joins of one
  -- game queue up on the game row instead of deadlocking with the "game is full" update
  SELECT * INTO r FROM public.partner_requests
   WHERE id = (SELECT request_id FROM public.partner_joins WHERE id = p_join_id) FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  SELECT * INTO j FROM public.partner_joins WHERE id = p_join_id FOR UPDATE;
  IF r.wa_id <> p_host_wa THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  -- the tap is a message from the host: their 24-hour window is open again
  UPDATE public.partner_requests SET last_message_at = now() WHERE id = r.id;

  IF j.status <> 'pending' THEN
    v_state := j.status;
  ELSIF r.window_end <= now() THEN
    UPDATE public.partner_joins SET status = 'expired', decided_at = now() WHERE id = j.id;
    v_state := 'expired';
  ELSIF NOT p_accept THEN
    UPDATE public.partner_joins SET status = 'declined', decided_at = now() WHERE id = j.id;
    v_state := 'declined';
  ELSIF public.tori_request_filled(r.id) >= r.players_needed THEN
    UPDATE public.partner_joins SET status = 'full', decided_at = now() WHERE id = j.id;
    v_state := 'full';
  ELSE
    UPDATE public.partner_joins SET status = 'accepted', decided_at = now() WHERE id = j.id;
    v_state := 'accepted';
    IF public.tori_request_filled(r.id) >= r.players_needed THEN
      UPDATE public.partner_requests SET status = 'matched', updated_at = now()
       WHERE id = r.id AND status = 'open';
      WITH f AS (
        UPDATE public.partner_joins SET status = 'full', decided_at = now()
         WHERE request_id = r.id AND status = 'pending'
        RETURNING joiner_wa)
      SELECT coalesce(array_agg(joiner_wa), '{}') INTO v_full FROM f;
    END IF;
  END IF;

  SELECT * INTO r FROM public.partner_requests WHERE id = r.id;
  RETURN jsonb_build_object(
    'state', v_state, 'changed', j.status = 'pending', 'join_id', j.id,
    'request', public.tori_request_brief(r),
    'host', public.tori_person_card(r.wa_id, r.area, r.time_label),
    'joiner', public.tori_person_card(j.joiner_wa, r.area, r.time_label),
    'full_joiners', to_jsonb(v_full));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_set_spots: "spots 3" — how many people can join this person's latest live game.
-- A full game with more spots reopens (reopened = request id, to search for a match again); fewer spots
-- than people already in makes it full, and pending joins are closed (full_joiners, to be told).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_set_spots(p_wa_id text, p_spots int)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r        public.partner_requests;
  v_spots  int := least(greatest(coalesce(p_spots, 1), 1), 10);
  v_reopen uuid;
  v_full   text[] := '{}';
BEGIN
  SELECT * INTO r FROM public.partner_requests
   WHERE wa_id = p_wa_id AND status IN ('open', 'proposed', 'matched') AND window_end > now()
   ORDER BY opened_at DESC NULLS LAST LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'none');
  END IF;
  UPDATE public.partner_requests SET players_needed = v_spots, updated_at = now() WHERE id = r.id RETURNING * INTO r;
  IF r.status = 'matched' AND public.tori_request_filled(r.id) < v_spots THEN
    UPDATE public.partner_requests SET status = 'open', updated_at = now() WHERE id = r.id RETURNING * INTO r;
    v_reopen := r.id;
  ELSIF r.status = 'open' AND public.tori_request_filled(r.id) >= v_spots THEN
    UPDATE public.partner_requests SET status = 'matched', updated_at = now() WHERE id = r.id RETURNING * INTO r;
    WITH f AS (
      UPDATE public.partner_joins SET status = 'full', decided_at = now()
       WHERE request_id = r.id AND status = 'pending'
      RETURNING joiner_wa)
    SELECT coalesce(array_agg(joiner_wa), '{}') INTO v_full FROM f;
  END IF;
  RETURN jsonb_build_object('state', 'ok', 'request', public.tori_request_brief(r), 'reopened', v_reopen,
                            'too_few', public.tori_request_filled(r.id) > v_spots, 'full_joiners', to_jsonb(v_full));
END $$;

-- A join request for a host outside the 24-hour window, kept until the game is over (008)
CREATE OR REPLACE FUNCTION public.tori_hold_join(p_wa_id text, p_kind text, p_join_id uuid, p_body jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_expires timestamptz;
BEGIN
  SELECT r.window_end INTO v_expires
    FROM public.partner_joins j JOIN public.partner_requests r ON r.id = j.request_id
   WHERE j.id = p_join_id;
  v_expires := coalesce(v_expires, now() + interval '1 day');
  IF v_expires > now() THEN
    INSERT INTO public.tori_held_messages (wa_id, kind, join_id, body, expires_at)
    VALUES (p_wa_id, p_kind, p_join_id, p_body, v_expires);
  END IF;
END $$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for n8n
-- (Postgres credential) only. The anon / authenticated roles exist only on Supabase.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'tori\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
