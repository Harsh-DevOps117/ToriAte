-- Harsh AI voice calls: WhatsApp calls answered by the Vapi assistant through voice-bridge/, and calls
-- from the web page (/voice). Tables only; the rules are in 015_voice_calls.repeatable.sql.
-- One row per call. Audio never comes here: n8n logs the call's lifecycle, Vapi's end-of-call report
-- adds the summary and transcript.

CREATE TABLE IF NOT EXISTS public.voice_calls (
  id            bigserial PRIMARY KEY,
  channel       text NOT NULL CHECK (channel IN ('whatsapp', 'web')),
  meta_call_id  text UNIQUE,                 -- 'wacid.…' (WhatsApp calls only)
  vapi_call_id  text UNIQUE,
  caller_wa_id  text,
  caller_name   text,
  state         text NOT NULL DEFAULT 'ringing'
                CHECK (state IN ('ringing', 'connecting', 'active', 'ended', 'failed', 'rejected')),
  started_at    timestamptz NOT NULL DEFAULT now(),
  answered_at   timestamptz,
  ended_at      timestamptz,
  end_reason    text,                        -- 'caller_hung_up', 'assistant_ended', 'busy', Vapi's endedReason …
  duration_s    integer,
  summary       text,
  transcript    text,
  cost_usd      numeric(10, 4),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (meta_call_id IS NOT NULL OR vapi_call_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS voice_calls_started ON public.voice_calls (started_at DESC);

CREATE TABLE IF NOT EXISTS public.voice_call_events (
  id       bigserial PRIMARY KEY,
  call_id  bigint NOT NULL REFERENCES public.voice_calls (id) ON DELETE CASCADE,
  source   text NOT NULL CHECK (source IN ('meta', 'bridge', 'vapi')),
  event    text NOT NULL,
  payload  jsonb NOT NULL DEFAULT '{}',
  at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS voice_call_events_call ON public.voice_call_events (call_id, at);
