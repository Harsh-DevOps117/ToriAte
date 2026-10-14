-- Messages kept for people outside WhatsApp's 24-hour window (workflow 06).
-- Tables only. The functions are in 008_held_messages.repeatable.sql.
--
-- WhatsApp only lets the bot message someone within 24 hours of their last message (otherwise an
-- approved template is needed). A match offer or update for someone who has been quiet longer is
-- kept here and sent the next time they message the bot ("any match?", "hi", anything). Every
-- "Looking for a partner" reply tells people to check in before they head out.

CREATE TABLE IF NOT EXISTS public.tori_held_messages (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa_id        text NOT NULL,                           -- recipient, digits only
  kind         text NOT NULL CHECK (kind IN ('match_offer', 'match_update')),
  match_id     uuid REFERENCES public.partner_matches (id),
  body         jsonb NOT NULL,                          -- WhatsApp message without messaging_product / to
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,                    -- the game is over: never sent after this
  delivered_at timestamptz
);
CREATE INDEX IF NOT EXISTS tori_held_messages_due ON public.tori_held_messages (wa_id) WHERE delivered_at IS NULL;
-- one offer per person and match
CREATE UNIQUE INDEX IF NOT EXISTS tori_held_messages_one_offer
  ON public.tori_held_messages (wa_id, match_id) WHERE kind = 'match_offer';

-- When the last side was shown the offer. The 2-hour answer clock starts here, so an offer kept
-- for someone offline doesn't run out before they have seen it.
ALTER TABLE public.partner_matches ADD COLUMN IF NOT EXISTS offered_at timestamptz;
UPDATE public.partner_matches SET offered_at = created_at WHERE offered_at IS NULL;

ALTER TABLE public.tori_held_messages ENABLE ROW LEVEL SECURITY;
