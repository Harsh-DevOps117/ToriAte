-- Harsh AI voice call log (tables: 015_voice_calls.sql). Called by workflow 13 only.
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).
--
-- States only move forward: ringing → connecting → active → ended | failed | rejected. A late or repeated
-- event (Meta retries webhooks; the bridge and Meta both report the end) fills in missing details but
-- never reopens a finished call.

CREATE OR REPLACE FUNCTION public.voice_state_rank(s text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s WHEN 'ringing' THEN 1 WHEN 'connecting' THEN 2 WHEN 'active' THEN 3
                WHEN 'ended' THEN 4 WHEN 'failed' THEN 4 WHEN 'rejected' THEN 4 END;  -- NULL: not a state
$$;

-- The call with this Meta or Vapi call ID, created when it is new. Both IDs are matched, so an event that
-- knows only one of them (Meta: the wacid, Vapi: its own ID) finds the call the bridge linked to both.
CREATE OR REPLACE FUNCTION public.voice_call_for(p_channel text, p_meta text, p_vapi text)
RETURNS public.voice_calls LANGUAGE plpgsql AS $$
DECLARE c public.voice_calls;
BEGIN
  IF nullif(p_meta, '') IS NULL AND nullif(p_vapi, '') IS NULL THEN
    RAISE EXCEPTION 'voice call event without a call ID';
  END IF;
  SELECT * INTO c FROM public.voice_calls
   WHERE (nullif(p_meta, '') IS NOT NULL AND meta_call_id = p_meta)
      OR (nullif(p_vapi, '') IS NOT NULL AND vapi_call_id = p_vapi)
   ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.voice_calls (channel, meta_call_id, vapi_call_id)
    VALUES (p_channel, nullif(p_meta, ''), nullif(p_vapi, ''))
    ON CONFLICT DO NOTHING
    RETURNING * INTO c;
    IF NOT FOUND THEN  -- a concurrent event created it first
      SELECT * INTO c FROM public.voice_calls
       WHERE meta_call_id = nullif(p_meta, '') OR vapi_call_id = nullif(p_vapi, '') ORDER BY id LIMIT 1 FOR UPDATE;
    END IF;
  END IF;
  RETURN c;
END $$;

-- One lifecycle event from Meta (the calls webhook, one element of value.calls[] plus value.contacts[0])
-- or from the bridge ({event, meta_call_id, vapi_call_id, wa_id, name, reason, duration_s}).
--   Meta events:   connect, terminate (status COMPLETED | FAILED, duration)
--   Bridge events: ringing, connecting, active, ended, failed, rejected
CREATE OR REPLACE FUNCTION public.voice_log_event(p_source text, ev jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  c public.voice_calls;
  e text := ev ->> 'event';
  meta_id text := coalesce(ev ->> 'meta_call_id', CASE WHEN p_source = 'meta' THEN ev ->> 'id' END);
  new_state text;
BEGIN
  c := public.voice_call_for('whatsapp', meta_id, ev ->> 'vapi_call_id');
  new_state := CASE
    WHEN p_source = 'meta' AND e = 'connect' THEN 'ringing'
    WHEN p_source = 'meta' AND e = 'terminate' THEN CASE WHEN upper(ev ->> 'status') = 'FAILED' THEN 'failed' ELSE 'ended' END
    WHEN p_source = 'bridge' AND e IN ('ringing', 'connecting', 'active', 'ended', 'failed', 'rejected') THEN e
  END;

  UPDATE public.voice_calls SET
    vapi_call_id = coalesce(vapi_call_id, nullif(ev ->> 'vapi_call_id', '')),
    caller_wa_id = coalesce(caller_wa_id, nullif(ev ->> 'wa_id', ''), nullif(ev ->> 'from', '')),
    caller_name  = coalesce(caller_name, nullif(ev ->> 'name', '')),
    state        = CASE WHEN new_state IS NOT NULL AND public.voice_state_rank(new_state) > public.voice_state_rank(state)
                        THEN new_state ELSE state END,
    answered_at  = CASE WHEN new_state = 'active' THEN coalesce(answered_at, now()) ELSE answered_at END,
    ended_at     = CASE WHEN public.voice_state_rank(new_state) = 4 THEN coalesce(ended_at, now()) ELSE ended_at END,
    end_reason   = CASE WHEN public.voice_state_rank(new_state) = 4
                        THEN coalesce(end_reason, nullif(ev ->> 'reason', ''), ev #>> '{errors,0,message}') ELSE end_reason END,
    duration_s   = coalesce(duration_s, nullif(ev ->> 'duration_s', '')::int, nullif(ev ->> 'duration', '')::int),
    updated_at   = now()
  WHERE id = c.id
  RETURNING * INTO c;

  -- the SDP offer is large and only useful to the bridge
  INSERT INTO public.voice_call_events (call_id, source, event, payload)
  VALUES (c.id, p_source, coalesce(e, 'unknown'), ev #- '{session,sdp}');

  RETURN jsonb_build_object('call_id', c.id, 'state', c.state);
END $$;

-- Vapi's end-of-call report (the `message` object Vapi posts to the server URL). Web calls appear here
-- for the first time; WhatsApp calls are matched through the Meta call ID the bridge put in the metadata.
CREATE OR REPLACE FUNCTION public.voice_log_report(m jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  c public.voice_calls;
  vapi_id text := m #>> '{call,id}';
  meta_id text := coalesce(m #>> '{call,assistantOverrides,metadata,metaCallId}', m #>> '{call,metadata,metaCallId}');
  channel text := CASE WHEN meta_id IS NOT NULL OR m #>> '{call,type}' = 'vapi.websocketCall' THEN 'whatsapp' ELSE 'web' END;
BEGIN
  c := public.voice_call_for(channel, meta_id, vapi_id);
  UPDATE public.voice_calls SET
    vapi_call_id = coalesce(vapi_call_id, vapi_id),
    state        = CASE WHEN public.voice_state_rank(state) < 4 THEN 'ended' ELSE state END,
    answered_at  = coalesce(answered_at, (m ->> 'startedAt')::timestamptz),
    ended_at     = coalesce(ended_at, (m ->> 'endedAt')::timestamptz, now()),
    end_reason   = coalesce(end_reason, m ->> 'endedReason'),
    duration_s   = coalesce(duration_s, round((m ->> 'durationSeconds')::numeric)::int),
    summary      = coalesce(m #>> '{analysis,summary}', m ->> 'summary', summary),
    transcript   = coalesce(m #>> '{artifact,transcript}', m ->> 'transcript', transcript),
    cost_usd     = coalesce((m ->> 'cost')::numeric, cost_usd),
    updated_at   = now()
  WHERE id = c.id
  RETURNING * INTO c;

  INSERT INTO public.voice_call_events (call_id, source, event, payload)
  VALUES (c.id, 'vapi', 'end-of-call-report',
          jsonb_build_object('endedReason', m ->> 'endedReason', 'cost', m -> 'cost', 'durationSeconds', m -> 'durationSeconds'));

  RETURN jsonb_build_object('call_id', c.id, 'state', c.state, 'channel', c.channel);
END $$;

-- Calls, newest first
CREATE OR REPLACE VIEW public.v_voice_calls AS
SELECT id, channel, state, caller_name, caller_wa_id, started_at, answered_at, ended_at, duration_s, end_reason,
       left(summary, 200) AS summary, meta_call_id, vapi_call_id
  FROM public.voice_calls
 ORDER BY started_at DESC;
