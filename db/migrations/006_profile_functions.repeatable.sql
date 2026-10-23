-- User profiles and onboarding for the Tori WhatsApp bot (workflow 06). Tables: 006_user_profiles.sql.
-- Every rule lives here, one transaction per call; n8n only calls these functions and sends the replies.
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

-- Find or create the person behind a WhatsApp number (digits only, as the webhook sends it).
-- A name they told the bot is kept; the WhatsApp profile name only fills an empty one.
CREATE OR REPLACE FUNCTION public.tori_user(p_wa_id text, p_name text DEFAULT NULL)
RETURNS public.tori_users
LANGUAGE plpgsql AS $$
DECLARE
  u public.tori_users;
BEGIN
  INSERT INTO public.tori_users AS t (phone, name)
  VALUES ('+' || p_wa_id, nullif(trim(p_name), ''))
  ON CONFLICT (phone) DO UPDATE
    SET name = coalesce(t.name, EXCLUDED.name),
        updated_at = CASE WHEN t.name IS NULL AND EXCLUDED.name IS NOT NULL THEN now() ELSE t.updated_at END
  RETURNING * INTO u;
  INSERT INTO public.tori_conversation_state (user_id) VALUES (u.id) ON CONFLICT (user_id) DO NOTHING;
  RETURN u;
END $$;

-- The onboarding steps still to do, in the order the bot asks (one at a time). Required: name (told
-- or confirmed, not just the WhatsApp name), age, gender, interests. Optional, asked once: an
-- Instagram / LinkedIn link, a photo and "about you" (typed or a voice note; "Skip" counts). Then, if
-- they gave a link or photo, who may see them before both people say yes. Complete when nothing is left.
CREATE OR REPLACE FUNCTION public.tori_profile_missing(u public.tori_users)
RETURNS text[]
LANGUAGE sql STABLE AS $$
  WITH ph AS (SELECT EXISTS (SELECT 1 FROM public.tori_user_photos p WHERE p.user_id = u.id) AS has_photo)
  SELECT array_remove(ARRAY[
    CASE WHEN u.name IS NULL OR u.name_source <> 'user' THEN 'name' END,
    CASE WHEN u.birth_year IS NULL THEN 'age' END,
    CASE WHEN u.gender IS NULL THEN 'gender' END,
    CASE WHEN coalesce(cardinality(u.interests), 0) = 0 THEN 'interests' END,
    CASE WHEN u.social_url IS NULL AND NOT 'social' = ANY (u.skipped) THEN 'social' END,
    CASE WHEN NOT ph.has_photo AND NOT 'photo' = ANY (u.skipped) THEN 'photo' END,
    CASE WHEN u.about_text IS NULL AND NOT 'about' = ANY (u.skipped) THEN 'about' END,
    CASE WHEN u.privacy_set_at IS NULL AND (u.social_url IS NOT NULL OR ph.has_photo) THEN 'privacy' END], NULL)
  FROM ph
$$;

-- Keep the stored flag in line with the current steps (re-run whenever this file changes).
UPDATE public.tori_users u
   SET profile_status = CASE WHEN cardinality(public.tori_profile_missing(u)) = 0 THEN 'complete' ELSE 'incomplete' END
 WHERE profile_status IS DISTINCT FROM CASE WHEN cardinality(public.tori_profile_missing(u)) = 0 THEN 'complete' ELSE 'incomplete' END;

