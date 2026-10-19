-- ToriPay, part 2: people add their own gym, turf or coach on WhatsApp ("tori pay gym 500" when Tori
-- doesn't know it yet). The bot asks name → IFSC → account holder → account number (twice). The account
-- number goes from the bot to the web app and straight on to RazorpayX; Tori keeps the last 4 digits only.
-- A payee someone adds is private to them: never in search, payable only through their own shortcut.

ALTER TABLE public.payees ADD COLUMN IF NOT EXISTS added_by uuid REFERENCES public.tori_users (id);  -- NULL = added by the Tori team
ALTER TABLE public.payees ADD COLUMN IF NOT EXISTS bank_name text;     -- 'HDFC Bank' (IFSC lookup)
ALTER TABLE public.payees ADD COLUMN IF NOT EXISTS branch text;
CREATE INDEX IF NOT EXISTS payees_added_by ON public.payees (added_by) WHERE added_by IS NOT NULL;

-- One "add a payee" conversation per person, while it is going on
CREATE TABLE IF NOT EXISTS public.toripay_drafts (
  user_id       uuid PRIMARY KEY REFERENCES public.tori_users (id),
  step          text NOT NULL CHECK (step IN ('name', 'ifsc', 'holder', 'account', 'account_confirm')),
  nickname      text NOT NULL,                        -- the shortcut it will be saved as ("gym")
  payee_id      uuid REFERENCES public.payees (id),    -- set: changing the bank details of this payee
  amount_paise  bigint,                               -- set: pay this much once it is saved
  handle        text,
  display_name  text,
  ifsc          text,
  bank_name     text,
  branch        text,
  holder        text,
  account_hash  text,                                 -- sha256 of the first entry, to check the second; never the number
  account_last4 text,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL
);
ALTER TABLE public.toripay_drafts ENABLE ROW LEVEL SECURITY;
