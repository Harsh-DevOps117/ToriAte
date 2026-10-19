-- ToriPay rules (tables: 013_payees.sql; ledger: 012). One transaction per call; n8n and the web app only
-- call these functions. Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).
--
-- Money: "tori pay gym 500" confirmed → user:<id> −500, payee:<id> +(500 − commission), tori:revenue +commission.
-- Payout done → payee:<id> −net, tori:payouts +net. Payout failed → everything back to the person.

CREATE OR REPLACE FUNCTION public.payee_account(p_payee_id uuid)
RETURNS text
LANGUAGE sql AS $$
  INSERT INTO public.wallet_accounts (account, kind) VALUES ('payee:' || p_payee_id, 'payee') ON CONFLICT (account) DO NOTHING;
  SELECT 'payee:' || p_payee_id;
$$;

-- what a person may see about a payee before paying (no full account number: Tori never stores it)
CREATE OR REPLACE FUNCTION public.payee_public(p public.payees)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('payee_id', p.id, 'handle', p.handle, 'name', p.display_name, 'category', p.category,
                            'area', p.area, 'city', p.city, 'bank', coalesce(p.bank_name, left(p.ifsc, 4)), 'last4', p.account_last4,
                            'verified_name', coalesce(p.bank_verified_name, p.account_holder), 'commission_bps', p.commission_bps,
                            'self_added', p.added_by IS NOT NULL);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Admin: add or update a business by handle (web POST /api/admin/payees). p = { handle, display_name,
-- category, city, area, aliases[], owner_wa, account_holder, account_last4, ifsc, bank_verified_name,
-- rzp_contact_id, rzp_fund_account_id, commission_bps, status }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.payee_upsert(p jsonb, p_by text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r public.payees;
BEGIN
  INSERT INTO public.payees AS t (handle, display_name, category, city, area, aliases, owner_wa, account_holder, account_last4,
                                  ifsc, bank_verified_name, rzp_contact_id, rzp_fund_account_id, commission_bps, status, updated_by)
  VALUES (lower(p ->> 'handle'), p ->> 'display_name', coalesce(p ->> 'category', 'other'), lower(p ->> 'city'), p ->> 'area',
          coalesce(ARRAY(SELECT lower(trim(x)) FROM jsonb_array_elements_text(coalesce(p -> 'aliases', '[]')) x WHERE trim(x) <> ''), '{}'),
          nullif(regexp_replace(coalesce(p ->> 'owner_wa', ''), '\D', '', 'g'), ''),
          p ->> 'account_holder', p ->> 'account_last4', upper(p ->> 'ifsc'), p ->> 'bank_verified_name',
          p ->> 'rzp_contact_id', p ->> 'rzp_fund_account_id', coalesce((p ->> 'commission_bps')::int, 0),
          coalesce(p ->> 'status', 'verified'), p_by)
  ON CONFLICT (handle) DO UPDATE SET
    display_name = EXCLUDED.display_name, category = EXCLUDED.category, city = EXCLUDED.city, area = EXCLUDED.area,
    aliases = EXCLUDED.aliases, owner_wa = EXCLUDED.owner_wa,
    -- bank details change only when new ones are given (the account number itself is never stored)
    account_holder = EXCLUDED.account_holder, account_last4 = EXCLUDED.account_last4, ifsc = EXCLUDED.ifsc,
    bank_verified_name = coalesce(EXCLUDED.bank_verified_name, CASE WHEN t.account_last4 = EXCLUDED.account_last4 AND t.ifsc = EXCLUDED.ifsc THEN t.bank_verified_name END),
    rzp_contact_id = coalesce(EXCLUDED.rzp_contact_id, t.rzp_contact_id),
    rzp_fund_account_id = coalesce(EXCLUDED.rzp_fund_account_id,
                                   CASE WHEN t.account_last4 = EXCLUDED.account_last4 AND t.ifsc = EXCLUDED.ifsc THEN t.rzp_fund_account_id END),
    commission_bps = EXCLUDED.commission_bps, status = EXCLUDED.status, updated_at = now(), updated_by = p_by
  RETURNING * INTO r;
  PERFORM public.payee_account(r.id);
  RETURN public.payee_public(r) || jsonb_build_object('status', r.status, 'has_fund_account', r.rzp_fund_account_id IS NOT NULL);
END $$;

-- Verified businesses matching what someone typed ("gym", "fitzone", "fit zone hsr"), best first
CREATE OR REPLACE FUNCTION public.payee_search(p_query text, p_limit int DEFAULT 10)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT lower(trim(coalesce(p_query, ''))) AS t),
  words AS (SELECT w FROM q, regexp_split_to_table(q.t, '\s+') w WHERE length(w) >= 2),
  scored AS (
    SELECT p AS row, p.display_name, (
        3 * (lower(p.display_name) LIKE '%' || q.t || '%')::int
      + 3 * (q.t = ANY (p.aliases))::int
      + 2 * (p.handle LIKE '%' || replace(q.t, ' ', '-') || '%')::int
      + 2 * (p.category = q.t OR (q.t IN ('gym', 'gyms', 'fitness') AND p.category = 'gym')
             OR (q.t IN ('turf', 'football', 'cricket') AND p.category = 'turf')
             OR (q.t IN ('court', 'badminton', 'tennis', 'pickleball') AND p.category = 'court'))::int
      + (SELECT count(*) FROM words WHERE lower(p.display_name) LIKE '%' || w || '%'
                                       OR lower(coalesce(p.area, '')) LIKE '%' || w || '%' OR w = ANY (p.aliases))::int
      ) AS score
      FROM public.payees p, q
     WHERE p.status = 'verified' AND p.added_by IS NULL AND q.t <> '')
  SELECT coalesce(jsonb_agg(public.payee_public(s.row) ORDER BY s.score DESC, s.display_name), '[]')
    FROM (SELECT * FROM scored WHERE score > 0 ORDER BY score DESC, display_name LIMIT least(greatest(p_limit, 1), 10)) s;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Shortcuts: "gym" → a payee. state of toripay_resolve: favourite | one | many | none
