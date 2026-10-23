-- Matching v2 (plan/tori-matching-architecture.md §6, §3.3). Tables: 009_profiles_v2.sql.
-- Replaces three functions first defined in 004_partner_matching.sql:
--   save_partner_request   + stores the geocoded point (lat, lng)
--   match_partner_request  radius + configurable time gap + compatible activities
--   respond_partner_match  sequential consent: the searcher answers first, then the waiting person is asked
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings: defaults here, overridden by rows in public.tori_settings
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_cfg()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
           'time_gap_min', 120,               -- the two time ranges at most this far apart
           'radius_km', 3,                    -- geocoded areas at most this far apart
           'compatible_activities', '[]'::jsonb)  -- groups that match each other, e.g. [["tennis", "padel"]]
         || coalesce((SELECT jsonb_object_agg(key, value) FROM public.tori_settings), '{}');
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- save_partner_request (004) + lat / lng from the "fields" object
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
    -- the name they confirmed (017) beats the WhatsApp profile name the workflow passes in
    profile_name    = coalesce((SELECT u.name FROM public.tori_users u WHERE u.phone = '+' || p_wa_id AND u.name_source = 'user'),
                               p_name, profile_name),
    activity        = p ->> 'activity',
    city            = p ->> 'city',
    area            = p ->> 'area',
    area_key        = p ->> 'area_key',
    lat             = CASE WHEN jsonb_typeof(p -> 'lat') = 'number' THEN (p ->> 'lat')::float8 END,
    lng             = CASE WHEN jsonb_typeof(p -> 'lng') = 'number' THEN (p ->> 'lng')::float8 END,
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

-- The part of a request's time that matters for matching: an exact time is a point (the centre of
-- its ±30 min window), a part of day ("evening") is its whole range.
CREATE OR REPLACE FUNCTION public.tori_time_range(r public.partner_requests)
RETURNS tstzrange
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN r.time_exact IS NOT NULL
              THEN tstzrange(r.window_start + (r.window_end - r.window_start) / 2,
                             r.window_start + (r.window_end - r.window_start) / 2, '[]')
              ELSE tstzrange(r.window_start, r.window_end, '[]') END;
$$;

-- Minutes between two requests' time ranges (0 when they overlap).
CREATE OR REPLACE FUNCTION public.tori_time_gap_min(a public.partner_requests, b public.partner_requests)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT greatest(0, extract(epoch FROM greatest(lower(public.tori_time_range(a)), lower(public.tori_time_range(b)))
                                      - least(upper(public.tori_time_range(a)), upper(public.tori_time_range(b)))) / 60)::numeric;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- match_partner_request: find the best open partner and propose the pair.
-- Rules (tori_cfg): same date; same activity, or in one compatible group; time ranges at most
-- time_gap_min apart; geocoded areas within radius_km (or, when either isn't geocoded, the same city
-- and area name); never yourself; never the same two requests twice; no pair that declined this week.
-- Skill: beginner and advanced never meet; a request without a level uses the person's profile level
-- ("about you"). Best = nearest, then closest in time, then most interests in common, then the oldest
-- request. Returns NULL or both sides.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.match_partner_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  me      public.partner_requests;
  other   public.partner_requests;
  cfg     jsonb := public.tori_cfg();
  v_match uuid;
  v_km    numeric;
  v_gap   numeric;
  my_user public.tori_users;
