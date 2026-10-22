-- Tori Wallet rules (tables: 012_wallet.sql). One transaction per call; n8n and the web app only call
-- these functions. Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).
--
-- Amounts are integer paise. Limits come from wallet_cfg(): defaults here, overridden by tori_settings
-- rows named wallet_* (e.g. INSERT INTO tori_settings VALUES ('wallet_max_balance_paise', '2000000')).

CREATE OR REPLACE FUNCTION public.wallet_cfg()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
           'wallet_min_topup_paise', 10000,       -- ₹100
           'wallet_max_topup_paise', 1000000,     -- ₹10,000
           'wallet_max_balance_paise', 1000000,   -- ₹10,000
           'wallet_charge_minutes', 30,           -- a one-tap payment request is valid this long
           'wallet_link_minutes', 15,             -- the WhatsApp "add credits" link
           'wallet_session_days', 30,
           'wallet_referral_bonus_paise', 3000,   -- 30 credits each, for the friend and for who invited them (016)
           'wallet_referral_days', 7,             -- a code works within this many days of first messaging Tori
           'wallet_referral_max', 50)             -- friends one person can earn a bonus for
         || coalesce((SELECT jsonb_object_agg(key, value) FROM public.tori_settings WHERE key LIKE 'wallet\_%'), '{}');
$$;

-- a random secret, and the hash we store instead of it
CREATE OR REPLACE FUNCTION public.wallet_new_token()
RETURNS text
LANGUAGE sql VOLATILE AS $$
  SELECT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;
CREATE OR REPLACE FUNCTION public.wallet_hash(p_token text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex');
$$;

-- the person's wallet account ('user:<id>'), created on first use
CREATE OR REPLACE FUNCTION public.wallet_user_account(p_user_id uuid)
RETURNS text
LANGUAGE sql AS $$
  INSERT INTO public.wallet_accounts (account, user_id, kind) VALUES ('user:' || p_user_id, p_user_id, 'user')
  ON CONFLICT (account) DO NOTHING;
  SELECT 'user:' || p_user_id;
$$;

CREATE OR REPLACE FUNCTION public.wallet_balance(p_user_id uuid)
RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(amount_paise), 0)::bigint FROM public.wallet_postings WHERE account = 'user:' || p_user_id;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- wallet_post: the only way money moves. p_legs = [{ "account": …, "amount": paise }, …] summing to 0.
-- Idempotent on p_key. Accounts are locked in a fixed order (no deadlocks); a person's credits can never
-- go below zero. Returns the journal id.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.wallet_post(p_kind text, p_ref text, p_key text, p_memo text, p_by text, p_legs jsonb)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  j     uuid;
  total numeric;
