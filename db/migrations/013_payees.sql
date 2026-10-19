-- ToriPay: pay a verified business (gym, turf, coach…) from the Tori Wallet over WhatsApp.
-- Tables only; the rules are in 013_payees.repeatable.sql.
--
-- Businesses (payees) are added by the Tori team with the bank details Tori already has; only an admin can
-- change where a payee is paid. People save shortcuts ("gym" → FitZone HSR) and say "tori pay gym 500".
-- The money leaves Tori through RazorpayX Payouts to the payee's verified fund account, or, until
-- RazorpayX is enabled, stays owed in the ledger ('payee:<id>') for the team to settle.

CREATE TABLE IF NOT EXISTS public.payees (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  handle           text NOT NULL UNIQUE CHECK (handle ~ '^[a-z0-9][a-z0-9-]{1,40}$'),   -- 'fitzone-hsr'
  display_name     text NOT NULL,                     -- 'FitZone Gym'
  category         text NOT NULL CHECK (category IN ('gym', 'turf', 'court', 'coach', 'physio', 'other')),
  city             text,
  area             text,
  aliases          text[] NOT NULL DEFAULT '{}',      -- extra words people use: {fitzone, fit zone}
  owner_wa         text,                              -- the owner's WhatsApp (digits): told about payments
  -- where the money goes. The full account number is sent once to RazorpayX and never stored.
  account_holder   text NOT NULL,
  account_last4    text NOT NULL CHECK (account_last4 ~ '^\d{4}$'),
  ifsc             text NOT NULL CHECK (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  bank_verified_name text,                            -- the name the bank returned (penny drop), if checked
  rzp_contact_id   text,
  rzp_fund_account_id text,
  commission_bps   int NOT NULL DEFAULT 0 CHECK (commission_bps BETWEEN 0 AND 3000),   -- 100 = 1 % kept by Tori
  status           text NOT NULL DEFAULT 'verified' CHECK (status IN ('verified', 'suspended')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       text NOT NULL
);

-- A person's shortcuts: "gym" → FitZone HSR. Several per person; "gym edit" points it elsewhere.
CREATE TABLE IF NOT EXISTS public.user_payees (
  user_id    uuid NOT NULL REFERENCES public.tori_users (id),
  nickname   text NOT NULL CHECK (nickname ~ '^[a-z0-9][a-z0-9 _-]{0,29}$'),
  payee_id   uuid NOT NULL REFERENCES public.payees (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, nickname)
);

-- One "tori pay" payment
CREATE TABLE IF NOT EXISTS public.payee_payments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES public.tori_users (id),
  payee_id         uuid NOT NULL REFERENCES public.payees (id),
  nickname         text,                               -- the shortcut used ("gym"), to save it on success
  amount_paise     bigint NOT NULL CHECK (amount_paise > 0),
  commission_paise bigint NOT NULL DEFAULT 0 CHECK (commission_paise >= 0),
  status           text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'cancelled', 'expired', 'paid', 'processing', 'settled', 'failed')),
  -- paid = taken from the wallet, owed to the payee; processing = payout sent; settled = in the payee's bank
  rzp_payout_id    text UNIQUE,
  failure_reason   text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,
  paid_at          timestamptz,
  settled_at       timestamptz
);
CREATE INDEX IF NOT EXISTS payee_payments_user ON public.payee_payments (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS payee_payments_owed ON public.payee_payments (payee_id) WHERE status IN ('paid', 'processing');

-- the ledger (012) gains 'payee' accounts and the payment kinds
ALTER TABLE public.wallet_accounts DROP CONSTRAINT IF EXISTS wallet_accounts_kind_check;
ALTER TABLE public.wallet_accounts ADD CONSTRAINT wallet_accounts_kind_check CHECK (kind IN ('user', 'tori', 'payee'));
ALTER TABLE public.wallet_journal DROP CONSTRAINT IF EXISTS wallet_journal_kind_check;
ALTER TABLE public.wallet_journal ADD CONSTRAINT wallet_journal_kind_check
  CHECK (kind IN ('topup', 'charge', 'refund', 'adjustment', 'payee_payment', 'payout', 'payout_reversal'));
INSERT INTO public.wallet_accounts (account, kind) VALUES ('tori:revenue', 'tori'), ('tori:payouts', 'tori')
ON CONFLICT DO NOTHING;

ALTER TABLE public.payees         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_payees    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payee_payments ENABLE ROW LEVEL SECURITY;