-- An Instagram or LinkedIn profile from a link or an @handle; NULL if it is neither.
CREATE OR REPLACE FUNCTION public.tori_normalize_social(p text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  t text := trim(coalesce(p, ''));
  m text[];
BEGIN
  m := regexp_match(t, 'linkedin\.com/in/([A-Za-z0-9_%-]{2,100})', 'i');
  IF m IS NOT NULL THEN
    RETURN jsonb_build_object('kind', 'linkedin', 'url', 'https://www.linkedin.com/in/' || m[1]);
  END IF;
  m := regexp_match(t, 'instagram\.com/([A-Za-z0-9._]{1,30})', 'i');
  IF m IS NOT NULL AND lower(m[1]) NOT IN ('p', 'reel', 'reels', 'stories', 'explore', 'accounts') THEN
    RETURN jsonb_build_object('kind', 'instagram', 'url', 'https://instagram.com/' || lower(m[1]));
  END IF;
  m := regexp_match(t, '^@([A-Za-z0-9._]{1,30})$');
  IF m IS NOT NULL THEN
    RETURN jsonb_build_object('kind', 'instagram', 'url', 'https://instagram.com/' || lower(m[1]));
  END IF;
  RETURN NULL;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_log_inbound: first node after the WhatsApp Trigger. Creates the user (phone only) on
-- first contact and logs the message. duplicate = true when Meta redelivers the same
-- message ID: the workflow stops there.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_log_inbound(p_wa_id text, p_name text, p_message_id text,
                                                   p_type text, p_body text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u    public.tori_users;
  v_step text;
  v_name_step text;
BEGIN
  IF coalesce(p_wa_id, '') !~ '^[1-9]\d{5,14}$' THEN
    RETURN jsonb_build_object('duplicate', false);     -- status update or unknown payload: let it through
  END IF;
  u := public.tori_user(p_wa_id, p_name);
  -- in the middle of adding a ToriPay payee (014): the bot sends the answer there; bank account numbers
  -- are not kept in the message log
  SELECT d.step INTO v_step FROM public.toripay_drafts d WHERE d.user_id = u.id AND d.expires_at > now();
  -- waiting for "Please confirm your name" (017): the bot reads the answer before anything else
  SELECT s.name_step INTO v_name_step FROM public.tori_conversation_state s
   WHERE s.user_id = u.id AND s.name_asked_at > now() - interval '1 day';
  INSERT INTO public.tori_messages (user_id, wa_message_id, direction, type, body)
  VALUES (u.id, nullif(p_message_id, ''), 'in', nullif(p_type, ''),
          CASE WHEN v_step IN ('account', 'account_confirm') AND regexp_replace(coalesce(p_body, ''), '[\s.-]', '', 'g') ~ '\d{6,}' THEN '[bank account number]'
               ELSE nullif(p_body, '') END)
  ON CONFLICT (wa_message_id) DO NOTHING;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('user_id', u.id, 'duplicate', true);
  END IF;
  -- any message reopens WhatsApp's 24-hour window: the match flow checks last_message_at
  UPDATE public.partner_requests SET last_message_at = now()
   WHERE wa_id = p_wa_id AND status IN ('draft', 'pending_profile', 'open', 'proposed');
  RETURN jsonb_build_object('user_id', u.id, 'duplicate', false, 'toripay_step', v_step, 'name_step', v_name_step);
END $$;

-- What the bot sent (profile questions and the replies that follow them).
CREATE OR REPLACE FUNCTION public.tori_log_outbound(p_wa_id text, p_message_id text, p_body text)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.tori_messages (user_id, wa_message_id, direction, type, body)
  VALUES ((public.tori_user(p_wa_id)).id, nullif(p_message_id, ''), 'out', 'text', p_body)
  ON CONFLICT (wa_message_id) DO NOTHING;
$$;

-- What workflow 06 needs to know before reading a message ("Get partner draft").
CREATE OR REPLACE FUNCTION public.tori_profile_context(p_wa_id text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    -- status from the steps still to do, not the stored flag: the steps can change (009 added name,
    -- link, photo), and a profile complete under the old rules must be asked the new questions
    (SELECT jsonb_build_object('status', CASE WHEN cardinality(m.steps) = 0 THEN 'complete' ELSE 'incomplete' END,
                               'state', s.state, 'missing', to_jsonb(m.steps), 'next', m.steps[1])
       FROM public.tori_users u
       LEFT JOIN public.tori_conversation_state s ON s.user_id = u.id
       CROSS JOIN LATERAL (SELECT public.tori_profile_missing(u) AS steps) m
      WHERE u.phone = '+' || p_wa_id),
    jsonb_build_object('status', 'incomplete', 'state', 'idle', 'next', 'name',
                       'missing', jsonb_build_array('name', 'age', 'gender', 'interests', 'social', 'photo')));
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_save_profile: merge what the person told us. p (nulls ignored):
--   name, age, gender, interests  (the LLM's "profile" object)
--   social                        (a link or @handle: error 'bad_social' when it is neither)
--   name_confirm: true            ("Use my WhatsApp name" button)
--   skip: 'social' | 'photo' | 'about' | [...]   privacy: 'before' | 'after'   (buttons)
-- Returns { complete, next, missing, name, wa_first, error, resume }. When the profile becomes complete
-- while a request is waiting for it, the request is picked up again:
--   resume.action = 'open' → the request is open; workflow 06 acks it and searches for a match
--   resume.action = 'ask'  → the request still lacks details; resume.text is the question
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_save_profile(p_wa_id text, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u       public.tori_users;
  s       public.tori_conversation_state;
  r       public.partner_requests;
  v_age   int;
  v_new   text[];
  v_miss  text[];
  v_res   jsonb;
  v_soc   jsonb;
  v_err   text;
  v_skip  text[];
BEGIN
  u := public.tori_user(p_wa_id);
  p := coalesce(p, '{}');
  IF nullif(trim(p ->> 'social'), '') IS NOT NULL THEN
    v_soc := public.tori_normalize_social(p ->> 'social');
    IF v_soc IS NULL THEN v_err := 'bad_social'; END IF;
  END IF;
  v_skip := CASE jsonb_typeof(p -> 'skip')
              WHEN 'string' THEN ARRAY[p ->> 'skip']
              WHEN 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p -> 'skip'))
              ELSE '{}' END;
  v_skip := ARRAY(SELECT x FROM unnest(v_skip) x WHERE x IN ('social', 'photo', 'about'));
  IF jsonb_typeof(p -> 'age') = 'number' AND (p ->> 'age') ~ '^\d{1,3}$' THEN
    v_age := (p ->> 'age')::int;
  END IF;
  IF jsonb_typeof(p -> 'interests') = 'array' THEN
    SELECT array_agg(DISTINCT x) INTO v_new
      FROM (SELECT lower(regexp_replace(trim(e), '\s+', '_', 'g')) AS x
              FROM jsonb_array_elements_text(p -> 'interests') e) t
     WHERE x <> '';
  END IF;

  UPDATE public.tori_users SET
    -- "Yes, that's me" keeps the WhatsApp name without its emojis ("🔥Rocky🔥" → "Rocky", 017)
    name        = coalesce(nullif(left(trim(p ->> 'name'), 60), ''),
                           CASE WHEN coalesce((p ->> 'name_confirm')::boolean, false) THEN coalesce(public.tori_clean_name(name), name) END,
                           name),
    name_source = CASE WHEN nullif(trim(p ->> 'name'), '') IS NOT NULL
                         OR (coalesce((p ->> 'name_confirm')::boolean, false) AND name IS NOT NULL)
                       THEN 'user' ELSE name_source END,
    social_kind = coalesce(v_soc ->> 'kind', social_kind),
    social_url  = coalesce(v_soc ->> 'url', social_url),
    skipped     = ARRAY(SELECT DISTINCT unnest(skipped || v_skip)),
    privacy     = CASE WHEN p ->> 'privacy' IN ('before', 'after')
                       THEN jsonb_build_object('photo', p ->> 'privacy', 'social', p ->> 'privacy') ELSE privacy END,
    privacy_set_at = CASE WHEN p ->> 'privacy' IN ('before', 'after') THEN now() ELSE privacy_set_at END,
    -- an age is stored as a birth year (± 1), so the profile stays right next year
    birth_year = CASE WHEN v_age BETWEEN 10 AND 100
                      THEN extract(year FROM now() AT TIME ZONE timezone)::int - v_age ELSE birth_year END,
    gender     = CASE WHEN p ->> 'gender' IN ('male', 'female', 'non_binary', 'other', 'prefer_not_to_say')
                      THEN p ->> 'gender' ELSE gender END,
    interests  = CASE WHEN v_new IS NULL THEN interests
                      ELSE ARRAY(SELECT DISTINCT unnest(coalesce(interests, '{}') || v_new) ORDER BY 1) END,
    updated_at = now()
  WHERE id = u.id
  RETURNING * INTO u;

  v_miss := public.tori_profile_missing(u);
  UPDATE public.tori_users
     SET profile_status = CASE WHEN cardinality(v_miss) = 0 THEN 'complete' ELSE 'incomplete' END
   WHERE id = u.id;

  SELECT * INTO s FROM public.tori_conversation_state WHERE user_id = u.id FOR UPDATE;
  IF cardinality(v_miss) = 0 AND s.state = 'awaiting_profile' THEN
    SELECT * INTO r FROM public.partner_requests
     WHERE id = s.pending_request_id AND status = 'pending_profile' FOR UPDATE;
    IF FOUND AND coalesce((s.context ->> 'request_complete')::boolean, false) AND r.window_end > now() THEN
      UPDATE public.partner_requests
         SET status = 'open', profile_name = coalesce(u.name, profile_name),
             last_message_at = now(), updated_at = now()
       WHERE id = r.id;
      -- one live request per person, activity and day: the newest one wins (as save_partner_request)
      UPDATE public.partner_requests SET status = 'cancelled', updated_at = now()
       WHERE wa_id = r.wa_id AND id <> r.id AND status IN ('draft', 'open')
         AND activity = r.activity AND play_date = r.play_date;
      v_res := jsonb_build_object('action', 'open', 'request_id', r.id, 'activity', r.activity,
                                  'play_date', r.play_date, 'time_label', r.time_label, 'area', r.area,
                                  'city', r.city, 'spots', r.players_needed);
    ELSIF FOUND AND coalesce((s.context ->> 'request_complete')::boolean, false) THEN
      -- onboarding took longer than the game: keep the rest, ask for a new day and time
      UPDATE public.partner_requests
         SET status = 'draft', play_date = NULL, time_exact = NULL, part_of_day = NULL, time_label = NULL,
             window_start = NULL, window_end = NULL, last_message_at = now(), updated_at = now()
       WHERE id = r.id;
      v_res := jsonb_build_object('action', 'ask', 'request_id', r.id,
                                  'text', 'That time has already passed. Which day and time works for you?');
    ELSIF FOUND THEN
      -- a draft again (30 minutes to finish it), and the question the bot would have asked
      UPDATE public.partner_requests SET status = 'draft', last_message_at = now(), updated_at = now()
       WHERE id = r.id;
      v_res := jsonb_build_object('action', 'ask', 'request_id', r.id, 'text', s.context ->> 'followup');
    END IF;
    -- a board "JOIN <code>" that was waiting for this profile (011): workflow 06 sends it on now
    IF s.context ? 'join_code' THEN
      v_res := coalesce(v_res, '{}') || jsonb_build_object('join_code', s.context ->> 'join_code');
    END IF;
    UPDATE public.tori_conversation_state
       SET state = 'idle', pending_request_id = NULL, context = '{}', updated_at = now()
     WHERE user_id = u.id;
  END IF;

  RETURN jsonb_build_object('complete', cardinality(v_miss) = 0, 'missing', to_jsonb(v_miss), 'next', v_miss[1],
                            'name', CASE WHEN u.name_source = 'user' THEN u.name END,
                            -- the WhatsApp name, offered as a one-tap answer to "What's your name?"
                            'wa_first', public.tori_first_name(u.name),
                            'error', v_err, 'resume', v_res);
END $$;

-- A tap on an onboarding button (pf_…): name_wa ("Yes, that's me"), name_no ("No, change it": the next text
-- is their name, 017 → ask_name), gender_<male|female|other>, skip_<social|photo|about>, priv_<before|after>.
-- Same result as tori_save_profile.
CREATE OR REPLACE FUNCTION public.tori_profile_button(p_wa_id text, p_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
  IF p_id = 'pf_name_no' THEN
    PERFORM public.tori_name_ask_type(p_wa_id, '{"kind": "onboarding"}');
    RETURN public.tori_save_profile(p_wa_id, '{}') || '{"ask_name": true}';
  END IF;
  RETURN public.tori_save_profile(p_wa_id, CASE
    WHEN p_id = 'pf_name_wa'       THEN '{"name_confirm": true}'::jsonb
    WHEN p_id LIKE 'pf\_gender\_%' THEN jsonb_build_object('gender', substr(p_id, 11))
    WHEN p_id LIKE 'pf\_skip\_%'   THEN jsonb_build_object('skip', substr(p_id, 9))
    WHEN p_id LIKE 'pf\_priv\_%'   THEN jsonb_build_object('privacy', substr(p_id, 9))
    ELSE '{}'::jsonb END);
END $$;

-- "About you", typed or transcribed from a voice note (p_source 'text' / 'voice'). p_extracted is the
-- LLM's reading of it: { summary, skill_level, interests }. The summary (no numbers, emails or links)
-- goes on match cards; the skill level is used when a request doesn't state one; interests are merged.
-- Fewer than 3 letters (an empty transcription, "ok") returns error 'bad_about'.
CREATE OR REPLACE FUNCTION public.tori_save_about(p_wa_id text, p_text text, p_source text, p_extracted jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u         public.tori_users;
  v_text    text := left(trim(coalesce(p_text, '')), 4000);
  v_sum     text;
  v_new     text[];
  e         jsonb := coalesce(p_extracted, '{}');
BEGIN
  u := public.tori_user(p_wa_id);
  IF length(regexp_replace(v_text, '[^[:alpha:]]', '', 'g')) < 3 THEN
    RETURN public.tori_save_profile(p_wa_id, '{}') || '{"error": "bad_about"}';
  END IF;
  -- the summary is shown to strangers: drop anything that looks like contact details
  v_sum := nullif(trim(regexp_replace(regexp_replace(regexp_replace(coalesce(e ->> 'summary', ''),
             'https?://\S+|www\.\S+', '', 'gi'),
             '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '', 'g'),
             '\+?\d[\d\s-]{6,}\d', '', 'g')), '');
  IF jsonb_typeof(e -> 'interests') = 'array' THEN
    SELECT array_agg(DISTINCT x) INTO v_new
      FROM (SELECT lower(regexp_replace(trim(i), '\s+', '_', 'g')) AS x
              FROM jsonb_array_elements_text(e -> 'interests') i) t
     WHERE x <> '';
  END IF;
  UPDATE public.tori_users SET
    about_text    = v_text,
    about_source  = CASE WHEN p_source IN ('text', 'voice') THEN p_source ELSE 'text' END,
    about_summary = left(v_sum, 200),
    skill_level   = CASE WHEN e ->> 'skill_level' IN ('beginner', 'intermediate', 'advanced')
                         THEN e ->> 'skill_level' ELSE skill_level END,
    interests     = CASE WHEN v_new IS NULL THEN interests
                         ELSE ARRAY(SELECT DISTINCT unnest(coalesce(interests, '{}') || v_new) ORDER BY 1) END,
    updated_at    = now()
  WHERE id = u.id;
  RETURN public.tori_save_profile(p_wa_id, '{}') || jsonb_build_object('about_summary', left(v_sum, 200));
END $$;

-- A profile photo sent while onboarding (downloaded from WhatsApp by workflow 06, base64).
-- JPEG / PNG / WebP up to 5 MB; anything else returns error 'bad_photo'. A new photo replaces the old
-- one and gets a new token, so links to the old one stop working.
CREATE OR REPLACE FUNCTION public.tori_save_photo(p_wa_id text, p_mime text, p_base64 text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u       public.tori_users;
  v_mime  text := lower(trim(split_part(coalesce(p_mime, ''), ';', 1)));
  v_bytes bytea;
BEGIN
  u := public.tori_user(p_wa_id);
  BEGIN
    v_bytes := decode(coalesce(p_base64, ''), 'base64');
  EXCEPTION WHEN others THEN
    v_bytes := NULL;
  END;
  IF v_bytes IS NULL OR octet_length(v_bytes) = 0 OR octet_length(v_bytes) > 5242880
     OR v_mime NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
    RETURN public.tori_save_profile(p_wa_id, '{}') || '{"error": "bad_photo"}';
  END IF;
  INSERT INTO public.tori_user_photos (user_id, mime, bytes) VALUES (u.id, v_mime, v_bytes)
  ON CONFLICT (user_id) DO UPDATE
    SET token = gen_random_uuid(), mime = EXCLUDED.mime, bytes = EXCLUDED.bytes, created_at = now();
  RETURN public.tori_save_profile(p_wa_id, '{}');
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- tori_hold_request: a partner request from someone without a complete profile.
-- p = the "fields" object of "Validate partner request" (as for save_partner_request);
-- p_complete = whether the request itself has everything; p_followup = the question to
-- ask about the request afterwards. The request is saved first ('pending_profile'), so it
-- is never lost, then whatever profile fields the same message held are saved.
-- Returns tori_save_profile's result.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tori_hold_request(p_wa_id text, p_name text, p jsonb, p_complete boolean,
                                                    p_followup text, p_profile jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u public.tori_users;
  s public.tori_conversation_state;
  r public.partner_requests;
BEGIN
  u := public.tori_user(p_wa_id, p_name);
  SELECT * INTO s FROM public.tori_conversation_state WHERE user_id = u.id FOR UPDATE;

  -- a change to the parked request ("make it 7 pm") updates it: as this person's newest draft,
  -- save_partner_request continues it instead of starting another one
  UPDATE public.partner_requests SET status = 'draft', updated_at = now()
   WHERE id = s.pending_request_id AND status = 'pending_profile';
  r := public.save_partner_request(p_wa_id, p_name, p, false);
  UPDATE public.partner_requests SET status = 'pending_profile' WHERE id = r.id;
  -- one parked request per person
  UPDATE public.partner_requests SET status = 'cancelled', updated_at = now()
   WHERE wa_id = p_wa_id AND status = 'pending_profile' AND id <> r.id;

  UPDATE public.tori_conversation_state
     SET state = 'awaiting_profile', pending_request_id = r.id, updated_at = now(),
         context = jsonb_build_object('request_complete', p_complete, 'followup', p_followup,
                                      'asks', coalesce((context ->> 'asks')::int, 0) + 1)
   WHERE user_id = u.id;

  RETURN public.tori_save_profile(p_wa_id, p_profile) || jsonb_build_object('request_id', r.id);
END $$;

-- "Stop looking" also drops the parked request and stops asking for the profile.
CREATE OR REPLACE FUNCTION public.tori_cancel_pending(p_wa_id text)
RETURNS void
LANGUAGE sql AS $$
  UPDATE public.partner_requests SET status = 'cancelled', updated_at = now()
   WHERE wa_id = p_wa_id AND status = 'pending_profile';
  UPDATE public.tori_conversation_state s
     SET state = 'idle', pending_request_id = NULL, context = '{}', updated_at = now()
    FROM public.tori_users u
   WHERE u.id = s.user_id AND u.phone = '+' || p_wa_id AND s.state <> 'idle';
$$;

-- Every 15 minutes (with expire_partner_requests): requests parked for a profile that never
-- came are dropped after 7 days. Returns how many.
CREATE OR REPLACE FUNCTION public.tori_expire_pending()
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  WITH gone AS (
    UPDATE public.partner_requests SET status = 'expired', updated_at = now()
     WHERE status = 'pending_profile' AND updated_at < now() - interval '7 days'
    RETURNING id),
  reset AS (
    UPDATE public.tori_conversation_state
       SET state = 'idle', pending_request_id = NULL, context = '{}', updated_at = now()
     WHERE pending_request_id IN (SELECT id FROM gone)
    RETURNING 1)
  SELECT count(*) INTO n FROM gone;
  RETURN n;
END $$;

-- partner_requests.opened_at and join_code (011): stamped the first time a request goes live, whichever
-- function opens it. (tori_new_join_code is in 011_joins.repeatable.sql.)
CREATE OR REPLACE FUNCTION public.tori_stamp_opened()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IN ('open', 'proposed', 'matched') THEN
    NEW.opened_at := coalesce(NEW.opened_at, now());
    NEW.join_code := coalesce(NEW.join_code, public.tori_new_join_code());
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER partner_requests_opened_at
  BEFORE INSERT OR UPDATE OF status ON public.partner_requests
  FOR EACH ROW EXECUTE FUNCTION public.tori_stamp_opened();

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
