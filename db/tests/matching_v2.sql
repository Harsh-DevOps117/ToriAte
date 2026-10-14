-- Matching v2 (009): radius, time gap, compatible activities, sequential consent, privacy-aware cards.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/matching_v2.sql against a database with 004–009 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

-- an open request for tomorrow: exact time 'HH:MM' (±30 min window) or a part of day; optional point
CREATE OR REPLACE FUNCTION pg_temp.req(wa text, activity text, area text, hhmm text, part text DEFAULT NULL,
                                       lat float8 DEFAULT NULL, lng float8 DEFAULT NULL) RETURNS uuid LANGUAGE sql AS $$
  WITH d AS (SELECT ((now() AT TIME ZONE 'Asia/Kolkata')::date + 1) AS day),
  w AS (SELECT CASE WHEN hhmm IS NOT NULL THEN ((d.day + hhmm::time) AT TIME ZONE 'Asia/Kolkata') - interval '30 minutes'
                    ELSE ((d.day + time '16:00') AT TIME ZONE 'Asia/Kolkata') END AS ws,
               CASE WHEN hhmm IS NOT NULL THEN ((d.day + hhmm::time) AT TIME ZONE 'Asia/Kolkata') + interval '30 minutes'
                    ELSE ((d.day + time '20:00') AT TIME ZONE 'Asia/Kolkata') END AS we, d.day FROM d)
  SELECT (public.save_partner_request(wa, 'P' || right(wa, 2), jsonb_strip_nulls(jsonb_build_object(
    'activity', activity, 'city', 'bangalore', 'area', area, 'area_key', lower(regexp_replace(area, '\W', '', 'g')),
    'lat', lat, 'lng', lng, 'play_date', w.day, 'time_exact', hhmm, 'part_of_day', part, 'time_label', coalesce(hhmm, part),
    'window_start', w.ws, 'window_end', w.we, 'players_needed', 1, 'raw_text', 'test')), true)).id FROM w $$;

-- coordinates (from mock-apis): HSR 12.9116,77.6474 · Koramangala 12.9352,77.6245 (≈3.6 km) · a point ≈1 km from HSR
DO $$
DECLARE
  a uuid; b uuid; c uuid; m jsonb; mid uuid; r jsonb; v jsonb;
