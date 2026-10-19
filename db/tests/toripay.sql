-- ToriPay (013): verified payees, shortcuts, one-tap pay from the wallet, payouts, refunds, manual settlement.
-- Run: psql -v ON_ERROR_STOP=1 -f db/tests/toripay.sql against a database with 006–013 applied. Rolled back.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; RAISE NOTICE 'ok: %', msg; END $$;

DO $$
DECLARE
  uid uuid; r jsonb; f uuid; z uuid; pay uuid; pay2 uuid; pay3 uuid;
BEGIN
  -- the person has ₹1,000 in the wallet
  uid := (public.tori_user('919600000001', 'Ravi Kumar')).id;
  PERFORM public.wallet_attach_order((public.wallet_create_topup(uid, 100000) ->> 'topup_id')::uuid, 'order_P1');
  PERFORM public.wallet_credit_topup('order_P1', 'pay_P1', 100000, 'test');

  -- 1. the team adds businesses (bank details: only last 4 + IFSC stored)
  r := public.payee_upsert('{"handle": "fitzone-hsr", "display_name": "FitZone Gym", "category": "gym", "city": "Bangalore",
                             "area": "HSR Layout", "aliases": ["fitzone", "fit zone"], "owner_wa": "+91 98765 00001",
                             "account_holder": "FITZONE FITNESS PVT LTD", "account_last4": "1234", "ifsc": "hdfc0001234",
                             "rzp_fund_account_id": "fa_FIT", "commission_bps": 200}', 'admin:test');
  f := (r ->> 'payee_id')::uuid;
  PERFORM pg_temp.ok(r ->> 'bank' = 'HDFC' AND r ->> 'last4' = '1234' AND (r ->> 'has_fund_account')::boolean, 'FitZone added, IFSC normalised');
  z := (public.payee_upsert('{"handle": "zen-gym-indiranagar", "display_name": "Zen Gym", "category": "gym", "area": "Indiranagar",
                              "account_holder": "ZEN GYM", "account_last4": "9876", "ifsc": "ICIC0004321"}', 'admin:test') ->> 'payee_id')::uuid;
  PERFORM public.payee_upsert('{"handle": "green-turf", "display_name": "Green Turf", "category": "turf",
                                "account_holder": "GREEN TURF LLP", "account_last4": "5555", "ifsc": "SBIN0000001"}', 'admin:test');

  -- 2. search and shortcuts
  r := public.toripay_resolve('919600000001', 'gym');
  PERFORM pg_temp.ok(r ->> 'state' = 'many' AND jsonb_array_length(r -> 'options') = 2, '"gym": two gyms to choose from (not the turf)');
  r := public.toripay_resolve('919600000001', 'fitzone');
  PERFORM pg_temp.ok(r ->> 'state' = 'one' AND (r #>> '{payee,payee_id}')::uuid = f, '"fitzone": exactly FitZone');
  PERFORM pg_temp.ok(public.toripay_resolve('919600000001', 'spaceship') ->> 'state' = 'none', 'nothing for "spaceship"');

  -- 3. pay ₹500 to FitZone as "gym": confirm → wallet −500, FitZone owed 490, Tori keeps 10 (2 %)
  r := public.toripay_start('919600000001', f, 50000, 'gym');
  pay := (r ->> 'payment_id')::uuid;
  PERFORM pg_temp.ok(r ->> 'state' = 'ok' AND (r ->> 'enough')::boolean AND (r ->> 'commission_paise')::bigint = 1000,
                     'confirm screen: ₹500, 2 % commission, enough credits');
  PERFORM pg_temp.ok(public.toripay_confirm(pay, '919600000002') ->> 'state' = 'unknown', 'someone else cannot confirm it');
  r := public.toripay_confirm(pay, '919600000001');
  PERFORM pg_temp.ok(r ->> 'state' = 'paid' AND (r ->> 'balance_paise')::bigint = 50000 AND (r ->> 'net_paise')::bigint = 49000
                     AND r #>> '{payout,fund_account_id}' = 'fa_FIT' AND r ->> 'owner_wa' = '919876500001', 'one tap: paid, ₹500 left, ₹490 to send');
  PERFORM pg_temp.ok(public.toripay_confirm(pay, '919600000001') ->> 'state' = 'already_paid' AND public.wallet_balance(uid) = 50000,
                     'a second tap pays nothing');
  r := public.toripay_resolve('919600000001', 'gym');
  PERFORM pg_temp.ok(r ->> 'state' = 'favourite' AND (r #>> '{payee,payee_id}')::uuid = f, '"gym" is now a shortcut to FitZone');
  PERFORM pg_temp.ok((SELECT sum(amount_paise) FROM wallet_postings WHERE account = 'payee:' || f) = 49000
                     AND (SELECT sum(amount_paise) FROM wallet_postings WHERE account = 'tori:revenue') = 1000, 'ledger: FitZone owed ₹490, Tori ₹10');

  -- 4. payout processed → settled; the webhook again changes nothing
  PERFORM public.payout_mark(pay, 'pout_1');
  PERFORM pg_temp.ok((public.payout_settled('pout_1', 'processed') ->> 'state') = 'settled', 'payout processed: settled');
  PERFORM pg_temp.ok((public.payout_settled('pout_1', 'processed') ->> 'state') = 'already', 'the same webhook again: nothing');
  PERFORM pg_temp.ok((SELECT coalesce(sum(amount_paise), 0) FROM wallet_postings WHERE account = 'payee:' || f) = 0, 'nothing owed to FitZone now');

  -- 5. a payout that fails refunds the whole amount (commission too)
  pay2 := (public.toripay_start('919600000001', f, 20000, 'gym') ->> 'payment_id')::uuid;
  PERFORM public.toripay_confirm(pay2, '919600000001');
  PERFORM public.payout_mark(pay2, 'pout_2');
  r := public.payout_settled('pout_2', 'reversed', 'beneficiary bank down');
  PERFORM pg_temp.ok(r ->> 'state' = 'refunded' AND (r ->> 'balance_paise')::bigint = 50000 AND r ->> 'wa_id' = '919600000001',
                     'payout reversed: ₹200 back in the wallet');

  -- 6. not enough, expired, cancelled, suspended
  pay3 := (public.toripay_start('919600000001', z, 90000, 'zen') ->> 'payment_id')::uuid;
  r := public.toripay_confirm(pay3, '919600000001');
  PERFORM pg_temp.ok(r ->> 'state' = 'insufficient' AND (r ->> 'short_paise')::bigint = 40000, '₹900 with ₹500: ₹400 short');
  PERFORM pg_temp.ok(public.toripay_cancel(pay3, '919600000001') ->> 'state' = 'cancelled', 'cancelled');
  pay3 := (public.toripay_start('919600000001', z, 1000, NULL) ->> 'payment_id')::uuid;
  UPDATE payee_payments SET expires_at = now() - interval '1 minute' WHERE id = pay3;
  PERFORM pg_temp.ok(public.toripay_confirm(pay3, '919600000001') ->> 'state' = 'expired', 'expired confirm screen: not paid');
  PERFORM pg_temp.ok(public.toripay_start('919600000001', z, 50, NULL) ->> 'state' = 'bad_amount', 'under ₹1 refused');
  pay3 := (public.toripay_start('919600000001', z, 1000, NULL) ->> 'payment_id')::uuid;
  PERFORM public.payee_upsert('{"handle": "zen-gym-indiranagar", "display_name": "Zen Gym", "category": "gym", "account_holder": "ZEN GYM",
                                "account_last4": "9876", "ifsc": "ICIC0004321", "status": "suspended"}', 'admin:test');
  PERFORM pg_temp.ok(public.toripay_confirm(pay3, '919600000001') ->> 'state' = 'unavailable', 'a suspended business cannot be paid');
  PERFORM pg_temp.ok(public.toripay_resolve('919600000001', 'gym') ->> 'state' = 'favourite', 'search hides suspended ones; the shortcut still works');

  -- 7. no RazorpayX yet: owed report and manual settlement
  PERFORM public.payee_upsert('{"handle": "green-turf", "display_name": "Green Turf", "category": "turf", "account_holder": "GREEN TURF LLP",
                                "account_last4": "5555", "ifsc": "SBIN0000001"}', 'admin:test');
  pay3 := (public.toripay_start('919600000001', (SELECT id FROM payees WHERE handle = 'green-turf'), 30000, 'turf') ->> 'payment_id')::uuid;
  r := public.toripay_confirm(pay3, '919600000001');
  PERFORM pg_temp.ok(r ->> 'state' = 'paid' AND r -> 'payout' = 'null'::jsonb OR (r ->> 'payout') IS NULL, 'no fund account: paid, nothing to send yet');
  r := public.payees_owed();
  PERFORM pg_temp.ok(r -> 0 ->> 'handle' = 'green-turf' AND (r -> 0 ->> 'owed_paise')::bigint = 30000, 'report: Green Turf is owed ₹300');
  r := public.payee_settle_manual('green-turf', 'admin:test', 'NEFT UTR123');
  PERFORM pg_temp.ok((r ->> 'settled_payments')::int = 1 AND (r ->> 'settled_paise')::bigint = 30000, 'settled by hand: 1 payment, ₹300');
  PERFORM pg_temp.ok(jsonb_array_length(public.payees_owed()) = 0, 'nothing owed any more');

  -- 8. shortcuts: list, point elsewhere ("gym edit"), remove; invariants
  PERFORM public.user_payee_set('919600000001', 'gym', (SELECT id FROM payees WHERE handle = 'green-turf'));
  PERFORM pg_temp.ok(public.toripay_resolve('919600000001', 'gym') #>> '{payee,handle}' = 'green-turf', '"gym edit" points the shortcut elsewhere');
  PERFORM pg_temp.ok(jsonb_array_length(public.user_payee_list('919600000001')) = 2, 'two shortcuts: gym, turf');
  PERFORM pg_temp.ok(public.user_payee_remove('919600000001', 'turf'), '"turf" shortcut removed');
  PERFORM pg_temp.ok(jsonb_array_length(public.user_payee_list('919600000001')) = 1, 'one shortcut left');
  -- 9. the bot's entry point
  PERFORM public.payee_upsert('{"handle": "zen-gym-indiranagar", "display_name": "Zen Gym", "category": "gym", "area": "Indiranagar",
                                "account_holder": "ZEN GYM", "account_last4": "9876", "ifsc": "ICIC0004321"}', 'admin:test');
  r := public.toripay_bot('919600000003', 'Asha', '{"action": "pay", "word": "gym", "amount_paise": 50000}');
  PERFORM pg_temp.ok(r ->> 'kind' = 'choose' AND jsonb_array_length(r -> 'options') = 2, 'bot: "tori pay gym 500" with no shortcut → choose');
  r := public.toripay_bot('919600000003', 'Asha', jsonb_build_object('action', 'pick', 'payee_id', z, 'amount_paise', 50000, 'nickname', 'gym'));
  PERFORM pg_temp.ok(r ->> 'kind' = 'confirm' AND NOT (r ->> 'enough')::boolean AND r #>> '{link,token}' IS NOT NULL,
                     'bot: picked Zen Gym, ₹0 wallet → confirm with an add-credits link');
  PERFORM pg_temp.ok(public.toripay_bot('919600000003', 'Asha', jsonb_build_object('action', 'confirm', 'payment_id', r ->> 'payment_id'))
                     ->> 'state' = 'insufficient', 'bot: Pay with ₹0 → insufficient');
  r := public.toripay_bot('919600000001', NULL, '{"action": "pay", "word": "gym", "amount_paise": 10000}');
  PERFORM pg_temp.ok(r ->> 'kind' = 'confirm' AND r #>> '{payee,handle}' = 'green-turf' AND r -> 'link' = 'null'::jsonb,
                     'bot: shortcut "gym" → straight to confirm');
  PERFORM pg_temp.ok(public.toripay_bot('919600000001', NULL, '{"action": "pay", "word": "gym"}') ->> 'kind' = 'need_amount', 'bot: no amount → ask');
  r := public.toripay_bot('919600000001', NULL, '{"action": "edit", "word": "gym"}');
  PERFORM pg_temp.ok(r ->> 'kind' = 'edit' AND r #>> '{current,handle}' = 'green-turf' AND jsonb_array_length(r -> 'options') = 2, 'bot: "gym edit" → current + gyms');
  PERFORM pg_temp.ok(public.toripay_bot('919600000001', NULL, jsonb_build_object('action', 'edit_pick', 'payee_id', z, 'nickname', 'gym')) ->> 'kind' = 'saved'
                     AND public.toripay_resolve('919600000001', 'gym') #>> '{payee,handle}' = 'zen-gym-indiranagar', 'bot: picked → "gym" is Zen Gym');
  PERFORM pg_temp.ok(public.toripay_bot('919600000001', NULL, '{"action": "remove", "word": "Gym"}') ->> 'kind' = 'removed', 'bot: removed');
  PERFORM pg_temp.ok(public.toripay_nickname('Fit  Zone') = 'fit zone' AND public.toripay_nickname('fit''s gym') IS NULL, 'nicknames cleaned');
  r := public.toripay_start('919600000001', z, 1000, 'fit''s gym');
  PERFORM pg_temp.ok(public.toripay_confirm((r ->> 'payment_id')::uuid, '919600000001') ->> 'state' = 'paid', 'an odd word still pays (no shortcut saved)');
  -- 10. adding a payee on WhatsApp: name → IFSC → holder → account → account again
  r := public.toripay_bot('919600000004', 'Meera', '{"action": "pay", "word": "yoga studio", "amount_paise": 20000}');
  PERFORM pg_temp.ok(r ->> 'kind' = 'add_step' AND r ->> 'step' = 'name' AND r ->> 'nickname' = 'yoga studio',
                     'unknown business → "what is it called?"');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"text": "Y"}') ->> 'error' = 'name', 'a one-letter name is refused');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"text": "Shanti Yoga, HSR"}') ->> 'step' = 'ifsc', 'name → IFSC');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"ifsc": "HDFC123"}') ->> 'error' = 'ifsc', 'a bad IFSC is refused');
  r := public.toripay_draft_answer('919600000004', '{"ifsc": "hdfc0001234", "bank": "HDFC Bank", "branch": "HSR Layout"}');
  PERFORM pg_temp.ok(r ->> 'step' = 'holder' AND r ->> 'bank_name' = 'HDFC Bank', 'IFSC → bank found → holder');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"text": "Shanti Yoga LLP"}') ->> 'step' = 'account', 'holder → account');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"text": "12 34"}') ->> 'error' = 'account', 'a short number is refused');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"text": "5010 0123 4567 89"}') ->> 'step' = 'account_confirm', 'account → once more');
  PERFORM pg_temp.ok((SELECT count(*) FROM toripay_drafts WHERE row_to_json(toripay_drafts)::text LIKE '%50100123456789%') = 0,
                     'the draft keeps a hash, not the number');
  r := public.toripay_draft_check('919600000004', '50100123456780');
  PERFORM pg_temp.ok(r ->> 'error' = 'mismatch' AND r ->> 'step' = 'account', 'a different second number → ask again');
  PERFORM public.toripay_draft_answer('919600000004', '{"text": "50100123456789"}');
  r := public.toripay_draft_check('919600000004', '50100123456789');
  PERFORM pg_temp.ok((r ->> 'ok')::boolean AND r ->> 'handle' LIKE 'u-%' AND r ->> 'holder' = 'SHANTI YOGA LLP', 'numbers match → ready for RazorpayX');
  r := public.toripay_draft_finish('919600000004', 'cont_X', 'fa_SHANTI');
  PERFORM pg_temp.ok(r ->> 'kind' = 'confirm' AND (r ->> 'added')::boolean AND r #>> '{payee,name}' = 'Shanti Yoga, HSR'
                     AND (r #>> '{payee,self_added}')::boolean AND r #>> '{payee,bank}' = 'HDFC Bank' AND (r ->> 'amount_paise')::bigint = 20000,
                     'saved → straight to [Pay ₹200]');
  PERFORM pg_temp.ok(public.toripay_resolve('919600000004', 'yoga studio') ->> 'state' = 'favourite', '"yoga studio" is their shortcut');
  PERFORM pg_temp.ok(public.payee_search('shanti', 10) = '[]'::jsonb, 'nobody else finds it in search');
  PERFORM pg_temp.ok(public.toripay_start('919600000001', (r #>> '{payee,payee_id}')::uuid, 1000, NULL) ->> 'state' = 'unavailable',
                     'nobody else can pay it');
  PERFORM pg_temp.ok(public.user_payee_set('919600000001', 'x', (r #>> '{payee,payee_id}')::uuid) ->> 'state' = 'unknown',
                     '…or save it as their shortcut');
  r := public.toripay_bot('919600000004', NULL, '{"action": "add", "nickname": "yoga studio", "fix": true}');
  PERFORM pg_temp.ok(r ->> 'step' = 'name' AND (r ->> 'fixing')::boolean AND r ->> 'display_name' = 'Shanti Yoga, HSR', '"change bank details" starts again');
  PERFORM pg_temp.ok(public.toripay_draft_answer('919600000004', '{"text": "same"}') ->> 'display_name' = 'Shanti Yoga, HSR', '"same" keeps the name');
  PERFORM public.toripay_draft_answer('919600000004', '{"ifsc": "ICIC0004321", "bank": "ICICI Bank"}');
  PERFORM public.toripay_draft_answer('919600000004', '{"text": "Shanti Yoga LLP"}');
  PERFORM public.toripay_draft_answer('919600000004', '{"text": "000111222333"}');
  PERFORM public.toripay_draft_check('919600000004', '000111222333');
  r := public.toripay_draft_finish('919600000004', 'cont_Y', 'fa_SHANTI2');
  PERFORM pg_temp.ok(r ->> 'kind' = 'added' AND (r ->> 'fixed')::boolean AND r #>> '{payee,last4}' = '2333'
                     AND (SELECT rzp_fund_account_id FROM payees WHERE id = (r #>> '{payee,payee_id}')::uuid) = 'fa_SHANTI2', 'new bank details saved');
  PERFORM pg_temp.ok(public.toripay_bot('919600000001', NULL, '{"action": "add", "nickname": "gym", "fix": true}') ->> 'kind' = 'not_found',
                     'only payees you added can be changed by you');
  PERFORM public.toripay_bot('919600000004', NULL, '{"action": "add", "nickname": "coach"}');
  PERFORM pg_temp.ok(public.toripay_draft_cancel('919600000004') ->> 'kind' = 'add_cancelled', 'cancel');
  PERFORM pg_temp.ok(public.toripay_draft_get('919600000004') IS NULL, 'nothing left after cancel');
  -- the message log hides account numbers typed at those steps
  PERFORM public.toripay_bot('919600000004', NULL, '{"action": "add", "nickname": "coach"}');
  UPDATE toripay_drafts SET step = 'account' WHERE user_id = (SELECT id FROM tori_users WHERE phone = '+919600000004');
  r := public.tori_log_inbound('919600000004', 'Meera', 'wamid.TPACC1', 'text', '50100123456789');
  PERFORM pg_temp.ok(r ->> 'toripay_step' = 'account' AND (SELECT body FROM tori_messages WHERE wa_message_id = 'wamid.TPACC1') = '[bank account number]',
                     'inbound log: "[bank account number]", and the bot knows the step');
  r := public.wallet_check();
  PERFORM pg_temp.ok((r ->> 'unbalanced_journals')::int = 0 AND (r ->> 'negative_wallets')::int = 0, 'ledger invariants hold');
  PERFORM pg_temp.ok(public.wallet_balance(uid) = 19000, 'final balance ₹190 (1000 − 500 − 300 − 10)');
END $$;
ROLLBACK;
