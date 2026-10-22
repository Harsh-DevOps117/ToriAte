-- Referrals (016): invite codes, both wallets credited once, abuse rules, limits, ledger invariants.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/referrals.sql against a database with 006–016 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;
CREATE OR REPLACE FUNCTION pg_temp.bal(wa text) RETURNS bigint LANGUAGE sql AS $$
  SELECT public.wallet_balance((SELECT id FROM public.tori_users WHERE phone = '+' || wa)) $$;

DO $$
DECLARE
  r jsonb; code text; code_b text; n int;
BEGIN
  -- Asha has been on Tori for a month; her friends are new
  PERFORM public.tori_user('919600000001', 'Asha Rao');
  UPDATE public.tori_users SET created_at = now() - interval '30 days' WHERE phone = '+919600000001';

  -- 1. the code
  r := public.referral_invite('919600000001');
  code := r ->> 'code';
  PERFORM pg_temp.ok(code ~ '^TORI-[A-HJKMNP-Z2-9]{6}$', 'invite → a TORI-XXXXXX code without look-alike characters');
  PERFORM pg_temp.ok(public.referral_invite('919600000001') ->> 'code' = code, 'the same code every time');
  PERFORM pg_temp.ok((r ->> 'bonus_paise')::bigint = 3000 AND (r ->> 'friends')::int = 0 AND r ->> 'name' = 'Asha',
                     'invite shows the 30-credit bonus and no friends yet');

  -- 2. codes that don't count
  PERFORM pg_temp.ok(public.referral_apply('919600000002', 'Bina', 'TORI-ZZZZZZ') ->> 'state' = 'unknown', 'unknown code');
  PERFORM pg_temp.ok(public.referral_apply('919600000001', 'Asha', code) ->> 'state' = 'own', 'your own code does nothing');
  PERFORM pg_temp.ok(pg_temp.bal('919600000001') = 0, 'still 0 after your own code');

  -- 3. a new friend joins: both get 30 credits, in one balanced entry
  r := public.referral_apply('919600000002', 'Bina Shah', lower(replace(code, '-', ' ')));
  PERFORM pg_temp.ok(r ->> 'state' = 'ok', 'a new friend''s code works, typed any way ("tori k7p2qx")');
  PERFORM pg_temp.ok((r ->> 'bonus_paise')::bigint = 3000 AND (r -> 'referrer' ->> 'bonus_paise')::bigint = 3000
                     AND r -> 'referrer' ->> 'wa_id' = '919600000001' AND r -> 'referrer' ->> 'name' = 'Asha'
                     AND r ->> 'friend_name' = 'Bina', 'the reply names both people and both bonuses');
  PERFORM pg_temp.ok(pg_temp.bal('919600000002') = 3000 AND pg_temp.bal('919600000001') = 3000, 'both wallets have 30 credits');
  PERFORM pg_temp.ok((SELECT count(*) FROM public.wallet_journal WHERE kind = 'referral') = 1
                     AND (SELECT sum(amount_paise) FROM public.wallet_postings WHERE account = 'tori:referrals') = -6000,
                     'one journal entry; Tori''s referral account paid ₹60');
  PERFORM pg_temp.ok(public.wallet_history((SELECT id FROM public.tori_users WHERE phone = '+919600000002')) -> 0 ->> 'kind' = 'referral'
                     AND public.wallet_history((SELECT id FROM public.tori_users WHERE phone = '+919600000002')) -> 0 ->> 'memo'
                         = 'Invite bonus: Bina joined with Asha''s code', 'history shows the invite bonus');

  -- 4. once per person
  r := public.referral_apply('919600000002', 'Bina', code);
  PERFORM pg_temp.ok(r ->> 'state' = 'already' AND (r ->> 'same_referrer')::boolean, 'the same code again → already');
  PERFORM public.tori_user('919600000003', 'Chirag');
  code_b := public.referral_invite('919600000003') ->> 'code';
  r := public.referral_apply('919600000002', 'Bina', code_b);
  PERFORM pg_temp.ok(r ->> 'state' = 'already' AND NOT (r ->> 'same_referrer')::boolean, 'another person''s code later → already');
  PERFORM pg_temp.ok(pg_temp.bal('919600000002') = 3000 AND pg_temp.bal('919600000003') = 0, 'nobody was credited again');

  -- 5. only new people, and invites can't go both ways
  r := public.referral_apply('919600000001', 'Asha', code_b);
  PERFORM pg_temp.ok(r ->> 'state' = 'not_new', 'someone on Tori for a month can''t use a code');
  r := public.referral_apply('919600000003', 'Chirag', code);      -- Chirag is new: works
  PERFORM pg_temp.ok(r ->> 'state' = 'ok' AND (r -> 'referrer' ->> 'friends')::int = 2, 'Chirag joins with Asha''s code (her 2nd friend)');
  PERFORM public.tori_user('919600000004', 'Dev');
  PERFORM public.referral_apply('919600000004', 'Dev', code_b);    -- Dev joins with Chirag's code
  r := public.referral_apply('919600000003', 'Chirag', public.referral_invite('919600000004') ->> 'code');
  PERFORM pg_temp.ok(r ->> 'state' = 'already', 'Chirag can''t also claim Dev''s code');
  PERFORM public.tori_user('919600000005', 'Esha');
  PERFORM public.referral_apply('919600000005', 'Esha', public.referral_invite('919600000004') ->> 'code');   -- Esha ← Dev
  PERFORM public.tori_user('919600000006', 'Farah');
  PERFORM public.referral_apply('919600000006', 'Farah', public.referral_invite('919600000005') ->> 'code'); -- Farah ← Esha
  -- Dev invited Esha; Dev was referred, so the "has invited people" rule is what stops a loop through new people
  PERFORM public.tori_user('919600000007', 'Gita');
  PERFORM public.referral_apply('919600000007', 'Gita', public.referral_invite('919600000006') ->> 'code');  -- Gita ← Farah
  r := public.referral_apply('919600000006', 'Farah', public.referral_invite('919600000007') ->> 'code');
  PERFORM pg_temp.ok(r ->> 'state' = 'already', 'a referred person who invites someone can''t be "re-referred" back');
  PERFORM public.tori_user('919600000008', 'Hari');
  PERFORM public.referral_invite('919600000008');
  PERFORM public.tori_user('919600000009', 'Isha');
  PERFORM public.referral_apply('919600000009', 'Isha', public.referral_invite('919600000008') ->> 'code');  -- Isha ← Hari
  r := public.referral_apply('919600000008', 'Hari', public.referral_invite('919600000009') ->> 'code');
  PERFORM pg_temp.ok(r ->> 'state' = 'not_new', 'Hari invited Isha, so Hari can''t use Isha''s code (no swapping bonuses)');
  PERFORM pg_temp.ok(pg_temp.bal('919600000008') = 3000 AND pg_temp.bal('919600000009') = 3000, 'Hari and Isha: 30 each, once');

  -- 6. a code works for wallet_referral_days after someone first messages Tori
  PERFORM public.tori_user('919600000010', 'Jai');
  UPDATE public.tori_users SET created_at = now() - interval '8 days' WHERE phone = '+919600000010';
  r := public.referral_apply('919600000010', 'Jai', code);
  PERFORM pg_temp.ok(r ->> 'state' = 'not_new' AND (r ->> 'days')::int = 7, 'joined 8 days ago → too late');
  UPDATE public.tori_users SET created_at = now() - interval '6 days' WHERE phone = '+919600000010';
  PERFORM pg_temp.ok(public.referral_apply('919600000010', 'Jai', code) ->> 'state' = 'ok', 'joined 6 days ago → still works');

  -- 7. the friend limit: the friend still gets the bonus, the referrer stops earning
  INSERT INTO public.tori_settings (key, value) VALUES ('wallet_referral_max', '3');
  PERFORM public.tori_user('919600000011', 'Kiran');
  r := public.referral_apply('919600000011', 'Kiran', code);
  PERFORM pg_temp.ok(r ->> 'state' = 'ok' AND (r ->> 'bonus_paise')::bigint = 3000
                     AND (r -> 'referrer' ->> 'bonus_paise')::bigint = 0 AND (r -> 'referrer' ->> 'limit_reached')::boolean,
                     'past the friend limit: the friend gets 30, the referrer 0');
  PERFORM pg_temp.ok(pg_temp.bal('919600000001') = 9000, 'Asha earned for 3 friends only (₹90)');
  r := public.referral_invite('919600000001');
  PERFORM pg_temp.ok((r ->> 'friends')::int = 4 AND (r ->> 'earned_paise')::bigint = 9000, 'invite shows 4 friends, ₹90 earned');
  DELETE FROM public.tori_settings WHERE key = 'wallet_referral_max';

  -- 8. the bonus amount is a setting; the wallet balance cap still holds
  INSERT INTO public.tori_settings (key, value) VALUES ('wallet_referral_bonus_paise', '5000');
  PERFORM public.wallet_post('adjustment', 'test', 'test:fill-asha', 'test', 'test',
    jsonb_build_array(jsonb_build_object('account', 'tori:razorpay', 'amount', -(1000000 - 9000 - 2000)),
                      jsonb_build_object('account', public.wallet_user_account((SELECT id FROM public.tori_users WHERE phone = '+919600000001')),
                                         'amount', 1000000 - 9000 - 2000)));     -- Asha: ₹20 under the ₹10,000 cap
  PERFORM public.tori_user('919600000012', 'Lata');
  r := public.referral_apply('919600000012', 'Lata', code);
  PERFORM pg_temp.ok((r ->> 'bonus_paise')::bigint = 5000 AND (r -> 'referrer' ->> 'bonus_paise')::bigint = 2000
                     AND NOT (r -> 'referrer' ->> 'limit_reached')::boolean, 'bonus ₹50 from settings; Asha gets ₹20, up to the cap');
  PERFORM pg_temp.ok(pg_temp.bal('919600000001') = 1000000, 'Asha is exactly at the cap');
  DELETE FROM public.tori_settings WHERE key = 'wallet_referral_bonus_paise';

  -- 9. held "your friend joined" message for a referrer outside the 24-hour window
  PERFORM public.referral_hold('919600000001', '{"type": "text", "text": {"body": "Bina joined"}}');
  PERFORM pg_temp.ok(public.tori_take_held('919600000001') -> 0 -> 'text' ->> 'body' = 'Bina joined', 'held message delivered on her next message');
  PERFORM pg_temp.ok(jsonb_array_length(public.tori_take_held('919600000001')) = 0, '… once');

  -- 10. the ledger still balances
  SELECT count(*) INTO n FROM public.referrals;
  PERFORM pg_temp.ok(n = 10, '10 referrals recorded');
  PERFORM pg_temp.ok(public.wallet_check() = '{"negative_wallets": 0, "unbalanced_journals": 0}', 'ledger invariants hold');
END $$;
ROLLBACK;
