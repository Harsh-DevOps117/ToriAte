-- "Please confirm your name": before someone is matched (partner, cab buddy, like-minded people) the bot asks
-- whether the name from their WhatsApp profile is the one other users should see. Yes → confirmed; No → they
-- type it. Many WhatsApp profile names are not real names ("🔥Rocky🔥", "Busy", a shop name).
-- Tables only; the rules are in 017_name_confirm.repeatable.sql. A confirmed name is tori_users.name with
-- name_source = 'user' (009).

ALTER TABLE public.tori_conversation_state
  ADD COLUMN IF NOT EXISTS name_step     text CHECK (name_step IN ('confirm', 'type')),  -- waiting for Yes / No, or for the typed name
  ADD COLUMN IF NOT EXISTS name_resume   jsonb,         -- what to do once the name is confirmed: replay the message, or go on onboarding
  ADD COLUMN IF NOT EXISTS name_asked_at timestamptz;   -- the question is forgotten after a day
