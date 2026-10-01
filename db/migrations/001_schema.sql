CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS tori;

CREATE TABLE tori.setting (
  key   text PRIMARY KEY,
  value text NOT NULL,
  note  text
);

INSERT INTO tori.setting (key, value, note) VALUES
  ('inbound_domain', 'in.toridesk.com', 'domain of the per-venue forwarding addresses'),
  ('playo_sender_regex', '(^|[@.])playo\.(co|io|club|in)$', 'lower-cased From address must match; confirm against the pilot''s real emails'),
  ('playo_forwarded_from_regex', '(^|\n)[>\s]*from:[^\n]*playo\.(co|io|club|in)', 'owner forwarded a Playo email by hand: body must contain this'),
  ('gmail_verification_sender', 'forwarding-noreply@google.com', 'Gmail "confirm forwarding" emails'),
  ('parse_max_attempts', '3', 'transient LLM failures are retried this many times before the email is marked unreadable'),
  ('review_past_days', '2', 'slot starting more than N days before the email arrived is flagged'),
  ('review_future_days', '180', 'slot starting more than N days after the email arrived is flagged');

CREATE TABLE tori.staff (
  id             bigserial PRIMARY KEY,
  name           text NOT NULL,
  whatsapp       text,
  email          text,
  copy_bookings  boolean NOT NULL DEFAULT true,
  is_ops_default boolean NOT NULL DEFAULT false,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tori.tenant (
  id                 bigserial PRIMARY KEY,
  name               text NOT NULL,
  owner_name         text,
  owner_whatsapp     text,
  owner_email        text,
  notify_owner       boolean NOT NULL DEFAULT true,
  account_manager_id bigint REFERENCES tori.staff (id),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tori.venue (
  id                  bigserial PRIMARY KEY,
  tenant_id           bigint NOT NULL REFERENCES tori.tenant (id),
  slug                text NOT NULL UNIQUE,
  name                text NOT NULL,
  inbound_address     text NOT NULL UNIQUE CHECK (inbound_address = lower(inbound_address)),
  owner_gmail         text,
  calendar_id         text,
  timezone            text NOT NULL DEFAULT 'Asia/Kolkata',
  opens_at            time,
  closes_at           time,
  status              text NOT NULL DEFAULT 'onboarding' CHECK (status IN ('onboarding', 'live', 'paused')),
  calendar_status     text NOT NULL DEFAULT 'unknown' CHECK (calendar_status IN ('unknown', 'ok', 'error')),
  quiet_alert_hours   int NOT NULL DEFAULT 24,
  forwarding_code     text,
  forwarding_code_at  timestamptz,
  last_playo_email_at timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tori.court (
  id           bigserial PRIMARY KEY,
  venue_id     bigint NOT NULL REFERENCES tori.venue (id),
  playo_name   text NOT NULL,
  display_name text,
  aliases      text[] NOT NULL DEFAULT '{}',
  sort         int NOT NULL DEFAULT 0,
  active       boolean NOT NULL DEFAULT true,
  UNIQUE (venue_id, playo_name)
);

CREATE TABLE tori.raw_message (
  id                  bigserial PRIMARY KEY,
  provider            text NOT NULL DEFAULT 'postmark',
  provider_message_id text NOT NULL,
  message_id_header   text,
  venue_id            bigint REFERENCES tori.venue (id),
  inbound_address     text,
  from_address        text,
  from_name           text,
  forwarded_for       text,
  subject             text,
  text_body           text,
  html_body           text,
  headers             jsonb NOT NULL DEFAULT '{}',
  payload             jsonb NOT NULL,
  email_date          timestamptz,
  received_at         timestamptz NOT NULL DEFAULT now(),
  kind                text NOT NULL CHECK (kind IN ('playo', 'playo_manual_forward', 'gmail_verification', 'other')),
  status              text NOT NULL DEFAULT 'received'
                      CHECK (status IN ('received', 'duplicate', 'rejected', 'pending_parse', 'applied', 'ignored', 'parse_failed')),
  status_reason       text,
  parse_result        jsonb,
  parse_model         text,
  parse_attempts      int NOT NULL DEFAULT 0,
  processed_at        timestamptz,
  bodies_purged_at    timestamptz,
  UNIQUE (provider, provider_message_id)
);
CREATE INDEX raw_message_venue_msgid ON tori.raw_message (venue_id, message_id_header);
CREATE INDEX raw_message_pending ON tori.raw_message (received_at) WHERE status = 'pending_parse';

CREATE TABLE tori.booking (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id              bigint NOT NULL REFERENCES tori.venue (id),
  playo_booking_id      text NOT NULL,
  status                text NOT NULL CHECK (status IN ('confirmed', 'cancelled')),
  customer_name         text,
  customer_phone_masked text,
  amount                numeric(10, 2),
  payment_status        text,
  sport                 text,
  first_raw_message_id  bigint REFERENCES tori.raw_message (id),
  last_raw_message_id   bigint REFERENCES tori.raw_message (id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  cancelled_at          timestamptz,
  UNIQUE (venue_id, playo_booking_id)
);

CREATE TABLE tori.booking_slot (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id         uuid NOT NULL REFERENCES tori.booking (id),
  venue_id           bigint NOT NULL REFERENCES tori.venue (id),
  court_id           bigint REFERENCES tori.court (id),
  court_label        text NOT NULL,
  court_key          text NOT NULL,
  starts_at          timestamptz NOT NULL,
  ends_at            timestamptz NOT NULL,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
  review_reasons     text[] NOT NULL DEFAULT '{}',
  clash_with         uuid[] NOT NULL DEFAULT '{}',
  gcal_event_id      text NOT NULL UNIQUE,
  calendar_state     text NOT NULL DEFAULT 'pending' CHECK (calendar_state IN ('pending', 'synced', 'deleted')),
  calendar_html_link text,
  calendar_synced_at timestamptz,
  first_synced_at    timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  cancelled_at       timestamptz,
  CHECK (ends_at > starts_at),
  UNIQUE (booking_id, court_key, starts_at)
);
CREATE INDEX booking_slot_overlap ON tori.booking_slot
  USING gist (court_id, tstzrange(starts_at, ends_at)) WHERE status = 'active';
CREATE INDEX booking_slot_booking ON tori.booking_slot (booking_id);

CREATE TABLE tori.calendar_note (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id       bigint NOT NULL REFERENCES tori.venue (id),
  raw_message_id bigint UNIQUE REFERENCES tori.raw_message (id),
  note_date      date NOT NULL,
  title          text NOT NULL,
  description    text NOT NULL,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved')),
  gcal_event_id  text NOT NULL UNIQUE,
  calendar_state text NOT NULL DEFAULT 'pending' CHECK (calendar_state IN ('pending', 'synced', 'deleted')),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tori.alert (
  id              bigserial PRIMARY KEY,
  venue_id        bigint REFERENCES tori.venue (id),
  kind            text NOT NULL,
  severity        text NOT NULL CHECK (severity IN ('info', 'warn', 'critical')),
  message         text NOT NULL,
  details         jsonb NOT NULL DEFAULT '{}',
  raw_message_id  bigint REFERENCES tori.raw_message (id),
  booking_id      uuid REFERENCES tori.booking (id),
  dedupe_key      text UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  acknowledged_at timestamptz,
  acknowledged_by text
);

CREATE TABLE tori.outbox (
  id              bigserial PRIMARY KEY,
  kind            text NOT NULL CHECK (kind IN ('calendar.sync_slot', 'calendar.note', 'calendar.test', 'whatsapp.send')),
  venue_id        bigint REFERENCES tori.venue (id),
  ref             text,
  payload         jsonb NOT NULL DEFAULT '{}',
  dedupe_key      text UNIQUE,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'failed', 'dead')),
  attempts        int NOT NULL DEFAULT 0,
  max_attempts    int NOT NULL DEFAULT 8,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_until    timestamptz,
  request         jsonb,
  result          jsonb,
  last_status     int,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  done_at         timestamptz
);
CREATE INDEX outbox_due ON tori.outbox (next_attempt_at) WHERE status IN ('pending', 'running');
CREATE UNIQUE INDEX outbox_one_pending_per_ref ON tori.outbox (kind, ref)
  WHERE status = 'pending' AND ref IS NOT NULL;
