-- Bot outbox log and call echo (tables: 018_bot_outbox_log.sql). Called by the web app only.
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).

-- A message the bot sent (web /api/graph, after Meta accepted it). The same message logged earlier by workflow 06
-- ("Log profile reply") gets its payload filled in.
CREATE OR REPLACE FUNCTION public.tori_log_bot_message(p_wa_id text, p_message_id text, p_type text, p_body text, p_payload jsonb)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.tori_messages (user_id, wa_message_id, direction, type, body, payload)
  VALUES ((public.tori_user(p_wa_id)).id, nullif(p_message_id, ''), 'out', nullif(p_type, ''), left(p_body, 4000), p_payload)
  ON CONFLICT (wa_message_id) DO UPDATE SET payload = EXCLUDED.payload, type = EXCLUDED.type;
$$;

-- The voice agent is about to hand the bot what the caller said
CREATE OR REPLACE FUNCTION public.tori_agent_said(p_wa_id text, p_said text)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.agent_echo (wa_id, said) VALUES (p_wa_id, left(p_said, 200))
  ON CONFLICT (wa_id) DO UPDATE SET said = EXCLUDED.said, at = now();
$$;

-- The bot is sending this person a message: what they said on the call (once, within a minute), else NULL
CREATE OR REPLACE FUNCTION public.tori_take_echo(p_wa_id text)
RETURNS text
LANGUAGE sql AS $$
  DELETE FROM public.agent_echo WHERE wa_id = p_wa_id RETURNING CASE WHEN at > now() - interval '1 minute' THEN said END;
$$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for the web app only.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('tori_log_bot_message', 'tori_agent_said', 'tori_take_echo')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
