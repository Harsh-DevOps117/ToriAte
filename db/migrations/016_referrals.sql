-- Referrals: invite a friend to Tori and both get wallet credits (30 credits = ₹30 each by default).
-- Tables only; the rules are in 016_referrals.repeatable.sql.
--
-- Everyone gets a code (TORI-K7P2QX). "invite" in WhatsApp sends it with a wa.me link that opens the bot with
-- the code typed in. When someone new sends it, one journal entry credits both wallets from 'tori:referrals'
-- (what Tori spends on referral bonuses), so the ledger still balances.

CREATE TABLE IF NOT EXISTS public.referral_codes (
  user_id    uuid PRIMARY KEY REFERENCES public.tori_users (id),
  code       text NOT NULL UNIQUE CHECK (code ~ '^[A-HJKMNP-Z2-9]{6}$'),   -- shown as TORI-<code>
  created_at timestamptz NOT NULL DEFAULT now()
);

-- One row per person who joined with a code: a person can be referred once
CREATE TABLE IF NOT EXISTS public.referrals (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id          uuid NOT NULL REFERENCES public.tori_users (id),
  referee_id           uuid NOT NULL UNIQUE REFERENCES public.tori_users (id),
  code                 text NOT NULL,
  referrer_bonus_paise bigint NOT NULL CHECK (referrer_bonus_paise >= 0),
  referee_bonus_paise  bigint NOT NULL CHECK (referee_bonus_paise >= 0),
  journal_id           uuid REFERENCES public.wallet_journal (id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (referrer_id <> referee_id)
);
CREATE INDEX IF NOT EXISTS referrals_referrer ON public.referrals (referrer_id, created_at DESC);

INSERT INTO public.wallet_accounts (account, kind) VALUES ('tori:referrals', 'tori') ON CONFLICT DO NOTHING;
ALTER TABLE public.wallet_journal DROP CONSTRAINT IF EXISTS wallet_journal_kind_check;
ALTER TABLE public.wallet_journal ADD CONSTRAINT wallet_journal_kind_check
  CHECK (kind IN ('topup', 'charge', 'refund', 'adjustment', 'payee_payment', 'payout', 'payout_reversal', 'referral'));

-- "Your friend joined" for a referrer outside WhatsApp's 24-hour window: kept and sent when they next write (008)
ALTER TABLE public.tori_held_messages DROP CONSTRAINT IF EXISTS tori_held_messages_kind_check;
ALTER TABLE public.tori_held_messages ADD CONSTRAINT tori_held_messages_kind_check
  CHECK (kind IN ('match_offer', 'match_update', 'join_request', 'referral'));

ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals      ENABLE ROW LEVEL SECURITY;