BEGIN
  SELECT * INTO me FROM public.partner_requests WHERE id = p_request_id;
  IF NOT FOUND OR me.status <> 'open' OR me.window_end <= now() THEN
    RETURN NULL;
  END IF;

  -- One search at a time per day. Two people posting at the same moment are serialised here,
  -- so they always see each other (no missed match, no deadlock, no double proposal).
  PERFORM pg_advisory_xact_lock(hashtext('partner|' || me.play_date::text));
  SELECT * INTO me FROM public.partner_requests WHERE id = p_request_id FOR UPDATE;
  IF me.status <> 'open' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO my_user FROM public.tori_users WHERE phone = '+' || me.wa_id;

  SELECT r.* INTO other
    FROM public.partner_requests r
    LEFT JOIN public.tori_users ru ON ru.phone = '+' || r.wa_id
    CROSS JOIN LATERAL (SELECT CASE WHEN me.lat IS NOT NULL AND r.lat IS NOT NULL
                                    THEN public.travel_distance_km(me.lat, me.lng, r.lat, r.lng) END AS km,
                               cardinality(ARRAY(SELECT unnest(coalesce(ru.interests, '{}'))
                                                 INTERSECT SELECT unnest(coalesce(my_user.interests, '{}')))) AS shared) d
   WHERE r.status = 'open'
     AND r.id <> me.id
     AND r.wa_id <> me.wa_id                                    -- never yourself
     AND r.play_date = me.play_date
     AND r.window_end > now()
     AND (r.activity = me.activity
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(cfg -> 'compatible_activities') g
                      WHERE g ? me.activity AND g ? r.activity))
     AND public.tori_time_gap_min(me, r) <= (cfg ->> 'time_gap_min')::numeric
     AND (d.km <= (cfg ->> 'radius_km')::numeric
          OR (d.km IS NULL AND r.city = me.city AND r.area_key = me.area_key))
     AND NOT coalesce((coalesce(r.skill_level, ru.skill_level), coalesce(me.skill_level, my_user.skill_level))
                      IN (('beginner', 'advanced'), ('advanced', 'beginner')), false)
     AND NOT EXISTS (                                           -- these two requests were never paired
           SELECT 1 FROM public.partner_matches pm
            WHERE least(pm.request_a, pm.request_b) = least(me.id, r.id)
              AND greatest(pm.request_a, pm.request_b) = greatest(me.id, r.id))
     AND NOT EXISTS (                                           -- these two people did not decline each other this week
           SELECT 1 FROM public.partner_matches pm
            WHERE least(pm.wa_a, pm.wa_b) = least(me.wa_id, r.wa_id)
              AND greatest(pm.wa_a, pm.wa_b) = greatest(me.wa_id, r.wa_id)
              AND pm.status = 'declined' AND pm.created_at > now() - interval '7 days')
   ORDER BY coalesce(d.km, (cfg ->> 'radius_km')::numeric), public.tori_time_gap_min(me, r), d.shared DESC, r.created_at
   LIMIT 1
   FOR UPDATE OF r;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  v_gap := public.tori_time_gap_min(me, other);
  v_km := CASE WHEN me.lat IS NOT NULL AND other.lat IS NOT NULL
               THEN round(public.travel_distance_km(me.lat, me.lng, other.lat, other.lng)::numeric, 1) END;

  INSERT INTO public.partner_matches (request_a, request_b, wa_a, wa_b, offered_at)
  VALUES (me.id, other.id, me.wa_id, other.wa_id, now())
  RETURNING id INTO v_match;
  UPDATE public.partner_requests SET status = 'proposed', updated_at = now() WHERE id IN (me.id, other.id);

  -- a = the searcher (asked first), b = the request that was waiting (asked once a says yes)
  RETURN jsonb_build_object(
    'match_id', v_match,
    'activity', me.activity,
    'play_date', me.play_date,
    'distance_km', v_km,
    'gap_min', v_gap,
    'a', jsonb_build_object('wa_id', me.wa_id, 'name', me.profile_name, 'area', me.area,
                            'time_label', me.time_label, 'last_message_at', me.last_message_at),
    'b', jsonb_build_object('wa_id', other.wa_id, 'name', other.profile_name, 'area', other.area,
                            'time_label', other.time_label, 'last_message_at', other.last_message_at));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- respond_partner_match: an "Interested" / "Not interested" tap. Idempotent.
