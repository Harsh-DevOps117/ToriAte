-- Referral rules (tables: 016_referrals.sql). One transaction per call; workflow 06 only calls these.
-- Re-applied by db/migrate.sh whenever this file changes (CREATE OR REPLACE only).
--
-- Settings (wallet_cfg(), overridable in tori_settings): wallet_referral_bonus_paise (3000 = 30 credits each),
-- wallet_referral_days (a code works within 7 days of someone's first message), wallet_referral_max (50 friends).

-- This person's code (6 characters, no 0/O/1/I/L), created on first use
CREATE OR REPLACE FUNCTION public.referral_code(p_user_id uuid)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  abc constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
BEGIN
  LOOP
    SELECT code INTO c FROM public.referral_codes WHERE user_id = p_user_id;
    IF FOUND THEN
      RETURN c;
    END IF;
    SELECT string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') INTO c FROM generate_series(1, 6);
    -- taken by someone else, or this person's code was created by a concurrent call: look again
    INSERT INTO public.referral_codes (user_id, code) VALUES (p_user_id, c) ON CONFLICT DO NOTHING;
    IF FOUND THEN
      RETURN c;
    END IF;
  END LOOP;
END $$;

-- "TORI-k7p2qx", "tori k7p2qx", "K7P2QX" → 'K7P2QX'
CREATE OR REPLACE FUNCTION public.referral_normalize(p text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(upper(regexp_replace(regexp_replace(trim(coalesce(p, '')), '^tori[\s-]*', '', 'i'), '[^A-Za-z0-9]', '', 'g')), '');
$$;

CREATE OR REPLACE FUNCTION public.referral_first_name(u public.tori_users)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(split_part(trim(coalesce(u.name, '')), ' ', 1), '');
$$;

-- "invite": the person's code and what they have earned so far
CREATE OR REPLACE FUNCTION public.referral_invite(p_wa_id text, p_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg jsonb := public.wallet_cfg();
  u   public.tori_users;
BEGIN
  u := public.tori_user(p_wa_id, p_name);
  RETURN jsonb_build_object(
    'code', 'TORI-' || public.referral_code(u.id),
    'name', public.referral_first_name(u),
    'bonus_paise', (cfg ->> 'wallet_referral_bonus_paise')::bigint,
    'max_friends', (cfg ->> 'wallet_referral_max')::int,
    'friends', (SELECT count(*) FROM public.referrals WHERE referrer_id = u.id),
    'earned_paise', (SELECT coalesce(sum(referrer_bonus_paise), 0) FROM public.referrals WHERE referrer_id = u.id),
    'balance_paise', public.wallet_balance(u.id));
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- referral_apply: someone sent a message with a friend's code. Both wallets get the bonus in one journal
-- entry, at most once per person (the referrals row and the journal key 'referral:<friend>' both say so).
-- state: ok | unknown (no such code) | own (their own code) | already (referred before; same_referrer says
-- whether by this code) | not_new (on Tori for longer than wallet_referral_days, or has invited people
-- already: invites can't go both ways).
-- The referrer gets nothing past wallet_referral_max friends; nobody is credited past the wallet balance cap.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.referral_apply(p_wa_id text, p_name text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg    jsonb := public.wallet_cfg();
  bonus  bigint := (cfg ->> 'wallet_referral_bonus_paise')::bigint;
  cap    bigint := (cfg ->> 'wallet_max_balance_paise')::bigint;
  v_code text := public.referral_normalize(p_code);
  u      public.tori_users;          -- the friend who sent the code
  ref    public.tori_users;          -- who invited them
  rf     public.referrals;
  acc_u  text;
  acc_r  text;
  b_u    bigint;
  b_r    bigint;
  j      uuid;
  v_full boolean;
BEGIN
  u := public.tori_user(p_wa_id, p_name);
  SELECT t.* INTO ref FROM public.referral_codes c JOIN public.tori_users t ON t.id = c.user_id WHERE c.code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'unknown', 'code', 'TORI-' || coalesce(v_code, ''));
  END IF;
  IF ref.id = u.id THEN
    RETURN jsonb_build_object('state', 'own', 'code', 'TORI-' || v_code);
  END IF;
  SELECT * INTO rf FROM public.referrals WHERE referee_id = u.id;
  IF FOUND THEN
    RETURN jsonb_build_object('state', 'already', 'same_referrer', rf.referrer_id = ref.id,
                              'bonus_paise', rf.referee_bonus_paise, 'balance_paise', public.wallet_balance(u.id),
                              'referrer', jsonb_build_object('name', public.referral_first_name(ref)));
  END IF;
  IF u.created_at < now() - make_interval(days => (cfg ->> 'wallet_referral_days')::int)
     OR EXISTS (SELECT 1 FROM public.referrals WHERE referrer_id = u.id) THEN
    RETURN jsonb_build_object('state', 'not_new', 'days', (cfg ->> 'wallet_referral_days')::int,
                              'referrer', jsonb_build_object('name', public.referral_first_name(ref)));
  END IF;

  -- one referral at a time per referrer (the friend limit), then both wallets (the balance cap); wallet_post
  -- takes the wallet locks again, which is free
  PERFORM 1 FROM public.referral_codes WHERE user_id = ref.id FOR UPDATE;
  acc_u := public.wallet_user_account(u.id);
  acc_r := public.wallet_user_account(ref.id);
  PERFORM 1 FROM public.wallet_accounts WHERE account IN (acc_u, acc_r) ORDER BY account FOR UPDATE;
  b_u := least(bonus, greatest(cap - public.wallet_balance(u.id), 0));
  v_full := (SELECT count(*) FROM public.referrals WHERE referrer_id = ref.id) >= (cfg ->> 'wallet_referral_max')::int;
  b_r := CASE WHEN v_full THEN 0 ELSE least(bonus, greatest(cap - public.wallet_balance(ref.id), 0)) END;

  -- a second code from the same person at the same moment waits here, then finds this row
  INSERT INTO public.referrals (referrer_id, referee_id, code, referrer_bonus_paise, referee_bonus_paise)
  VALUES (ref.id, u.id, v_code, b_r, b_u)
  ON CONFLICT (referee_id) DO NOTHING
  RETURNING * INTO rf;
  IF NOT FOUND THEN
    SELECT * INTO rf FROM public.referrals WHERE referee_id = u.id;
    RETURN jsonb_build_object('state', 'already', 'same_referrer', rf.referrer_id = ref.id,
                              'bonus_paise', rf.referee_bonus_paise, 'balance_paise', public.wallet_balance(u.id),
                              'referrer', jsonb_build_object('name', public.referral_first_name(ref)));
  END IF;
  IF b_u + b_r > 0 THEN
    j := public.wallet_post('referral', rf.id::text, 'referral:' || u.id,
           format('Invite bonus: %s joined with %s''s code', coalesce(public.referral_first_name(u), 'a friend'),
                  coalesce(public.referral_first_name(ref), 'a friend')),
           'referral',
           jsonb_build_array(jsonb_build_object('account', 'tori:referrals', 'amount', -(b_u + b_r)),
                             jsonb_build_object('account', acc_u, 'amount', b_u),
                             jsonb_build_object('account', acc_r, 'amount', b_r)));
    UPDATE public.referrals SET journal_id = j WHERE id = rf.id;
  END IF;

  RETURN jsonb_build_object(
    'state', 'ok', 'bonus_paise', b_u, 'balance_paise', public.wallet_balance(u.id),
    'referrer', jsonb_build_object(
      'wa_id', ltrim(ref.phone, '+'), 'name', public.referral_first_name(ref),
      'bonus_paise', b_r, 'balance_paise', public.wallet_balance(ref.id),
      'friends', (SELECT count(*) FROM public.referrals WHERE referrer_id = ref.id),
      'limit_reached', v_full,
      -- inside WhatsApp's 24-hour window? (else the bot keeps the message for their next one)
      'last_message_at', (SELECT max(created_at) FROM public.tori_messages WHERE user_id = ref.id AND direction = 'in')),
    'friend_name', public.referral_first_name(u));
END $$;

-- "Your friend joined" for a referrer outside the 24-hour window, sent the next time they write (008)
CREATE OR REPLACE FUNCTION public.referral_hold(p_wa_id text, p_body jsonb)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.tori_held_messages (wa_id, kind, body, expires_at)
  VALUES (p_wa_id, 'referral', p_body, now() + interval '30 days');
$$;

-- Supabase exposes public functions over REST to anyone with the anon key. These are for n8n only.
DO $$
DECLARE
  f text;
  r text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'referral\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;
