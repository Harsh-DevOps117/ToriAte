-- Tori Wallet (012): top-ups credited once, one-tap charges, limits, links and sessions, invariants.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/wallet.sql against a database with 006–012 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

DO $$
DECLARE
  uid uuid; r jsonb; t uuid; c uuid; c2 uuid; link text; sess text;
BEGIN
  uid := (public.tori_user('919500000001', 'Asha Rao')).id;
  PERFORM pg_temp.ok(public.wallet_balance(uid) = 0, 'new wallet is empty');

  -- 1. limits
  PERFORM pg_temp.ok(public.wallet_create_topup(uid, 5000) ->> 'state' = 'too_small', 'under ₹100 refused');
  PERFORM pg_temp.ok(public.wallet_create_topup(uid, 2000000) ->> 'state' = 'too_big', 'over ₹10,000 per top-up refused');

  -- 2. a top-up is credited exactly once, only for the right amount
  r := public.wallet_create_topup(uid, 50000);
  t := (r ->> 'topup_id')::uuid;
  PERFORM public.wallet_attach_order(t, 'order_T1');
  PERFORM pg_temp.ok(public.wallet_credit_topup('order_T1', 'pay_T1', 49900, 'test') ->> 'state' = 'mismatch', 'wrong amount is not credited');
  PERFORM pg_temp.ok(public.wallet_balance(uid) = 0, 'still 0 after the mismatch');
  r := public.wallet_credit_topup('order_T1', 'pay_T1', 50000, 'web');
  PERFORM pg_temp.ok(r ->> 'state' = 'credited' AND (r ->> 'balance_paise')::bigint = 50000 AND r ->> 'wa_id' = '919500000001',
                     'browser callback credits ₹500');
  r := public.wallet_credit_topup('order_T1', 'pay_T1', 50000, 'razorpay-webhook');
  PERFORM pg_temp.ok(r ->> 'state' = 'already' AND public.wallet_balance(uid) = 50000, 'the webhook for the same payment changes nothing');
  PERFORM pg_temp.ok(public.wallet_credit_topup('order_nope', 'pay_X', 100, 'web') ->> 'state' = 'unknown', 'unknown order');
  PERFORM pg_temp.ok(public.wallet_create_topup(uid, 960000) ->> 'state' = 'over_limit', 'the ₹10,000 balance cap holds');

  -- 3. one-tap charge
  r := public.wallet_create_charge('919500000001', 30000, 'Court 2, Smash Arena · Sat 7 PM', 'booking-1', 'venue-test');
  c := (r ->> 'charge_id')::uuid;
  PERFORM pg_temp.ok(r ->> 'state' = 'created' AND (r ->> 'enough')::boolean, 'charge created; enough credits');
  PERFORM pg_temp.ok((public.wallet_create_charge('919500000001', 30000, 'again', 'booking-1', 'venue-test') ->> 'charge_id')::uuid = c,
                     'the same booking asked twice → the same charge');
  PERFORM pg_temp.ok(public.wallet_pay_charge(c, '919500000002') ->> 'state' = 'unknown', 'someone else cannot pay it');
  r := public.wallet_pay_charge(c, '919500000001');
  PERFORM pg_temp.ok(r ->> 'state' = 'paid' AND (r ->> 'balance_paise')::bigint = 20000, 'one tap: ₹300 paid, ₹200 left');
  PERFORM pg_temp.ok(public.wallet_pay_charge(c, '919500000001') ->> 'state' = 'already_paid' AND public.wallet_balance(uid) = 20000,
                     'a second tap charges nothing');

  -- 4. not enough, expired, cancelled
  c2 := (public.wallet_create_charge('919500000001', 25000, 'Turf · Sun 6 AM', 'booking-2', 'venue-test') ->> 'charge_id')::uuid;
  r := public.wallet_pay_charge(c2, '919500000001');
  PERFORM pg_temp.ok(r ->> 'state' = 'insufficient' AND (r ->> 'short_paise')::bigint = 5000, 'not enough: ₹50 short');
  PERFORM pg_temp.ok(public.wallet_cancel_charge(c2, '919500000001') ->> 'state' = 'cancelled', 'cancelled');
  PERFORM pg_temp.ok(public.wallet_pay_charge(c2, '919500000001') ->> 'state' = 'cancelled', 'a cancelled charge cannot be paid');
  c2 := (public.wallet_create_charge('919500000001', 1000, 'Old', 'booking-3', 'venue-test') ->> 'charge_id')::uuid;
  UPDATE public.wallet_charges SET expires_at = now() - interval '1 minute' WHERE id = c2;
  PERFORM pg_temp.ok(public.wallet_pay_charge(c2, '919500000001') ->> 'state' = 'expired' AND public.wallet_balance(uid) = 20000,
                     'an expired charge is not paid');

  -- 5. refund a paid booking
  PERFORM pg_temp.ok((public.wallet_refund_charge(c, 'venue-test') ->> 'balance_paise')::bigint = 50000, 'refund puts ₹300 back');
  PERFORM pg_temp.ok((public.wallet_refund_charge(c, 'venue-test') ->> 'balance_paise')::bigint = 50000, 'refunding twice changes nothing');

  -- 6. history and invariants
  r := public.wallet_history(uid);
  PERFORM pg_temp.ok(jsonb_array_length(r) = 3 AND r -> 0 ->> 'kind' = 'refund' AND (r -> 2 ->> 'amount_paise')::bigint = 50000,
                     'history: top-up, charge, refund (newest first)');
  r := public.wallet_check();
  PERFORM pg_temp.ok((r ->> 'unbalanced_journals')::int = 0 AND (r ->> 'negative_wallets')::int = 0, 'every journal sums to 0, no wallet below 0');
  BEGIN
    PERFORM public.wallet_post('adjustment', 'x', 'bad:1', 'bad', 'test',
      jsonb_build_array(jsonb_build_object('account', 'user:' || uid, 'amount', -100)));
    PERFORM pg_temp.ok(false, 'an unbalanced journal must fail');
  EXCEPTION WHEN others THEN
    PERFORM pg_temp.ok(SQLERRM LIKE '%does not balance%', 'an unbalanced journal is refused');
  END;
  BEGIN
    PERFORM public.wallet_post('adjustment', 'x', 'neg:1', 'overspend', 'test',
      jsonb_build_array(jsonb_build_object('account', 'user:' || uid, 'amount', -9999999),
                        jsonb_build_object('account', 'tori:sales', 'amount', 9999999)));
    PERFORM pg_temp.ok(false, 'an overspend must fail');
  EXCEPTION WHEN others THEN
    PERFORM pg_temp.ok(SQLERRM LIKE '%negative%', 'a wallet can never go below 0');
  END;

  -- 7. WhatsApp link → web session
  r := public.wallet_issue_link('919500000001', NULL);
  link := r ->> 'token';
  PERFORM pg_temp.ok(length(link) = 64 AND (r ->> 'balance_paise')::bigint = 50000 AND r ->> 'name' = 'Asha',
                     'link issued with the balance');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM public.wallet_links WHERE token_hash = link), 'only the hash is stored');
  sess := public.wallet_open_session(link);
  PERFORM pg_temp.ok(sess IS NOT NULL AND public.wallet_open_session(link) IS NULL, 'the link opens one session, once');
  r := public.wallet_session_user(sess);
  PERFORM pg_temp.ok((r ->> 'user_id')::uuid = uid AND r ->> 'phone' = '+91 ••••• 0001', 'session → the right person, number masked');
  PERFORM pg_temp.ok(public.wallet_session_user('nope') IS NULL, 'a made-up session is nobody');
  link := public.wallet_issue_link('919500000001') ->> 'token';
  UPDATE public.wallet_links SET expires_at = now() - interval '1 minute' WHERE token_hash = public.wallet_hash(link);
  PERFORM pg_temp.ok(public.wallet_open_session(link) IS NULL, 'an expired link opens nothing');
  PERFORM public.wallet_end_session(sess);
  PERFORM pg_temp.ok(public.wallet_session_user(sess) IS NULL, 'logged out');
END $$;
ROLLBACK;
