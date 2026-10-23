-- Travel partner matching: every rule lives here, inside one transaction per call.
-- n8n (workflows 07–12) only moves data: it calls these functions and sends the WhatsApp messages
-- they ask for. The LLM never sees what these functions read; it only extracts fields.
--
-- Command functions return the same shape, so every workflow ends the same way:
--   { "outcome": "...", "intent_id": "...",
--     "notifications": [ { "user_id", "kind", "match_id" } ],   -- workflow 11 renders and sends them
--     "rematch": [ "<intent id>" ] }                              -- workflow 09 searches for them
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).

-- ─────────────────────────────────────────────────────────────────────────────
-- Configuration. Defaults here; n8n passes the TRAVEL_* environment variables
-- (see .env.example) and any value that is set and numeric wins.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_cfg(p jsonb DEFAULT '{}')
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_object_agg(d.key,
           CASE WHEN coalesce(p ->> d.key, '') ~ '^\s*\d+(\.\d+)?\s*$'
                THEN to_jsonb(trim(p ->> d.key)::numeric) ELSE d.value END)
  FROM jsonb_each('{
    "max_source_km": 3,
    "max_destination_km": 5,
    "max_time_diff_min": 45,
    "max_candidates": 3,
    "w_source": 0.4,
    "w_destination": 0.4,
    "w_time": 0.2,
    "consent_timeout_min": 120,
    "intent_grace_min": 30,
    "draft_ttl_min": 180,
    "max_days_ahead": 30,
    "max_changes_per_hour": 5,
    "max_changes_per_day": 15,
    "decline_cooldown_days": 7,
    "geocode_cache_days": 90
  }'::jsonb) AS d
$$;

-- Great-circle distance in km (haversine). Plain SQL, so it works without PostGIS.
CREATE OR REPLACE FUNCTION public.travel_distance_km(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
RETURNS float8
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT 2 * 6371.0088 * asin(least(1, sqrt(
           sin(radians(lat2 - lat1) / 2) ^ 2
         + cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lng2 - lng1) / 2) ^ 2)))
$$;

-- Ranking among eligible candidates: 0–100, higher is better. Each part is 1 at zero distance /
-- zero minutes and 0 at the eligibility limit; the weights (w_*) are configuration.
CREATE OR REPLACE FUNCTION public.travel_match_score(p_source_km float8, p_destination_km float8,
                                                     p_minutes float8, p_cfg jsonb)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT round((100 * (c.ws * coalesce(greatest(0, 1 - p_source_km / nullif(c.ms, 0)), 1)
                     + c.wd * coalesce(greatest(0, 1 - p_destination_km / nullif(c.md, 0)), 1)
                     + c.wt * coalesce(greatest(0, 1 - p_minutes / nullif(c.mt, 0)), 1))
                / nullif(c.ws + c.wd + c.wt, 0))::numeric, 2)
  FROM (SELECT (p_cfg ->> 'w_source')::float8 AS ws, (p_cfg ->> 'w_destination')::float8 AS wd,
               (p_cfg ->> 'w_time')::float8 AS wt, (p_cfg ->> 'max_source_km')::float8 AS ms,
               (p_cfg ->> 'max_destination_km')::float8 AS md, (p_cfg ->> 'max_time_diff_min')::float8 AS mt) c
$$;

-- Structured log / domain event. Callers pass IDs and codes only.
CREATE OR REPLACE FUNCTION public.travel_log(p_event text, p_user_id uuid, p_intent_id uuid,
                                             p_match_id uuid, p_details jsonb DEFAULT '{}')
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.travel_events (event, user_id, intent_id, match_id, details)
  VALUES (p_event, p_user_id, p_intent_id, p_match_id, coalesce(p_details, '{}'));
$$;

