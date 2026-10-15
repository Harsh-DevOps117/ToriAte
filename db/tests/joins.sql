-- Joining a game from the board (011): codes, host accept / decline, spots, Full, onboarding first, status.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/joins.sql against a database with 004–011 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

-- a complete profile
CREATE OR REPLACE FUNCTION pg_temp.person(wa text, name text) RETURNS void LANGUAGE sql AS $$
  SELECT public.tori_save_profile(wa, jsonb_build_object('name', name, 'age', 25, 'gender', 'other',
           'interests', jsonb_build_array('badminton'), 'skip', jsonb_build_array('social', 'photo', 'about'))) $$;

-- an open badminton game tomorrow 7 PM for `spots` people
CREATE OR REPLACE FUNCTION pg_temp.game(wa text, spots int, hours_ahead int DEFAULT 20) RETURNS uuid LANGUAGE sql AS $$
  SELECT (public.save_partner_request(wa, NULL, jsonb_build_object(
    'activity', 'badminton', 'city', 'bangalore', 'area', 'HSR Layout', 'area_key', 'hsrlayout',
    'play_date', ((now() + make_interval(hours => hours_ahead)) AT TIME ZONE 'Asia/Kolkata')::date, 'time_label', 'around 7 PM',
    'window_start', now() + make_interval(hours => hours_ahead) - interval '30 minutes',
    'window_end', now() + make_interval(hours => hours_ahead) + interval '30 minutes',
    'players_needed', spots, 'raw_text', 'test'), true)).id $$;

DO $$
DECLARE
  g uuid; code text; r jsonb; j1 uuid; j2 uuid; j3 uuid; j4 uuid; b record;
