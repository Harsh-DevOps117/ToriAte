-- Held messages (people outside WhatsApp's 24-hour window): SQL-level scenario tests. Rolled back.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/held_messages.sql against a database with 004–008 applied.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

-- an open badminton request in HSR Layout, `hours_ahead` from now
CREATE OR REPLACE FUNCTION pg_temp.open_req(wa text, hours_ahead int) RETURNS uuid LANGUAGE sql AS $$
  SELECT (public.save_partner_request(wa, 'P' || right(wa, 2), jsonb_build_object(
    'activity', 'badminton', 'city', 'bangalore', 'area', 'HSR Layout', 'area_key', 'hsrlayout',
    'play_date', ((now() + make_interval(hours => hours_ahead)) AT TIME ZONE 'Asia/Kolkata')::date,
    'time_label', 'around 7 PM',
    'window_start', now() + make_interval(hours => hours_ahead) - interval '30 minutes',
    'window_end', now() + make_interval(hours => hours_ahead) + interval '30 minutes',
    'players_needed', 1, 'raw_text', 'test'), true)).id $$;

DO $$
DECLARE
  ra uuid; rb uuid; m jsonb; mid uuid; r jsonb; n int;
BEGIN
  ra := pg_temp.open_req('919200000001', 3);
  UPDATE public.partner_requests SET last_message_at = now() - interval '30 hours' WHERE id = ra;   -- A went quiet
  rb := pg_temp.open_req('919200000002', 3);
  m := public.match_partner_request(rb);
  mid := (m ->> 'match_id')::uuid;
  PERFORM pg_temp.ok(mid IS NOT NULL, 'B is matched with A');
  PERFORM pg_temp.ok((m #>> '{b,last_message_at}')::timestamptz < now() - interval '24 hours', 'payload shows A is outside the window');

  -- 1. the offer for A is kept, once
  PERFORM public.tori_hold_message('919200000001', 'match_offer', mid, '{"type": "text", "text": {"body": "offer"}}');
  PERFORM public.tori_hold_message('919200000001', 'match_offer', mid, '{"type": "text", "text": {"body": "offer"}}');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.tori_held_messages WHERE wa_id = '919200000001') = 1, 'offer held once');
  PERFORM pg_temp.ok((SELECT expires_at FROM public.tori_held_messages WHERE wa_id = '919200000001')
                     = (SELECT window_end FROM public.partner_requests WHERE id = ra), 'held until the game is over');

  -- 2. B said yes long ago; the proposal must not time out while A hasn't seen it
  PERFORM public.respond_partner_match(mid, '919200000002', true);
  UPDATE public.partner_matches SET created_at = now() - interval '3 hours', offered_at = now() - interval '3 hours' WHERE id = mid;
  PERFORM public.expire_partner_requests();
  PERFORM pg_temp.ok((SELECT status FROM public.partner_matches WHERE id = mid) = 'pending', 'unseen offer does not time out');

  -- 3. A messages the bot: the offer goes out, once
  r := public.tori_log_inbound('919200000001', 'A', 'wamid.H1', 'text', 'hi');
  PERFORM pg_temp.ok((SELECT last_message_at > now() - interval '1 minute' FROM public.partner_requests WHERE id = ra),
                     'any inbound message refreshes the 24-hour window');
  r := public.tori_take_held('919200000001', false);
  PERFORM pg_temp.ok(jsonb_array_length(r) = 1 AND r -> 0 #>> '{text,body}' = 'offer', 'held offer delivered on the next message');
  PERFORM pg_temp.ok((SELECT offered_at > now() - interval '1 minute' FROM public.partner_matches WHERE id = mid), 'answer clock restarts when seen');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919200000001', false)) = 0, 'not delivered twice');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919200000001', true)) = 1, '"any match?" sends an unanswered offer again');

  -- 4. status
  r := public.tori_partner_status('919200000001');
  PERFORM pg_temp.ok(r #>> '{requests,0,waiting_on}' = 'you' AND r #>> '{requests,0,partner}' = 'P02', 'status: A must answer B''s offer');
  r := public.tori_partner_status('919200000002');
  PERFORM pg_temp.ok(r #>> '{requests,0,waiting_on}' = 'them', 'status: B waits for A');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_partner_status('919299999999') -> 'requests') = 0, 'status: nothing for a stranger');

  -- 5. once answered, the offer is never sent again
  PERFORM public.respond_partner_match(mid, '919200000001', true);
  PERFORM pg_temp.ok((SELECT status FROM public.partner_matches WHERE id = mid) = 'confirmed', 'both said yes');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919200000001', true)) = 0, 'answered offers are not re-sent');

  -- 6. updates (e.g. "it's a match") are delivered once, then never again
  PERFORM public.tori_hold_message('919200000002', 'match_update', mid, '{"type": "text", "text": {"body": "match!"}}');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919200000002', true)) = 1, 'update delivered');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919200000002', true)) = 0, 'update not repeated');

  -- 7. a seen offer still times out 2 hours after it was seen
  ra := pg_temp.open_req('919200000003', 4);
  rb := pg_temp.open_req('919200000004', 4);
  mid := (public.match_partner_request(rb) ->> 'match_id')::uuid;
  PERFORM public.tori_hold_message('919200000003', 'match_offer', mid, '{"type": "text", "text": {"body": "offer"}}');
  PERFORM public.tori_take_held('919200000003', false);
  UPDATE public.partner_matches SET created_at = now() - interval '3 hours', offered_at = now() - interval '3 hours' WHERE id = mid;
  PERFORM public.expire_partner_requests();
  PERFORM pg_temp.ok((SELECT status FROM public.partner_matches WHERE id = mid) = 'expired', 'seen offer times out after 2 hours');

  -- 8. nothing is held for a game that is already over
  UPDATE public.partner_requests SET window_start = now() - interval '2 hours', window_end = now() - interval '1 hour'
   WHERE id IN (ra, rb);
  PERFORM public.tori_hold_message('919200000003', 'match_update', mid, '{"type": "text", "text": {"body": "late"}}');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.tori_held_messages WHERE wa_id = '919200000003' AND kind = 'match_update'),
                     'no message kept after the game');

  -- 9. a message without a match (fallback expiry: one day)
  PERFORM public.tori_hold_message('919200000005', 'match_update', NULL, '{"type": "text", "text": {"body": "x"}}');
  PERFORM pg_temp.ok((SELECT expires_at BETWEEN now() + interval '23 hours' AND now() + interval '25 hours'
                        FROM public.tori_held_messages WHERE wa_id = '919200000005'), 'no match: kept for a day');
END $$;
ROLLBACK;
