-- Joining a specific game from the partner board (web/). Tables only; functions in 011_joins.repeatable.sql.
--
-- Every live request gets a short join code. The board's Join button opens WhatsApp with "JOIN <code>"
-- typed out, so the joiner's number is proven by WhatsApp itself (no website login). The request's
-- creator (the host) gets the joiner's card with Accept / Decline; every joiner goes to the host. The host
-- decides how many people can join (partner_requests.players_needed, "spots"); the board shows who joined.

ALTER TABLE public.partner_requests ADD COLUMN IF NOT EXISTS join_code text UNIQUE;

CREATE TABLE IF NOT EXISTS public.partner_joins (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id  uuid NOT NULL REFERENCES public.partner_requests (id),
  joiner_wa   text NOT NULL,                       -- WhatsApp number, digits only
  status      text NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'full', 'expired')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  decided_at  timestamptz,
  UNIQUE (request_id, joiner_wa)                   -- one join per person and game
);
CREATE INDEX IF NOT EXISTS partner_joins_pending ON public.partner_joins (request_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS partner_joins_joiner ON public.partner_joins (joiner_wa, status);

-- held messages (008) can also be a join request for a host outside the 24-hour window
ALTER TABLE public.tori_held_messages ADD COLUMN IF NOT EXISTS join_id uuid REFERENCES public.partner_joins (id);
ALTER TABLE public.tori_held_messages DROP CONSTRAINT IF EXISTS tori_held_messages_kind_check;
ALTER TABLE public.tori_held_messages ADD CONSTRAINT tori_held_messages_kind_check
  CHECK (kind IN ('match_offer', 'match_update', 'join_request'));

ALTER TABLE public.partner_joins ENABLE ROW LEVEL SECURITY;
