-- One conversation across WhatsApp chat and calls with the voice agent.
-- Every message the bot sends now passes through the web app on its way to Meta (web /api/graph): it is logged
-- here with its buttons, so the voice agent can say the bot's replies on the call (web /api/mcp, message_tori)
-- and the chat history is complete. Tables only; the rules are in 018_bot_outbox_log.repeatable.sql.

-- the message as sent (without "to"): text, buttons and list rows, so the agent can offer the same choices
ALTER TABLE public.tori_messages ADD COLUMN IF NOT EXISTS payload jsonb;

-- What the caller just said on a call, until the bot's next message to them is sent: that message starts with
-- it in the chat (📞 On your call: "…"), so the chat reads as one conversation.
CREATE TABLE IF NOT EXISTS public.agent_echo (
  wa_id text PRIMARY KEY,
  said  text NOT NULL,
  at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_echo ENABLE ROW LEVEL SECURITY;
