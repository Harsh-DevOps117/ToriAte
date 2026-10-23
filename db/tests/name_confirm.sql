-- "Please confirm your name" (017): cleaning typed names, the gate, Yes / No / typed answers, onboarding,
-- and the confirmed name reaching partner requests and travel matches.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/name_confirm.sql against a database with 004–017 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

DO $$
DECLARE
  r jsonb; u public.tori_users;
BEGIN
  -- 1. typed names
  PERFORM pg_temp.ok(public.tori_clean_name('my name is priya 😊') = 'Priya', '"my name is priya 😊" → Priya');
  PERFORM pg_temp.ok(public.tori_clean_name('I''m Rahul Verma') = 'Rahul Verma', '"I''m Rahul Verma" → Rahul Verma');
  PERFORM pg_temp.ok(public.tori_clean_name('mera naam Ankit hai') = 'Ankit', 'Hinglish: "mera naam Ankit hai" → Ankit');
  PERFORM pg_temp.ok(public.tori_clean_name('HARSH') = 'Harsh' AND public.tori_clean_name('McDonald') = 'McDonald',
                     'all caps → Harsh; mixed case kept');
  PERFORM pg_temp.ok(public.tori_clean_name('प्रिया') = 'प्रिया', 'Devanagari names work');
  PERFORM pg_temp.ok(public.tori_clean_name('Anne-Marie O''Neil') = 'Anne-Marie O''Neil', 'hyphens and apostrophes stay');
  PERFORM pg_temp.ok(public.tori_clean_name('yes') IS NULL AND public.tori_clean_name('Hi') IS NULL AND public.tori_clean_name('ok') IS NULL,
                     '"yes", "Hi", "ok" are not names');
  PERFORM pg_temp.ok(public.tori_clean_name('Rocky007') IS NULL AND public.tori_clean_name('@rocky') IS NULL
                     AND public.tori_clean_name('www.shop.com') IS NULL, 'digits, handles and links are not names');
  PERFORM pg_temp.ok(public.tori_clean_name('A') IS NULL AND public.tori_clean_name('🔥🔥') IS NULL
                     AND public.tori_clean_name('one two three four five') IS NULL, 'too short, only emojis, too many words');
  PERFORM pg_temp.ok(public.tori_first_name('🔥Rocky🔥 Singh') = 'Rocky' AND public.tori_first_name('Busy 24x7') IS NULL,
                     'first names for the question: "🔥Rocky🔥 Singh" → Rocky; "Busy 24x7" → none');

  -- 2. the gate: WhatsApp name "Harsh Kharwar" → asked once, Yes confirms it
  r := public.tori_name_gate('919700000001', 'Harsh Kharwar', '{"kind": "replay", "trigger": {"m": 1}}');
  PERFORM pg_temp.ok(r ->> 'confirmed' = 'false' AND r ->> 'step' = 'confirm' AND r ->> 'name' = 'Harsh', 'not confirmed → "Are you Harsh?"');
  PERFORM pg_temp.ok(public.tori_log_inbound('919700000001', 'Harsh Kharwar', 'wamid.NC1', 'text', 'x') ->> 'name_step' = 'confirm',
                     'the inbound log says the bot is waiting for Yes / No');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000001', 'text', 'Harsh') ->> 'state' = 'none', 'a text while Yes / No is asked is not taken as a name');
  r := public.tori_name_answer('919700000001', 'yes');
  PERFORM pg_temp.ok(r ->> 'state' = 'confirmed' AND r ->> 'name' = 'Harsh' AND r -> 'resume' ->> 'kind' = 'replay', 'Yes → confirmed, the message to replay comes back');
  SELECT * INTO u FROM public.tori_users WHERE phone = '+919700000001';
  PERFORM pg_temp.ok(u.name = 'Harsh Kharwar' AND u.name_source = 'user', 'stored: Harsh Kharwar, confirmed');
  PERFORM pg_temp.ok(public.tori_log_inbound('919700000001', 'Harsh Kharwar', 'wamid.NC2', 'text', 'x') ->> 'name_step' IS NULL, 'nothing asked any more');
  r := public.tori_name_gate('919700000001', 'Harsh Kharwar', '{}');
  PERFORM pg_temp.ok(r ->> 'confirmed' = 'true' AND r ->> 'name' = 'Harsh', 'next service: no question');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000001', 'yes') ->> 'state' = 'none', 'an old Yes button tapped again changes nothing');

  -- 3. No → type it; nonsense is refused; the typed name is saved and shown on live requests
  PERFORM public.save_partner_request('919700000002', 'Shop Owner', '{"activity": "football"}', false);
  r := public.tori_name_gate('919700000002', 'Shop Owner', '{"kind": "replay", "trigger": {"m": 2}}');
  PERFORM pg_temp.ok(r ->> 'step' = 'confirm' AND r ->> 'name' = 'Shop', '"Shop Owner" → "Are you Shop?"');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000002', 'no') ->> 'state' = 'ask_type', 'No → please type your name');
  PERFORM pg_temp.ok(public.tori_log_inbound('919700000002', 'Shop Owner', 'wamid.NC3', 'text', 'x') ->> 'name_step' = 'type', 'now waiting for the typed name');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000002', 'text', 'ok') ->> 'state' = 'bad_name', '"ok" → not a name, ask again');
  r := public.tori_name_answer('919700000002', 'text', 'my name is aisha khan');
  PERFORM pg_temp.ok(r ->> 'state' = 'saved' AND r ->> 'name' = 'Aisha' AND r -> 'resume' -> 'trigger' ->> 'm' = '2', 'typed → Aisha Khan saved, replay kept');
  PERFORM pg_temp.ok((SELECT name FROM public.tori_users WHERE phone = '+919700000002') = 'Aisha Khan', 'stored: Aisha Khan');
  PERFORM pg_temp.ok((SELECT profile_name FROM public.partner_requests WHERE wa_id = '919700000002') = 'Aisha Khan',
                     'her open draft shows Aisha Khan');
  PERFORM public.save_partner_request('919700000002', 'Shop Owner', '{"activity": "cricket"}', false);
  PERFORM pg_temp.ok((SELECT profile_name FROM public.partner_requests WHERE wa_id = '919700000002' ORDER BY updated_at DESC LIMIT 1) = 'Aisha Khan',
                     'a new request keeps the confirmed name, not the WhatsApp one');
  PERFORM public.tori_user('919700000002', 'Shop Owner');
  PERFORM pg_temp.ok((SELECT name FROM public.tori_users WHERE phone = '+919700000002') = 'Aisha Khan', 'the next message doesn''t bring the WhatsApp name back');

  -- 4. no usable WhatsApp name → asked to type it straight away; Yes then can't confirm anything
  r := public.tori_name_gate('919700000003', '🔥🔥', '{"kind": "replay"}');
  PERFORM pg_temp.ok(r ->> 'step' = 'type' AND r ->> 'name' IS NULL, 'WhatsApp name "🔥🔥" → "May I know your name?"');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000003', 'yes') ->> 'state' = 'ask_type', 'a Yes with no usable name → type it');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000003', 'cancel') ->> 'state' = 'cancelled', 'cancel stops asking');
  PERFORM pg_temp.ok(public.tori_name_answer('919700000003', 'text', 'Rohan') ->> 'state' = 'none', '… and a later text is not taken as a name');

  -- 5. the question is forgotten after a day
  PERFORM public.tori_name_gate('919700000004', 'Meera', '{}');
  UPDATE public.tori_conversation_state SET name_asked_at = now() - interval '25 hours'
   WHERE user_id = (SELECT id FROM public.tori_users WHERE phone = '+919700000004');
  PERFORM pg_temp.ok(public.tori_log_inbound('919700000004', 'Meera', 'wamid.NC4', 'text', 'x') ->> 'name_step' IS NULL, 'a day later: not waiting any more');
  r := public.tori_name_answer('919700000004', 'yes');
  PERFORM pg_temp.ok(r ->> 'state' = 'confirmed' AND r -> 'resume' = 'null'::jsonb, 'an old Yes still confirms, but replays nothing');

  -- 6. onboarding: "No, change it" → typed name → the next onboarding question
  PERFORM public.tori_user('919700000005', 'Cool Dude');
  r := public.tori_profile_button('919700000005', 'pf_name_no');
  PERFORM pg_temp.ok((r ->> 'ask_name')::boolean AND r ->> 'next' = 'name', 'onboarding "No, change it" → please type your name');
  r := public.tori_name_answer('919700000005', 'text', 'Kabir');
  PERFORM pg_temp.ok(r ->> 'state' = 'saved' AND r -> 'profile' ->> 'next' = 'age', 'typed Kabir → onboarding goes on with the age');
  PERFORM public.tori_user('919700000006', 'Neha Joshi');
  r := public.tori_profile_button('919700000006', 'pf_name_wa');
  PERFORM pg_temp.ok(r ->> 'next' = 'age' AND (SELECT name_source FROM public.tori_users WHERE phone = '+919700000006') = 'user',
                     'onboarding "Yes, that''s me" → confirmed, next the age');

  -- 7. travel matches show the confirmed name
  INSERT INTO public.travel_users (wa_id, profile_name) VALUES ('919700000002', 'Shop Owner'), ('919700000001', 'Harsh Kharwar');
  PERFORM pg_temp.ok((SELECT coalesce((SELECT tu.name FROM public.tori_users tu WHERE tu.phone = '+' || o.wa_id AND tu.name_source = 'user'), o.profile_name)
                        FROM public.travel_users o WHERE o.wa_id = '919700000002') = 'Aisha Khan',
                     'travel: the confirmed name beats the WhatsApp one (as travel_notification reads it)');
END $$;
ROLLBACK;
