-- Travel matching: SQL-level scenario tests (41 assertions). Runs inside a transaction that is rolled back.
-- Run: scripts/travel-e2e.sh (or: psql -v ON_ERROR_STOP=1 -f db/tests/travel_matching.sql against a database with 005 applied)
BEGIN;
SELECT public.travel_distance_km(25.4374, 81.9067, 25.4300, 81.8850) AS jhunsi_chungi_km,
       public.travel_distance_km(25.4374, 81.9067, 25.4536, 81.8340) AS jhunsi_civil_km,
       public.travel_match_score(2.4, 0.8, 30, public.travel_cfg()) AS score_example;

CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

CREATE OR REPLACE FUNCTION pg_temp.user_(wa text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (public.travel_begin_message(wa, 'User ' || wa, NULL) ->> 'user_id')::uuid $$;

CREATE OR REPLACE FUNCTION pg_temp.trip(src text, slat float8, slng float8, dst text, dlat float8, dlng float8, hhmm text, days int DEFAULT 1)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('source_text', src, 'source_lat', slat, 'source_lng', slng,
    'destination_text', dst, 'destination_lat', dlat, 'destination_lng', dlng,
    'travel_date', (now() AT TIME ZONE 'Asia/Kolkata')::date + days, 'departure_time', hhmm) $$;

DO $$
DECLARE
  cfg jsonb := '{}';
  ua uuid := pg_temp.user_('919000000001'); ub uuid := pg_temp.user_('919000000002');
  uc uuid := pg_temp.user_('919000000003'); ud uuid := pg_temp.user_('919000000004');
  r jsonb; ra jsonb; rb jsonb; m uuid; ia uuid; ib uuid; n jsonb; i int;
BEGIN
  -- dedupe
  r := public.travel_begin_message('919000000001', 'A', 'wamid.1');
  PERFORM pg_temp.ok(NOT (r->>'duplicate')::boolean, 'first delivery is new');
  r := public.travel_begin_message('919000000001', 'A', 'wamid.1');
  PERFORM pg_temp.ok((r->>'duplicate')::boolean, 'redelivery is a duplicate');

  -- A: Jhunsi -> Naini 18:00, no one yet
  ra := public.travel_activate_intent(ua, pg_temp.trip('Jhunsi, Prayagraj', 25.4374, 81.9067, 'Naini, Prayagraj', 25.3870, 81.8640, '18:00'), cfg);
  PERFORM pg_temp.ok(ra->>'outcome' = 'created', 'A created');
  ia := (ra->>'intent_id')::uuid;
  r := public.travel_find_matches(ia, cfg);
  PERFORM pg_temp.ok(NOT (r->>'matchFound')::boolean, 'A alone: no match');

  -- same request again: unchanged
  r := public.travel_activate_intent(ua, pg_temp.trip('jhunsi, prayagraj ', 25.4374, 81.9067, 'Naini, Prayagraj', 25.3870, 81.8640, '18:00'), cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'unchanged', 'same request again is unchanged');

  -- C: Civil Lines (7 km away) -> Naini 18:00: too far
  r := public.travel_activate_intent(uc, pg_temp.trip('Civil Lines, Prayagraj', 25.4536, 81.8340, 'Naini, Prayagraj', 25.3870, 81.8640, '18:00'), cfg);
  r := public.travel_find_matches((r->>'intent_id')::uuid, cfg);
  PERFORM pg_temp.ok(NOT (r->>'matchFound')::boolean, 'C 7 km away: no match');
  -- D: Chungi -> Naini 19:00 (60 min later): too late
  r := public.travel_activate_intent(ud, pg_temp.trip('Chungi, Prayagraj', 25.4300, 81.8850, 'Naini, Prayagraj', 25.3900, 81.8700, '19:20'), cfg);
  r := public.travel_find_matches((r->>'intent_id')::uuid, cfg);
  PERFORM pg_temp.ok(NOT (r->>'matchFound')::boolean, 'D 80 min later: no match');

  -- B later: Chungi -> Naini 18:30 finds A (reverse direction of discovery)
  rb := public.travel_activate_intent(ub, pg_temp.trip('Chungi, Prayagraj', 25.4300, 81.8850, 'Naini Bridge, Prayagraj', 25.3920, 81.8700, '18:30'), cfg);
  ib := (rb->>'intent_id')::uuid;
  r := public.travel_find_matches(ib, cfg);
  PERFORM pg_temp.ok((r->>'matchFound')::boolean, 'B finds A');
  PERFORM pg_temp.ok(r ? 'matchId' AND NOT (r::text ~ 'lat|lng|km|Jhunsi|9190'), 'matcher returns only ids: ' || r::text);
  m := (r->>'matchId')::uuid;
  PERFORM pg_temp.ok((r->'notifications'->0->>'user_id')::uuid = ub AND r->'notifications'->0->>'kind' = 'offer', 'offer goes to B (the requester)');
  PERFORM pg_temp.ok((SELECT count(*) FROM travel_matches) = 1, 'one match (D is 50 min from B, excluded)');

  -- what B may be told: no places, no number
  n := public.travel_notification(ub, m);
  PERFORM pg_temp.ok(n->>'their_time' = '18:00' AND NOT n ? 'their_wa_id' AND n::text !~ 'Jhunsi', 'offer data is coarse: ' || n::text);

  -- A taps someone else's button? (A has not been asked yet)
  r := public.travel_respond(ua, m, 'accept', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'unknown', 'A cannot act before being asked');
  -- stranger
  r := public.travel_respond(uc, m, 'accept', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'unknown', 'stranger cannot act on the match');

  -- B says yes (typed, no match id)
  r := public.travel_respond(ub, NULL, 'accept', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'accepted' AND r->'notifications'->1->>'kind' = 'request_b'
                     AND (r->'notifications'->1->>'user_id')::uuid = ua, 'B accepted, A is asked');
  PERFORM pg_temp.ok((SELECT status FROM travel_matches WHERE id = m) = 'USER_A_ACCEPTED', 'status USER_A_ACCEPTED');
  n := public.travel_notification(ua, m);
  PERFORM pg_temp.ok(NOT n ? 'their_wa_id', 'no contact after one consent');
  r := public.travel_respond(ub, m, 'accept', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'already' AND r->'notifications'->0->>'kind' = 'a_waiting', 'double tap is a no-op');

  -- A says yes: connected
  r := public.travel_respond(ua, m, 'accept', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'connected', 'connected');
  PERFORM pg_temp.ok((SELECT status FROM travel_matches WHERE id = m) = 'CONNECTED'
                     AND (SELECT bool_and(status = 'MATCHED') FROM travel_intents WHERE id IN (ia, ib)), 'both intents MATCHED');
  n := public.travel_notification(ua, m);
  PERFORM pg_temp.ok(n->>'their_wa_id' = '919000000002' AND n->>'their_name' = 'User', 'contact shared after both consents');
  r := public.travel_respond(ua, m, 'accept', NULL, cfg);
  PERFORM pg_temp.ok(r->'notifications'->0->>'kind' = 'already_connected', 'tap after connect');

  -- A blocks B after connecting
  r := public.travel_respond(ua, NULL, 'block', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'blocked' AND (SELECT status FROM travel_matches WHERE id = m) = 'BLOCKED', 'block');
  -- new trips for A and B: never matched again
  ra := public.travel_activate_intent(ua, pg_temp.trip('Jhunsi, Prayagraj', 25.4374, 81.9067, 'Naini, Prayagraj', 25.3870, 81.8640, '18:00', 2), cfg);
  rb := public.travel_activate_intent(ub, pg_temp.trip('Chungi, Prayagraj', 25.4300, 81.8850, 'Naini, Prayagraj', 25.3870, 81.8640, '18:10', 2), cfg);
  r := public.travel_find_matches((rb->>'intent_id')::uuid, cfg);
  PERFORM pg_temp.ok(NOT (r->>'matchFound')::boolean, 'blocked pair not matched again');
END $$;

-- decline, update/invalidation, candidates cap, rate limit, expiry
DO $$
DECLARE
  cfg jsonb := '{"max_changes_per_hour": "5"}';
  u uuid[] := ARRAY(SELECT pg_temp.user_('91800000000' || g) FROM generate_series(1, 6) g);
  r jsonb; m uuid; m2 uuid; i int; it uuid[] := '{}'; mine uuid;
BEGIN
  -- four people waiting near Koramangala -> Whitefield at 09:00 (day +3)
  FOR i IN 1..4 LOOP
    r := public.travel_activate_intent(u[i], pg_temp.trip('Koramangala ' || i, 12.9352 + i * 0.001, 77.6245, 'Whitefield', 12.9698, 77.7500, '09:0' || i, 3), cfg);
    it := it || (r->>'intent_id')::uuid;
  END LOOP;
  -- they all match each other; reset: only test the 5th person's view, so remove their matches
  -- (the first four found each other in order; that's fine)
  r := public.travel_activate_intent(u[5], pg_temp.trip('Koramangala', 12.9352, 77.6245, 'Whitefield', 12.9698, 77.7500, '09:00', 3), cfg);
  mine := (r->>'intent_id')::uuid;
  r := public.travel_find_matches(mine, cfg);
  PERFORM pg_temp.ok((r->>'matchFound')::boolean, 'fifth finds someone');
  PERFORM pg_temp.ok((SELECT count(*) FROM travel_matches WHERE travel_intent_a = mine) = 3, 'capped at 3 candidates');
  PERFORM pg_temp.ok((SELECT count(*) FROM travel_matches WHERE travel_intent_a = mine AND offered_at IS NOT NULL) = 1, 'only one shown');
  m := (r->>'matchId')::uuid;
  PERFORM pg_temp.ok((SELECT travel_intent_b FROM travel_matches WHERE id = m) = it[1], 'best score first (closest, same time)');

  -- decline -> next candidate
  r := public.travel_respond(u[5], m, 'decline', NULL, cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'declined' AND r->'rematch' ? mine::text, 'decline asks for a rematch');
  r := public.travel_find_matches(mine, cfg);
  m2 := (r->>'matchId')::uuid;
  PERFORM pg_temp.ok((r->>'matchFound')::boolean AND m2 <> m, 'next candidate offered');
  PERFORM pg_temp.ok((SELECT count(*) FROM travel_matches WHERE travel_intent_a = mine AND travel_intent_b = it[1]) = 1, 'declined pair not re-created');

  -- the candidate changes their time: the offer to u5 is withdrawn
  i := (SELECT array_position(it, travel_intent_b) FROM travel_matches WHERE id = m2);
  r := public.travel_activate_intent(u[i], pg_temp.trip('Koramangala ' || i, 12.9352 + i * 0.001, 77.6245, 'Whitefield', 12.9698, 77.7500, '11:00', 3), cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'updated', 'candidate updated');
  PERFORM pg_temp.ok((SELECT status || '/' || close_reason FROM travel_matches WHERE id = m2) = 'EXPIRED/intent_updated', 'stale match closed');
  PERFORM pg_temp.ok(r->'notifications' @> jsonb_build_array(jsonb_build_object('user_id', u[5], 'kind', 'match_withdrawn'))
                     AND r->'rematch' ? mine::text, 'requester told + rematched');

  -- u5 cancels
  r := public.travel_cancel_intent(u[5]);
  PERFORM pg_temp.ok(r->>'outcome' = 'cancelled' AND (SELECT status FROM travel_intents WHERE id = mine) = 'CANCELLED', 'cancel');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM travel_matches WHERE travel_intent_a = mine AND status IN ('PENDING','USER_A_ACCEPTED')), 'no live matches after cancel');

  -- rate limit: u6 changes the request repeatedly
  FOR i IN 1..6 LOOP
    r := public.travel_activate_intent(u[6], pg_temp.trip('Place ' || i, 12.0 + i * 0.1, 77.0, 'Somewhere', 13.0, 78.0, '10:00', 4), cfg);
  END LOOP;
  PERFORM pg_temp.ok(r->>'outcome' = 'rate_limited', '6th change in an hour is rate limited');

  -- past time
  r := public.travel_activate_intent(u[6], pg_temp.trip('X', 12, 77, 'Y', 13, 78, '10:00', -1), cfg);
  PERFORM pg_temp.ok(r->>'outcome' = 'in_past', 'past trip refused');

  -- expiry: move u1's trip into the past and sweep
  UPDATE travel_intents SET departure_at = now() - interval '2 hours', expires_at = now() - interval '1 hour' WHERE id = it[1];
  UPDATE travel_matches SET expires_at = now() - interval '1 minute' WHERE status IN ('PENDING', 'USER_A_ACCEPTED') AND it[1] IN (travel_intent_a, travel_intent_b);
  r := public.travel_sweep(cfg);
  PERFORM pg_temp.ok((SELECT status FROM travel_intents WHERE id = it[1]) = 'EXPIRED', 'sweep expires past trips');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM travel_matches WHERE it[1] IN (travel_intent_a, travel_intent_b) AND status IN ('PENDING','USER_A_ACCEPTED')), 'and their matches');
  r := public.travel_find_matches(it[1], cfg);
  PERFORM pg_temp.ok(NOT (r->>'matchFound')::boolean, 'expired intent is never matched');
END $$;

ROLLBACK;