BEGIN
  PERFORM pg_temp.person('919400000001', 'Hari');
  PERFORM pg_temp.person('919400000002', 'Jaya');
  PERFORM pg_temp.person('919400000003', 'Kiran');
  PERFORM pg_temp.person('919400000004', 'Lata');
  PERFORM pg_temp.person('919400000005', 'Mohan');
  g := pg_temp.game('919400000001', 2);
  code := (SELECT join_code FROM public.partner_requests WHERE id = g);
  PERFORM pg_temp.ok(code ~ '^[A-HJ-NP-Z2-9]{4}$', 'a live request gets a 4-character join code (' || code || ')');

  -- 1. codes and who may join
  PERFORM pg_temp.ok(public.tori_request_join('919400000002', NULL, 'ZZZZ') ->> 'state' = 'unknown', 'unknown code');
  PERFORM pg_temp.ok(public.tori_request_join('919400000001', NULL, code) ->> 'state' = 'own', 'the host cannot join their own game');
  r := public.tori_request_join('919400000002', NULL, lower(code));
  j1 := (r ->> 'join_id')::uuid;
  PERFORM pg_temp.ok(r ->> 'state' = 'requested' AND r #>> '{host,wa_id}' = '919400000001' AND r #>> '{joiner,offer,name}' = 'Jaya'
                     AND r #> '{joiner,offer,wa_id}' IS NULL, 'join requested (code is case-insensitive); the host gets Jaya''s card, no number');
  PERFORM pg_temp.ok(public.tori_request_join('919400000002', NULL, code) ->> 'state' = 'already_pending', 'asking twice changes nothing');

  -- 2. only the host answers; accept connects them
  PERFORM pg_temp.ok(public.tori_answer_join('919400000003', j1, true) ->> 'state' = 'unknown', 'someone else cannot answer');
  r := public.tori_answer_join('919400000001', j1, true);
  PERFORM pg_temp.ok(r ->> 'state' = 'accepted' AND (r ->> 'changed')::boolean AND r #>> '{joiner,connected,wa_id}' = '919400000002'
                     AND (r #>> '{request,filled}')::int = 1, 'host accepts: 1 of 2 filled, numbers for both');
  PERFORM pg_temp.ok(NOT (public.tori_answer_join('919400000001', j1, false) ->> 'changed')::boolean, 'a second tap changes nothing');
  SELECT * INTO b FROM public.v_partner_board WHERE id = g;
  PERFORM pg_temp.ok(b.joined_count = 1 AND b.joined_names = '{Jaya}' AND b.board_status = 'looking' AND b.join_code = code,
                     'board: 1 joined (Jaya), still looking');

  -- 3. every joiner goes to the host; the last spot fills the game
  j2 := (public.tori_request_join('919400000003', NULL, code) ->> 'join_id')::uuid;
  j3 := (public.tori_request_join('919400000004', NULL, code) ->> 'join_id')::uuid;
  PERFORM pg_temp.ok((SELECT count(*) FROM public.partner_joins WHERE request_id = g AND status = 'pending') = 2, 'two more joins wait for the host');
  r := public.tori_answer_join('919400000001', j2, true);
  PERFORM pg_temp.ok(r ->> 'state' = 'accepted' AND r -> 'full_joiners' = '["919400000004"]', 'game full: Lata''s pending join is closed and she is to be told');
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE id = g) = 'matched', 'request is full');
  SELECT * INTO b FROM public.v_partner_board WHERE id = g;
  PERFORM pg_temp.ok(b.board_status = 'matched' AND b.joined_names = '{Jaya,Kiran}', 'board: Full, Jaya and Kiran');
  PERFORM pg_temp.ok(public.tori_request_join('919400000005', NULL, code) ->> 'state' = 'full', 'a new joiner hears it is full');
  PERFORM pg_temp.ok(public.tori_answer_join('919400000001', j3, true) ->> 'state' = 'full', 'accepting a closed join does nothing');

  -- 4. more spots reopen the game
  r := public.tori_set_spots('919400000001', 3);
  PERFORM pg_temp.ok(r ->> 'state' = 'ok' AND (r ->> 'reopened')::uuid = g AND (r #>> '{request,spots}')::int = 3, 'spots 3: the game reopens');
  PERFORM pg_temp.ok((SELECT board_status FROM public.v_partner_board WHERE id = g) = 'looking', 'board: looking again');
  j4 := (public.tori_request_join('919400000005', NULL, code) ->> 'join_id')::uuid;
  PERFORM pg_temp.ok(public.tori_answer_join('919400000001', j4, false) ->> 'state' = 'declined', 'host declines Mohan');
  PERFORM pg_temp.ok(public.tori_request_join('919400000005', NULL, code) ->> 'state' = 'declined_before', 'Mohan cannot ask again');
  j3 := (public.tori_request_join('919400000004', NULL, code) ->> 'join_id')::uuid;
  r := public.tori_set_spots('919400000001', 2);
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE id = g) = 'matched' AND r -> 'full_joiners' = '["919400000004"]',
                     'spots 2 with 2 in: full again, the waiting joiner is to be told');
  PERFORM pg_temp.ok(public.tori_set_spots('919400000001', 99) #>> '{request,spots}' = '10', 'spots are capped at 10');
  PERFORM pg_temp.ok(public.tori_set_spots('919499999999', 2) ->> 'state' = 'none', 'no live game: nothing to change');

  -- 5. status: the host sees who joined; the joiner sees their joins
  r := public.tori_partner_status('919400000001');
  PERFORM pg_temp.ok(r #>> '{requests,0,joined}' = '["Jaya", "Kiran"]' AND (r #>> '{requests,0,spots}')::int = 10, 'host status: joined names and spots');
  r := public.tori_partner_status('919400000002');
  PERFORM pg_temp.ok(r #>> '{joins,0,status}' = 'accepted' AND r #>> '{joins,0,host}' = 'Hari', 'joiner status: joined Hari''s game');

  -- 6. no profile yet: onboarding first, then the join goes on
  r := public.tori_request_join('919400000009', 'Nina K', code);
  PERFORM pg_temp.ok(r ->> 'state' = 'needs_profile' AND r ->> 'next' = 'name', 'new person: onboarding starts with the name');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.partner_joins WHERE joiner_wa = '919400000009'), 'no join yet');
  r := public.tori_save_profile('919400000009', '{"name": "Nina", "age": 23, "gender": "female", "interests": ["badminton"], "skip": ["social", "photo", "about"]}');
  PERFORM pg_temp.ok((r ->> 'complete')::boolean AND r #>> '{resume,join_code}' = code, 'profile complete: the join code comes back to send it on');

  -- 7. a join request kept for a host outside the 24-hour window, until answered
  j1 := (public.tori_request_join('919400000009', NULL, code) ->> 'join_id')::uuid;
  PERFORM public.tori_hold_join('919400000001', 'join_request', j1, '{"type": "text", "text": {"body": "Nina wants to join"}}');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919400000001', false)) = 1, 'held join request delivered when the host writes');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919400000001', true)) = 1, '"any match?" sends it again while unanswered');
  PERFORM public.tori_answer_join('919400000001', j1, true);
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919400000001', true)) = 0, 'answered: never again');

  -- 8. a game in the past cannot be joined
  g := pg_temp.game('919400000005', 1, 1);
  UPDATE public.partner_requests SET window_start = now() - interval '2 hours', window_end = now() - interval '1 hour' WHERE id = g;
  PERFORM pg_temp.ok(public.tori_request_join('919400000002', NULL, (SELECT join_code FROM public.partner_requests WHERE id = g)) ->> 'state' = 'closed',
                     'past game: closed');
END $$;
ROLLBACK;
