-- Tori Wallet: prepaid credits (1 credit = ₹1), added with Razorpay, spent with one tap.
-- Tables only; the rules are in 012_wallet.repeatable.sql.
--
-- Balances are never stored: every change is a journal entry whose postings sum to 0, and a balance is
-- the sum of an account's postings. Accounts: 'user:<tori_users.id>' (a person's credits),
-- 'tori:razorpay' (money received through Razorpay), 'tori:sales' (credits spent on bookings).

CREATE TABLE IF NOT EXISTS public.wallet_accounts (
  account    text PRIMARY KEY,
  user_id    uuid UNIQUE REFERENCES public.tori_users (id),
  kind       text NOT NULL CHECK (kind IN ('user', 'tori')),
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.wallet_accounts (account, kind) VALUES ('tori:razorpay', 'tori'), ('tori:sales', 'tori')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.wallet_journal (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            text NOT NULL CHECK (kind IN ('topup', 'charge', 'refund', 'adjustment')),
  ref             text,                      -- Razorpay payment id, charge id …
  idempotency_key text NOT NULL UNIQUE,      -- 'topup:pay_X', 'charge:<id>': the same event posts once
  memo            text,
  created_by      text NOT NULL,             -- 'razorpay-webhook', 'web', 'bot', 'admin:<name>'
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wallet_postings (
  id           bigserial PRIMARY KEY,
  journal_id   uuid NOT NULL REFERENCES public.wallet_journal (id),
  account      text NOT NULL REFERENCES public.wallet_accounts (account),
  amount_paise bigint NOT NULL CHECK (amount_paise <> 0)   -- + into the account, − out of it
);
CREATE INDEX IF NOT EXISTS wallet_postings_account ON public.wallet_postings (account);
CREATE INDEX IF NOT EXISTS wallet_postings_journal ON public.wallet_postings (journal_id);

-- One "add credits" payment
CREATE TABLE IF NOT EXISTS public.wallet_topups (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES public.tori_users (id),
  amount_paise   bigint NOT NULL CHECK (amount_paise > 0),
  rzp_order_id   text UNIQUE,
  rzp_payment_id text UNIQUE,
  status         text NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'paid', 'failed')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  paid_at        timestamptz
);
CREATE INDEX IF NOT EXISTS wallet_topups_user ON public.wallet_topups (user_id, created_at DESC);

-- One-tap checkout: a booking asks the person to pay from their wallet
CREATE TABLE IF NOT EXISTS public.wallet_charges (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES public.tori_users (id),
  amount_paise bigint NOT NULL CHECK (amount_paise > 0),
  description  text NOT NULL,              -- "Court 2, Smash Arena · Sat 7 PM"
  ref          text,                       -- the booking's id in the system that asked
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'cancelled', 'expired', 'refunded')),
  created_by   text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  paid_at      timestamptz,
  UNIQUE (created_by, ref)                 -- the same booking can't be charged twice
);
CREATE INDEX IF NOT EXISTS wallet_charges_user ON public.wallet_charges (user_id, created_at DESC);

-- One-time links from WhatsApp ("add credits") and the web sessions they open. Only hashes are stored.
CREATE TABLE IF NOT EXISTS public.wallet_links (
  token_hash text PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES public.tori_users (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at    timestamptz
);
CREATE TABLE IF NOT EXISTS public.wallet_sessions (
  token_hash   text PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES public.tori_users (id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

-- Every Razorpay webhook, stored before it is processed (a replay is ignored)
CREATE TABLE IF NOT EXISTS public.razorpay_events (
  event_id     text PRIMARY KEY,           -- x-razorpay-event-id
  event        text NOT NULL,
  payload      jsonb NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  result       jsonb
);

ALTER TABLE public.wallet_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_journal  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_topups   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_charges  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_links    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.razorpay_events ENABLE ROW LEVEL SECURITY;