CREATE OR REPLACE FUNCTION public.travel_note(p_user_id uuid, p_kind text, p_match_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('user_id', p_user_id, 'kind', p_kind, 'match_id', p_match_id);
$$;

CREATE OR REPLACE FUNCTION public.travel_result(p_outcome text, p_intent_id uuid, p_notifications jsonb,
                                                p_rematch uuid[] DEFAULT '{}')
RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('outcome', p_outcome, 'intent_id', p_intent_id,
                            'notifications', coalesce(p_notifications, '[]'),
                            'rematch', to_jsonb(ARRAY(SELECT DISTINCT unnest(p_rematch))));
$$;

-- One writer at a time per user (two quick messages can't create two requests)
CREATE OR REPLACE FUNCTION public.travel_lock_user(p_user_id uuid)
RETURNS void
LANGUAGE sql AS $$
  SELECT pg_advisory_xact_lock(hashtext('travel-user'), hashtext(p_user_id::text));
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Inbound message: identify the user, remember the 24-hour window, drop redeliveries.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_begin_message(p_wa_id text, p_name text, p_message_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_user uuid;
  v_new  boolean := true;
BEGIN
  INSERT INTO public.travel_users AS u (wa_id, profile_name, last_message_at)
  VALUES (p_wa_id, nullif(trim(p_name), ''), now())
  ON CONFLICT (wa_id) DO UPDATE
    SET profile_name = coalesce(nullif(trim(EXCLUDED.profile_name), ''), u.profile_name),
        last_message_at = now(), updated_at = now()
  RETURNING id INTO v_user;

  IF nullif(p_message_id, '') IS NOT NULL THEN
    INSERT INTO public.travel_inbound_messages (message_id, user_id) VALUES (p_message_id, v_user)
    ON CONFLICT (message_id) DO NOTHING;
    v_new := FOUND;
    IF NOT v_new THEN
      PERFORM public.travel_log('travel.message.duplicate', v_user, NULL, NULL);
    END IF;
  END IF;
  RETURN jsonb_build_object('user_id', v_user, 'duplicate', NOT v_new);
END $$;

-- What the LLM may see about this person's own travel state (workflow 06, "Get partner draft").
-- Only their own request; nothing about anyone else.
CREATE OR REPLACE FUNCTION public.travel_context(p_wa_id text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH u AS (SELECT id FROM public.travel_users WHERE wa_id = p_wa_id),
  cfg AS (SELECT public.travel_cfg() AS c)
  SELECT jsonb_build_object(
    'request', (SELECT jsonb_build_object('source', i.source_text, 'destination', i.destination_text,
                                          'date', i.travel_date, 'time', to_char(i.departure_time, 'HH24:MI'),
                                          'status', lower(i.status))
                  FROM public.travel_intents i, cfg
                 WHERE i.user_id = (SELECT id FROM u)
                   AND (i.status = 'ACTIVE'
                        OR (i.status = 'DRAFT'
                            AND i.updated_at > now() - make_interval(mins => (cfg.c ->> 'draft_ttl_min')::int)))
                 ORDER BY i.updated_at DESC LIMIT 1),
    'awaiting_answer', EXISTS (SELECT 1 FROM public.travel_matches m
                                WHERE (m.user_a = (SELECT id FROM u) AND m.status = 'PENDING' AND m.offered_at IS NOT NULL)
                                   OR (m.user_b = (SELECT id FROM u) AND m.status = 'USER_A_ACCEPTED')),
    -- someone they were told about or connected with recently: "block this person" refers to them
    'recent_match', EXISTS (SELECT 1 FROM public.travel_matches m
                             WHERE ((m.user_a = (SELECT id FROM u) AND m.offered_at IS NOT NULL)
                                    OR (m.user_b = (SELECT id FROM u) AND m.b_asked_at IS NOT NULL))
                               AND m.updated_at > now() - interval '30 days'));
$$;

-- The user's current request (for merging a follow-up answer) and whether they may change it now.
CREATE OR REPLACE FUNCTION public.travel_load_request(p_user_id uuid, p_cfg jsonb)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH cfg AS (SELECT public.travel_cfg(p_cfg) AS c),
  changes AS (
    SELECT count(*) FILTER (WHERE e.created_at > now() - interval '1 hour') AS last_hour, count(*) AS last_day
      FROM public.travel_events e
     WHERE e.user_id = p_user_id AND e.event IN ('travel.intent.created', 'travel.intent.updated')
       AND e.created_at > now() - interval '1 day')
  SELECT jsonb_build_object(
    'request', (SELECT jsonb_build_object('id', i.id, 'status', lower(i.status),
                                          'source', i.source_text, 'destination', i.destination_text,
                                          'date', i.travel_date, 'time', to_char(i.departure_time, 'HH24:MI'))
                  FROM public.travel_intents i, cfg
                 WHERE i.user_id = p_user_id
                   AND (i.status = 'ACTIVE'
                        OR (i.status = 'DRAFT'
                            AND i.updated_at > now() - make_interval(mins => (cfg.c ->> 'draft_ttl_min')::int)))
                 ORDER BY i.updated_at DESC LIMIT 1),
    'rate_limited', (SELECT ch.last_hour >= (cfg.c ->> 'max_changes_per_hour')::int
                         OR ch.last_day >= (cfg.c ->> 'max_changes_per_day')::int FROM changes ch, cfg))
$$;

-- An incomplete request: remember what we have so the bot only asks for what is missing.
-- An ACTIVE request is never downgraded to a draft.
CREATE OR REPLACE FUNCTION public.travel_save_draft(p_user_id uuid, p jsonb)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  cur public.travel_intents;
BEGIN
  PERFORM public.travel_lock_user(p_user_id);
  SELECT * INTO cur FROM public.travel_intents
   WHERE user_id = p_user_id AND status IN ('DRAFT', 'ACTIVE') FOR UPDATE;
  IF FOUND AND cur.status = 'ACTIVE' THEN
    RETURN cur.id;
  END IF;
  IF NOT FOUND THEN
    INSERT INTO public.travel_intents (user_id) VALUES (p_user_id) RETURNING * INTO cur;
  END IF;
  UPDATE public.travel_intents SET
    source_text      = nullif(p ->> 'source_text', ''),
    destination_text = nullif(p ->> 'destination_text', ''),
    travel_date      = nullif(p ->> 'travel_date', '')::date,
    departure_time   = nullif(p ->> 'departure_time', '')::time,
    updated_at       = now()
  WHERE id = cur.id;
  RETURN cur.id;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Close every live match of one request (it changed, was cancelled, or its owner
-- connected with someone else). Whoever had already been asked about the match is told.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_close_open_matches(p_intent_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  m          record;
  v_notes    jsonb := '[]';
  v_rematch  uuid[] := '{}';
BEGIN
  FOR m IN
    UPDATE public.travel_matches
       SET status = 'EXPIRED', close_reason = p_reason, updated_at = now()
     WHERE status IN ('PENDING', 'USER_A_ACCEPTED', 'USER_B_ACCEPTED')
       AND p_intent_id IN (travel_intent_a, travel_intent_b)
    RETURNING *
  LOOP
    PERFORM public.travel_log('travel.match.expired', NULL, p_intent_id, m.id, jsonb_build_object('reason', p_reason));
    IF m.travel_intent_a = p_intent_id THEN
      -- this request is A: B only knows about the match once A said yes
      IF m.b_asked_at IS NOT NULL THEN
        v_notes := v_notes || public.travel_note(m.user_b, 'match_withdrawn', m.id);
      END IF;
    ELSIF m.offered_at IS NOT NULL THEN
      -- this request is B and A was looking at the offer: tell A and offer the next candidate
      v_notes := v_notes || public.travel_note(m.user_a, 'match_withdrawn', m.id);
      v_rematch := v_rematch || m.travel_intent_a;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('notifications', v_notes, 'rematch', to_jsonb(v_rematch));
END $$;

CREATE OR REPLACE FUNCTION public.travel_uuids(p jsonb)
RETURNS uuid[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(x::uuid), '{}') FROM jsonb_array_elements_text(coalesce(p, '[]')) AS x;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Complete request (fields validated by n8n, places geocoded): create or update the
-- user's ACTIVE TravelIntent. A real change bumps the version and closes stale matches.
-- p: source_text, source_lat, source_lng, destination_text, destination_lat,
--    destination_lng, travel_date (YYYY-MM-DD), departure_time (HH:MM)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_activate_intent(p_user_id uuid, p jsonb, p_cfg jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg       jsonb := public.travel_cfg(p_cfg);
  cur       public.travel_intents;
  v_has     boolean;
  v_id      uuid;
  v_date    date := (p ->> 'travel_date')::date;
  v_time    time := (p ->> 'departure_time')::time;
  v_dep     timestamptz;
  v_closed  jsonb := '{"notifications": [], "rematch": []}';
  n_hour    int;
  n_day     int;
BEGIN
  PERFORM public.travel_lock_user(p_user_id);
  v_dep := (v_date + v_time) AT TIME ZONE 'Asia/Kolkata';
  IF v_dep <= now() THEN
    RETURN public.travel_result('in_past', NULL, jsonb_build_array(public.travel_note(p_user_id, 'in_past')));
  END IF;
  IF v_dep > now() + make_interval(days => (cfg ->> 'max_days_ahead')::int) THEN
    RETURN public.travel_result('too_far', NULL, jsonb_build_array(public.travel_note(p_user_id, 'too_far')));
  END IF;

  SELECT * INTO cur FROM public.travel_intents
   WHERE user_id = p_user_id AND status IN ('DRAFT', 'ACTIVE') FOR UPDATE;
  v_has := FOUND;

  IF v_has AND cur.status = 'ACTIVE'
     AND lower(trim(cur.source_text)) = lower(trim(p ->> 'source_text'))
     AND lower(trim(cur.destination_text)) = lower(trim(p ->> 'destination_text'))
     AND cur.travel_date = v_date AND cur.departure_time = v_time THEN
    PERFORM public.travel_log('travel.intent.duplicate', p_user_id, cur.id, NULL);
    RETURN public.travel_result('unchanged', cur.id,
             jsonb_build_array(public.travel_note(p_user_id, 'request_unchanged')), ARRAY[cur.id]);
  END IF;

  -- Rate limit: every new or changed request is a fresh search, so cap how often someone can
  -- move their start / end point around (anti-enumeration).
  SELECT count(*) FILTER (WHERE created_at > now() - interval '1 hour'), count(*)
    INTO n_hour, n_day
    FROM public.travel_events
   WHERE user_id = p_user_id AND event IN ('travel.intent.created', 'travel.intent.updated')
     AND created_at > now() - interval '1 day';
  IF n_hour >= (cfg ->> 'max_changes_per_hour')::int OR n_day >= (cfg ->> 'max_changes_per_day')::int THEN
    PERFORM public.travel_log('travel.intent.rate_limited', p_user_id, CASE WHEN v_has THEN cur.id END, NULL,
                              jsonb_build_object('last_hour', n_hour, 'last_day', n_day));
    RETURN public.travel_result('rate_limited', NULL, jsonb_build_array(public.travel_note(p_user_id, 'rate_limited')));
  END IF;

  IF NOT v_has THEN
    INSERT INTO public.travel_intents (user_id) VALUES (p_user_id) RETURNING * INTO cur;
  END IF;
  UPDATE public.travel_intents SET
    status           = 'ACTIVE',
    source_text      = p ->> 'source_text',
    source_lat       = (p ->> 'source_lat')::float8,
    source_lng       = (p ->> 'source_lng')::float8,
    destination_text = p ->> 'destination_text',
    destination_lat  = (p ->> 'destination_lat')::float8,
    destination_lng  = (p ->> 'destination_lng')::float8,
    travel_date      = v_date,
    departure_time   = v_time,
    departure_at     = v_dep,
    expires_at       = v_dep + make_interval(mins => (cfg ->> 'intent_grace_min')::int),
    version          = CASE WHEN cur.status = 'ACTIVE' THEN version + 1 ELSE version END,
    updated_at       = now()
  WHERE id = cur.id
  RETURNING id INTO v_id;

  IF cur.status = 'ACTIVE' THEN
    -- route or time changed: matches made for the old details are stale
    v_closed := public.travel_close_open_matches(v_id, 'intent_updated');
    PERFORM public.travel_log('travel.intent.updated', p_user_id, v_id, NULL,
      jsonb_build_object('version', cur.version + 1,
                         'route_changed', lower(trim(cur.source_text)) <> lower(trim(p ->> 'source_text'))
                                          OR lower(trim(cur.destination_text)) <> lower(trim(p ->> 'destination_text')),
                         'time_changed', cur.travel_date <> v_date OR cur.departure_time <> v_time,
                         'closed_matches', jsonb_array_length(v_closed -> 'notifications')));
    RETURN public.travel_result('updated', v_id,
             jsonb_build_array(public.travel_note(p_user_id, 'request_updated')) || (v_closed -> 'notifications'),
             ARRAY[v_id] || public.travel_uuids(v_closed -> 'rematch'));
  END IF;

  PERFORM public.travel_log('travel.intent.created', p_user_id, v_id, NULL);
  RETURN public.travel_result('created', v_id,
           jsonb_build_array(public.travel_note(p_user_id, 'request_created')), ARRAY[v_id]);
END $$;

-- "Cancel my travel partner request"
CREATE OR REPLACE FUNCTION public.travel_cancel_intent(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r         public.travel_intents;
  v_closed  jsonb;
  v_notes   jsonb := '[]';
  v_rematch uuid[] := '{}';
  v_n       int := 0;
BEGIN
  PERFORM public.travel_lock_user(p_user_id);
  FOR r IN SELECT * FROM public.travel_intents
            WHERE user_id = p_user_id AND status IN ('DRAFT', 'ACTIVE') FOR UPDATE LOOP
    v_closed := public.travel_close_open_matches(r.id, 'intent_cancelled');
    v_notes := v_notes || (v_closed -> 'notifications');
    v_rematch := v_rematch || public.travel_uuids(v_closed -> 'rematch');
    UPDATE public.travel_intents SET status = 'CANCELLED', updated_at = now() WHERE id = r.id;
    PERFORM public.travel_log('travel.intent.cancelled', p_user_id, r.id, NULL, jsonb_build_object('was', lower(r.status)));
    v_n := v_n + 1;
  END LOOP;
  RETURN public.travel_result(CASE WHEN v_n > 0 THEN 'cancelled' ELSE 'nothing' END, NULL,
           jsonb_build_array(public.travel_note(p_user_id, CASE WHEN v_n > 0 THEN 'cancelled_ack' ELSE 'nothing_to_cancel' END))
           || v_notes,
           v_rematch);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Show the requester (A) their best waiting candidate, one at a time, so nobody gets a burst
-- of messages. Candidates that went stale meanwhile are closed silently.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_next_offer(p_intent_id uuid, p_cfg jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg jsonb := public.travel_cfg(p_cfg);
  me  public.travel_intents;
  m   public.travel_matches;
  ib  public.travel_intents;
BEGIN
  SELECT * INTO me FROM public.travel_intents WHERE id = p_intent_id;
  IF NOT FOUND OR me.status <> 'ACTIVE' OR me.departure_at <= now() THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.travel_matches
              WHERE travel_intent_a = me.id AND offered_at IS NOT NULL
                AND status IN ('PENDING', 'USER_A_ACCEPTED')) THEN
    RETURN NULL;   -- they are already looking at one
  END IF;
  LOOP
    SELECT * INTO m FROM public.travel_matches
     WHERE travel_intent_a = me.id AND status = 'PENDING' AND offered_at IS NULL
     ORDER BY match_score DESC, created_at
     LIMIT 1 FOR UPDATE SKIP LOCKED;
    EXIT WHEN NOT FOUND;
    SELECT * INTO ib FROM public.travel_intents WHERE id = m.travel_intent_b;
    IF ib.status = 'ACTIVE' AND ib.departure_at > now()
       AND NOT EXISTS (SELECT 1 FROM public.travel_blocks b
                        WHERE (b.blocker_user_id = m.user_a AND b.blocked_user_id = m.user_b)
                           OR (b.blocker_user_id = m.user_b AND b.blocked_user_id = m.user_a)) THEN
      UPDATE public.travel_matches
         SET offered_at = now(), updated_at = now(),
             expires_at = least(now() + make_interval(mins => (cfg ->> 'consent_timeout_min')::int),
                                me.departure_at, ib.departure_at)
       WHERE id = m.id;
      PERFORM public.travel_log('travel.match.offered', me.user_id, me.id, m.id);
      RETURN public.travel_note(me.user_id, 'offer', m.id);
    END IF;
    UPDATE public.travel_matches SET status = 'EXPIRED', close_reason = 'superseded', updated_at = now() WHERE id = m.id;
    PERFORM public.travel_log('travel.match.expired', me.user_id, me.id, m.id, '{"reason": "superseded"}');
  END LOOP;
  RETURN NULL;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The matcher. Runs for every new or changed request, and again whenever a request needs
-- its next candidate. Searches the ACTIVE pool, so a request that waited with no match
-- (A) is found by a later one (B): both directions work.
-- Returns only { matchFound, matchId, notifications }: no places, distances or other users.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_find_matches(p_intent_id uuid, p_cfg jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg        jsonb := public.travel_cfg(p_cfg);
  me         public.travel_intents;
  max_s      float8 := (cfg ->> 'max_source_km')::float8;
  max_d      float8 := (cfg ->> 'max_destination_km')::float8;
  max_t      float8 := (cfg ->> 'max_time_diff_min')::float8;
  v_cool     interval := make_interval(days => (cfg ->> 'decline_cooldown_days')::int);
  v_slots    int;
  v_eligible int;
  v_rejected int;
  v_created  int;
  v_offer    jsonb;
  none       jsonb := jsonb_build_object('matchFound', false, 'matchId', NULL, 'notifications', '[]'::jsonb);
BEGIN
  SELECT * INTO me FROM public.travel_intents WHERE id = p_intent_id;
  IF NOT FOUND OR me.status <> 'ACTIVE' OR me.departure_at <= now() THEN
    RETURN none;
  END IF;
  -- One search at a time per travel day: two people posting at the same moment are
  -- serialised here, so the second one always sees the first (no missed match, no duplicate).
  PERFORM pg_advisory_xact_lock(hashtext('travel-day'), hashtext(me.travel_date::text));
  SELECT * INTO me FROM public.travel_intents WHERE id = p_intent_id;
  IF me.status <> 'ACTIVE' THEN
    RETURN none;
  END IF;

  SELECT greatest(0, (cfg ->> 'max_candidates')::int - count(*)) INTO v_slots
    FROM public.travel_matches
   WHERE travel_intent_a = me.id AND status IN ('PENDING', 'USER_A_ACCEPTED');

  WITH near AS (
    -- cheap index-friendly box first, exact great-circle distance after
    SELECT o.id, o.user_id, o.version, o.departure_at, o.created_at,
           public.travel_distance_km(me.source_lat, me.source_lng, o.source_lat, o.source_lng) AS s_km,
           public.travel_distance_km(me.destination_lat, me.destination_lng, o.destination_lat, o.destination_lng) AS d_km,
           abs(extract(epoch FROM o.departure_at - me.departure_at)) / 60 AS t_min
      FROM public.travel_intents o
     WHERE o.status = 'ACTIVE'
       AND o.id <> me.id
       AND o.user_id <> me.user_id
       AND o.travel_date = me.travel_date
       AND o.departure_at > now()
       AND o.departure_at BETWEEN me.departure_at - make_interval(secs => max_t * 60)
                              AND me.departure_at + make_interval(secs => max_t * 60)
       AND o.source_lat BETWEEN me.source_lat - max_s / 111.0 AND me.source_lat + max_s / 111.0
       AND o.source_lng BETWEEN me.source_lng - max_s / (111.0 * greatest(cos(radians(me.source_lat)), 0.01))
                            AND me.source_lng + max_s / (111.0 * greatest(cos(radians(me.source_lat)), 0.01))
       AND o.destination_lat BETWEEN me.destination_lat - max_d / 111.0 AND me.destination_lat + max_d / 111.0
       AND o.destination_lng BETWEEN me.destination_lng - max_d / (111.0 * greatest(cos(radians(me.destination_lat)), 0.01))
                                 AND me.destination_lng + max_d / (111.0 * greatest(cos(radians(me.destination_lat)), 0.01))
       -- either person blocked the other
       AND NOT EXISTS (SELECT 1 FROM public.travel_blocks b
                        WHERE (b.blocker_user_id = me.user_id AND b.blocked_user_id = o.user_id)
                           OR (b.blocker_user_id = o.user_id AND b.blocked_user_id = me.user_id))
       -- these two requests were already paired: live, answered or ignored (re-pairing is only
       -- allowed when the old match closed because a request changed)
       AND NOT EXISTS (SELECT 1 FROM public.travel_matches x
                        WHERE least(x.travel_intent_a, x.travel_intent_b) = least(me.id, o.id)
                          AND greatest(x.travel_intent_a, x.travel_intent_b) = greatest(me.id, o.id)
                          AND NOT (x.status = 'EXPIRED' AND x.close_reason IN ('intent_updated', 'superseded')))
       -- these two people said no to each other recently
       AND NOT EXISTS (SELECT 1 FROM public.travel_matches x
                        WHERE least(x.user_a, x.user_b) = least(me.user_id, o.user_id)
                          AND greatest(x.user_a, x.user_b) = greatest(me.user_id, o.user_id)
                          AND x.status IN ('DECLINED', 'BLOCKED') AND x.updated_at > now() - v_cool)),
  scored AS (
    SELECT n.*, (n.s_km <= max_s AND n.d_km <= max_d AND n.t_min <= max_t) AS eligible,
           public.travel_match_score(n.s_km, n.d_km, n.t_min, cfg) AS score
      FROM near n),
  picked AS (
    SELECT * FROM scored WHERE eligible ORDER BY score DESC, created_at LIMIT v_slots),
  ins AS (
    INSERT INTO public.travel_matches
      (travel_intent_a, travel_intent_b, user_a, user_b, intent_a_version, intent_b_version,
       source_distance_km, destination_distance_km, time_difference_minutes, match_score, expires_at)
    SELECT me.id, p.id, me.user_id, p.user_id, me.version, p.version,
           round(p.s_km::numeric, 3), round(p.d_km::numeric, 3), round(p.t_min)::int, p.score,
           least(me.departure_at, p.departure_at)
      FROM picked p
    ON CONFLICT DO NOTHING
    RETURNING id, match_score),
  logged AS (
    INSERT INTO public.travel_events (event, user_id, intent_id, match_id, details)
    SELECT 'travel.match.found', me.user_id, me.id, ins.id, jsonb_build_object('score', ins.match_score) FROM ins
    RETURNING 1)
  SELECT (SELECT count(*) FROM scored WHERE eligible), (SELECT count(*) FROM scored WHERE NOT eligible),
         (SELECT count(*) FROM ins)
    INTO v_eligible, v_rejected, v_created;

  IF v_eligible > 0 THEN
    PERFORM public.travel_log('travel.match.candidate_found', me.user_id, me.id, NULL,
                              jsonb_build_object('eligible', v_eligible, 'created', v_created, 'slots', v_slots));
  END IF;
  IF v_rejected > 0 THEN
    -- nearby-ish (inside the search box) but over a distance or time limit
    PERFORM public.travel_log('travel.match.rejected', me.user_id, me.id, NULL, jsonb_build_object('count', v_rejected));
  END IF;

  v_offer := public.travel_next_offer(me.id, cfg);
  IF v_offer IS NULL THEN
    RETURN none;
  END IF;
  RETURN jsonb_build_object('matchFound', true, 'matchId', v_offer ->> 'match_id',
                            'notifications', jsonb_build_array(v_offer));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Consent, decline, block and report. p_action: accept | decline | block | report.
-- p_match_id comes from the button the person tapped; NULL means a typed "yes" / "block this
-- person", which applies to their latest relevant match. Idempotent: double taps change nothing.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_respond(p_user_id uuid, p_match_id uuid, p_action text,
                                                 p_reason text, p_cfg jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg       jsonb := public.travel_cfg(p_cfg);
  m         public.travel_matches;
  ia        public.travel_intents;
  ib        public.travel_intents;
  v_role    text;
  v_other   uuid;
  v_closed  jsonb;
  v_notes   jsonb := '[]';
  v_rematch uuid[] := '{}';
BEGIN
  IF p_action NOT IN ('accept', 'decline', 'block', 'report') THEN
    RAISE EXCEPTION 'travel_respond: unknown action %', p_action;
  END IF;

  IF p_match_id IS NULL THEN
    IF p_action IN ('accept', 'decline') THEN
      SELECT id INTO p_match_id FROM public.travel_matches
       WHERE (user_a = p_user_id AND status = 'PENDING' AND offered_at IS NOT NULL)
          OR (user_b = p_user_id AND status = 'USER_A_ACCEPTED')
       ORDER BY coalesce(b_asked_at, offered_at) DESC LIMIT 1;
    ELSE
      SELECT id INTO p_match_id FROM public.travel_matches
       WHERE ((user_a = p_user_id AND offered_at IS NOT NULL) OR (user_b = p_user_id AND b_asked_at IS NOT NULL))
         AND updated_at > now() - interval '30 days'
       ORDER BY (status = 'CONNECTED') DESC, updated_at DESC LIMIT 1;
    END IF;
    IF p_match_id IS NULL THEN
      RETURN public.travel_result('nothing_pending', NULL, jsonb_build_array(public.travel_note(p_user_id,
               CASE WHEN p_action IN ('accept', 'decline') THEN 'nothing_pending' ELSE 'no_match_to_block' END)));
    END IF;
  END IF;

  SELECT * INTO m FROM public.travel_matches WHERE id = p_match_id FOR UPDATE;
  -- authorisation: only the two people in the match, and only once they have been asked about it
  IF NOT FOUND OR p_user_id NOT IN (m.user_a, m.user_b)
     OR (p_user_id = m.user_a AND m.offered_at IS NULL)
     OR (p_user_id = m.user_b AND m.b_asked_at IS NULL) THEN
    PERFORM public.travel_log('travel.consent.rejected', p_user_id, NULL, NULL, jsonb_build_object('action', p_action));
    RETURN public.travel_result('unknown', NULL, jsonb_build_array(public.travel_note(p_user_id, 'match_unavailable')));
  END IF;
  v_role := CASE WHEN p_user_id = m.user_a THEN 'a' ELSE 'b' END;
  v_other := CASE v_role WHEN 'a' THEN m.user_b ELSE m.user_a END;
  SELECT * INTO ia FROM public.travel_intents WHERE id = m.travel_intent_a;
  SELECT * INTO ib FROM public.travel_intents WHERE id = m.travel_intent_b;

  -- ── block / report: works on any of their matches, open or connected ──
  IF p_action IN ('block', 'report') THEN
    INSERT INTO public.travel_blocks (blocker_user_id, blocked_user_id, match_id)
    VALUES (p_user_id, v_other, m.id)
    ON CONFLICT (blocker_user_id, blocked_user_id) DO NOTHING;
    IF p_action = 'report' THEN
      INSERT INTO public.travel_reports (reporter_user_id, reported_user_id, match_id, reason)
      VALUES (p_user_id, v_other, m.id, left(nullif(trim(p_reason), ''), 500));
      PERFORM public.travel_log('travel.report.created', p_user_id, NULL, m.id);
    END IF;
    -- the other person is never told they were blocked; if they were waiting on this match,
    -- it just becomes unavailable
    IF m.status = 'USER_A_ACCEPTED' THEN
      IF v_role = 'b' THEN
        v_notes := v_notes || public.travel_note(m.user_a, 'counterpart_declined', m.id);
        v_rematch := v_rematch || m.travel_intent_a;
      ELSE
        v_notes := v_notes || public.travel_note(m.user_b, 'match_withdrawn', m.id);
      END IF;
    END IF;
    IF v_role = 'a' AND m.status IN ('PENDING', 'USER_A_ACCEPTED') THEN
      v_rematch := v_rematch || m.travel_intent_a;   -- the blocker's own next candidate
    END IF;
    -- every live match between these two people ends
    UPDATE public.travel_matches
       SET status = 'BLOCKED', updated_at = now(),
           close_reason = CASE WHEN id = m.id AND p_action = 'report' THEN 'reported' ELSE 'blocked' END
     WHERE (id = m.id AND status <> 'BLOCKED')
        OR (status IN ('PENDING', 'USER_A_ACCEPTED', 'USER_B_ACCEPTED')
            AND least(user_a, user_b) = least(p_user_id, v_other)
            AND greatest(user_a, user_b) = greatest(p_user_id, v_other));
    PERFORM public.travel_log('travel.match.blocked', p_user_id, NULL, m.id,
                              jsonb_build_object('action', p_action, 'was', lower(m.status)));
    RETURN public.travel_result(p_action || 'ed', NULL,
             jsonb_build_array(public.travel_note(p_user_id, p_action || 'ed_ack', m.id)) || v_notes, v_rematch);
  END IF;

  PERFORM public.travel_log('travel.consent.received', p_user_id, NULL, m.id,
                            jsonb_build_object('action', p_action, 'role', v_role, 'status', lower(m.status)));

  -- the answer window passed before the sweep noticed
  IF m.status IN ('PENDING', 'USER_A_ACCEPTED') AND m.expires_at <= now() THEN
    UPDATE public.travel_matches SET status = 'EXPIRED', close_reason = 'timeout', updated_at = now()
     WHERE id = m.id RETURNING * INTO m;
    PERFORM public.travel_log('travel.match.expired', p_user_id, NULL, m.id, '{"reason": "timeout"}');
    IF m.b_asked_at IS NOT NULL AND v_role = 'b' AND ia.status = 'ACTIVE' THEN
      v_notes := v_notes || public.travel_note(m.user_a, 'counterpart_timeout', m.id);
      v_rematch := v_rematch || m.travel_intent_a;
    END IF;
    RETURN public.travel_result('expired', NULL,
             jsonb_build_array(public.travel_note(p_user_id, 'match_unavailable', m.id)) || v_notes, v_rematch);
  END IF;

  IF v_role = 'a' AND m.status = 'PENDING' THEN
    IF p_action = 'decline' THEN
      UPDATE public.travel_matches
         SET status = 'DECLINED', user_a_consent = false, close_reason = 'declined_by_a', updated_at = now()
       WHERE id = m.id;
      PERFORM public.travel_log('travel.match.declined', p_user_id, ia.id, m.id, '{"by": "a"}');
      RETURN public.travel_result('declined', NULL,
               jsonb_build_array(public.travel_note(p_user_id, 'declined_ack', m.id)), ARRAY[ia.id]);
    END IF;
    IF ib.status <> 'ACTIVE' OR ib.departure_at <= now() THEN
      UPDATE public.travel_matches SET status = 'EXPIRED', close_reason = 'superseded', updated_at = now()
       WHERE id = m.id;
      PERFORM public.travel_log('travel.match.expired', p_user_id, ia.id, m.id, '{"reason": "superseded"}');
      RETURN public.travel_result('unavailable', NULL,
               jsonb_build_array(public.travel_note(p_user_id, 'match_unavailable', m.id)), ARRAY[ia.id]);
    END IF;
    UPDATE public.travel_matches
       SET status = 'USER_A_ACCEPTED', user_a_consent = true, b_asked_at = now(), updated_at = now(),
           expires_at = least(now() + make_interval(mins => (cfg ->> 'consent_timeout_min')::int),
                              ia.departure_at, ib.departure_at)
     WHERE id = m.id;
    PERFORM public.travel_log('travel.match.accepted', p_user_id, ia.id, m.id, '{"by": "a"}');
    RETURN public.travel_result('accepted', NULL, jsonb_build_array(
             public.travel_note(p_user_id, 'a_waiting', m.id),
             public.travel_note(m.user_b, 'request_b', m.id)));
  END IF;

  IF v_role = 'b' AND m.status = 'USER_A_ACCEPTED' THEN
    IF p_action = 'decline' THEN
      UPDATE public.travel_matches
         SET status = 'DECLINED', user_b_consent = false, close_reason = 'declined_by_b', updated_at = now()
       WHERE id = m.id;
      PERFORM public.travel_log('travel.match.declined', p_user_id, ib.id, m.id, '{"by": "b"}');
      RETURN public.travel_result('declined', NULL, jsonb_build_array(
               public.travel_note(p_user_id, 'declined_ack', m.id),
               public.travel_note(m.user_a, 'counterpart_declined', m.id)), ARRAY[ia.id]);
    END IF;
    -- both said yes
    UPDATE public.travel_matches
       SET status = 'CONNECTED', user_b_consent = true, connected_at = now(), updated_at = now()
     WHERE id = m.id;
    UPDATE public.travel_intents SET status = 'MATCHED', updated_at = now() WHERE id IN (ia.id, ib.id);
    -- their other candidates and pending requests are no longer needed
    v_closed := public.travel_close_open_matches(ia.id, 'superseded');
    v_notes := v_notes || (v_closed -> 'notifications');
    v_rematch := v_rematch || public.travel_uuids(v_closed -> 'rematch');
    v_closed := public.travel_close_open_matches(ib.id, 'superseded');
    v_notes := v_notes || (v_closed -> 'notifications');
    v_rematch := v_rematch || public.travel_uuids(v_closed -> 'rematch');
    PERFORM public.travel_log('travel.match.accepted', p_user_id, ib.id, m.id, '{"by": "b"}');
    PERFORM public.travel_log('travel.match.connected', NULL, NULL, m.id);
    RETURN public.travel_result('connected', NULL, jsonb_build_array(
             public.travel_note(m.user_b, 'connected', m.id),
             public.travel_note(m.user_a, 'connected', m.id)) || v_notes, v_rematch);
  END IF;

  -- double tap, or a button for a match that already ended
  RETURN public.travel_result('already', NULL, jsonb_build_array(public.travel_note(p_user_id,
           CASE WHEN m.status = 'CONNECTED' THEN 'already_connected'
                WHEN m.status = 'USER_A_ACCEPTED' AND v_role = 'a' THEN 'a_waiting'
                ELSE 'match_unavailable' END, m.id)));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Every few minutes (workflow 12): unanswered matches, past trips, abandoned drafts, old rows.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_sweep(p_cfg jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg        jsonb := public.travel_cfg(p_cfg);
  m          record;
  v_notes    jsonb := '[]';
  v_rematch  uuid[] := '{}';
  n_matches  int := 0;
  n_intents  int;
BEGIN
  FOR m IN
    UPDATE public.travel_matches x
       SET status = 'EXPIRED', updated_at = now(),
           close_reason = CASE WHEN x.offered_at IS NULL THEN 'superseded' ELSE 'timeout' END
     WHERE x.status IN ('PENDING', 'USER_A_ACCEPTED', 'USER_B_ACCEPTED') AND x.expires_at <= now()
    RETURNING x.*
  LOOP
    n_matches := n_matches + 1;
    PERFORM public.travel_log('travel.match.expired', NULL, NULL, m.id, jsonb_build_object('reason', m.close_reason));
    -- A said yes and B never answered: tell A and look again. (If A never answered, stay quiet.)
    IF m.b_asked_at IS NOT NULL AND EXISTS (SELECT 1 FROM public.travel_intents
                                             WHERE id = m.travel_intent_a AND status = 'ACTIVE' AND departure_at > now()) THEN
      v_notes := v_notes || public.travel_note(m.user_a, 'counterpart_timeout', m.id);
      v_rematch := v_rematch || m.travel_intent_a;
    END IF;
  END LOOP;

  WITH x AS (
    UPDATE public.travel_intents SET status = 'EXPIRED', updated_at = now()
     WHERE (status = 'ACTIVE' AND expires_at <= now())
        OR (status = 'DRAFT' AND updated_at < now() - make_interval(mins => (cfg ->> 'draft_ttl_min')::int))
    RETURNING id, user_id),
  logged AS (
    INSERT INTO public.travel_events (event, user_id, intent_id) SELECT 'travel.intent.expired', user_id, id FROM x
    RETURNING 1)
  SELECT count(*) INTO n_intents FROM x;

  DELETE FROM public.travel_inbound_messages WHERE received_at < now() - interval '7 days';
  DELETE FROM public.travel_geocode_cache
   WHERE created_at < now() - make_interval(days => (cfg ->> 'geocode_cache_days')::int);
  DELETE FROM public.travel_events WHERE created_at < now() - interval '180 days';

  IF n_matches + n_intents > 0 THEN
    PERFORM public.travel_log('travel.sweep', NULL, NULL, NULL,
                              jsonb_build_object('expired_matches', n_matches, 'expired_intents', n_intents));
  END IF;
  RETURN public.travel_result('swept', NULL, v_notes, v_rematch);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- What workflow 11 may put in one message to one user. This is the privacy gate:
--  * the user's own trip (their own data, for confirmations);
--  * the other trip's departure time, rounded to 15 minutes;
--  * the other person's first name and WhatsApp number ONLY when the match is CONNECTED
--    and both consents are recorded.
-- Never: the other person's places, coordinates or distances.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_notification(p_user_id uuid, p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  u      public.travel_users;
  o      public.travel_users;
  m      public.travel_matches;
  mine   public.travel_intents;
  theirs public.travel_intents;
  v      jsonb;
BEGIN
  SELECT * INTO u FROM public.travel_users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  v := jsonb_build_object('wa_id', u.wa_id,
                          'inside_window', coalesce(u.last_message_at > now() - interval '23 hours', false));

  IF p_match_id IS NOT NULL THEN
    SELECT * INTO m FROM public.travel_matches WHERE id = p_match_id AND p_user_id IN (user_a, user_b);
  END IF;
  IF m.id IS NULL THEN
    -- no match: their latest request, for "Got it / Updated / You already have this request"
    SELECT * INTO mine FROM public.travel_intents WHERE user_id = p_user_id
     ORDER BY (status IN ('ACTIVE', 'DRAFT')) DESC, updated_at DESC LIMIT 1;
  ELSE
    SELECT * INTO mine FROM public.travel_intents
     WHERE id = CASE WHEN m.user_a = p_user_id THEN m.travel_intent_a ELSE m.travel_intent_b END;
    SELECT * INTO theirs FROM public.travel_intents
     WHERE id = CASE WHEN m.user_a = p_user_id THEN m.travel_intent_b ELSE m.travel_intent_a END;
    v := v || jsonb_build_object(
      'match_id', m.id,
      'match_status', m.status,
      'their_date', theirs.travel_date,
      'their_time', to_char(time '00:00' + round(extract(epoch FROM theirs.departure_time) / 900) * interval '15 minutes',
                            'HH24:MI'));
    IF m.status = 'CONNECTED' AND m.user_a_consent AND m.user_b_consent THEN
      SELECT * INTO o FROM public.travel_users
       WHERE id = CASE WHEN m.user_a = p_user_id THEN m.user_b ELSE m.user_a END;
      v := v || jsonb_build_object('their_wa_id', o.wa_id,
                                   -- the name they confirmed in workflow 06 (017), else their WhatsApp name
                                   'their_name', nullif(split_part(trim(coalesce(
                                     (SELECT tu.name FROM public.tori_users tu WHERE tu.phone = '+' || o.wa_id AND tu.name_source = 'user'),
                                     o.profile_name, '')), ' ', 1), ''));
    END IF;
  END IF;
  IF mine.id IS NOT NULL THEN
    v := v || jsonb_build_object('my_source', mine.source_text, 'my_destination', mine.destination_text,
                                 'my_date', mine.travel_date, 'my_time', to_char(mine.departure_time, 'HH24:MI'));
  END IF;
  RETURN v;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Geocoding cache (workflow 08)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.travel_geocode_lookup(p_key text, p_user_id uuid, p_cfg jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c public.travel_geocode_cache;
BEGIN
  SELECT * INTO c FROM public.travel_geocode_cache
   WHERE query_key = p_key
     AND created_at > now() - make_interval(days => (public.travel_cfg(p_cfg) ->> 'geocode_cache_days')::int);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  PERFORM public.travel_log('travel.geocode.success', p_user_id, NULL, NULL,
                            jsonb_build_object('provider', c.provider, 'cached', true));
  RETURN jsonb_build_object('lat', c.lat, 'lng', c.lng);
END $$;

CREATE OR REPLACE FUNCTION public.travel_geocode_store(p_key text, p_provider text, p_lat float8, p_lng float8,
                                                       p_label text, p_user_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.travel_geocode_cache (query_key, provider, lat, lng, label)
  VALUES (p_key, p_provider, p_lat, p_lng, left(p_label, 300))
  ON CONFLICT (query_key) DO UPDATE
    SET lat = EXCLUDED.lat, lng = EXCLUDED.lng, label = EXCLUDED.label, created_at = now();
  PERFORM public.travel_log('travel.geocode.success', p_user_id, NULL, NULL,
                            jsonb_build_object('provider', p_provider, 'cached', false));
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
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'travel\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