BEGIN
  SELECT id INTO j FROM public.wallet_journal WHERE idempotency_key = p_key;
  IF FOUND THEN
    RETURN j;
  END IF;
  -- only people's wallets are locked (they must not go negative); Tori's own accounts are not, so
  -- payments by different people never wait for each other
  PERFORM 1 FROM public.wallet_accounts
   WHERE kind = 'user' AND account IN (SELECT l ->> 'account' FROM jsonb_array_elements(p_legs) l)
   ORDER BY account FOR UPDATE;
  SELECT sum((l ->> 'amount')::bigint) INTO total FROM jsonb_array_elements(p_legs) l;
  IF total IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'wallet: journal % does not balance (%)', p_key, total;
  END IF;

  INSERT INTO public.wallet_journal (kind, ref, idempotency_key, memo, created_by)
  VALUES (p_kind, p_ref, p_key, p_memo, p_by)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO j;
  IF j IS NULL THEN                       -- posted by a concurrent call that held the locks first
    SELECT id INTO j FROM public.wallet_journal WHERE idempotency_key = p_key;
    RETURN j;
  END IF;
  INSERT INTO public.wallet_postings (journal_id, account, amount_paise)
  SELECT j, l ->> 'account', (l ->> 'amount')::bigint FROM jsonb_array_elements(p_legs) l
   WHERE (l ->> 'amount')::bigint <> 0;

  IF EXISTS (SELECT 1 FROM public.wallet_accounts a
              WHERE a.kind = 'user' AND a.account IN (SELECT l ->> 'account' FROM jsonb_array_elements(p_legs) l)
                AND (SELECT coalesce(sum(amount_paise), 0) FROM public.wallet_postings p WHERE p.account = a.account) < 0) THEN
    RAISE EXCEPTION 'wallet: % would make a balance negative', p_key;
  END IF;
  RETURN j;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Login from WhatsApp: "add credits" → a one-time link (15 min) → a web session (30 days)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.wallet_issue_link(p_wa_id text, p_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u     public.tori_users;
  token text := public.wallet_new_token();
BEGIN
  u := public.tori_user(p_wa_id, p_name);
  PERFORM public.wallet_user_account(u.id);
  INSERT INTO public.wallet_links (token_hash, user_id, expires_at)
  VALUES (public.wallet_hash(token), u.id, now() + make_interval(mins => (public.wallet_cfg() ->> 'wallet_link_minutes')::int));
  RETURN jsonb_build_object('token', token, 'balance_paise', public.wallet_balance(u.id),
                            'name', nullif(split_part(trim(coalesce(u.name, '')), ' ', 1), ''));
END $$;

-- a valid, unused link → a session token (the link can't be used again). NULL otherwise.
CREATE OR REPLACE FUNCTION public.wallet_open_session(p_link_token text)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  l       public.wallet_links;
  session text := public.wallet_new_token();
BEGIN
  UPDATE public.wallet_links SET used_at = now()
   WHERE token_hash = public.wallet_hash(p_link_token) AND used_at IS NULL AND expires_at > now()
  RETURNING * INTO l;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.wallet_sessions (token_hash, user_id, expires_at)
  VALUES (public.wallet_hash(session), l.user_id, now() + make_interval(days => (public.wallet_cfg() ->> 'wallet_session_days')::int));
  RETURN session;
END $$;

-- who a session belongs to (name, masked number, balance). NULL when unknown or expired.
CREATE OR REPLACE FUNCTION public.wallet_session_user(p_session text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  s public.wallet_sessions;
  u public.tori_users;
BEGIN
  UPDATE public.wallet_sessions SET last_seen_at = now()
   WHERE token_hash = public.wallet_hash(p_session) AND expires_at > now()
  RETURNING * INTO s;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT * INTO u FROM public.tori_users WHERE id = s.user_id;
  RETURN jsonb_build_object('user_id', u.id,
                            'name', nullif(split_part(trim(coalesce(u.name, '')), ' ', 1), ''),
                            'phone', regexp_replace(u.phone, '^(\+\d{2})\d+(\d{4})$', '\1 ••••• \2'),
                            'contact', u.phone,          -- prefills Razorpay Checkout; only sent to this person's browser
                            'balance_paise', public.wallet_balance(u.id));
END $$;

CREATE OR REPLACE FUNCTION public.wallet_end_session(p_session text)
RETURNS void
LANGUAGE sql AS $$
  DELETE FROM public.wallet_sessions WHERE token_hash = public.wallet_hash(p_session);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Adding credits (Razorpay Orders + Checkout)
-- ─────────────────────────────────────────────────────────────────────────────
-- state: ok (topup_id) | too_small | too_big | over_limit (balance would pass the cap)
CREATE OR REPLACE FUNCTION public.wallet_create_topup(p_user_id uuid, p_amount_paise bigint)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg jsonb := public.wallet_cfg();
  t   public.wallet_topups;
BEGIN
  IF p_amount_paise IS NULL OR p_amount_paise < (cfg ->> 'wallet_min_topup_paise')::bigint THEN
    RETURN jsonb_build_object('state', 'too_small', 'min_paise', (cfg ->> 'wallet_min_topup_paise')::bigint);
  ELSIF p_amount_paise > (cfg ->> 'wallet_max_topup_paise')::bigint THEN
    RETURN jsonb_build_object('state', 'too_big', 'max_paise', (cfg ->> 'wallet_max_topup_paise')::bigint);
  ELSIF public.wallet_balance(p_user_id) + p_amount_paise > (cfg ->> 'wallet_max_balance_paise')::bigint THEN
    RETURN jsonb_build_object('state', 'over_limit', 'max_balance_paise', (cfg ->> 'wallet_max_balance_paise')::bigint,
                              'balance_paise', public.wallet_balance(p_user_id));
  END IF;
  PERFORM public.wallet_user_account(p_user_id);
  INSERT INTO public.wallet_topups (user_id, amount_paise) VALUES (p_user_id, p_amount_paise) RETURNING * INTO t;
  RETURN jsonb_build_object('state', 'ok', 'topup_id', t.id, 'amount_paise', t.amount_paise);
END $$;

CREATE OR REPLACE FUNCTION public.wallet_attach_order(p_topup_id uuid, p_order_id text)
RETURNS void
LANGUAGE sql AS $$
  UPDATE public.wallet_topups SET rzp_order_id = p_order_id WHERE id = p_topup_id AND rzp_order_id IS NULL;
$$;

-- A captured payment for an order (browser callback after the signature check, or the webhook).
-- Idempotent. The amount must equal what the order was created for.
-- state: credited | already | mismatch | unknown
CREATE OR REPLACE FUNCTION public.wallet_credit_topup(p_order_id text, p_payment_id text, p_amount_paise bigint, p_by text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  t public.wallet_topups;
BEGIN
  SELECT * INTO t FROM public.wallet_topups WHERE rzp_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  IF t.status = 'paid' THEN
    RETURN jsonb_build_object('state', 'already', 'user_id', t.user_id, 'amount_paise', t.amount_paise,
                              'balance_paise', public.wallet_balance(t.user_id));
  END IF;
  IF p_amount_paise IS DISTINCT FROM t.amount_paise THEN
    RETURN jsonb_build_object('state', 'mismatch', 'expected_paise', t.amount_paise, 'got_paise', p_amount_paise);
  END IF;
  UPDATE public.wallet_topups SET status = 'paid', rzp_payment_id = p_payment_id, paid_at = now() WHERE id = t.id;
  PERFORM public.wallet_post('topup', p_payment_id, 'topup:' || p_payment_id, 'Added credits', p_by,
    jsonb_build_array(jsonb_build_object('account', 'tori:razorpay', 'amount', -t.amount_paise),
                      jsonb_build_object('account', public.wallet_user_account(t.user_id), 'amount', t.amount_paise)));
  RETURN jsonb_build_object('state', 'credited', 'user_id', t.user_id, 'amount_paise', t.amount_paise,
                            'balance_paise', public.wallet_balance(t.user_id),
                            'wa_id', (SELECT ltrim(phone, '+') FROM public.tori_users WHERE id = t.user_id));
END $$;

CREATE OR REPLACE FUNCTION public.wallet_fail_topup(p_order_id text)
RETURNS void
LANGUAGE sql AS $$
  UPDATE public.wallet_topups SET status = 'failed' WHERE rzp_order_id = p_order_id AND status = 'created';
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- One-tap checkout: a booking asks; the person taps Pay; credits move. No payment gateway.
-- ─────────────────────────────────────────────────────────────────────────────
-- Idempotent on (p_by, p_ref): asking twice for the same booking returns the same charge.
CREATE OR REPLACE FUNCTION public.wallet_create_charge(p_wa_id text, p_amount_paise bigint, p_description text,
                                                       p_ref text, p_by text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u public.tori_users;
  c public.wallet_charges;
  v_state text := 'created';
BEGIN
  IF coalesce(p_amount_paise, 0) <= 0 THEN
    RETURN jsonb_build_object('state', 'bad_amount');
  END IF;
  u := public.tori_user(p_wa_id);
  PERFORM public.wallet_user_account(u.id);
  INSERT INTO public.wallet_charges (user_id, amount_paise, description, ref, created_by, expires_at)
  VALUES (u.id, p_amount_paise, left(coalesce(nullif(trim(p_description), ''), 'Tori booking'), 200), p_ref, p_by,
          now() + make_interval(mins => (public.wallet_cfg() ->> 'wallet_charge_minutes')::int))
  ON CONFLICT (created_by, ref) DO NOTHING
  RETURNING * INTO c;
  IF NOT FOUND THEN
    SELECT * INTO c FROM public.wallet_charges WHERE created_by = p_by AND ref = p_ref;
    v_state := 'already';
  END IF;
  RETURN jsonb_build_object('state', v_state, 'charge_id', c.id, 'status', c.status, 'amount_paise', c.amount_paise,
                            'description', c.description, 'expires_at', c.expires_at,
                            'balance_paise', public.wallet_balance(u.id),
                            'enough', public.wallet_balance(u.id) >= c.amount_paise);
END $$;

-- The tap. state: paid | already_paid | insufficient | expired | cancelled | refunded | unknown
CREATE OR REPLACE FUNCTION public.wallet_pay_charge(p_charge_id uuid, p_wa_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c   public.wallet_charges;
  acc text;
  bal bigint;
BEGIN
  SELECT * INTO c FROM public.wallet_charges WHERE id = p_charge_id FOR UPDATE;
  IF NOT FOUND OR c.user_id IS DISTINCT FROM (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  acc := public.wallet_user_account(c.user_id);
  PERFORM 1 FROM public.wallet_accounts WHERE account = acc FOR UPDATE;   -- one spend at a time per wallet
  bal := public.wallet_balance(c.user_id);
  IF c.status = 'paid' THEN
    RETURN jsonb_build_object('state', 'already_paid', 'amount_paise', c.amount_paise, 'description', c.description, 'balance_paise', bal);
  ELSIF c.status <> 'pending' THEN
    RETURN jsonb_build_object('state', c.status, 'amount_paise', c.amount_paise, 'description', c.description, 'balance_paise', bal);
  ELSIF c.expires_at <= now() THEN
    UPDATE public.wallet_charges SET status = 'expired' WHERE id = c.id;
    RETURN jsonb_build_object('state', 'expired', 'amount_paise', c.amount_paise, 'description', c.description, 'balance_paise', bal);
  ELSIF bal < c.amount_paise THEN
    RETURN jsonb_build_object('state', 'insufficient', 'amount_paise', c.amount_paise, 'description', c.description,
                              'balance_paise', bal, 'short_paise', c.amount_paise - bal);
  END IF;
  PERFORM public.wallet_post('charge', c.id::text, 'charge:' || c.id, c.description, 'wallet',
    jsonb_build_array(jsonb_build_object('account', acc, 'amount', -c.amount_paise),
                      jsonb_build_object('account', 'tori:sales', 'amount', c.amount_paise)));
  UPDATE public.wallet_charges SET status = 'paid', paid_at = now() WHERE id = c.id;
  RETURN jsonb_build_object('state', 'paid', 'amount_paise', c.amount_paise, 'description', c.description,
                            'ref', c.ref, 'created_by', c.created_by, 'balance_paise', public.wallet_balance(c.user_id));
END $$;

CREATE OR REPLACE FUNCTION public.wallet_cancel_charge(p_charge_id uuid, p_wa_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c public.wallet_charges;
BEGIN
  UPDATE public.wallet_charges SET status = 'cancelled'
   WHERE id = p_charge_id AND status = 'pending'
     AND user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id)
  RETURNING * INTO c;
  RETURN jsonb_build_object('state', CASE WHEN FOUND THEN 'cancelled' ELSE 'unknown' END,
                            'description', c.description, 'amount_paise', c.amount_paise);
END $$;

-- A paid booking was cancelled: the credits go back (idempotent).
CREATE OR REPLACE FUNCTION public.wallet_refund_charge(p_charge_id uuid, p_by text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  c public.wallet_charges;
BEGIN
  SELECT * INTO c FROM public.wallet_charges WHERE id = p_charge_id FOR UPDATE;
  IF NOT FOUND OR c.status NOT IN ('paid', 'refunded') THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  IF c.status = 'paid' THEN
    PERFORM public.wallet_post('refund', c.id::text, 'refund:' || c.id, 'Refund: ' || c.description, p_by,
      jsonb_build_array(jsonb_build_object('account', 'tori:sales', 'amount', -c.amount_paise),
                        jsonb_build_object('account', public.wallet_user_account(c.user_id), 'amount', c.amount_paise)));
    UPDATE public.wallet_charges SET status = 'refunded' WHERE id = c.id;
  END IF;
  RETURN jsonb_build_object('state', 'refunded', 'amount_paise', c.amount_paise, 'balance_paise', public.wallet_balance(c.user_id));
END $$;

-- The person's last p_limit movements, newest first: { at, kind, amount_paise (signed), memo, ref }
CREATE OR REPLACE FUNCTION public.wallet_history(p_user_id uuid, p_limit int DEFAULT 50)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  -- ties on the timestamp (same transaction) are broken by the order the postings were written
  SELECT coalesce(jsonb_agg(jsonb_build_object('at', x.at, 'kind', x.kind, 'amount_paise', x.amount_paise,
                                               'memo', x.memo, 'ref', x.ref) ORDER BY x.at DESC, x.seq DESC), '[]')
    FROM (SELECT j.created_at AS at, j.kind, p.amount_paise, j.memo, j.ref, p.id AS seq
            FROM public.wallet_postings p JOIN public.wallet_journal j ON j.id = p.journal_id
           WHERE p.account = 'user:' || p_user_id
           ORDER BY j.created_at DESC, p.id DESC LIMIT least(greatest(p_limit, 1), 200)) x;
$$;

-- Razorpay webhooks: stored first (x-razorpay-event-id), so a replay is ignored and a crash can be retried.
-- true = new event, to be processed now.
CREATE OR REPLACE FUNCTION public.wallet_record_event(p_event_id text, p_event text, p_payload jsonb)
RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.razorpay_events (event_id, event, payload) VALUES (p_event_id, p_event, p_payload)
  ON CONFLICT (event_id) DO NOTHING;
  IF FOUND THEN
    RETURN true;
  END IF;
  -- seen before: process again only if it never finished (a crash mid-way)
  RETURN EXISTS (SELECT 1 FROM public.razorpay_events WHERE event_id = p_event_id AND processed_at IS NULL);
END $$;
CREATE OR REPLACE FUNCTION public.wallet_event_done(p_event_id text, p_result jsonb)
RETURNS void
LANGUAGE sql AS $$
  UPDATE public.razorpay_events SET processed_at = now(), result = p_result WHERE event_id = p_event_id;
$$;

-- Invariants, for tests and a nightly check: both must be 0.
CREATE OR REPLACE FUNCTION public.wallet_check()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'unbalanced_journals', (SELECT count(*) FROM (SELECT journal_id FROM public.wallet_postings GROUP BY journal_id
                                                   HAVING sum(amount_paise) <> 0) x),
    'negative_wallets', (SELECT count(*) FROM (SELECT p.account FROM public.wallet_postings p
                                                 JOIN public.wallet_accounts a ON a.account = p.account AND a.kind = 'user'
                                                GROUP BY p.account HAVING sum(p.amount_paise) < 0) y));
$$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for n8n and the
-- web app only. The anon / authenticated roles exist only on Supabase.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'wallet\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
