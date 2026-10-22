-- Harsh AI voice call log (015): lifecycle from Meta + the bridge, repeated and late events, two callers
-- at once, Vapi end-of-call reports for WhatsApp and web calls.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/voice_calls.sql against a database with 015 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

DO $$
DECLARE r jsonb; c public.voice_calls; n int;
BEGIN
  -- 1. Meta connect → bridge progress → caller hangs up (Meta terminate) → bridge reports the end too
  r := public.voice_log_event('meta', '{"id":"wacid.A","event":"connect","from":"919500000001","name":"Asha",
                                        "session":{"sdp_type":"offer","sdp":"v=0 big"}}');
  PERFORM pg_temp.ok(r ->> 'state' = 'ringing', 'connect webhook opens a ringing call');
  PERFORM pg_temp.ok((SELECT payload #> '{session,sdp}' IS NULL FROM public.voice_call_events ORDER BY id DESC LIMIT 1),
                     'the SDP offer is not stored');
  PERFORM public.voice_log_event('bridge', '{"event":"connecting","meta_call_id":"wacid.A","vapi_call_id":"vapi-A"}');
  r := public.voice_log_event('bridge', '{"event":"active","meta_call_id":"wacid.A"}');
  SELECT * INTO c FROM public.voice_calls WHERE meta_call_id = 'wacid.A';
  PERFORM pg_temp.ok(c.state = 'active' AND c.answered_at IS NOT NULL AND c.vapi_call_id = 'vapi-A'
                     AND c.caller_wa_id = '919500000001' AND c.caller_name = 'Asha', 'accepted call is active and linked to its Vapi call');
  PERFORM public.voice_log_event('meta', '{"id":"wacid.A","event":"terminate","status":"COMPLETED","duration":42}');
  PERFORM public.voice_log_event('bridge', '{"event":"ended","meta_call_id":"wacid.A","reason":"caller_hung_up","duration_s":41}');
  SELECT * INTO c FROM public.voice_calls WHERE meta_call_id = 'wacid.A';
  PERFORM pg_temp.ok(c.state = 'ended' AND c.duration_s = 42 AND c.ended_at IS NOT NULL, 'terminate ends it; Meta''s duration wins');
  PERFORM pg_temp.ok(c.end_reason = 'caller_hung_up', 'the bridge''s reason fills the missing end reason');

  -- 2. a retried connect webhook after the end never reopens the call
  r := public.voice_log_event('meta', '{"id":"wacid.A","event":"connect"}');
  PERFORM pg_temp.ok(r ->> 'state' = 'ended', 'duplicate connect after the end changes nothing');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.voice_calls WHERE meta_call_id = 'wacid.A') = 1, 'still one row');

  -- 3. a second caller at the same time stays separate
  PERFORM public.voice_log_event('meta', '{"id":"wacid.B","event":"connect","from":"919500000002"}');
  PERFORM public.voice_log_event('bridge', '{"event":"active","meta_call_id":"wacid.B","vapi_call_id":"vapi-B"}');
  PERFORM public.voice_log_event('meta', '{"id":"wacid.C","event":"connect","from":"919500000003"}');
  PERFORM public.voice_log_event('bridge', '{"event":"rejected","meta_call_id":"wacid.C","reason":"busy"}');
  PERFORM pg_temp.ok((SELECT state FROM public.voice_calls WHERE meta_call_id = 'wacid.B') = 'active'
                     AND (SELECT state || '/' || end_reason FROM public.voice_calls WHERE meta_call_id = 'wacid.C') = 'rejected/busy',
                     'B is active while C was turned away as busy');
  SELECT count(*) INTO n FROM public.voice_call_events e JOIN public.voice_calls v ON v.id = e.call_id WHERE v.meta_call_id = 'wacid.B';
  PERFORM pg_temp.ok(n = 2, 'B''s events are B''s only');

  -- 4. a failed call keeps Meta's error
  PERFORM public.voice_log_event('meta', '{"id":"wacid.B","event":"terminate","status":"FAILED","errors":[{"code":138021,"message":"media timeout"}]}');
  PERFORM pg_temp.ok((SELECT state || '/' || end_reason FROM public.voice_calls WHERE meta_call_id = 'wacid.B') = 'failed/media timeout',
                     'FAILED terminate records the error');

  -- 5. Vapi's end-of-call report: WhatsApp call matched by metadata, web call created
  r := public.voice_log_report('{"type":"end-of-call-report","endedReason":"customer-ended-call","cost":0.0712,"durationSeconds":40.6,
                                 "analysis":{"summary":"Asked about NoteFlow."},"artifact":{"transcript":"AI: Hi\nUser: NoteFlow?"},
                                 "call":{"id":"vapi-A","type":"vapi.websocketCall","assistantOverrides":{"metadata":{"metaCallId":"wacid.A"}}}}');
  SELECT * INTO c FROM public.voice_calls WHERE meta_call_id = 'wacid.A';
  PERFORM pg_temp.ok(c.summary = 'Asked about NoteFlow.' AND c.transcript LIKE 'AI: Hi%' AND c.cost_usd = 0.0712 AND c.duration_s = 42,
                     'report adds summary, transcript and cost to the WhatsApp call');
  r := public.voice_log_report('{"endedReason":"customer-ended-call","durationSeconds":12,"summary":"Asked about skills.",
                                 "call":{"id":"vapi-WEB","type":"webCall"}}');
  PERFORM pg_temp.ok(r ->> 'channel' = 'web' AND r ->> 'state' = 'ended', 'web call is logged from its report');

  BEGIN
    PERFORM public.voice_log_event('bridge', '{"event":"active"}');
    RAISE EXCEPTION 'FAIL: event without IDs accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL:%' THEN RAISE; END IF;
    RAISE NOTICE 'ok: event without a call ID is refused';
  END;
END $$;
ROLLBACK;
