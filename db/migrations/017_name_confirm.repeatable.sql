-- "Please confirm your name" (tables: 017_name_confirm.sql). Re-applied by db/migrate.sh whenever this file
-- changes (CREATE OR REPLACE only).
--
-- Workflow 06 calls tori_name_gate() before any matching service starts. Not confirmed yet → the bot asks
-- "Other users will see you as: Harsh. Is this correct?" [Yes, that's me] [No, change it] and keeps the message
-- that started it (name_resume). tori_name_answer() takes the answer; once the name is confirmed the bot
-- replays that message, so the person never has to ask twice. Onboarding (006) asks the same question.

-- A name someone typed (or their WhatsApp profile name) made fit to show: "my name is priya 😊" → 'Priya'.
-- NULL when it can't be a name: digits, links, handles, more than 4 words, "yes" / "ok" / "hi" …
CREATE OR REPLACE FUNCTION public.tori_clean_name(p text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  t text := regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g');
BEGIN
  t := regexp_replace(t, '^(my name is|my name''?s|name is|name ?:|i am|i''m|im|this is|it''s|mera naam|mera name)\s*', '', 'i');
  t := regexp_replace(t, '\s+(hai|hu|hoon|here)$', '', 'i');
  IF t ~ '\d' OR t ~* '(https?:|www\.|\.com\b|@)' THEN
    RETURN NULL;
  END IF;
  -- emojis and symbols go; everything else stays (letters and combining marks of any script: प्रिया keeps its ्)
  t := regexp_replace(t, '[\U0001F000-\U0001FAFF\u2600-\u27BF\u2190-\u21FF\u2B00-\u2BFF\uFE00-\uFE0F\u200D\u20E3\u00A9\u00AE\u2122'
                         '!"#$%&()*+,/:;<=>?\[\]\\^_`{|}~]', '', 'g');
  t := trim(both ' .''’-' FROM regexp_replace(t, '\s+', ' ', 'g'));
  IF length(t) NOT BETWEEN 2 AND 40 OR t !~ '[[:alpha:]].*[[:alpha:]]'
     OR array_length(regexp_split_to_array(t, ' '), 1) > 4
     OR lower(t) ~ '^(yes|no|ok|okay|hi+|hello|hey|menu|start|cancel|stop|skip|haan|han|nahi|nahin|na|nope|yeah|yep|yup|thanks?|thank you|correct|right|wrong)$' THEN
    RETURN NULL;
  END IF;
  IF t = lower(t) OR t = upper(t) THEN
    t := initcap(t);
  END IF;
  RETURN t;
END $$;

-- What other users see: the first word of the name (cards, the board and travel matches show first names)
CREATE OR REPLACE FUNCTION public.tori_first_name(p text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(split_part(coalesce(public.tori_clean_name(p), ''), ' ', 1), '');
$$;

-- Before a matching service: confirmed → { confirmed: true, name }. Otherwise the question is set up and
-- { confirmed: false, step: 'confirm' (show the WhatsApp name with Yes / No) | 'type' (no usable WhatsApp
-- name: ask them to type it), name }. p_resume is what to do once confirmed ({ kind: 'replay', trigger }).
-- p_check = false lets a message through without a question (answers inside a flow that already started).
CREATE OR REPLACE FUNCTION public.tori_name_gate(p_wa_id text, p_name text, p_resume jsonb, p_check boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u       public.tori_users;
  v_first text;
  v_step  text;
BEGIN
  u := public.tori_user(p_wa_id, p_name);
  IF NOT coalesce(p_check, true) OR (u.name_source = 'user' AND u.name IS NOT NULL) THEN
    RETURN jsonb_build_object('confirmed', true, 'name', coalesce(public.tori_first_name(u.name), split_part(u.name, ' ', 1)));
  END IF;
  v_first := public.tori_first_name(u.name);
  v_step := CASE WHEN v_first IS NULL THEN 'type' ELSE 'confirm' END;
  UPDATE public.tori_conversation_state
     SET name_step = v_step, name_resume = p_resume, name_asked_at = now(), updated_at = now()
   WHERE user_id = u.id;
  RETURN jsonb_build_object('confirmed', false, 'step', v_step, 'name', v_first);
END $$;

-- "No, change it" from onboarding (pf_name_no, 006): the next text they send is their name
CREATE OR REPLACE FUNCTION public.tori_name_ask_type(p_wa_id text, p_resume jsonb)
RETURNS void
LANGUAGE sql AS $$
  UPDATE public.tori_conversation_state
     SET name_step = 'type', name_resume = p_resume, name_asked_at = now(), updated_at = now()
   WHERE user_id = (public.tori_user(p_wa_id)).id;
$$;

-- The answer. p_answer: 'yes' | 'no' | 'text' (p_text = the typed name) | 'cancel'.
-- state: confirmed (Yes) | saved (typed) | ask_type (No, or Yes without a usable WhatsApp name) |
--        bad_name (that can't be a name: ask again) | cancelled | none (nothing was being asked)
-- Once confirmed: resume = what started it; for onboarding, profile = tori_save_profile's next step.
CREATE OR REPLACE FUNCTION public.tori_name_answer(p_wa_id text, p_answer text, p_text text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u       public.tori_users;
  s       public.tori_conversation_state;
  active  boolean;
  v_name  text;
  v_state text;
BEGIN
  u := public.tori_user(p_wa_id);
  SELECT * INTO s FROM public.tori_conversation_state WHERE user_id = u.id FOR UPDATE;
  active := s.name_step IS NOT NULL AND s.name_asked_at > now() - interval '1 day';

  IF p_answer = 'cancel' THEN
    UPDATE public.tori_conversation_state SET name_step = NULL, name_resume = NULL, name_asked_at = NULL
     WHERE user_id = u.id;
    RETURN jsonb_build_object('state', CASE WHEN active THEN 'cancelled' ELSE 'none' END);
  ELSIF p_answer = 'no' THEN
    UPDATE public.tori_conversation_state
       SET name_step = 'type', name_asked_at = now(), name_resume = CASE WHEN active THEN name_resume END
     WHERE user_id = u.id;
    RETURN jsonb_build_object('state', 'ask_type');
  ELSIF p_answer = 'yes' THEN
    IF NOT active AND u.name_source = 'user' THEN
      RETURN jsonb_build_object('state', 'none', 'name', public.tori_first_name(u.name));
    END IF;
    v_name := public.tori_clean_name(u.name);
    IF v_name IS NULL THEN
      UPDATE public.tori_conversation_state SET name_step = 'type', name_asked_at = now() WHERE user_id = u.id;
      RETURN jsonb_build_object('state', 'ask_type');
    END IF;
    v_state := 'confirmed';
  ELSIF p_answer = 'text' THEN
    IF NOT active OR s.name_step <> 'type' THEN
      RETURN jsonb_build_object('state', 'none');
    END IF;
    v_name := public.tori_clean_name(p_text);
    IF v_name IS NULL THEN
      RETURN jsonb_build_object('state', 'bad_name');
    END IF;
    v_state := 'saved';
  ELSE
    RETURN jsonb_build_object('state', 'none');
  END IF;

  UPDATE public.tori_users SET name = v_name, name_source = 'user', updated_at = now() WHERE id = u.id;
  UPDATE public.tori_conversation_state SET name_step = NULL, name_resume = NULL, name_asked_at = NULL, updated_at = now()
   WHERE user_id = u.id;
  -- requests already on the board or waiting for a match show the confirmed name from now on
  UPDATE public.partner_requests SET profile_name = v_name
   WHERE wa_id = p_wa_id AND status IN ('draft', 'pending_profile', 'open', 'proposed', 'matched');
  RETURN jsonb_build_object(
    'state', v_state, 'name', public.tori_first_name(v_name),
    'resume', CASE WHEN active THEN s.name_resume END,
    'profile', CASE WHEN active AND s.name_resume ->> 'kind' = 'onboarding' THEN public.tori_save_profile(p_wa_id, '{}') END);
END $$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for n8n only.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('tori_clean_name', 'tori_first_name', 'tori_name_gate', 'tori_name_ask_type', 'tori_name_answer')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
