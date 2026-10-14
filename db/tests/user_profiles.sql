-- User profiles / onboarding: SQL-level scenario tests. Runs inside a transaction that is rolled back.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/user_profiles.sql against a database with 004, 006 and 007 applied.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

-- a complete request, as "Validate partner request" builds it (badminton today, 2-3 hours from now)
CREATE OR REPLACE FUNCTION pg_temp.req(hours_ahead int DEFAULT 2) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('activity', 'badminton', 'city', 'bangalore', 'area', 'HSR Layout', 'area_key', 'hsrlayout',
    'play_date', (now() + make_interval(hours => hours_ahead)) AT TIME ZONE 'Asia/Kolkata',
    'time_label', 'around 7 PM',
    'window_start', now() + make_interval(hours => hours_ahead),
    'window_end', now() + make_interval(hours => hours_ahead + 1),
    'players_needed', 1, 'raw_text', 'badminton partner today 7 pm') $$;

DO $$
DECLARE
  r jsonb; rid uuid; st record; u record; n int;
BEGIN
  -- 1. inbound log: creates the user, dedupes redeliveries, ignores status updates
  r := public.tori_log_inbound('919000000001', 'Rahul Sharma', 'wamid.A1', 'text', 'I want to find a partner for badminton today 7 pm');
  PERFORM pg_temp.ok(NOT (r ->> 'duplicate')::boolean, 'first delivery is new');
  r := public.tori_log_inbound('919000000001', 'Rahul Sharma', 'wamid.A1', 'text', 'I want to find a partner for badminton today 7 pm');
  PERFORM pg_temp.ok((r ->> 'duplicate')::boolean, 'redelivery is a duplicate');
  r := public.tori_log_inbound('', '', '', '', '');
  PERFORM pg_temp.ok(NOT (r ->> 'duplicate')::boolean, 'payload without a sender passes');
  SELECT * INTO u FROM public.tori_users WHERE phone = '+919000000001';
  PERFORM pg_temp.ok(u.profile_status = 'incomplete' AND u.name = 'Rahul Sharma', 'user created with phone + WhatsApp name');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.tori_messages WHERE user_id = u.id) = 1, 'message logged once');
  r := public.tori_profile_context('919000000001');
  PERFORM pg_temp.ok(r ->> 'state' = 'idle' AND r ->> 'next' = 'name' AND jsonb_array_length(r -> 'missing') = 7, 'context: idle, 7 steps to do, name first');
  r := public.tori_profile_context('919999999999');
  PERFORM pg_temp.ok(r ->> 'status' = 'incomplete', 'context for an unknown number');

  -- 2. first request is parked, not lost
  r := public.tori_hold_request('919000000001', 'Rahul Sharma', pg_temp.req(), true, NULL, NULL);
  rid := (r ->> 'request_id')::uuid;
  PERFORM pg_temp.ok(NOT (r ->> 'complete')::boolean AND r -> 'resume' = 'null'::jsonb OR r ->> 'resume' IS NULL, 'held: profile incomplete, nothing resumed');
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE id = rid) = 'pending_profile', 'request saved as pending_profile');
  SELECT * INTO st FROM public.tori_conversation_state WHERE user_id = u.id;
  PERFORM pg_temp.ok(st.state = 'awaiting_profile' AND st.pending_request_id = rid, 'state awaiting_profile, points at request');

  -- 3. a change while waiting updates the same parked request
  r := public.tori_hold_request('919000000001', NULL, pg_temp.req(3) || '{"raw_text": "make it 8"}', true, NULL, NULL);
  PERFORM pg_temp.ok((r ->> 'request_id')::uuid = rid, 'change keeps the same request');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.partner_requests WHERE wa_id = '919000000001') = 1, 'still one request');

  -- 4. partial profile answer: the next step is what's still missing
  r := public.tori_save_profile('919000000001', '{"name": null, "age": 24, "gender": "male", "interests": []}');
  PERFORM pg_temp.ok(NOT (r ->> 'complete')::boolean AND r ->> 'next' = 'name' AND r ->> 'wa_first' = 'Rahul',
                     'name still missing; the WhatsApp first name is offered');
  r := public.tori_profile_button('919000000001', 'pf_name_wa');
  PERFORM pg_temp.ok(r ->> 'next' = 'interests' AND r ->> 'name' = 'Rahul Sharma', 'name confirmed with the button; interests next');
  r := public.tori_save_profile('919000000001', '{"interests": ["Badminton", "table tennis"]}');
  PERFORM pg_temp.ok(r ->> 'next' = 'social', 'then the optional link');
  r := public.tori_save_profile('919000000001', '{"social": "my insta is cool"}');
  PERFORM pg_temp.ok(r ->> 'error' = 'bad_social' AND r ->> 'next' = 'social', 'a bad link is refused and asked again');
  r := public.tori_save_profile('919000000001', '{"social": "https://www.instagram.com/Rahul.S_99/?hl=en"}');
  PERFORM pg_temp.ok(r ->> 'next' = 'photo', 'link saved; photo next');
  PERFORM pg_temp.ok((SELECT social_url FROM public.tori_users WHERE id = u.id) = 'https://instagram.com/rahul.s_99', 'link normalised');
  r := public.tori_save_photo('919000000001', 'image/gif', encode('GIF89a', 'base64'));
  PERFORM pg_temp.ok(r ->> 'error' = 'bad_photo' AND r ->> 'next' = 'photo', 'a GIF is refused');
  r := public.tori_save_photo('919000000001', 'image/jpeg; charset=binary', encode('\xffd8ffe0'::bytea, 'base64'));
  PERFORM pg_temp.ok(r ->> 'next' = 'about', 'photo saved; "about you" next');
  r := public.tori_save_about('919000000001', 'ok', 'text', '{}');
  PERFORM pg_temp.ok(r ->> 'error' = 'bad_about' AND r ->> 'next' = 'about', 'too short to be about anyone: asked again');
  r := public.tori_save_about('919000000001',
         'I play badminton thrice a week, intermediate, call me on 98765 43210 or rahul@example.com', 'voice',
         '{"summary": "Plays badminton thrice a week at an intermediate level. Call 98765 43210 or rahul@example.com, see https://x.y", "skill_level": "intermediate", "interests": ["Cycling"]}');
  PERFORM pg_temp.ok(r ->> 'next' = 'privacy' AND r ->> 'about_summary' NOT LIKE '%9876%' AND r ->> 'about_summary' NOT LIKE '%@%'
                     AND r ->> 'about_summary' NOT LIKE '%http%', 'about saved; no number, email or link in the summary');
  PERFORM pg_temp.ok((SELECT skill_level || '|' || about_source || '|' || array_to_string(interests, ',') FROM public.tori_users WHERE id = u.id)
                     = 'intermediate|voice|badminton,cycling,table_tennis', 'skill level, source and interests from "about you"');
  PERFORM pg_temp.ok((SELECT state FROM public.tori_conversation_state WHERE user_id = u.id) = 'awaiting_profile', 'still awaiting');

  -- 5. completing the profile opens the parked request
  r := public.tori_profile_button('919000000001', 'pf_priv_before');
  PERFORM pg_temp.ok((r ->> 'complete')::boolean AND r #>> '{resume,action}' = 'open' AND (r #>> '{resume,request_id}')::uuid = rid, 'complete → resume open');
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE id = rid) = 'open', 'request is open');
  PERFORM pg_temp.ok((SELECT opened_at IS NOT NULL FROM public.partner_requests WHERE id = rid), 'opened_at stamped when it goes live');
  SELECT * INTO u FROM public.tori_users WHERE phone = '+919000000001';
  PERFORM pg_temp.ok(u.profile_status = 'complete' AND u.name = 'Rahul Sharma' AND u.name_source = 'user'
                     AND u.interests = '{badminton,cycling,table_tennis}' AND u.privacy ->> 'photo' = 'before'
                     AND u.birth_year = extract(year FROM now())::int - 24 AND u.gender = 'male', 'profile stored');
  PERFORM pg_temp.ok((SELECT state FROM public.tori_conversation_state WHERE user_id = u.id) = 'idle', 'back to idle');
  r := public.tori_save_profile('919000000001', '{"interests": ["football"]}');
  PERFORM pg_temp.ok(r -> 'resume' = 'null'::jsonb OR r ->> 'resume' IS NULL, 'later profile update resumes nothing');
  PERFORM pg_temp.ok((SELECT interests FROM public.tori_users WHERE id = u.id) = '{badminton,cycling,football,table_tennis}', 'interests are merged');

  -- 6. incomplete request + profile in the first message
  r := public.tori_hold_request('919000000002', 'Priya', pg_temp.req() - 'window_start' - 'window_end' - 'play_date',
                                false, 'What time works for you?', '{"name": "Priya", "age": 27, "gender": "female", "interests": ["badminton"], "skip": ["social", "photo", "about"]}');
  rid := (r ->> 'request_id')::uuid;
  PERFORM pg_temp.ok((r ->> 'complete')::boolean AND r #>> '{resume,action}' = 'ask' AND r #>> '{resume,text}' = 'What time works for you?', 'profile in same message → ask the request question');
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE id = rid) = 'draft', 'request is a draft again');

  -- 7. the game time passed during onboarding
  r := public.tori_hold_request('919000000003', 'Arjun', pg_temp.req(), true, NULL, NULL);
  rid := (r ->> 'request_id')::uuid;
  UPDATE public.partner_requests SET window_start = now() - interval '2 hours', window_end = now() - interval '1 hour' WHERE id = rid;
  r := public.tori_save_profile('919000000003', '{"name": "Arjun", "age": 30, "gender": "prefer_not_to_say", "interests": ["badminton"], "skip": ["social", "photo", "about"]}');
  PERFORM pg_temp.ok(r #>> '{resume,action}' = 'ask' AND r #>> '{resume,text}' LIKE '%already passed%', 'past time → ask for a new time');
  PERFORM pg_temp.ok((SELECT window_end IS NULL AND activity = 'badminton' FROM public.partner_requests WHERE id = rid), 'time cleared, rest kept');

  -- 8. bad values are ignored
  r := public.tori_save_profile('919000000004', '{"age": 400, "gender": "robot", "interests": ["  "]}');
  PERFORM pg_temp.ok(r -> 'missing' = '["name", "age", "gender", "interests", "social", "photo", "about"]', 'invalid values ignored');
  r := public.tori_profile_button('919000000004', 'pf_name_wa');
  PERFORM pg_temp.ok(r ->> 'next' = 'name', 'no WhatsApp name: the name button changes nothing');
  r := public.tori_profile_button('919000000004', 'pf_gender_other');
  PERFORM pg_temp.ok((SELECT gender FROM public.tori_users WHERE phone = '+919000000004') = 'other', 'gender button');
  r := public.tori_save_profile('919000000004', '{"name": "Zed", "age": 19, "interests": ["chess"], "social": "@zed.plays"}');
  PERFORM pg_temp.ok(r ->> 'next' = 'photo', 'an @handle counts as Instagram');
  r := public.tori_profile_button('919000000004', 'pf_skip_photo');
  PERFORM pg_temp.ok(r ->> 'next' = 'about', 'skipping the photo → "about you"');
  r := public.tori_profile_button('919000000004', 'pf_skip_about');
  PERFORM pg_temp.ok(r ->> 'next' = 'privacy', 'skipping "about you" still asks privacy (there is a link)');
  r := public.tori_profile_button('919000000004', 'pf_priv_after');
  PERFORM pg_temp.ok((r ->> 'complete')::boolean, 'complete after the privacy choice');
  PERFORM pg_temp.ok(public.tori_normalize_social('linkedin.com/in/zed-k-123') ->> 'url' = 'https://www.linkedin.com/in/zed-k-123'
                     AND public.tori_normalize_social('https://instagram.com/p/Cxyz') IS NULL, 'LinkedIn kept; an Instagram post link refused');

  -- 9. cancel while waiting
  r := public.tori_hold_request('919000000005', 'Sam', pg_temp.req(), true, NULL, NULL);
  rid := (r ->> 'request_id')::uuid;
  PERFORM public.tori_cancel_pending('919000000005');
  PERFORM pg_temp.ok((SELECT status FROM public.partner_requests WHERE id = rid) = 'cancelled', 'cancel drops the parked request');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.v_partner_board WHERE id = rid), 'a request dropped before going live is not on the board');
  PERFORM pg_temp.ok((SELECT s.state FROM public.tori_conversation_state s JOIN public.tori_users u2 ON u2.id = s.user_id
                       WHERE u2.phone = '+919000000005') = 'idle', 'cancel resets the state');

  -- 10. parked requests expire after 7 days; pending_profile is never a match candidate
  r := public.tori_hold_request('919000000006', 'Old', pg_temp.req(), true, NULL, NULL);
  rid := (r ->> 'request_id')::uuid;
  PERFORM pg_temp.ok(public.match_partner_request(rid) IS NULL, 'parked request is not matched');
  UPDATE public.partner_requests SET updated_at = now() - interval '8 days' WHERE id = rid;
  n := public.tori_expire_pending();
  PERFORM pg_temp.ok(n = 1 AND (SELECT status FROM public.partner_requests WHERE id = rid) = 'expired', 'stale parked request expired');

  -- 11. a profile complete under the old rules (age, gender, interests) still gets the new questions
  INSERT INTO public.tori_users (phone, name, birth_year, gender, interests, profile_status)
  VALUES ('+919000000007', 'Old Timer', 1999, 'male', '{badminton}', 'complete');
  r := public.tori_profile_context('919000000007');
  PERFORM pg_temp.ok(r ->> 'status' = 'incomplete' AND r ->> 'next' = 'name', 'stale "complete" flag: context says incomplete, asks the name');

  -- 12. outbound log
  PERFORM public.tori_log_outbound('919000000001', 'wamid.OUT1', 'Thanks!');
  PERFORM public.tori_log_outbound('919000000001', '', 'no id');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.tori_messages m JOIN public.tori_users u2 ON u2.id = m.user_id
                       WHERE u2.phone = '+919000000001' AND direction = 'out') = 2, 'outbound logged');
END $$;
ROLLBACK;