-- ─────────────────────────────────────────────────────────────────────────────
-- the word someone used ("Gym", "fit zone") as a shortcut name, or NULL if it can't be one
CREATE OR REPLACE FUNCTION public.toripay_nickname(p_word text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN w ~ '^[a-z0-9][a-z0-9 _-]{0,29}$' THEN w END
    FROM (SELECT regexp_replace(lower(trim(coalesce(p_word, ''))), '\s+', ' ', 'g') AS w) x;
$$;

CREATE OR REPLACE FUNCTION public.toripay_resolve(p_wa_id text, p_word text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u     public.tori_users;
  nick  text := lower(trim(coalesce(p_word, '')));
  p     public.payees;
  hits  jsonb;
BEGIN
  u := public.tori_user(p_wa_id);
  SELECT py.* INTO p FROM public.user_payees up JOIN public.payees py ON py.id = up.payee_id
   WHERE up.user_id = u.id AND up.nickname = nick AND py.status = 'verified';
  IF FOUND THEN
    RETURN jsonb_build_object('state', 'favourite', 'nickname', nick, 'payee', public.payee_public(p));
  END IF;
  hits := public.payee_search(nick, 10);
  RETURN jsonb_build_object('state', CASE jsonb_array_length(hits) WHEN 0 THEN 'none' WHEN 1 THEN 'one' ELSE 'many' END,
                            'nickname', nick, 'options', hits, 'payee', CASE WHEN jsonb_array_length(hits) = 1 THEN hits -> 0 END);
END $$;

CREATE OR REPLACE FUNCTION public.user_payee_set(p_wa_id text, p_nickname text, p_payee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u    public.tori_users;
  p    public.payees;
  nick text := public.toripay_nickname(p_nickname);
BEGIN
  u := public.tori_user(p_wa_id);
  SELECT * INTO p FROM public.payees WHERE id = p_payee_id AND status = 'verified' AND (added_by IS NULL OR added_by = u.id);
  IF NOT FOUND OR nick IS NULL THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  INSERT INTO public.user_payees (user_id, nickname, payee_id) VALUES (u.id, nick, p.id)
  ON CONFLICT (user_id, nickname) DO UPDATE SET payee_id = EXCLUDED.payee_id, updated_at = now();
  RETURN jsonb_build_object('state', 'saved', 'nickname', nick, 'payee', public.payee_public(p));
END $$;

CREATE OR REPLACE FUNCTION public.user_payee_list(p_wa_id text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('nickname', up.nickname) || public.payee_public(p) ORDER BY up.nickname), '[]')
    FROM public.user_payees up
    JOIN public.payees p ON p.id = up.payee_id
    JOIN public.tori_users u ON u.id = up.user_id
   WHERE u.phone = '+' || p_wa_id;
$$;

CREATE OR REPLACE FUNCTION public.user_payee_remove(p_wa_id text, p_nickname text)
RETURNS boolean
LANGUAGE sql AS $$
  WITH d AS (DELETE FROM public.user_payees
              WHERE user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id)
                AND nickname = lower(trim(coalesce(p_nickname, ''))) RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM d);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Paying: start (the confirm message) → confirm (one tap) → payout → settled / failed
-- ─────────────────────────────────────────────────────────────────────────────
-- state: ok | bad_amount | unavailable
CREATE OR REPLACE FUNCTION public.toripay_start(p_wa_id text, p_payee_id uuid, p_amount_paise bigint, p_nickname text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u   public.tori_users;
  p   public.payees;
  pp  public.payee_payments;
  max_paise bigint := (public.wallet_cfg() ->> 'wallet_max_balance_paise')::bigint;
BEGIN
  u := public.tori_user(p_wa_id);
  SELECT * INTO p FROM public.payees WHERE id = p_payee_id AND status = 'verified' AND (added_by IS NULL OR added_by = u.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unavailable');
  END IF;
  IF coalesce(p_amount_paise, 0) < 100 OR p_amount_paise > max_paise THEN
    RETURN jsonb_build_object('state', 'bad_amount', 'max_paise', max_paise);
  END IF;
  PERFORM public.wallet_user_account(u.id);
  INSERT INTO public.payee_payments (user_id, payee_id, nickname, amount_paise, commission_paise, expires_at)
  VALUES (u.id, p.id, public.toripay_nickname(p_nickname), p_amount_paise,
          (p_amount_paise * p.commission_bps) / 10000, now() + interval '15 minutes')
  RETURNING * INTO pp;
  RETURN jsonb_build_object('state', 'ok', 'payment_id', pp.id, 'amount_paise', pp.amount_paise,
                            'commission_paise', pp.commission_paise, 'payee', public.payee_public(p),
                            'balance_paise', public.wallet_balance(u.id), 'enough', public.wallet_balance(u.id) >= pp.amount_paise);
END $$;

-- The tap. state: paid | already_paid | insufficient | expired | cancelled | unavailable | unknown
-- On paid: payout = what workflow 06 / the web app need to send the money (fund account, net amount).
CREATE OR REPLACE FUNCTION public.toripay_confirm(p_payment_id uuid, p_wa_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  pp  public.payee_payments;
  p   public.payees;
  acc text;
  bal bigint;
BEGIN
  SELECT * INTO pp FROM public.payee_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND OR pp.user_id IS DISTINCT FROM (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  SELECT * INTO p FROM public.payees WHERE id = pp.payee_id;
  acc := public.wallet_user_account(pp.user_id);
  PERFORM 1 FROM public.wallet_accounts WHERE account = acc FOR UPDATE;   -- one spend at a time per wallet
  bal := public.wallet_balance(pp.user_id);
  IF pp.status IN ('paid', 'processing', 'settled') THEN
    RETURN jsonb_build_object('state', 'already_paid', 'payee', public.payee_public(p), 'amount_paise', pp.amount_paise, 'balance_paise', bal);
  ELSIF pp.status <> 'pending' THEN
    RETURN jsonb_build_object('state', pp.status, 'payee', public.payee_public(p), 'amount_paise', pp.amount_paise, 'balance_paise', bal);
  ELSIF pp.expires_at <= now() THEN
    UPDATE public.payee_payments SET status = 'expired' WHERE id = pp.id;
    RETURN jsonb_build_object('state', 'expired', 'payee', public.payee_public(p), 'amount_paise', pp.amount_paise, 'balance_paise', bal);
  ELSIF p.status <> 'verified' THEN
    UPDATE public.payee_payments SET status = 'cancelled', failure_reason = 'payee suspended' WHERE id = pp.id;
    RETURN jsonb_build_object('state', 'unavailable', 'payee', public.payee_public(p));
  ELSIF bal < pp.amount_paise THEN
    RETURN jsonb_build_object('state', 'insufficient', 'payee', public.payee_public(p), 'amount_paise', pp.amount_paise,
                              'balance_paise', bal, 'short_paise', pp.amount_paise - bal);
  END IF;

  PERFORM public.wallet_post('payee_payment', pp.id::text, 'payee_payment:' || pp.id, 'Paid ' || p.display_name, 'toripay',
    jsonb_build_array(jsonb_build_object('account', acc, 'amount', -pp.amount_paise),
                      jsonb_build_object('account', public.payee_account(p.id), 'amount', pp.amount_paise - pp.commission_paise),
                      jsonb_build_object('account', 'tori:revenue', 'amount', pp.commission_paise)));
  UPDATE public.payee_payments SET status = 'paid', paid_at = now() WHERE id = pp.id;
  IF pp.nickname IS NOT NULL THEN                         -- "gym" now means this payee for this person
    INSERT INTO public.user_payees (user_id, nickname, payee_id) VALUES (pp.user_id, pp.nickname, p.id)
    ON CONFLICT (user_id, nickname) DO UPDATE SET payee_id = EXCLUDED.payee_id, updated_at = now();
  END IF;
  RETURN jsonb_build_object('state', 'paid', 'payment_id', pp.id, 'payee', public.payee_public(p),
                            'amount_paise', pp.amount_paise, 'net_paise', pp.amount_paise - pp.commission_paise,
                            'balance_paise', public.wallet_balance(pp.user_id), 'nickname', pp.nickname,
                            'owner_wa', p.owner_wa, 'payer_name', (SELECT split_part(trim(coalesce(name, '')), ' ', 1) FROM public.tori_users WHERE id = pp.user_id),
                            'payout', CASE WHEN p.rzp_fund_account_id IS NOT NULL
                                           THEN jsonb_build_object('fund_account_id', p.rzp_fund_account_id) END);
END $$;

CREATE OR REPLACE FUNCTION public.toripay_cancel(p_payment_id uuid, p_wa_id text)
RETURNS jsonb
LANGUAGE sql AS $$
  WITH c AS (UPDATE public.payee_payments SET status = 'cancelled'
              WHERE id = p_payment_id AND status = 'pending'
                AND user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) RETURNING 1)
  SELECT jsonb_build_object('state', CASE WHEN EXISTS (SELECT 1 FROM c) THEN 'cancelled' ELSE 'unknown' END);
$$;

-- What the web app needs to send a payout (only for a paid payment with a fund account)
CREATE OR REPLACE FUNCTION public.payout_details(p_payment_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('payment_id', pp.id, 'status', pp.status, 'net_paise', pp.amount_paise - pp.commission_paise,
                            'fund_account_id', p.rzp_fund_account_id, 'payee', p.display_name,
                            'reference', 'toripay-' || replace(pp.id::text, '-', ''))
    FROM public.payee_payments pp JOIN public.payees p ON p.id = pp.payee_id
   WHERE pp.id = p_payment_id;
$$;

CREATE OR REPLACE FUNCTION public.payout_mark(p_payment_id uuid, p_payout_id text)
RETURNS void
LANGUAGE sql AS $$
  UPDATE public.payee_payments SET status = 'processing', rzp_payout_id = p_payout_id
   WHERE id = p_payment_id AND status = 'paid';
$$;

-- RazorpayX webhook (payout.processed / payout.failed / payout.reversed / payout.rejected), or the team's
-- manual settlement (p_payout_id = 'manual:<payment id>' with event 'processed'). Idempotent.
-- state: settled | refunded | already | unknown
CREATE OR REPLACE FUNCTION public.payout_settled(p_payout_id text, p_event text, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  pp public.payee_payments;
  p  public.payees;
  net bigint;
BEGIN
  SELECT * INTO pp FROM public.payee_payments
   WHERE rzp_payout_id = p_payout_id
      OR (p_payout_id LIKE 'manual:%' AND id::text = substr(p_payout_id, 8))
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unknown');
  END IF;
  SELECT * INTO p FROM public.payees WHERE id = pp.payee_id;
  net := pp.amount_paise - pp.commission_paise;
  IF pp.status IN ('settled', 'failed') THEN
    RETURN jsonb_build_object('state', 'already', 'status', pp.status);
  END IF;
  IF p_event = 'processed' AND pp.status IN ('paid', 'processing') THEN
    PERFORM public.wallet_post('payout', p_payout_id, 'payout:' || pp.id, 'Payout to ' || p.display_name, 'razorpayx',
      jsonb_build_array(jsonb_build_object('account', public.payee_account(p.id), 'amount', -net),
                        jsonb_build_object('account', 'tori:payouts', 'amount', net)));
    UPDATE public.payee_payments SET status = 'settled', settled_at = now(),
           rzp_payout_id = coalesce(rzp_payout_id, p_payout_id) WHERE id = pp.id;
    RETURN jsonb_build_object('state', 'settled', 'payee', p.display_name, 'net_paise', net);
  ELSIF p_event IN ('failed', 'reversed', 'rejected') AND pp.status IN ('paid', 'processing') THEN
    PERFORM public.wallet_post('payout_reversal', p_payout_id, 'payout_reversal:' || pp.id, 'Refund: payment to ' || p.display_name || ' failed', 'razorpayx',
      jsonb_build_array(jsonb_build_object('account', public.payee_account(p.id), 'amount', -net),
                        jsonb_build_object('account', 'tori:revenue', 'amount', -pp.commission_paise),
                        jsonb_build_object('account', public.wallet_user_account(pp.user_id), 'amount', pp.amount_paise)));
    UPDATE public.payee_payments SET status = 'failed', failure_reason = left(coalesce(p_reason, p_event), 200) WHERE id = pp.id;
    RETURN jsonb_build_object('state', 'refunded', 'payee', p.display_name, 'amount_paise', pp.amount_paise,
                              'wa_id', (SELECT ltrim(phone, '+') FROM public.tori_users WHERE id = pp.user_id),
                              'balance_paise', public.wallet_balance(pp.user_id));
  END IF;
  RETURN jsonb_build_object('state', 'ignored', 'status', pp.status);
END $$;

-- The team's "to settle" report: what Tori owes each payee (paid by people, not yet in the payee's bank)
CREATE OR REPLACE FUNCTION public.payees_owed()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_agg(x ORDER BY x.owed_paise DESC), '[]') FROM (
    SELECT p.handle, p.display_name, p.ifsc, p.account_last4, p.account_holder,
           sum(pp.amount_paise - pp.commission_paise) FILTER (WHERE pp.status = 'paid') AS owed_paise,
           sum(pp.amount_paise - pp.commission_paise) FILTER (WHERE pp.status = 'processing') AS in_transit_paise,
           count(*) FILTER (WHERE pp.status = 'paid') AS payments
      FROM public.payees p JOIN public.payee_payments pp ON pp.payee_id = p.id AND pp.status IN ('paid', 'processing')
     GROUP BY p.id) x;
$$;

-- The team paid a payee by bank transfer themselves (RazorpayX off): settle everything owed to it.
CREATE OR REPLACE FUNCTION public.payee_settle_manual(p_handle text, p_by text, p_reference text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r     record;
  n     int := 0;
  total bigint := 0;
BEGIN
  FOR r IN SELECT pp.id, pp.amount_paise - pp.commission_paise AS net FROM public.payee_payments pp
             JOIN public.payees p ON p.id = pp.payee_id
            WHERE p.handle = lower(p_handle) AND pp.status = 'paid' ORDER BY pp.paid_at LOOP
    PERFORM public.payout_settled('manual:' || r.id, 'processed');
    UPDATE public.payee_payments SET failure_reason = left('manual: ' || coalesce(p_reference, '') || ' by ' || p_by, 200) WHERE id = r.id;
    n := n + 1;
    total := total + r.net;
  END LOOP;
  RETURN jsonb_build_object('settled_payments', n, 'settled_paise', total);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Adding a payee on WhatsApp (014): name → IFSC → account holder → account number → the number again.
-- The web app (POST /api/toripay/answer) drives the steps: it looks the IFSC up, and on the second
-- account number creates the RazorpayX fund account, then calls toripay_draft_finish. The number itself
-- is never stored: the first entry is kept as a hash, to check the second.
-- Replies: kind add_step {step, error?} | add_cancelled | add_gone | added | confirm (saved, now pay)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.toripay_draft_view(d public.toripay_drafts)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('kind', 'add_step', 'step', d.step, 'nickname', d.nickname, 'fixing', d.payee_id IS NOT NULL,
                            'display_name', d.display_name, 'ifsc', d.ifsc, 'bank_name', d.bank_name, 'branch', d.branch,
                            'holder', d.holder, 'amount_paise', d.amount_paise);
$$;

CREATE OR REPLACE FUNCTION public.toripay_draft_start(p_wa_id text, p_nickname text, p_amount_paise bigint, p_fix boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u    public.tori_users;
  nick text := coalesce(public.toripay_nickname(p_nickname),
                        public.toripay_nickname(trim(regexp_replace(lower(coalesce(p_nickname, '')), '[^a-z0-9 _-]', '', 'g'))), 'payee');
  cur  public.payees;
  d    public.toripay_drafts;
BEGIN
  u := public.tori_user(p_wa_id);
  IF p_fix THEN                                           -- "gym edit" → change the bank details of the one they added
    SELECT py.* INTO cur FROM public.user_payees up JOIN public.payees py ON py.id = up.payee_id
     WHERE up.user_id = u.id AND up.nickname = nick AND py.added_by = u.id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('kind', 'not_found', 'word', nick);
    END IF;
  END IF;
  INSERT INTO public.toripay_drafts AS t (user_id, step, nickname, payee_id, amount_paise, handle, display_name, expires_at)
  VALUES (u.id, 'name', nick, cur.id, CASE WHEN p_amount_paise > 0 THEN p_amount_paise END, cur.handle, cur.display_name,
          now() + interval '30 minutes')
  ON CONFLICT (user_id) DO UPDATE SET step = 'name', nickname = EXCLUDED.nickname, payee_id = EXCLUDED.payee_id,
    amount_paise = EXCLUDED.amount_paise, handle = EXCLUDED.handle, display_name = EXCLUDED.display_name, ifsc = NULL,
    bank_name = NULL, branch = NULL, holder = NULL, account_hash = NULL, account_last4 = NULL, updated_at = now(),
    expires_at = EXCLUDED.expires_at
  RETURNING * INTO d;
  RETURN public.toripay_draft_view(d);
END $$;

CREATE OR REPLACE FUNCTION public.toripay_draft_get(p_wa_id text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT public.toripay_draft_view(d) FROM public.toripay_drafts d JOIN public.tori_users u ON u.id = d.user_id
   WHERE u.phone = '+' || p_wa_id AND d.expires_at > now();
$$;

CREATE OR REPLACE FUNCTION public.toripay_draft_cancel(p_wa_id text)
RETURNS jsonb
LANGUAGE sql AS $$
  WITH d AS (DELETE FROM public.toripay_drafts WHERE user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) RETURNING 1)
  SELECT jsonb_build_object('kind', CASE WHEN EXISTS (SELECT 1 FROM d) THEN 'add_cancelled' ELSE 'add_gone' END);
$$;

-- back to a step (a mismatch, or the bank refused the details): the account number is asked again
CREATE OR REPLACE FUNCTION public.toripay_draft_back(p_wa_id text, p_step text, p_error text, p_detail text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  d public.toripay_drafts;
BEGIN
  UPDATE public.toripay_drafts SET step = p_step, account_hash = NULL, account_last4 = NULL, updated_at = now(),
         expires_at = now() + interval '30 minutes'
   WHERE user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) RETURNING * INTO d;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('kind', 'add_gone');
  END IF;
  RETURN public.toripay_draft_view(d) || jsonb_build_object('error', p_error, 'detail', left(p_detail, 120));
END $$;

-- one answer. p: {text} for name / holder / account; {ifsc, bank, branch} for ifsc (looked up by the web app)
CREATE OR REPLACE FUNCTION public.toripay_draft_answer(p_wa_id text, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  d   public.toripay_drafts;
  v   text := regexp_replace(trim(coalesce(p ->> 'text', '')), '\s+', ' ', 'g');
  acc text;
  err text;
BEGIN
  SELECT * INTO d FROM public.toripay_drafts
   WHERE user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('kind', 'add_gone');
  END IF;
  IF d.step = 'name' THEN
    IF d.payee_id IS NOT NULL AND lower(v) IN ('same', 'ok', 'okay', 'keep', 'keep it', 'yes') THEN
      v := d.display_name;
    END IF;
    IF length(v) BETWEEN 2 AND 60 THEN
      d.display_name := v; d.step := 'ifsc';
    ELSE err := 'name'; END IF;
  ELSIF d.step = 'ifsc' THEN
    IF upper(p ->> 'ifsc') ~ '^[A-Z]{4}0[A-Z0-9]{6}$' THEN
      d.ifsc := upper(p ->> 'ifsc'); d.bank_name := nullif(p ->> 'bank', ''); d.branch := nullif(p ->> 'branch', ''); d.step := 'holder';
    ELSE err := 'ifsc'; END IF;
  ELSIF d.step = 'holder' THEN
    IF v ~ '^[A-Za-z][A-Za-z .&''-]{1,79}$' THEN
      d.holder := upper(v); d.step := 'account';
    ELSE err := 'holder'; END IF;
  ELSIF d.step = 'account' THEN
    acc := regexp_replace(v, '[\s-]', '', 'g');
    IF acc ~ '^\d{9,18}$' THEN
      d.account_hash := encode(sha256(convert_to(d.user_id || ':' || acc, 'UTF8')), 'hex');
      d.account_last4 := right(acc, 4); d.step := 'account_confirm';
    ELSE err := 'account'; END IF;
  ELSE
    err := 'step';                                        -- account_confirm goes through toripay_draft_check
  END IF;
  UPDATE public.toripay_drafts SET step = d.step, display_name = d.display_name, ifsc = d.ifsc, bank_name = d.bank_name,
         branch = d.branch, holder = d.holder, account_hash = d.account_hash, account_last4 = d.account_last4,
         updated_at = now(), expires_at = now() + interval '30 minutes'
   WHERE user_id = d.user_id;
  RETURN public.toripay_draft_view(d) || CASE WHEN err IS NOT NULL THEN jsonb_build_object('error', err) ELSE '{}' END;
END $$;

-- the second account number: the same as the first? Then what the web app needs to create the fund account.
CREATE OR REPLACE FUNCTION public.toripay_draft_check(p_wa_id text, p_account text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  d   public.toripay_drafts;
  acc text := regexp_replace(coalesce(p_account, ''), '[\s-]', '', 'g');
BEGIN
  SELECT * INTO d FROM public.toripay_drafts
   WHERE user_id = (SELECT id FROM public.tori_users WHERE phone = '+' || p_wa_id) AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('kind', 'add_gone');
  ELSIF d.step <> 'account_confirm' THEN
    RETURN public.toripay_draft_view(d) || jsonb_build_object('error', 'step');
  ELSIF d.account_hash IS DISTINCT FROM encode(sha256(convert_to(d.user_id || ':' || acc, 'UTF8')), 'hex') THEN
    RETURN public.toripay_draft_back(p_wa_id, 'account', 'mismatch');
  END IF;
  IF d.handle IS NULL THEN
    d.handle := 'u-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    UPDATE public.toripay_drafts SET handle = d.handle WHERE user_id = d.user_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'handle', d.handle, 'display_name', d.display_name, 'holder', d.holder, 'ifsc', d.ifsc);
END $$;

-- RazorpayX has the account: save the payee (or its new bank details), the shortcut, and pay if asked to
CREATE OR REPLACE FUNCTION public.toripay_draft_finish(p_wa_id text, p_contact_id text, p_fund_account_id text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  u  public.tori_users;
  d  public.toripay_drafts;
  py public.payees;
  st jsonb;
BEGIN
  u := public.tori_user(p_wa_id);
  SELECT * INTO d FROM public.toripay_drafts WHERE user_id = u.id AND step = 'account_confirm' AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('kind', 'add_gone');
  END IF;
  IF d.payee_id IS NOT NULL THEN
    UPDATE public.payees SET display_name = d.display_name, account_holder = d.holder, account_last4 = d.account_last4,
           ifsc = d.ifsc, bank_name = d.bank_name, branch = d.branch, bank_verified_name = NULL,
           rzp_contact_id = p_contact_id, rzp_fund_account_id = p_fund_account_id, updated_at = now(), updated_by = 'user:' || p_wa_id
     WHERE id = d.payee_id AND added_by = u.id RETURNING * INTO py;
  ELSE
    INSERT INTO public.payees (handle, display_name, category, account_holder, account_last4, ifsc, bank_name, branch,
                               rzp_contact_id, rzp_fund_account_id, added_by, updated_by)
    VALUES (d.handle, d.display_name,
            CASE WHEN d.nickname ~ 'gym|fitness|yoga|crossfit' THEN 'gym'
                 WHEN d.nickname ~ 'turf|football|cricket|futsal' THEN 'turf'
                 WHEN d.nickname ~ 'court|badminton|tennis|pickleball|padel|squash' THEN 'court'
                 WHEN d.nickname ~ 'coach|trainer|class|academy' THEN 'coach'
                 WHEN d.nickname ~ 'physio' THEN 'physio' ELSE 'other' END,
            d.holder, d.account_last4, d.ifsc, d.bank_name, d.branch, p_contact_id, p_fund_account_id, u.id, 'user:' || p_wa_id)
    RETURNING * INTO py;
  END IF;
  PERFORM public.payee_account(py.id);
  PERFORM public.user_payee_set(p_wa_id, d.nickname, py.id);
  DELETE FROM public.toripay_drafts WHERE user_id = u.id;
  IF d.amount_paise IS NOT NULL THEN
    st := public.toripay_start(p_wa_id, py.id, d.amount_paise, d.nickname);
    IF st ->> 'state' = 'ok' THEN
      RETURN st || jsonb_build_object('kind', 'confirm', 'added', true, 'nickname', d.nickname,
                                      'link', CASE WHEN NOT (st ->> 'enough')::boolean THEN public.wallet_issue_link(p_wa_id) END);
    END IF;
  END IF;
  RETURN jsonb_build_object('kind', 'added', 'payee', public.payee_public(py), 'nickname', d.nickname, 'fixed', d.payee_id IS NOT NULL);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The WhatsApp bot's one entry point (workflow 06, section 16). p.action:
--   pay {word, amount_paise}        "tori pay gym 500"   → confirm | choose | none | need_amount
--   pick {payee_id, amount_paise, nickname}  a row from the choose list → confirm
--   confirm / cancel {payment_id}   the [Pay ₹500] / [Cancel] buttons
--   edit {word}                     "gym edit"           → edit (options to point it at)
--   edit_pick {payee_id, nickname}  a row from that list → saved
--   list                            "my payees"          → list
--   remove {word}                   "tori pay remove gym" → removed | not_found
--   add {nickname, amount_paise?, fix?}  add a payee with its bank details (or change the ones they added) → add_step
--   (a word Tori doesn't know under "pay" starts adding it too)
-- kind = what to reply; 'link' (a wallet login link) is added when credits are short.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.toripay_bot(p_wa_id text, p_name text, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  act  text := coalesce(p ->> 'action', '');
  word text := regexp_replace(lower(trim(coalesce(p ->> 'word', ''))), '\s+', ' ', 'g');
  amt  bigint := nullif(p ->> 'amount_paise', '')::bigint;
  r    jsonb;
  st   jsonb;
  cur  public.payees;
BEGIN
  PERFORM public.tori_user(p_wa_id, p_name);
  IF act IN ('pay', 'pick') THEN
    IF act = 'pay' THEN
      r := public.toripay_resolve(p_wa_id, word);
      IF r ->> 'state' = 'none' AND word <> '' THEN        -- not on Tori yet: add it (asks for the bank details)
        RETURN public.toripay_draft_start(p_wa_id, word, amt);
      END IF;
      IF r ->> 'state' IN ('none', 'many') OR amt IS NULL THEN
        RETURN r || jsonb_build_object('kind', CASE WHEN r ->> 'state' = 'none' THEN 'none' WHEN amt IS NULL THEN 'need_amount' ELSE 'choose' END,
                                       'word', word, 'amount_paise', amt, 'shortcuts', public.user_payee_list(p_wa_id));
      END IF;
      st := public.toripay_start(p_wa_id, (r #>> '{payee,payee_id}')::uuid, amt, word);
    ELSE
      st := public.toripay_start(p_wa_id, nullif(p ->> 'payee_id', '')::uuid, amt, p ->> 'nickname');
    END IF;
    IF st ->> 'state' <> 'ok' THEN
      RETURN st || jsonb_build_object('kind', st ->> 'state', 'amount_paise', amt);
    END IF;
    RETURN st || jsonb_build_object('kind', 'confirm', 'link', CASE WHEN NOT (st ->> 'enough')::boolean THEN public.wallet_issue_link(p_wa_id) END);

  ELSIF act = 'confirm' THEN
    r := public.toripay_confirm(nullif(p ->> 'payment_id', '')::uuid, p_wa_id);
    RETURN r || jsonb_build_object('kind', 'confirmed', 'link', CASE WHEN r ->> 'state' = 'insufficient' THEN public.wallet_issue_link(p_wa_id) END);
  ELSIF act = 'cancel' THEN
    RETURN public.toripay_cancel(nullif(p ->> 'payment_id', '')::uuid, p_wa_id) || jsonb_build_object('kind', 'cancelled');

  ELSIF act = 'edit' THEN
    SELECT py.* INTO cur FROM public.user_payees up JOIN public.tori_users u ON u.id = up.user_id
      JOIN public.payees py ON py.id = up.payee_id WHERE u.phone = '+' || p_wa_id AND up.nickname = word;
    r := public.payee_search(word, 10);
    IF jsonb_array_length(r) = 0 AND cur.id IS NOT NULL THEN
      r := public.payee_search(cur.category, 10);              -- "my coach edit": other businesses of the same kind
    END IF;
    RETURN jsonb_build_object('kind', 'edit', 'nickname', public.toripay_nickname(word), 'word', word, 'options', r,
                              'current', CASE WHEN cur.id IS NOT NULL THEN public.payee_public(cur) END);
  ELSIF act = 'add' THEN                                  -- "➕ Add a new one" / "✏️ Change bank details"
    RETURN public.toripay_draft_start(p_wa_id, coalesce(p ->> 'nickname', word), amt, coalesce((p ->> 'fix')::boolean, false));
  ELSIF act = 'edit_pick' THEN
    RETURN public.user_payee_set(p_wa_id, p ->> 'nickname', nullif(p ->> 'payee_id', '')::uuid) || jsonb_build_object('kind', 'saved');
  ELSIF act = 'remove' THEN
    RETURN jsonb_build_object('kind', CASE WHEN public.user_payee_remove(p_wa_id, word) THEN 'removed' ELSE 'not_found' END, 'word', word);
  END IF;
  RETURN jsonb_build_object('kind', 'list', 'shortcuts', public.user_payee_list(p_wa_id),
                            'balance_paise', public.wallet_balance((public.tori_user(p_wa_id)).id));
END $$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for n8n and the
-- web app only. The anon / authenticated roles exist only on Supabase.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND (p.proname LIKE 'payee\_%' OR p.proname LIKE 'toripay\_%' OR p.proname LIKE 'payout\_%' OR p.proname LIKE 'user\_payee\_%'
            OR p.proname IN ('payees_owed'))
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
