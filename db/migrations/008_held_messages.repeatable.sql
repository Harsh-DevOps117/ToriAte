-- Messages kept for people outside WhatsApp's 24-hour window. Table: 008_held_messages.sql.
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).

-- Keep a message for someone who can't be reached now. It expires when the game is over
-- (the earlier end of the two requests' time windows).
CREATE OR REPLACE FUNCTION public.tori_hold_message(p_wa_id text, p_kind text, p_match_id uuid, p_body jsonb)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_expires timestamptz;
BEGIN
  SELECT least(ra.window_end, rb.window_end) INTO v_expires
    FROM public.partner_matches m
    JOIN public.partner_requests ra ON ra.id = m.request_a
    JOIN public.partner_requests rb ON rb.id = m.request_b
   WHERE m.id = p_match_id;
  v_expires := coalesce(v_expires, now() + interval '1 day');
  IF v_expires <= now() THEN
    RETURN;
  END IF;
  INSERT INTO public.tori_held_messages (wa_id, kind, match_id, body, expires_at)
  VALUES (p_wa_id, p_kind, p_match_id, p_body, v_expires)
  ON CONFLICT (wa_id, match_id) WHERE kind = 'match_offer' DO NOTHING;
END $$;

-- The messages to send this person now, oldest first, marked as delivered. Offers are only sent
-- while their match still waits for an answer. p_resend ("any match?"): offers already delivered
-- but not answered yet are sent again too.
CREATE OR REPLACE FUNCTION public.tori_take_held(p_wa_id text, p_resend boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_out jsonb;
BEGIN
  WITH live_offer AS (
    SELECT m.id FROM public.partner_matches m
     WHERE m.status = 'pending' AND p_wa_id IN (m.wa_a, m.wa_b)
       AND (CASE WHEN p_wa_id = m.wa_a THEN m.a_response ELSE m.b_response END) IS NULL),
  due AS (
    UPDATE public.tori_held_messages h SET delivered_at = now()
     WHERE h.wa_id = p_wa_id AND h.expires_at > now()
       AND (h.delivered_at IS NULL OR (p_resend AND h.kind IN ('match_offer', 'join_request')))
       AND (h.kind <> 'match_offer' OR h.match_id IN (SELECT id FROM live_offer))
       -- a join request (011) only while it still waits for the host's answer
       AND (h.kind <> 'join_request' OR h.join_id IN (SELECT id FROM public.partner_joins WHERE status = 'pending'))
    RETURNING h.*),
  -- the 2-hour answer clock starts when the offer is actually seen
  seen AS (
    UPDATE public.partner_matches m SET offered_at = now()
     WHERE m.id IN (SELECT match_id FROM due WHERE kind = 'match_offer'))
  SELECT coalesce(jsonb_agg(body ORDER BY created_at), '[]') INTO v_out FROM due;
  RETURN v_out;
END $$;

-- "any match?": this person's live requests (what each waits for, spots, who joined, joins waiting for
-- their answer) and the games they asked to join (011).
CREATE OR REPLACE FUNCTION public.tori_partner_status(p_wa_id text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'requests', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'activity', r.activity, 'play_date', r.play_date, 'time_label', r.time_label, 'area', r.area,
               'status', r.status, 'code', r.join_code, 'spots', r.players_needed,
               -- b hasn't been told about a match until a said yes (009): for b it's still "looking"
               'waiting_on', (SELECT CASE WHEN m.wa_b = p_wa_id AND m.a_response IS DISTINCT FROM 'yes' THEN NULL
                                          WHEN (CASE WHEN m.wa_a = p_wa_id THEN m.a_response ELSE m.b_response END) IS NULL
                                          THEN 'you' ELSE 'them' END
                                FROM public.partner_matches m
                               WHERE m.status = 'pending' AND r.id IN (m.request_a, m.request_b)
                               ORDER BY m.created_at DESC LIMIT 1),
               'partner', (SELECT CASE WHEN o.id IS NOT NULL AND (m.wa_a = p_wa_id OR m.a_response = 'yes') THEN coalesce(nullif(split_part(trim(o.profile_name), ' ', 1), ''), 'your partner') END
                             FROM public.partner_matches m
                             JOIN public.partner_requests o ON o.id = CASE WHEN m.request_a = r.id THEN m.request_b ELSE m.request_a END
                            WHERE m.status = 'pending' AND r.id IN (m.request_a, m.request_b)
                            ORDER BY m.created_at DESC LIMIT 1),
               'joined', coalesce((SELECT to_jsonb(b.joined_names) FROM public.v_partner_board b WHERE b.id = r.id), '[]'),
               'pending_joins', (SELECT count(*) FROM public.partner_joins j WHERE j.request_id = r.id AND j.status = 'pending'))
             ORDER BY r.window_start)
        FROM public.partner_requests r
       WHERE r.wa_id = p_wa_id AND r.status IN ('open', 'proposed', 'matched') AND r.window_end > now()), '[]'),
    'joins', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'activity', r.activity, 'play_date', r.play_date, 'time_label', r.time_label, 'area', r.area,
               'host', coalesce(nullif(split_part(trim(coalesce(hu.name, r.profile_name, '')), ' ', 1), ''), 'the host'),
               'status', j.status)
             ORDER BY r.window_start)
        FROM public.partner_joins j
        JOIN public.partner_requests r ON r.id = j.request_id
        LEFT JOIN public.tori_users hu ON hu.phone = '+' || r.wa_id
       WHERE j.joiner_wa = p_wa_id AND j.status IN ('pending', 'accepted') AND r.window_end > now()), '[]'));
$$;

-- Replaces the 004 version: a proposal kept for someone offline doesn't time out after 2 hours;
-- it waits until they have seen it (offered_at) or the game time has passed.
CREATE OR REPLACE FUNCTION public.expire_partner_requests()
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_reopened uuid[];
BEGIN
  -- proposals not answered within 2 hours of being seen, or whose game time has passed
  WITH stale AS (
    UPDATE public.partner_matches pm SET status = 'expired', decided_at = now()
     WHERE pm.status = 'pending'
       AND ((coalesce(pm.offered_at, pm.created_at) < now() - interval '2 hours'
             AND NOT EXISTS (SELECT 1 FROM public.tori_held_messages h
                              WHERE h.match_id = pm.id AND h.kind = 'match_offer'
                                AND h.delivered_at IS NULL AND h.expires_at > now()))
            OR EXISTS (SELECT 1 FROM public.partner_requests r
                        WHERE r.id IN (pm.request_a, pm.request_b) AND r.window_end < now()))
    RETURNING pm.*),
  -- whoever said yes goes back into the pool, and so does b when it was never asked (a didn't say
  -- yes: 009 asks b only after a); whoever was asked and did not answer leaves it
  sides AS (
    SELECT request_a AS id, a_response = 'yes' AS keep FROM stale
    UNION ALL
    SELECT request_b, b_response = 'yes' OR a_response IS DISTINCT FROM 'yes' FROM stale),
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

  -- held messages nobody came back for
  DELETE FROM public.tori_held_messages WHERE expires_at < now() - interval '7 days';

  RETURN jsonb_build_object('reopened', to_jsonb(v_reopened));
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
     WHERE p.pronamespace = 'public'::regnamespace
       AND (p.proname LIKE 'tori\_%' OR p.proname = 'expire_partner_requests')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