-- Sequential consent: a (the searcher) sees b's card first. When a says yes, b is asked
-- (offered_at restarts the 2-hour clock). When b says yes too, the match is confirmed.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.respond_partner_match(p_match_id uuid, p_wa_id text, p_accept boolean)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  m          public.partner_matches;
  ra         public.partner_requests;
  rb         public.partner_requests;
  v_changed  boolean := false;
  v_ask_b    boolean := false;
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
      IF p_accept AND m.b_response IS NULL THEN
        UPDATE public.partner_matches SET offered_at = now() WHERE id = m.id RETURNING * INTO m;
        v_ask_b := true;
      END IF;
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
    'ask_b', v_ask_b,                                   -- a just said yes: send b the card now
    'b_was_asked', m.a_response = 'yes',                -- whether b ever saw this match
    'responder', CASE WHEN p_wa_id = m.wa_a THEN 'a' ELSE 'b' END,
    'match_id', m.id,
    'activity', ra.activity,
    'play_date', ra.play_date,
    'reopened', to_jsonb(v_reopened),
    'a', jsonb_build_object('wa_id', ra.wa_id, 'name', ra.profile_name, 'area', ra.area,
                            'time_label', ra.time_label, 'last_message_at', ra.last_message_at),
    'b', jsonb_build_object('wa_id', rb.wa_id, 'name', rb.profile_name, 'area', rb.area,
                            'time_label', rb.time_label, 'last_message_at', rb.last_message_at));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_match_view: what each side may see about the other, by privacy choice.
--   offer      before both said yes: first name, age, interests, area, time, and the photo / link
--              only if their owner chose "Anyone I match with"; has_photo / has_social say one exists
--   connected  after both said yes: + WhatsApp number, link and photo
-- photo_token is served by the board at /p/<token> (web/).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_match_view(p_match_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH m AS (SELECT * FROM public.partner_matches WHERE id = p_match_id),
  side AS (
    SELECT s.side, r.wa_id, r.area, r.time_label, r.last_message_at,
           coalesce(CASE WHEN u.name_source = 'user' THEN u.name END, r.profile_name, u.name) AS full_name,
           CASE WHEN u.birth_year IS NOT NULL THEN extract(year FROM now() AT TIME ZONE coalesce(u.timezone, 'Asia/Kolkata'))::int - u.birth_year END AS age,
           u.interests, u.social_kind, u.social_url, u.privacy, ph.token AS photo_token,
           u.about_summary, coalesce(r.skill_level, u.skill_level) AS skill
      FROM m
      CROSS JOIN LATERAL (VALUES ('a', m.request_a), ('b', m.request_b)) s(side, request_id)
      JOIN public.partner_requests r ON r.id = s.request_id
      LEFT JOIN public.tori_users u ON u.phone = '+' || r.wa_id
      LEFT JOIN public.tori_user_photos ph ON ph.user_id = u.id),
  card AS (
    SELECT side, jsonb_build_object(
      'wa_id', wa_id,
      'last_message_at', last_message_at,
      'offer', jsonb_strip_nulls(jsonb_build_object(
        'name', nullif(split_part(trim(coalesce(full_name, '')), ' ', 1), ''),
        'age', age, 'interests', to_jsonb(interests), 'area', area, 'time_label', time_label,
        'about', about_summary, 'skill', skill,
        'social_kind', social_kind,
        'social_url', CASE WHEN privacy ->> 'social' = 'before' THEN social_url END,
        'photo_token', CASE WHEN privacy ->> 'photo' = 'before' THEN photo_token END,
        'has_social', social_url IS NOT NULL,
        'has_photo', photo_token IS NOT NULL)),
      'connected', jsonb_strip_nulls(jsonb_build_object(
        'name', nullif(split_part(trim(coalesce(full_name, '')), ' ', 1), ''),
        'wa_id', wa_id, 'area', area, 'time_label', time_label,
        'social_kind', social_kind, 'social_url', social_url, 'photo_token', photo_token))) AS c
    FROM side)
  SELECT jsonb_build_object('match_id', p_match_id,
                            'a', (SELECT c FROM card WHERE side = 'a'),
                            'b', (SELECT c FROM card WHERE side = 'b'))
   WHERE EXISTS (SELECT 1 FROM m);
$$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for n8n
-- (Postgres credential) only. The anon / authenticated roles exist only on Supabase.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND (p.proname LIKE 'tori\_%' OR p.proname IN ('save_partner_request', 'match_partner_request', 'respond_partner_match'))
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