BEGIN
  PERFORM pg_temp.ok(public.tori_cfg() ->> 'time_gap_min' = '120' AND public.tori_cfg() ->> 'radius_km' = '3', 'defaults: 2 h, 3 km');

  -- 1. time: 7 PM and 8 PM match (60 min); 7 PM and 9:30 PM don't (150 min)
  a := pg_temp.req('919300000001', 'badminton', 'HSR Layout', '19:00');
  c := pg_temp.req('919300000003', 'badminton', 'HSR Layout', '21:30');
  PERFORM pg_temp.ok(public.match_partner_request(c) IS NULL, '7 PM vs 9:30 PM: no match');
  b := pg_temp.req('919300000002', 'badminton', 'HSR Layout', '20:00');
  m := public.match_partner_request(b);
  PERFORM pg_temp.ok((m #>> '{b,wa_id}') = '919300000001' AND (m ->> 'gap_min')::numeric = 60, '7 PM vs 8 PM: match, 60 min apart');
  mid := (m ->> 'match_id')::uuid;

  -- 2. sequential consent: B (the searcher, side a) answers first; then A is asked
  r := public.respond_partner_match(mid, '919300000002', true);
  PERFORM pg_temp.ok(r ->> 'state' = 'pending' AND (r ->> 'ask_b')::boolean AND (r ->> 'b_was_asked')::boolean, 'searcher says yes → ask the other side');
  r := public.tori_partner_status('919300000001');
  PERFORM pg_temp.ok(r #>> '{requests,0,waiting_on}' = 'you' AND r #>> '{requests,0,partner}' = 'P02', 'status for the asked side');
  r := public.respond_partner_match(mid, '919300000001', false);
  PERFORM pg_temp.ok(r ->> 'state' = 'declined' AND jsonb_array_length(r -> 'reopened') = 2, 'asked side declines → both back in the pool');

  -- 3. part of day: "evening" (16–20) and 9 PM are 60 min apart → match; a no from the searcher means b was never asked
  a := pg_temp.req('919300000011', 'football', 'Indiranagar', NULL, 'evening');
  b := pg_temp.req('919300000012', 'football', 'Indiranagar', '21:00');
  m := public.match_partner_request(b);
  PERFORM pg_temp.ok(m IS NOT NULL, 'evening vs 9 PM: match');
  r := public.tori_partner_status('919300000011');
  PERFORM pg_temp.ok(r #>> '{requests,0,waiting_on}' IS NULL AND r #>> '{requests,0,partner}' IS NULL,
                     'the waiting side is not told before the searcher says yes');
  r := public.respond_partner_match((m ->> 'match_id')::uuid, '919300000012', false);
  PERFORM pg_temp.ok(r ->> 'state' = 'declined' AND NOT (r ->> 'b_was_asked')::boolean, 'searcher declines: the other side never knew');

  -- 4. radius: geocoded areas 1 km apart match even with different names; 3.6 km apart don't
  a := pg_temp.req('919300000021', 'tennis', 'HSR Layout', '07:00', NULL, 12.9116, 77.6474);
  c := pg_temp.req('919300000023', 'tennis', 'Koramangala', '07:00', NULL, 12.9352, 77.6245);
  PERFORM pg_temp.ok(public.match_partner_request(c) IS NULL, '3.6 km apart: no match');
  b := pg_temp.req('919300000022', 'tennis', 'Agara', '07:30', NULL, 12.9200, 77.6440);
  m := public.match_partner_request(b);
  PERFORM pg_temp.ok((m #>> '{b,wa_id}') = '919300000021' AND (m ->> 'distance_km')::numeric < 1.5, '≈1 km apart, different area names: match');

  -- 5. not geocoded: same area name matches, a different one doesn't
  a := pg_temp.req('919300000031', 'chess', 'Jayanagar', '17:00');
  b := pg_temp.req('919300000032', 'chess', 'JP Nagar', '17:00');
  PERFORM pg_temp.ok(public.match_partner_request(b) IS NULL, 'no coordinates, different areas: no match');
  c := pg_temp.req('919300000033', 'chess', 'Jaya Nagar', '17:30');
  PERFORM pg_temp.ok(public.match_partner_request(c) #>> '{b,wa_id}' = '919300000031', 'no coordinates, same area name: match');

  -- 6. compatible activities only when configured
  a := pg_temp.req('919300000041', 'padel', 'HSR Layout', '18:00');
  b := pg_temp.req('919300000042', 'tennis', 'HSR Layout', '18:00');
  PERFORM pg_temp.ok(public.match_partner_request(b) IS NULL, 'tennis vs padel: no match by default');
  INSERT INTO public.tori_settings (key, value) VALUES ('compatible_activities', '[["tennis", "padel"]]');
  PERFORM pg_temp.ok(public.match_partner_request(b) #>> '{b,wa_id}' = '919300000041', 'tennis vs padel: match once configured');
  DELETE FROM public.tori_settings;

  -- 7. the time gap is a setting
  a := pg_temp.req('919300000051', 'cycling', 'HSR Layout', '06:00');
  b := pg_temp.req('919300000052', 'cycling', 'HSR Layout', '07:30');
  INSERT INTO public.tori_settings (key, value) VALUES ('time_gap_min', '60');
  PERFORM pg_temp.ok(public.match_partner_request(b) IS NULL, 'gap setting 60: 90 min apart, no match');
  DELETE FROM public.tori_settings;
  m := public.match_partner_request(b);
  PERFORM pg_temp.ok(m IS NOT NULL, 'default 120: match');

  -- 8. expiry: the searcher never answered → the waiting side (never asked) goes back into the pool
  UPDATE public.partner_matches SET offered_at = now() - interval '3 hours' WHERE id = (m ->> 'match_id')::uuid;
  PERFORM public.expire_partner_requests();
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE wa_id = '919300000051' AND activity = 'cycling') = 'open'
                     AND (SELECT status FROM public.partner_requests WHERE wa_id = '919300000052' AND activity = 'cycling') = 'expired',
                     'no answer from the searcher: it leaves the pool, the never-asked side stays');

  -- 9. cards follow privacy choices
  PERFORM public.tori_save_profile('919300000061', '{"name": "Meera Rao", "age": 26, "gender": "female", "interests": ["badminton"], "social": "@meera.r"}');
  PERFORM public.tori_save_photo('919300000061', 'image/png', encode('\x89504e47'::bytea, 'base64'));
  PERFORM public.tori_save_about('919300000061', 'Weekend doubles player, intermediate', 'text',
                                 '{"summary": "Weekend doubles player, intermediate level.", "skill_level": "intermediate", "interests": []}');
  PERFORM public.tori_profile_button('919300000061', 'pf_priv_before');
  PERFORM public.tori_save_profile('919300000062', '{"name": "Kabir", "age": 30, "gender": "male", "interests": ["badminton", "running"], "social": "linkedin.com/in/kabir-s"}');
  PERFORM public.tori_profile_button('919300000062', 'pf_skip_photo');
  PERFORM public.tori_profile_button('919300000062', 'pf_priv_after');
  a := pg_temp.req('919300000061', 'badminton', 'Koramangala', '18:00');
  b := pg_temp.req('919300000062', 'badminton', 'Koramangala', '18:30');
  m := public.match_partner_request(b);
  v := public.tori_match_view((m ->> 'match_id')::uuid);
  PERFORM pg_temp.ok(v #>> '{b,offer,name}' = 'Meera' AND (v #>> '{b,offer,age}')::int BETWEEN 25 AND 26
                     AND v #>> '{b,offer,social_url}' = 'https://instagram.com/meera.r' AND v #> '{b,offer,photo_token}' IS NOT NULL,
                     'Meera chose "anyone I match with": name, age, link and photo on her card');
  PERFORM pg_temp.ok(v #> '{a,offer,social_url}' IS NULL AND (v #>> '{a,offer,has_social}')::boolean
                     AND v #> '{a,offer,photo_token}' IS NULL AND v #> '{a,offer,wa_id}' IS NULL,
                     'Kabir chose "after": no link on his card yet, and never a number');
  PERFORM pg_temp.ok(v #>> '{a,connected,social_url}' = 'https://www.linkedin.com/in/kabir-s' AND v #>> '{a,connected,wa_id}' = '919300000062',
                     'after both say yes: link and number');
  PERFORM pg_temp.ok(v #>> '{a,offer,interests}' = '["badminton", "running"]', 'interests on the card');
  PERFORM pg_temp.ok(v #>> '{b,offer,about}' = 'Weekend doubles player, intermediate level.' AND v #>> '{b,offer,skill}' = 'intermediate',
                     '"about you" summary and level on the card');

  -- 10. the profile's level counts when the request has none: a beginner never meets an advanced player
  PERFORM public.tori_save_about('919300000071', 'Advanced squash player, tournaments', 'text', '{"summary": "Plays tournaments.", "skill_level": "advanced"}');
  PERFORM public.tori_save_about('919300000072', 'Just started squash', 'text', '{"summary": "New to squash.", "skill_level": "beginner"}');
  a := pg_temp.req('919300000071', 'squash', 'HSR Layout', '18:00');
  b := pg_temp.req('919300000072', 'squash', 'HSR Layout', '18:00');
  PERFORM pg_temp.ok(public.match_partner_request(b) IS NULL, 'beginner vs advanced (from "about you"): no match');
  PERFORM public.tori_save_about('919300000073', 'Intermediate squash', 'text', '{"summary": "Plays squash.", "skill_level": "intermediate"}');
  c := pg_temp.req('919300000073', 'squash', 'HSR Layout', '18:00');
  PERFORM pg_temp.ok(public.match_partner_request(c) IS NOT NULL, 'intermediate meets either');

  -- 11. equally near and equally timed: more interests in common wins
  PERFORM public.tori_save_profile('919300000081', '{"interests": ["yoga", "chess"]}');
  PERFORM public.tori_save_profile('919300000082', '{"interests": ["running", "hiking", "yoga"]}');
  PERFORM public.tori_save_profile('919300000083', '{"interests": ["running", "hiking"]}');
  a := pg_temp.req('919300000081', 'running', 'HSR Layout', '06:00');
  b := pg_temp.req('919300000082', 'running', 'HSR Layout', '06:00');
  c := pg_temp.req('919300000083', 'running', 'HSR Layout', '06:00');
  PERFORM pg_temp.ok(public.match_partner_request(c) #>> '{b,wa_id}' = '919300000082', 'the candidate with more shared interests is picked');
END $$;
ROLLBACK;
