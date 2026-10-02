SET client_min_messages = warning;

DROP TYPE IF EXISTS tori.slot_in CASCADE;
CREATE TYPE tori.slot_in AS (
  court_id    bigint,
  court_label text,
  court_key   text,
  starts_at   timestamptz,
  ends_at     timestamptz,
  reasons     text[]
);

CREATE OR REPLACE FUNCTION tori.cfg(p_key text) RETURNS text
LANGUAGE sql STABLE AS $$ SELECT value FROM tori.setting WHERE key = p_key $$;

CREATE OR REPLACE FUNCTION tori.court_key(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(
           regexp_replace(lower(coalesce(p, '')), '(^|[^0-9])0+([0-9])', '\1\2', 'g'),
           '[^a-z0-9]+', '', 'g')
$$;

CREATE OR REPLACE FUNCTION tori.mask_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p IS NULL OR btrim(p) = '' THEN NULL
    WHEN p ~ '[xX*•]' THEN btrim(p)
    WHEN length(regexp_replace(p, '\D', '', 'g')) < 4 THEN NULL
    ELSE '******' || right(regexp_replace(p, '\D', '', 'g'), 4)
  END
$$;

CREATE OR REPLACE FUNCTION tori.short_name(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  WITH w AS (SELECT regexp_split_to_array(btrim(coalesce(p, '')), '\s+') AS parts)
  SELECT CASE
    WHEN btrim(coalesce(p, '')) = '' THEN 'Customer'
    WHEN cardinality(parts) = 1 THEN parts[1]
    ELSE parts[1] || ' ' || upper(left(parts[cardinality(parts)], 1)) || '.'
  END FROM w
$$;

CREATE OR REPLACE FUNCTION tori.fmt_slot(p_court text, p_start timestamptz, p_end timestamptz, p_tz text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT p_court || ' · ' || to_char(p_start AT TIME ZONE p_tz, 'Dy DD Mon, FMHH12:MI AM')
         || '–' || to_char(p_end AT TIME ZONE p_tz, 'FMHH12:MI AM')
$$;

CREATE OR REPLACE FUNCTION tori.reason_text(p text[]) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT string_agg(CASE r
    WHEN 'unknown_court'  THEN 'court name is not in Tori''s list for this venue'
    WHEN 'outside_hours'  THEN 'outside opening hours'
    WHEN 'odd_duration'   THEN 'unusual duration'
    WHEN 'in_past'        THEN 'date is in the past'
    WHEN 'far_future'     THEN 'date is far in the future'
    WHEN 'low_confidence' THEN 'parser was unsure'
    ELSE r END, '; ')
  FROM unnest(p) r
$$;

CREATE OR REPLACE FUNCTION tori.match_court(p_venue_id bigint, p_label text) RETURNS bigint
LANGUAGE sql STABLE AS $$
  WITH k AS (SELECT tori.court_key(p_label) AS key),
  exact AS (
    SELECT c.id FROM tori.court c, k
    WHERE c.venue_id = p_venue_id AND c.active AND k.key <> ''
      AND (tori.court_key(c.name) = k.key
           OR tori.court_key(c.display_name) = k.key
           OR EXISTS (SELECT 1 FROM unnest(c.aliases) a WHERE tori.court_key(a) = k.key))
    ORDER BY c.id),
  suffix AS (
    SELECT c.id FROM tori.court c, k
    WHERE c.venue_id = p_venue_id AND c.active AND length(k.key) >= 2
      AND (tori.court_key(c.name) LIKE '%' || k.key OR k.key LIKE '%' || tori.court_key(c.name)))
  SELECT coalesce((SELECT id FROM exact LIMIT 1),
                  (SELECT min(id) FROM suffix HAVING count(*) = 1))
$$;


CREATE OR REPLACE FUNCTION tori.source_for_sender(p_from text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT code FROM tori.booking_source WHERE lower(btrim(coalesce(p_from, ''))) ~ sender_regex ORDER BY code LIMIT 1
$$;

CREATE OR REPLACE FUNCTION tori.source_label(p_source text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT label FROM tori.booking_source WHERE code = p_source), p_source, 'Booking')
$$;

CREATE OR REPLACE FUNCTION tori.enqueue_calendar(p_kind text, p_venue_id bigint, p_ref text, p_payload jsonb DEFAULT '{}')
RETURNS void LANGUAGE sql AS $$
  INSERT INTO tori.outbox (kind, venue_id, ref, payload)
  VALUES (p_kind, p_venue_id, p_ref, p_payload)
  ON CONFLICT (kind, ref) WHERE status = 'pending' AND ref IS NOT NULL
  DO UPDATE SET next_attempt_at = least(tori.outbox.next_attempt_at, now()),
                payload = EXCLUDED.payload,
                updated_at = now()
$$;

CREATE OR REPLACE FUNCTION tori.notify(p_venue_id bigint, p_audience text, p_event text,
                                       p_text text, p_params jsonb, p_dedupe text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    WITH t AS (
      SELECT t.* FROM tori.venue v JOIN tori.tenant t ON t.id = v.tenant_id WHERE v.id = p_venue_id),
    am AS (
      SELECT s.* FROM t JOIN tori.staff s ON s.id = t.account_manager_id WHERE s.active),
    rcpt AS (
      SELECT 'owner' AS role, t.owner_name AS name, t.owner_whatsapp AS whatsapp
        FROM t WHERE p_audience IN ('booking', 'owner') AND t.notify_owner
      UNION ALL
      SELECT 'account_manager', am.name, am.whatsapp
        FROM am WHERE p_audience = 'ops' OR (p_audience = 'booking' AND am.copy_bookings)
      UNION ALL
      SELECT 'ops_default', s.name, s.whatsapp
        FROM tori.staff s
        WHERE p_audience = 'ops' AND s.active AND s.is_ops_default AND NOT EXISTS (SELECT 1 FROM am))
    SELECT DISTINCT ON (wa) role, name, wa
    FROM (SELECT role, name, regexp_replace(whatsapp, '\D', '', 'g') AS wa FROM rcpt) x
    WHERE wa IS NOT NULL AND wa <> ''
  LOOP
    INSERT INTO tori.outbox (kind, venue_id, payload, dedupe_key, max_attempts)
    VALUES ('whatsapp.send', p_venue_id,
            jsonb_build_object('to', r.wa, 'name', r.name, 'role', r.role, 'event', p_event,
                               'text', p_text, 'params', p_params),
            p_dedupe || ':' || r.wa, 5)
    ON CONFLICT (dedupe_key) DO NOTHING;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION tori.raise_alert(p_venue_id bigint, p_kind text, p_severity text, p_message text,
                                            p_details jsonb DEFAULT '{}', p_raw_id bigint DEFAULT NULL,
                                            p_booking_id uuid DEFAULT NULL, p_dedupe text DEFAULT NULL,
                                            p_notify boolean DEFAULT true)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
  v_name text;
  v_owner text;
BEGIN
  INSERT INTO tori.alert (venue_id, kind, severity, message, details, raw_message_id, booking_id, dedupe_key)
  VALUES (p_venue_id, p_kind, p_severity, p_message, coalesce(p_details, '{}'), p_raw_id, p_booking_id, p_dedupe)
  ON CONFLICT (dedupe_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL AND p_notify THEN
    SELECT v.name, concat_ws(' · ', t.owner_name, t.owner_whatsapp)
      INTO v_name, v_owner
      FROM tori.venue v LEFT JOIN tori.tenant t ON t.id = v.tenant_id WHERE v.id = p_venue_id;
    PERFORM tori.notify(p_venue_id, 'ops', 'alert',
      CASE p_severity WHEN 'critical' THEN '🚨' WHEN 'warn' THEN '⚠️' ELSE 'ℹ️' END
        || ' *Tori alert* · ' || coalesce(v_name, 'unknown venue') || E'\n\n' || p_message
        || coalesce(E'\n\n📞 Owner: ' || nullif(v_owner, ''), '')
        || E'\nAlert #' || v_id,
      jsonb_build_array(coalesce(v_name, 'unknown venue'), p_kind, p_message),
      'alert:' || v_id);
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION tori.refresh_clashes(p_slot_id uuid) RETURNS uuid[]
LANGUAGE plpgsql AS $$
DECLARE
  s tori.booking_slot%ROWTYPE;
  v_now uuid[];
  v_added uuid[];
  v_removed uuid[];
  x uuid;
BEGIN
  SELECT * INTO s FROM tori.booking_slot WHERE id = p_slot_id;
  IF s.status = 'active' AND s.court_id IS NOT NULL THEN
    SELECT coalesce(array_agg(o.id ORDER BY o.id), '{}') INTO v_now
    FROM tori.booking_slot o
    WHERE o.status = 'active' AND o.court_id = s.court_id AND o.booking_id <> s.booking_id
      AND tstzrange(o.starts_at, o.ends_at) && tstzrange(s.starts_at, s.ends_at);
  ELSE
    v_now := '{}';
  END IF;

  v_added   := ARRAY(SELECT unnest(v_now) EXCEPT SELECT unnest(s.clash_with));
  v_removed := ARRAY(SELECT unnest(s.clash_with) EXCEPT SELECT unnest(v_now));
  IF cardinality(v_added) = 0 AND cardinality(v_removed) = 0 THEN
    RETURN v_added;
  END IF;

  UPDATE tori.booking_slot SET clash_with = v_now, updated_at = now() WHERE id = s.id;
  FOREACH x IN ARRAY v_added LOOP
    UPDATE tori.booking_slot
       SET clash_with = ARRAY(SELECT DISTINCT unnest(clash_with || s.id)), updated_at = now()
     WHERE id = x;
    PERFORM tori.enqueue_calendar('calendar.sync_slot', s.venue_id, x::text);
  END LOOP;
  FOREACH x IN ARRAY v_removed LOOP
    UPDATE tori.booking_slot SET clash_with = array_remove(clash_with, s.id), updated_at = now() WHERE id = x;
    PERFORM tori.enqueue_calendar('calendar.sync_slot', s.venue_id, x::text);
  END LOOP;
  PERFORM tori.enqueue_calendar('calendar.sync_slot', s.venue_id, s.id::text);
  RETURN v_added;
END $$;

CREATE OR REPLACE FUNCTION tori.store_raw_message(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v tori.venue%ROWTYPE;
  v_provider text := coalesce(nullif(p ->> 'provider', ''), 'postmark');
  v_from text := lower(btrim(coalesce(p ->> 'from_address', '')));
  v_to text := lower(btrim(coalesce(p ->> 'inbound_address', '')));
  v_fwd text := lower(nullif(btrim(p ->> 'forwarded_for'), ''));
  v_msgid text := nullif(btrim(p ->> 'message_id_header'), '');
  v_text text := coalesce(p ->> 'text_body', '');
  v_kind text;
  v_source text;
  v_label text;
  v_id bigint;
  v_code text;
  v_owner text;
  v_email_date timestamptz;
BEGIN
  SELECT * INTO v FROM tori.venue WHERE inbound_address = v_to;

  IF v_msgid IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('raw:' || coalesce(v.id::text, '-') || ':' || v_msgid));
  END IF;

  IF v_from = lower(tori.cfg('gmail_verification_sender')) THEN
    v_kind := 'gmail_verification';
  ELSE
    v_source := tori.source_for_sender(v_from);
    IF v_source IS NOT NULL THEN
      v_kind := 'booking_email';
    ELSIF v.owner_gmail IS NOT NULL AND v_from = lower(v.owner_gmail) THEN
      SELECT code INTO v_source FROM tori.booking_source WHERE v_text ~* forwarded_from_regex ORDER BY code LIMIT 1;
      v_kind := CASE WHEN v_source IS NOT NULL THEN 'manual_forward' END;
    END IF;
  END IF;
  v_kind := coalesce(v_kind, 'other');
  v_label := tori.source_label(v_source);

  BEGIN
    v_email_date := nullif(p ->> 'email_date', '')::timestamptz;
  EXCEPTION WHEN others THEN
    v_email_date := NULL;
  END;

  INSERT INTO tori.raw_message (provider, provider_message_id, message_id_header, venue_id, inbound_address,
                                from_address, from_name, forwarded_for, subject, text_body, html_body,
                                headers, payload, email_date, kind, source)
  VALUES (v_provider, coalesce(nullif(p ->> 'provider_message_id', ''), md5(p::text)), v_msgid, v.id, v_to,
          v_from, p ->> 'from_name', v_fwd, p ->> 'subject', p ->> 'text_body', p ->> 'html_body',
          coalesce(p -> 'headers', '{}'), coalesce(p -> 'payload', p), v_email_date, v_kind, v_source)
  ON CONFLICT (provider, provider_message_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM tori.raw_message
    WHERE provider = v_provider AND provider_message_id = p ->> 'provider_message_id';
    RETURN jsonb_build_object('raw_id', v_id, 'action', 'ignore', 'reason', 'provider retry of a stored email');
  END IF;

  IF v_msgid IS NOT NULL AND EXISTS (
       SELECT 1 FROM tori.raw_message
       WHERE venue_id IS NOT DISTINCT FROM v.id AND message_id_header = v_msgid
         AND id <> v_id AND status <> 'duplicate') THEN
    UPDATE tori.raw_message SET status = 'duplicate', status_reason = 'same Message-ID already received',
           processed_at = now() WHERE id = v_id;
    RETURN jsonb_build_object('raw_id', v_id, 'action', 'ignore', 'reason', 'duplicate email');
  END IF;

  IF v.id IS NULL THEN
    UPDATE tori.raw_message SET status = 'rejected', status_reason = 'unknown inbound address',
           processed_at = now() WHERE id = v_id;
    PERFORM tori.raise_alert(NULL, 'unknown_address', 'warn',
      'Email to unknown address ' || v_to || ' from ' || v_from || ' (subject: ' || coalesce(p ->> 'subject', '') || ').',
      jsonb_build_object('to', v_to, 'from', v_from), v_id, NULL, 'unknown_address:' || v_to || ':' || current_date);
    RETURN jsonb_build_object('raw_id', v_id, 'action', 'ignore', 'reason', 'unknown inbound address');
  END IF;

  IF v_kind = 'gmail_verification' THEN
    v_code := coalesce(substring(p ->> 'subject' FROM '#([0-9]{4,})'),
                       substring(v_text FROM '(?i)confirmation code:?\s*([0-9]{4,})'));
    v_owner := lower(substring(p ->> 'subject' FROM '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)'));
    UPDATE tori.venue
       SET forwarding_code = v_code, forwarding_code_at = now(),
           owner_gmail = coalesce(owner_gmail, v_owner), updated_at = now()
     WHERE id = v.id;
    UPDATE tori.raw_message SET status = 'applied', status_reason = 'gmail forwarding code ' || coalesce(v_code, '?'),
           processed_at = now() WHERE id = v_id;
    PERFORM tori.raise_alert(v.id, 'forwarding_code', 'info',
      'Gmail forwarding code for ' || v.name || ': ' || coalesce(v_code, '(not found, open email #' || v_id || ')')
        || coalesce(' — requested by ' || v_owner, '') || '. Read it out to the owner (step B2).',
      jsonb_build_object('code', v_code, 'owner_gmail', v_owner), v_id, NULL, 'forwarding_code:' || v_id, true);
    RETURN jsonb_build_object('raw_id', v_id, 'action', 'dispatch', 'reason', 'gmail forwarding code', 'code', v_code);
  END IF;

  IF v_kind = 'other' THEN
    UPDATE tori.raw_message SET status = 'rejected', status_reason = 'sender is not a booking platform', processed_at = now()
     WHERE id = v_id;
    PERFORM tori.raise_alert(v.id, 'unknown_sender', 'warn',
      'Email from ' || v_from || ' (not ' || (SELECT string_agg(label, '/' ORDER BY label) FROM tori.booking_source)
        || ') reached ' || v.name || '''s address and was ignored. '
        || 'If a platform changed sender, update tori.booking_source.sender_regex and reprocess email #' || v_id || '.',
      jsonb_build_object('from', v_from, 'subject', p ->> 'subject'), v_id, NULL,
      'unknown_sender:' || v.id || ':' || v_from || ':' || current_date);
    RETURN jsonb_build_object('raw_id', v_id, 'action', 'ignore', 'reason', 'sender is not a booking platform');
  END IF;

  IF v_kind = 'booking_email' AND v.owner_gmail IS NOT NULL AND v_fwd IS NOT NULL
     AND position(lower(v.owner_gmail) IN v_fwd) = 0 THEN
    UPDATE tori.raw_message SET status = 'rejected', status_reason = 'forwarded by ' || v_fwd || ', expected ' || v.owner_gmail,
           processed_at = now() WHERE id = v_id;
    PERFORM tori.raise_alert(v.id, 'wrong_forwarder', 'critical',
      'A ' || v_label || ' email for ' || v.name || ' was forwarded by ' || v_fwd || ' instead of ' || v.owner_gmail
        || '. Ignored. If the owner changed Gmail, update venue.owner_gmail and reprocess email #' || v_id || '.',
      jsonb_build_object('forwarded_for', v_fwd), v_id, NULL, 'wrong_forwarder:' || v_id);
    RETURN jsonb_build_object('raw_id', v_id, 'action', 'ignore', 'reason', 'forwarded by an unexpected Gmail');
  END IF;

  UPDATE tori.venue SET last_booking_email_at = now(), updated_at = now() WHERE id = v.id;
  UPDATE tori.raw_message SET status = 'pending_parse' WHERE id = v_id;
  RETURN jsonb_build_object('raw_id', v_id, 'action', 'parse', 'venue_id', v.id, 'kind', v_kind, 'source', v_source);
END $$;

CREATE OR REPLACE FUNCTION tori.parse_input(p_raw_id bigint) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'raw_id', r.id,
    'status', r.status,
    'venue_id', v.id,
    'venue_name', v.name,
    'source', r.source,
    'source_label', tori.source_label(r.source),
    'timezone', v.timezone,
    'received_local', to_char(r.received_at AT TIME ZONE v.timezone, 'Dy DD Mon YYYY HH24:MI'),
    'courts', coalesce((SELECT jsonb_agg(c.name ORDER BY c.sort, c.id)
                        FROM tori.court c WHERE c.venue_id = v.id AND c.active), '[]'),
    'from', r.from_address,
    'subject', r.subject,
    'text', coalesce(nullif(r.text_body, ''), r.html_body, ''))
  FROM tori.raw_message r JOIN tori.venue v ON v.id = r.venue_id
  WHERE r.id = p_raw_id
$$;

CREATE OR REPLACE FUNCTION tori.resolve_notes(p_raw_id bigint) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE n tori.calendar_note%ROWTYPE;
BEGIN
  FOR n IN UPDATE tori.calendar_note SET status = 'resolved'
           WHERE raw_message_id = p_raw_id AND status = 'active' RETURNING * LOOP
    PERFORM tori.enqueue_calendar('calendar.note', n.venue_id, n.id::text);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION tori.mark_unreadable(p_raw_id bigint, p_reason text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r tori.raw_message%ROWTYPE;
  v tori.venue%ROWTYPE;
  v_note uuid := gen_random_uuid();
  v_src text;
BEGIN
  SELECT * INTO r FROM tori.raw_message WHERE id = p_raw_id;
  SELECT * INTO v FROM tori.venue WHERE id = r.venue_id;
  v_src := tori.source_label(r.source);
  UPDATE tori.raw_message SET status = 'parse_failed', status_reason = p_reason, processed_at = now() WHERE id = r.id;

  INSERT INTO tori.calendar_note (id, venue_id, raw_message_id, note_date, title, description, gcal_event_id)
  VALUES (v_note, v.id, r.id, (r.received_at AT TIME ZONE v.timezone)::date,
          '⚠️ Check ' || v_src || ' email',
          'Tori could not read a ' || v_src || ' email, so a booking or cancellation may be missing from this calendar. '
            || 'Please check the ' || v_src || ' app before selling walk-in slots.' || E'\n\n'
            || 'Subject: ' || coalesce(r.subject, '(none)') || E'\n'
            || 'Received: ' || to_char(r.received_at AT TIME ZONE v.timezone, 'DD Mon YYYY, HH24:MI') || E'\n'
            || 'Tori reference: email #' || r.id,
          'torinote' || replace(v_note::text, '-', ''))
  ON CONFLICT (raw_message_id) DO UPDATE SET status = 'active'
  RETURNING id INTO v_note;
  PERFORM tori.enqueue_calendar('calendar.note', v.id, v_note::text);

  PERFORM tori.raise_alert(v.id, 'unreadable', 'critical',
    'Could not read a ' || v_src || ' email (' || p_reason || '). Subject: "' || coalesce(r.subject, '') || '". '
      || 'A "Check ' || v_src || ' email" note is in the calendar. Fix the booking by hand, then reprocess email #' || r.id || '.',
    jsonb_build_object('reason', p_reason), r.id, NULL, 'unreadable:' || r.id);
  RETURN jsonb_build_object('raw_id', r.id, 'action', 'unreadable', 'reason', p_reason);
END $$;

CREATE OR REPLACE FUNCTION tori.apply_parse(p_raw_id bigint, p_parse jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  r tori.raw_message%ROWTYPE;
  v tori.venue%ROWTYPE;
  res jsonb := coalesce(p_parse -> 'result', '{}');
  v_type text;
  v_src text;
  v_pid text;
  v_haystack text;
  s jsonb;
  si tori.slot_in;
  v_slots tori.slot_in[] := '{}';
  v_unparsed int := 0;
  v_unmatched int := 0;
  v_date date;
  v_st time;
  v_et time;
  v_start timestamptz;
  v_end timestamptz;
  v_reasons text[];
  b tori.booking%ROWTYPE;
  v_new_booking boolean;
  sl tori.booking_slot%ROWTYPE;
  v_sid uuid;
  x uuid;
  y uuid;
  v_added uuid[];
  v_new_slots uuid[] := '{}';
  v_cancel uuid[] := '{}';
  v_clashes int := 0;
  v_pairs jsonb := '[]';
  p jsonb;
  v_lines text;
  v_event text;
  v_text text;
  v_review text;
  o record;
BEGIN
  SELECT * INTO r FROM tori.raw_message WHERE id = p_raw_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'raw_message % not found', p_raw_id;
  END IF;
  IF r.status <> 'pending_parse' THEN
    RETURN jsonb_build_object('raw_id', r.id, 'action', 'skipped', 'reason', 'status is ' || r.status);
  END IF;
  SELECT * INTO v FROM tori.venue WHERE id = r.venue_id;
  v_src := tori.source_label(r.source);

  UPDATE tori.raw_message
     SET parse_result = p_parse, parse_model = p_parse ->> 'model',
         parse_attempts = parse_attempts
           + CASE WHEN coalesce((p_parse ->> 'rate_limited')::boolean, false) THEN 0 ELSE 1 END
   WHERE id = r.id
  RETURNING * INTO r;

  IF NOT coalesce((p_parse ->> 'ok')::boolean, false) THEN
    IF coalesce((p_parse ->> 'retryable')::boolean, false)
       AND r.parse_attempts < coalesce(tori.cfg('parse_max_attempts')::int, 3) THEN
      UPDATE tori.raw_message SET status_reason = 'parser: ' || coalesce(p_parse ->> 'error', '?') || ' (will retry)'
       WHERE id = r.id;
      RETURN jsonb_build_object('raw_id', r.id, 'action', 'retry_later', 'attempt', r.parse_attempts);
    END IF;
    RETURN tori.mark_unreadable(r.id, 'parser: ' || coalesce(p_parse ->> 'error', 'unknown error'));
  END IF;

  v_type := res ->> 'email_type';
  IF v_type = 'not_a_booking' AND coalesce(res ->> 'confidence', 'low') <> 'high'
     AND r.subject ~* '\m(booking|booked|cancell?ed|reschedul)' THEN
    RETURN tori.mark_unreadable(r.id, 'looks like a booking email but the parser could not read it');
  END IF;
  IF v_type = 'not_a_booking' THEN
    UPDATE tori.raw_message SET status = 'ignored', status_reason = 'not a booking email', processed_at = now()
     WHERE id = r.id;
    RETURN jsonb_build_object('raw_id', r.id, 'action', 'ignored');
  END IF;
  IF v_type IS NULL OR v_type NOT IN ('booking_confirmed', 'booking_cancelled', 'booking_modified') THEN
    RETURN tori.mark_unreadable(r.id, 'unknown email_type ' || coalesce(v_type, 'null'));
  END IF;

  v_pid := nullif(btrim(coalesce(res ->> 'booking_id', res ->> 'playo_booking_id')), '');
  IF v_pid IS NULL THEN
    RETURN tori.mark_unreadable(r.id, 'no booking ID found');
  END IF;
  v_haystack := lower(regexp_replace(coalesce(r.subject, '') || coalesce(r.text_body, '') || coalesce(r.html_body, ''),
                                     '\s', '', 'g'));
  IF position(lower(regexp_replace(v_pid, '\s', '', 'g')) IN v_haystack) = 0 THEN
    RETURN tori.mark_unreadable(r.id, 'booking ID ' || v_pid || ' is not in the email text');
  END IF;

  FOR s IN SELECT * FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(res -> 'slots') = 'array' THEN res -> 'slots' ELSE '[]' END) LOOP
    BEGIN
      v_date := (s ->> 'date')::date;
      v_st := (s ->> 'start_time')::time;
      v_et := (s ->> 'end_time')::time;
    EXCEPTION WHEN others THEN
      v_unparsed := v_unparsed + 1;
      CONTINUE;
    END;
    IF v_date IS NULL OR v_st IS NULL OR v_et IS NULL THEN
      v_unparsed := v_unparsed + 1;
      CONTINUE;
    END IF;

    v_start := (v_date + v_st) AT TIME ZONE v.timezone;
    v_end := (v_date + v_et) AT TIME ZONE v.timezone;
    IF v_end <= v_start THEN
      v_end := v_end + interval '1 day';
    END IF;

    si.court_label := coalesce(nullif(btrim(s ->> 'court'), ''), '?');
    si.court_key := tori.court_key(si.court_label);
    si.court_id := tori.match_court(v.id, si.court_label);
    v_reasons := '{}';
    IF si.court_id IS NULL THEN
      v_reasons := v_reasons || 'unknown_court'::text;
    END IF;
    IF v.opens_at IS NOT NULL AND v.closes_at IS NOT NULL AND NOT EXISTS (
         SELECT 1
         FROM (VALUES (v_date), (v_date - 1)) d(day)
         CROSS JOIN LATERAL (
           SELECT (d.day + v.opens_at) AT TIME ZONE v.timezone AS opens,
                  (d.day + v.closes_at) AT TIME ZONE v.timezone
                    + CASE WHEN v.closes_at <= v.opens_at THEN interval '1 day' ELSE interval '0' END AS closes) w
         WHERE v_start >= w.opens AND v_end <= w.closes) THEN
      v_reasons := v_reasons || 'outside_hours'::text;
    END IF;
    IF v_end - v_start < interval '15 minutes' OR v_end - v_start > interval '12 hours' THEN
      v_reasons := v_reasons || 'odd_duration'::text;
    END IF;
    IF v_start < r.received_at - make_interval(days => coalesce(tori.cfg('review_past_days')::int, 2)) THEN
      v_reasons := v_reasons || 'in_past'::text;
    END IF;
    IF v_start > r.received_at + make_interval(days => coalesce(tori.cfg('review_future_days')::int, 180)) THEN
      v_reasons := v_reasons || 'far_future'::text;
    END IF;
    IF res ->> 'confidence' = 'low' THEN
      v_reasons := v_reasons || 'low_confidence'::text;
    END IF;
    si.starts_at := v_start;
    si.ends_at := v_end;
    si.reasons := v_reasons;
    v_slots := v_slots || si;
  END LOOP;

  IF v_type = 'booking_cancelled' THEN
    SELECT * INTO b FROM tori.booking WHERE venue_id = v.id AND source = r.source AND source_booking_id = v_pid FOR UPDATE;
    IF NOT FOUND THEN
      INSERT INTO tori.booking (venue_id, source, source_booking_id, status, customer_name, customer_phone_masked,
                                amount, payment_status, sport, first_raw_message_id, last_raw_message_id, cancelled_at)
      VALUES (v.id, r.source, v_pid, 'cancelled', res ->> 'customer_name', tori.mask_phone(res ->> 'customer_phone'),
              (res ->> 'amount')::numeric, coalesce(res ->> 'payment_status', 'unknown'), res ->> 'sport',
              r.id, r.id, now())
      RETURNING * INTO b;
      PERFORM tori.raise_alert(v.id, 'cancel_unknown_booking', 'info',
        'Cancellation for ' || v_src || ' booking ' || v_pid || ', which Tori never saw booked. Nothing to remove.',
        '{}', r.id, b.id, 'cancel_unknown:' || b.id, false);
      UPDATE tori.raw_message SET status = 'applied', status_reason = 'cancellation for unknown booking',
             processed_at = now() WHERE id = r.id;
      PERFORM tori.resolve_notes(r.id);
      RETURN jsonb_build_object('raw_id', r.id, 'action', 'cancel_unknown', 'booking_id', b.id);
    END IF;

    IF cardinality(v_slots) = 0 AND v_unparsed = 0 THEN
      v_cancel := ARRAY(SELECT id FROM tori.booking_slot WHERE booking_id = b.id AND status = 'active');
    ELSE
      FOREACH si IN ARRAY v_slots LOOP
        SELECT bs.id INTO x
        FROM tori.booking_slot bs
        WHERE bs.booking_id = b.id AND bs.starts_at = si.starts_at
          AND (bs.court_key = si.court_key
               OR bs.court_id = si.court_id
               OR (SELECT count(*) FROM tori.booking_slot z
                   WHERE z.booking_id = b.id AND z.starts_at = si.starts_at) = 1)
        ORDER BY (bs.court_key = si.court_key) DESC
        LIMIT 1;
        IF x IS NULL THEN
          v_unmatched := v_unmatched + 1;
        ELSE
          v_cancel := v_cancel || x;
        END IF;
      END LOOP;

      IF v_unmatched > 0 OR v_unparsed > 0 THEN
        PERFORM tori.raise_alert(v.id, 'cancel_mismatch', 'critical',
          'Cancellation email for ' || v_src || ' booking ' || v_pid || ' lists slots Tori cannot match, so NOTHING was removed. '
            || 'Check ' || v_src || ', fix the calendar by hand, then acknowledge.',
          jsonb_build_object('parsed_slots', res -> 'slots'), r.id, b.id, 'cancel_mismatch:' || r.id);
        UPDATE tori.raw_message SET status = 'applied', status_reason = 'cancellation needs manual review',
               processed_at = now() WHERE id = r.id;
        RETURN jsonb_build_object('raw_id', r.id, 'action', 'needs_review', 'booking_id', b.id);
      END IF;
      v_cancel := ARRAY(SELECT id FROM tori.booking_slot WHERE id = ANY (v_cancel) AND status = 'active');
    END IF;

    FOREACH x IN ARRAY v_cancel LOOP
      UPDATE tori.booking_slot SET status = 'cancelled', cancelled_at = now(), updated_at = now() WHERE id = x;
      PERFORM tori.refresh_clashes(x);
      PERFORM tori.enqueue_calendar('calendar.sync_slot', v.id, x::text);
    END LOOP;

    UPDATE tori.booking
       SET status = CASE WHEN EXISTS (SELECT 1 FROM tori.booking_slot WHERE booking_id = b.id AND status = 'active')
                         THEN 'confirmed' ELSE 'cancelled' END,
           cancelled_at = CASE WHEN EXISTS (SELECT 1 FROM tori.booking_slot WHERE booking_id = b.id AND status = 'active')
                               THEN NULL ELSE coalesce(cancelled_at, now()) END,
           last_raw_message_id = r.id, updated_at = now()
     WHERE id = b.id;

    IF cardinality(v_cancel) > 0 THEN
      SELECT string_agg(tori.fmt_slot(coalesce(c.display_name, c.name, bs.court_label), bs.starts_at, bs.ends_at, v.timezone),
                        E'\n' ORDER BY bs.starts_at)
        INTO v_lines
        FROM tori.booking_slot bs LEFT JOIN tori.court c ON c.id = bs.court_id
       WHERE bs.id = ANY (v_cancel);
      PERFORM tori.notify(v.id, 'booking', 'booking_cancelled',
        '❌ ' || v_src || ' booking cancelled · ' || v.name || E'\n' || v_lines || E'\n'
          || tori.short_name(b.customer_name) || ' · ' || v_src || ' ID ' || v_pid || E'\nRemoved from the calendar.',
        jsonb_build_array(v.name, replace(v_lines, E'\n', '; '), tori.short_name(b.customer_name) || ' · ' || v_src || ' ID ' || v_pid),
        'booking_cancelled:' || b.id || ':' || md5((SELECT string_agg(z::text, ',' ORDER BY z) FROM unnest(v_cancel) z)));
    END IF;

    UPDATE tori.raw_message
       SET status = 'applied', processed_at = now(),
           status_reason = CASE WHEN cardinality(v_cancel) = 0 THEN 'already cancelled' END
     WHERE id = r.id;
    PERFORM tori.resolve_notes(r.id);
    RETURN jsonb_build_object('raw_id', r.id, 'action', 'cancelled', 'booking_id', b.id,
                              'slots_cancelled', cardinality(v_cancel));
  END IF;

  IF cardinality(v_slots) = 0 THEN
    RETURN tori.mark_unreadable(r.id, 'no readable court, date and time');
  END IF;

  INSERT INTO tori.booking (venue_id, source, source_booking_id, status, customer_name, customer_phone_masked,
                            amount, payment_status, sport, first_raw_message_id, last_raw_message_id)
  VALUES (v.id, r.source, v_pid, 'confirmed', res ->> 'customer_name', tori.mask_phone(res ->> 'customer_phone'),
          (res ->> 'amount')::numeric, coalesce(res ->> 'payment_status', 'unknown'), res ->> 'sport', r.id, r.id)
  ON CONFLICT (venue_id, source, source_booking_id) DO UPDATE SET
    customer_name         = coalesce(EXCLUDED.customer_name, tori.booking.customer_name),
    customer_phone_masked = coalesce(EXCLUDED.customer_phone_masked, tori.booking.customer_phone_masked),
    amount                = coalesce(EXCLUDED.amount, tori.booking.amount),
    payment_status        = CASE WHEN EXCLUDED.payment_status = 'unknown' THEN tori.booking.payment_status
                                 ELSE EXCLUDED.payment_status END,
    sport                 = coalesce(EXCLUDED.sport, tori.booking.sport),
    last_raw_message_id   = EXCLUDED.last_raw_message_id,
    updated_at            = now()
  RETURNING * INTO b;
  v_new_booking := b.first_raw_message_id = r.id;

  IF b.status = 'cancelled' THEN
    UPDATE tori.raw_message SET status = 'applied', processed_at = now(),
           status_reason = 'booking was already cancelled (emails arrived out of order)'
     WHERE id = r.id;
    RETURN jsonb_build_object('raw_id', r.id, 'action', 'already_cancelled', 'booking_id', b.id);
  END IF;

  PERFORM 1 FROM tori.court
   WHERE id IN (SELECT u.court_id FROM unnest(v_slots) u WHERE u.court_id IS NOT NULL)
   ORDER BY id FOR UPDATE;

  IF v_type = 'booking_modified' THEN
    v_cancel := ARRAY(
      SELECT bs.id FROM tori.booking_slot bs
      WHERE bs.booking_id = b.id AND bs.status = 'active'
        AND NOT EXISTS (SELECT 1 FROM unnest(v_slots) u
                        WHERE u.court_key = bs.court_key AND u.starts_at = bs.starts_at));
    FOREACH x IN ARRAY v_cancel LOOP
      UPDATE tori.booking_slot SET status = 'cancelled', cancelled_at = now(), updated_at = now() WHERE id = x;
      PERFORM tori.refresh_clashes(x);
      PERFORM tori.enqueue_calendar('calendar.sync_slot', v.id, x::text);
    END LOOP;
  END IF;

  FOREACH si IN ARRAY v_slots LOOP
    v_sid := gen_random_uuid();
    INSERT INTO tori.booking_slot (id, booking_id, venue_id, court_id, court_label, court_key,
                                   starts_at, ends_at, review_reasons, gcal_event_id)
    VALUES (v_sid, b.id, v.id, si.court_id, si.court_label, si.court_key,
            si.starts_at, si.ends_at, si.reasons, 'tori' || replace(v_sid::text, '-', ''))
    ON CONFLICT (booking_id, court_key, starts_at) DO UPDATE SET
      ends_at        = CASE WHEN v_type = 'booking_modified' THEN EXCLUDED.ends_at ELSE tori.booking_slot.ends_at END,
      court_id       = CASE WHEN v_type = 'booking_modified' THEN EXCLUDED.court_id ELSE tori.booking_slot.court_id END,
      review_reasons = CASE WHEN v_type = 'booking_modified' THEN EXCLUDED.review_reasons ELSE tori.booking_slot.review_reasons END,
      status         = CASE WHEN v_type = 'booking_modified' THEN 'active' ELSE tori.booking_slot.status END,
      cancelled_at   = CASE WHEN v_type = 'booking_modified' THEN NULL ELSE tori.booking_slot.cancelled_at END,
      updated_at     = now()
    RETURNING * INTO sl;

    IF sl.id = v_sid THEN
      v_new_slots := v_new_slots || sl.id;
    END IF;
    IF sl.id = v_sid OR v_type = 'booking_modified' THEN
      v_added := tori.refresh_clashes(sl.id);
      PERFORM tori.enqueue_calendar('calendar.sync_slot', v.id, sl.id::text);
      FOREACH y IN ARRAY v_added LOOP
        v_pairs := v_pairs || jsonb_build_array(jsonb_build_object('slot', sl.id, 'other', y));
      END LOOP;
    END IF;
  END LOOP;

  IF cardinality(v_new_slots) > 0 OR v_type = 'booking_modified' THEN
    SELECT string_agg(tori.fmt_slot(coalesce(c.display_name, c.name, bs.court_label), bs.starts_at, bs.ends_at, v.timezone)
                        || CASE WHEN cardinality(bs.clash_with) > 0 THEN ' ⚠️ CLASH' ELSE '' END,
                      E'\n' ORDER BY bs.starts_at)
      INTO v_lines
      FROM tori.booking_slot bs LEFT JOIN tori.court c ON c.id = bs.court_id
     WHERE bs.booking_id = b.id AND bs.status = 'active'
       AND (v_type = 'booking_modified' OR bs.id = ANY (v_new_slots));
    v_event := CASE WHEN v_type = 'booking_modified' THEN 'booking_modified'
                    WHEN v_new_booking THEN 'booking_new' ELSE 'booking_updated' END;
    v_text := CASE v_event
                WHEN 'booking_new' THEN '✅ *New ' || v_src || ' booking*'
                WHEN 'booking_modified' THEN '🔁 *' || v_src || ' booking changed*'
                ELSE '➕ *Slots added to ' || v_src || ' booking*' END
              || E'\n🏟️ ' || v.name
              || E'\n🏸 ' || replace(coalesce(v_lines, '(no active slots)'), E'\n', E'\n🏸 ')
              || E'\n👤 ' || tori.short_name(b.customer_name)
              || coalesce(' · ₹' || trim_scale(b.amount)::text, '')
              || coalesce(' ' || replace(nullif(b.payment_status, 'unknown'), '_', ' '), '')
              || E'\n🔖 ' || v_src || ' ID: ' || v_pid
              || CASE WHEN v_lines LIKE '%CLASH%' THEN E'\n\n⚠️ Clashes with another booking. Details below.' ELSE '' END;
    PERFORM tori.notify(v.id, 'booking', v_event, v_text,
      jsonb_build_array(v.name, replace(coalesce(v_lines, ''), E'\n', '; '),
                        tori.short_name(b.customer_name) || coalesce(' · ₹' || trim_scale(b.amount)::text, '')
                          || ' · ' || v_src || ' ID ' || v_pid),
      v_event || ':' || b.id || ':' || r.id);
  END IF;

  FOR p IN SELECT * FROM jsonb_array_elements(v_pairs) LOOP
    SELECT * INTO sl FROM tori.booking_slot WHERE id = (p ->> 'slot')::uuid;
    y := (p ->> 'other')::uuid;
    v_clashes := v_clashes + 1;
    SELECT os.*, ob.source_booking_id AS other_pid, tori.source_label(ob.source) AS other_src,
           ob.customer_name AS other_customer,
           coalesce(c.display_name, c.name, os.court_label) AS court_name
      INTO o
      FROM tori.booking_slot os JOIN tori.booking ob ON ob.id = os.booking_id
      LEFT JOIN tori.court c ON c.id = os.court_id
     WHERE os.id = y;
    v_lines := tori.fmt_slot(o.court_name, greatest(o.starts_at, sl.starts_at), least(o.ends_at, sl.ends_at), v.timezone);
    PERFORM tori.raise_alert(v.id, 'clash', 'critical',
      'Double booking: ' || v_lines
        || E'\n1️⃣ ' || o.other_src || ' ' || o.other_pid || ' · ' || tori.short_name(o.other_customer) || ' (booked first)'
        || E'\n2️⃣ ' || v_src || ' ' || v_pid || ' · ' || tori.short_name(b.customer_name) || ' (new)'
        || E'\nBoth are marked CLASH in the calendar. Call the owner.',
      jsonb_build_object('slot', sl.id, 'other_slot', y), r.id, b.id,
      'clash:' || least(sl.id::text, y::text) || ':' || greatest(sl.id::text, y::text));
    PERFORM tori.notify(v.id, 'owner', 'clash',
      '⚠️ *Double booking*' || E'\n🏟️ ' || v.name || E'\n🏸 ' || v_lines
        || E'\n\n1️⃣ ' || tori.short_name(o.other_customer) || ' · ' || o.other_src || ' ' || o.other_pid || ' (booked first)'
        || E'\n2️⃣ ' || tori.short_name(b.customer_name) || ' · ' || v_src || ' ' || v_pid || ' (new)'
        || E'\n\nBoth are marked CLASH in your calendar. Tori will call you shortly to sort it out.',
      jsonb_build_array(v.name, v_lines, v_src || ' ' || v_pid || ' and ' || o.other_src || ' ' || o.other_pid),
      'clash:' || least(sl.id::text, y::text) || ':' || greatest(sl.id::text, y::text));
  END LOOP;

  SELECT string_agg(u.court_label || ' ' || to_char(u.starts_at AT TIME ZONE v.timezone, 'DD Mon HH24:MI')
                      || ': ' || tori.reason_text(u.reasons), '; ')
    INTO v_review
    FROM unnest(v_slots) u WHERE cardinality(u.reasons) > 0;
  IF v_unparsed > 0 THEN
    v_review := concat_ws('; ', v_review, v_unparsed || ' slot(s) could not be read');
  END IF;
  IF v_review IS NOT NULL THEN
    PERFORM tori.raise_alert(v.id, 'needs_review', 'warn',
      v_src || ' booking ' || v_pid || ' needs a check: ' || v_review || '. Event is in the calendar with ⚠️ CHECK.',
      jsonb_build_object('parsed', res), r.id, b.id, 'review:' || r.id);
  END IF;

  UPDATE tori.raw_message SET status = 'applied', status_reason = NULL, processed_at = now() WHERE id = r.id;
  PERFORM tori.resolve_notes(r.id);
  RETURN jsonb_build_object('raw_id', r.id, 'action', CASE WHEN v_new_booking THEN 'booked' ELSE v_type END,
                            'booking_id', b.id, 'new_slots', cardinality(v_new_slots),
                            'cancelled_slots', cardinality(v_cancel), 'clashes', v_clashes,
                            'needs_review', v_review IS NOT NULL);
END $$;

CREATE OR REPLACE FUNCTION tori.slot_event(p_slot_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'id', s.gcal_event_id,
    'summary',
      CASE WHEN cardinality(s.clash_with) > 0 THEN '⚠️ CLASH · '
           WHEN cardinality(s.review_reasons) > 0 THEN '⚠️ CHECK · ' ELSE '' END
      || coalesce(c.display_name, c.name, s.court_label) || ' · ' || tori.source_label(b.source)
      || ' · ' || tori.short_name(b.customer_name),
    'description', concat_ws(E'\n',
      tori.source_label(b.source) || ' booking ID: ' || b.source_booking_id,
      'Amount: ₹' || trim_scale(b.amount)::text,
      'Payment: ' || replace(b.payment_status, '_', ' '),
      'Phone: ' || b.customer_phone_masked,
      'Sport: ' || b.sport,
      'Received by Tori: ' || to_char(fr.received_at AT TIME ZONE v.timezone, 'DD Mon YYYY, HH24:MI'),
      CASE WHEN cardinality(s.clash_with) > 0 THEN
        E'\n⚠️ CLASH: this court is also booked by '
        || (SELECT string_agg(tori.source_label(ob.source) || ' ' || ob.source_booking_id || ' (' || tori.short_name(ob.customer_name) || ')', ', ')
              FROM tori.booking_slot os JOIN tori.booking ob ON ob.id = os.booking_id
             WHERE os.id = ANY (s.clash_with))
        || '. Tori will call you.' END,
      CASE WHEN cardinality(s.review_reasons) > 0 THEN E'\n⚠️ Check: ' || tori.reason_text(s.review_reasons) END,
      E'\nAdded by Tori Desk from ' || tori.source_label(b.source) || '. Changes come from '
        || tori.source_label(b.source) || '; edits here are overwritten.'),
    'start', jsonb_build_object('dateTime', to_char(s.starts_at AT TIME ZONE v.timezone, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                'timeZone', v.timezone),
    'end', jsonb_build_object('dateTime', to_char(s.ends_at AT TIME ZONE v.timezone, 'YYYY-MM-DD"T"HH24:MI:SS'),
                              'timeZone', v.timezone),
    'transparency', 'opaque',
    'status', 'confirmed',
    'colorId', CASE WHEN cardinality(s.clash_with) > 0 THEN '11'
                    WHEN cardinality(s.review_reasons) > 0 THEN '5' END,
    'extendedProperties', jsonb_build_object('private', jsonb_build_object(
      'bookingSource', b.source, 'bookingId', b.source_booking_id, 'toriSlotId', s.id::text, 'toriVenueId', v.id::text)),
    'reminders', jsonb_build_object('useDefault', false)))
  FROM tori.booking_slot s
  JOIN tori.booking b ON b.id = s.booking_id
  JOIN tori.venue v ON v.id = s.venue_id
  LEFT JOIN tori.court c ON c.id = s.court_id
  LEFT JOIN tori.raw_message fr ON fr.id = b.first_raw_message_id
  WHERE s.id = p_slot_id
$$;

CREATE OR REPLACE FUNCTION tori.build_request(j tori.outbox) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v tori.venue%ROWTYPE;
  s tori.booking_slot%ROWTYPE;
  b tori.booking%ROWTYPE;
  n tori.calendar_note%ROWTYPE;
  v_start timestamptz;
BEGIN
  SELECT * INTO v FROM tori.venue WHERE id = j.venue_id;

  IF j.kind = 'whatsapp.send' THEN
    RETURN jsonb_build_object('channel', 'whatsapp', 'to', j.payload ->> 'to', 'event', j.payload ->> 'event',
                              'text', j.payload ->> 'text', 'params', coalesce(j.payload -> 'params', '[]'));
  END IF;

  IF j.kind = 'calendar.sync_slot' THEN
    SELECT * INTO s FROM tori.booking_slot WHERE id = j.ref::uuid;
    SELECT * INTO b FROM tori.booking WHERE id = s.booking_id;
    IF s.status = 'active' AND b.status = 'confirmed' THEN
      RETURN jsonb_build_object('channel', 'gcal', 'action', 'upsert', 'calendar_id', v.calendar_id,
                                'event_id', s.gcal_event_id, 'event', tori.slot_event(s.id));
    END IF;
    RETURN jsonb_build_object('channel', 'gcal', 'action', 'delete', 'calendar_id', v.calendar_id,
                              'event_id', s.gcal_event_id);
  END IF;

  IF j.kind = 'calendar.note' THEN
    SELECT * INTO n FROM tori.calendar_note WHERE id = j.ref::uuid;
    IF n.status = 'resolved' THEN
      RETURN jsonb_build_object('channel', 'gcal', 'action', 'delete', 'calendar_id', v.calendar_id,
                                'event_id', n.gcal_event_id);
    END IF;
    RETURN jsonb_build_object('channel', 'gcal', 'action', 'upsert', 'calendar_id', v.calendar_id,
      'event_id', n.gcal_event_id,
      'event', jsonb_build_object(
        'id', n.gcal_event_id, 'summary', n.title, 'description', n.description,
        'start', jsonb_build_object('date', to_char(n.note_date, 'YYYY-MM-DD')),
        'end', jsonb_build_object('date', to_char(n.note_date + 1, 'YYYY-MM-DD')),
        'transparency', 'transparent', 'status', 'confirmed', 'colorId', '11',
        'extendedProperties', jsonb_build_object('private', jsonb_build_object('toriNoteId', n.id::text))));
  END IF;

  IF j.kind = 'calendar.test' THEN
    IF j.payload ->> 'action' = 'delete' THEN
      RETURN jsonb_build_object('channel', 'gcal', 'action', 'delete', 'calendar_id', v.calendar_id,
                                'event_id', 'toritest' || v.id);
    END IF;
    v_start := date_trunc('hour', now()) + interval '1 hour';
    RETURN jsonb_build_object('channel', 'gcal', 'action', 'upsert', 'calendar_id', v.calendar_id,
      'event_id', 'toritest' || v.id,
      'event', jsonb_build_object(
        'id', 'toritest' || v.id,
        'summary', '✅ Tori test event — connected',
        'description', 'Tori Desk can write to this calendar. This test event will be removed.',
        'start', jsonb_build_object('dateTime', to_char(v_start AT TIME ZONE v.timezone, 'YYYY-MM-DD"T"HH24:MI:SS'),
                                    'timeZone', v.timezone),
        'end', jsonb_build_object('dateTime', to_char((v_start + interval '30 minutes') AT TIME ZONE v.timezone,
                                                      'YYYY-MM-DD"T"HH24:MI:SS'), 'timeZone', v.timezone),
        'status', 'confirmed', 'transparency', 'transparent'));
  END IF;

  RAISE EXCEPTION 'unknown outbox kind %', j.kind;
END $$;

CREATE OR REPLACE FUNCTION tori.claim_jobs(p_limit int DEFAULT 25, p_lease interval DEFAULT '2 minutes')
RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE
  j tori.outbox%ROWTYPE;
  v_req jsonb;
BEGIN
  FOR j IN
    WITH due AS (
      SELECT o.id
      FROM tori.outbox o
      LEFT JOIN tori.venue v ON v.id = o.venue_id
      WHERE ((o.status = 'pending' AND o.next_attempt_at <= now())
             OR (o.status = 'running' AND o.locked_until < now()))
        AND (o.kind NOT LIKE 'calendar.%' OR v.calendar_id IS NOT NULL)
        AND NOT EXISTS (SELECT 1 FROM tori.outbox x
                        WHERE x.kind = o.kind AND x.ref = o.ref AND x.id <> o.id
                          AND x.status = 'running' AND x.locked_until >= now())
      ORDER BY o.id
      LIMIT p_limit
      FOR UPDATE OF o SKIP LOCKED)
    UPDATE tori.outbox o
       SET status = 'running', attempts = o.attempts + 1, locked_until = now() + p_lease, updated_at = now()
      FROM due
     WHERE o.id = due.id
    RETURNING o.*
  LOOP
    v_req := tori.build_request(j);
    UPDATE tori.outbox SET request = v_req WHERE id = j.id;
    RETURN NEXT jsonb_build_object('job_id', j.id, 'kind', j.kind, 'attempt', j.attempts) || v_req;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION tori.complete_job(p_job_id bigint, p_result jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  j tori.outbox%ROWTYPE;
  v_ok boolean := coalesce((p_result ->> 'ok')::boolean, false);
  v_status int := (p_result ->> 'status')::int;
  v_err text := left(p_result ->> 'error', 1000);
  v_body jsonb := p_result -> 'body';
  v_retry boolean;
  v_final text;
BEGIN
  SELECT * INTO j FROM tori.outbox WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox job % not found', p_job_id;
  END IF;

  IF v_ok THEN
    UPDATE tori.outbox
       SET status = 'done', done_at = now(), locked_until = NULL, result = p_result,
           last_status = v_status, last_error = NULL, updated_at = now()
     WHERE id = j.id;
    IF j.kind = 'calendar.sync_slot' THEN
      UPDATE tori.booking_slot
         SET calendar_state = CASE WHEN j.request ->> 'action' = 'upsert' THEN 'synced' ELSE 'deleted' END,
             calendar_html_link = coalesce(v_body ->> 'htmlLink', calendar_html_link),
             calendar_synced_at = now(),
             first_synced_at = CASE WHEN j.request ->> 'action' = 'upsert' THEN coalesce(first_synced_at, now())
                                    ELSE first_synced_at END
       WHERE id = j.ref::uuid;
    ELSIF j.kind = 'calendar.note' THEN
      UPDATE tori.calendar_note
         SET calendar_state = CASE WHEN j.request ->> 'action' = 'upsert' THEN 'synced' ELSE 'deleted' END
       WHERE id = j.ref::uuid;
    END IF;
    IF j.kind LIKE 'calendar.%' THEN
      UPDATE tori.venue SET calendar_status = 'ok', updated_at = now()
       WHERE id = j.venue_id AND calendar_status <> 'ok';
    END IF;
    RETURN jsonb_build_object('job_id', j.id, 'status', 'done');
  END IF;

  v_retry := coalesce((p_result ->> 'retryable')::boolean,
                      v_status IS NULL OR v_status IN (408, 429) OR v_status >= 500);

  IF j.kind LIKE 'calendar.%' AND v_status IN (401, 403, 404) THEN
    UPDATE tori.venue SET calendar_status = 'error', updated_at = now() WHERE id = j.venue_id;
    IF j.kind <> 'calendar.test' THEN
      PERFORM tori.raise_alert(j.venue_id, 'calendar_error', 'critical',
        'Google Calendar refused Tori (HTTP ' || v_status || '): '
          || CASE v_status
               WHEN 404 THEN 'wrong calendar ID, or the calendar is not shared with Tori''s service account.'
               WHEN 403 THEN 'sharing permission is not "Make changes to events", or the owner removed Tori.'
               ELSE 'service account key rejected.' END
          || ' Bookings will sync automatically once it is fixed.',
        jsonb_build_object('job_id', j.id, 'status', v_status, 'error', v_err), NULL, NULL,
        'calendar_error:' || j.venue_id || ':' || current_date);
      v_retry := true;
    END IF;
  END IF;
  IF j.kind = 'calendar.test' THEN
    v_retry := false;
  END IF;

  IF v_retry AND j.attempts < j.max_attempts THEN
    IF j.ref IS NOT NULL AND EXISTS (SELECT 1 FROM tori.outbox
                                     WHERE kind = j.kind AND ref = j.ref AND status = 'pending' AND id <> j.id) THEN
      UPDATE tori.outbox
         SET status = 'failed', locked_until = NULL, result = p_result, last_status = v_status,
             last_error = 'superseded by a newer job; ' || coalesce(v_err, ''), updated_at = now()
       WHERE id = j.id;
      RETURN jsonb_build_object('job_id', j.id, 'status', 'superseded');
    END IF;
    UPDATE tori.outbox
       SET status = 'pending', locked_until = NULL,
           next_attempt_at = now() + least(interval '1 minute' * power(2, greatest(j.attempts - 1, 0)), interval '1 hour'),
           result = p_result, last_status = v_status, last_error = v_err, updated_at = now()
     WHERE id = j.id;
    RETURN jsonb_build_object('job_id', j.id, 'status', 'retry');
  END IF;

  v_final := CASE WHEN j.kind = 'calendar.test' THEN 'failed' ELSE 'dead' END;
  UPDATE tori.outbox
     SET status = v_final, locked_until = NULL, result = p_result, last_status = v_status,
         last_error = v_err, updated_at = now()
   WHERE id = j.id;
  IF v_final = 'dead' THEN
    PERFORM tori.raise_alert(j.venue_id, 'job_dead', 'critical',
      'Tori gave up on ' || j.kind || ' after ' || j.attempts || ' attempts (HTTP ' || coalesce(v_status::text, 'none')
        || ': ' || left(coalesce(v_err, ''), 200) || '). Outbox job #' || j.id || '.',
      jsonb_build_object('job_id', j.id, 'request', j.request), NULL, NULL, 'job_dead:' || j.id,
      j.kind <> 'whatsapp.send');
  END IF;
  RETURN jsonb_build_object('job_id', j.id, 'status', v_final);
END $$;

CREATE OR REPLACE FUNCTION tori.check_monitors() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v tori.venue%ROWTYPE;
  n_quiet int := 0;
  v_retry bigint[];
BEGIN
  FOR v IN SELECT * FROM tori.venue
           WHERE status = 'live'
             AND coalesce(last_booking_email_at, created_at) < now() - make_interval(hours => quiet_alert_hours) LOOP
    IF tori.raise_alert(v.id, 'quiet', 'warn',
         'No booking email for ' || v.name || ' in ' || v.quiet_alert_hours || '+ hours (last: '
           || coalesce(to_char(v.last_booking_email_at AT TIME ZONE v.timezone, 'DD Mon HH24:MI'), 'never')
           || '). Check the owner''s Gmail filter and forwarding (steps B1–B3).',
         '{}', NULL, NULL, 'quiet:' || v.id || ':' || current_date) IS NOT NULL THEN
      n_quiet := n_quiet + 1;
    END IF;
  END LOOP;

  v_retry := ARRAY(SELECT id FROM tori.raw_message
                   WHERE status = 'pending_parse' AND received_at < now() - interval '1 minute'
                   ORDER BY id LIMIT 5);
  PERFORM tori.raise_alert(r.venue_id, 'parser_stuck', 'critical',
            'Email #' || r.id || ' ("' || coalesce(r.subject, '') || '") has waited '
              || floor(extract(epoch FROM now() - r.received_at) / 60) || ' min for the parser: '
              || coalesce(r.status_reason, '?') || '. Check the Groq key/quota.',
            '{}', r.id, NULL, 'parser_stuck:' || r.id)
     FROM tori.raw_message r
    WHERE r.status = 'pending_parse' AND r.received_at < now() - interval '30 minutes';
  RETURN jsonb_build_object('quiet_alerts', n_quiet, 'retry_raw_ids', to_jsonb(v_retry));
END $$;

CREATE OR REPLACE FUNCTION tori.purge_raw_bodies(p_days int DEFAULT 90) RETURNS int
LANGUAGE sql AS $$
  WITH p AS (
    UPDATE tori.raw_message
       SET text_body = NULL, html_body = NULL, payload = '{}', headers = '{}', bodies_purged_at = now()
     WHERE received_at < now() - make_interval(days => p_days) AND bodies_purged_at IS NULL
    RETURNING 1)
  SELECT count(*)::int FROM p
$$;

CREATE OR REPLACE FUNCTION tori.create_venue(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_tenant bigint := (p ->> 'tenant_id')::bigint;
  v_slug text := lower(btrim(p ->> 'slug'));
  v_addr text;
  v_id bigint;
  v_court text;
  i int := 0;
BEGIN
  IF v_slug IS NULL OR v_slug !~ '^[a-z0-9][a-z0-9-]{1,30}$' THEN
    RAISE EXCEPTION 'slug must be 2-31 chars of a-z, 0-9, -';
  END IF;
  IF v_tenant IS NULL THEN
    INSERT INTO tori.tenant (name, owner_name, owner_whatsapp, owner_email, account_manager_id)
    VALUES (coalesce(p ->> 'tenant_name', p ->> 'name'), p ->> 'owner_name', p ->> 'owner_whatsapp',
            p ->> 'owner_email', (p ->> 'account_manager_id')::bigint)
    RETURNING id INTO v_tenant;
  END IF;
  v_addr := v_slug || '-' || left(replace(gen_random_uuid()::text, '-', ''), 8) || '@' || tori.cfg('inbound_domain');
  INSERT INTO tori.venue (tenant_id, slug, name, inbound_address, owner_gmail, calendar_id, timezone, opens_at, closes_at,
                          status)
  VALUES (v_tenant, v_slug, p ->> 'name', v_addr, lower(nullif(p ->> 'owner_gmail', '')), nullif(p ->> 'calendar_id', ''),
          coalesce(p ->> 'timezone', 'Asia/Kolkata'), (p ->> 'opens_at')::time, (p ->> 'closes_at')::time,
          coalesce(p ->> 'status', 'onboarding'))
  RETURNING id INTO v_id;
  FOR v_court IN SELECT jsonb_array_elements_text(coalesce(p -> 'courts', '[]')) LOOP
    i := i + 1;
    INSERT INTO tori.court (venue_id, name, sort) VALUES (v_id, v_court, i);
  END LOOP;
  RETURN jsonb_build_object('venue_id', v_id, 'tenant_id', v_tenant, 'inbound_address', v_addr, 'courts', i);
END $$;

CREATE OR REPLACE FUNCTION tori.enqueue_calendar_test(p_venue text, p_action text DEFAULT 'create') RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v tori.venue%ROWTYPE;
  v_id bigint;
BEGIN
  SELECT * INTO v FROM tori.venue WHERE id::text = p_venue OR slug = p_venue;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'venue % not found', p_venue;
  END IF;
  IF v.calendar_id IS NULL THEN
    RAISE EXCEPTION 'venue % has no calendar_id yet', v.slug;
  END IF;
  IF p_action NOT IN ('create', 'delete') THEN
    RAISE EXCEPTION 'action must be create or delete';
  END IF;
  INSERT INTO tori.outbox (kind, venue_id, ref, payload, max_attempts)
  VALUES ('calendar.test', v.id, 'test:' || v.id, jsonb_build_object('action', p_action), 1)
  ON CONFLICT (kind, ref) WHERE status = 'pending' AND ref IS NOT NULL
  DO UPDATE SET payload = EXCLUDED.payload, updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION tori.job_result(p_job_id bigint) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'job_id', o.id, 'kind', o.kind, 'status', o.status, 'http_status', o.last_status,
    'error', o.last_error, 'action', o.request ->> 'action', 'calendar_id', o.request ->> 'calendar_id',
    'html_link', o.result -> 'body' ->> 'htmlLink',
    'hint', CASE
      WHEN o.status = 'done' THEN 'OK — ask the owner to confirm they see the event'
      WHEN o.last_status = 404 THEN 'Wrong calendar ID, or the calendar is shared with the wrong email'
      WHEN o.last_status = 403 THEN 'Permission is not "Make changes to events"'
      WHEN o.status IN ('pending', 'running') THEN 'Still running — call again in a few seconds'
      ELSE 'See error' END)
  FROM tori.outbox o WHERE o.id = p_job_id
$$;

CREATE OR REPLACE FUNCTION tori.reset_for_reprocess(p_raw_id bigint) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r tori.raw_message%ROWTYPE;
BEGIN
  SELECT * INTO r FROM tori.raw_message WHERE id = p_raw_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'raw_message % not found', p_raw_id;
  END IF;
  IF r.venue_id IS NULL OR r.kind = 'gmail_verification' OR r.status = 'duplicate' THEN
    RETURN jsonb_build_object('raw_id', r.id, 'action', 'ignore', 'reason', 'cannot reprocess ' || r.kind || '/' || r.status);
  END IF;
  UPDATE tori.raw_message
     SET source = coalesce(tori.source_for_sender(from_address), source),
         kind = CASE WHEN tori.source_for_sender(from_address) IS NOT NULL THEN 'booking_email' ELSE kind END,
         status = 'pending_parse', parse_attempts = 0, status_reason = 'reprocess requested'
   WHERE id = r.id
  RETURNING * INTO r;
  IF r.kind NOT IN ('booking_email', 'manual_forward') THEN
    UPDATE tori.raw_message SET status = 'rejected', status_reason = 'sender is not a booking platform' WHERE id = r.id;
    RETURN jsonb_build_object('raw_id', r.id, 'action', 'ignore', 'reason', 'sender is still not a booking platform');
  END IF;
  RETURN jsonb_build_object('raw_id', r.id, 'action', 'parse');
END $$;

DROP VIEW IF EXISTS tori.v_latency_summary;
DROP VIEW IF EXISTS tori.v_latency;
DROP VIEW IF EXISTS tori.v_bookings;
DROP VIEW IF EXISTS tori.v_open_alerts;
DROP VIEW IF EXISTS tori.v_outbox_health;

CREATE VIEW tori.v_bookings AS
SELECT v.name AS venue,
       coalesce(c.display_name, c.name, s.court_label) AS court,
       to_char(s.starts_at AT TIME ZONE v.timezone, 'Dy DD Mon YYYY HH24:MI') AS starts_local,
       to_char(s.ends_at AT TIME ZONE v.timezone, 'HH24:MI') AS ends_local,
       b.source, b.source_booking_id, b.customer_name, b.customer_phone_masked, b.amount, b.payment_status,
       b.status AS booking_status, s.status AS slot_status,
       cardinality(s.clash_with) > 0 AS clash, s.review_reasons, s.calendar_state, s.calendar_html_link,
       s.starts_at, v.id AS venue_id, b.id AS booking_id, s.id AS slot_id
FROM tori.booking_slot s
JOIN tori.booking b ON b.id = s.booking_id
JOIN tori.venue v ON v.id = s.venue_id
LEFT JOIN tori.court c ON c.id = s.court_id;

CREATE VIEW tori.v_latency AS
SELECT b.venue_id, b.source, b.source_booking_id, r.email_date, r.received_at,
       min(s.first_synced_at) AS in_calendar_at,
       extract(epoch FROM min(s.first_synced_at) - coalesce(r.email_date, r.received_at))::int AS seconds_to_calendar,
       extract(epoch FROM min(s.first_synced_at) - r.received_at)::int AS seconds_inside_tori
FROM tori.booking b
JOIN tori.raw_message r ON r.id = b.first_raw_message_id
JOIN tori.booking_slot s ON s.booking_id = b.id
GROUP BY b.venue_id, b.source, b.source_booking_id, r.email_date, r.received_at;

CREATE VIEW tori.v_latency_summary AS
SELECT venue_id, count(*) AS bookings,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY seconds_to_calendar) AS median_seconds,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY seconds_to_calendar) AS p95_seconds,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY seconds_inside_tori) AS median_seconds_inside_tori
FROM tori.v_latency
WHERE seconds_to_calendar IS NOT NULL
GROUP BY venue_id;

CREATE VIEW tori.v_open_alerts AS
SELECT a.id, a.created_at, a.severity, a.kind, v.name AS venue, a.message, a.raw_message_id, a.booking_id
FROM tori.alert a LEFT JOIN tori.venue v ON v.id = a.venue_id
WHERE a.acknowledged_at IS NULL
ORDER BY a.created_at DESC;

CREATE VIEW tori.v_outbox_health AS
SELECT kind, status, count(*) AS jobs, max(updated_at) AS last_change
FROM tori.outbox GROUP BY kind, status ORDER BY kind, status;
