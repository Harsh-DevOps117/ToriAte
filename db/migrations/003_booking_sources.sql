-- Bookings come from more than one platform (Playo, District by Zomato). The platform is the
-- "source"; adding another one later is an INSERT into tori.booking_source.

CREATE TABLE tori.booking_source (
  code                 text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  label                text NOT NULL,
  sender_regex         text NOT NULL,
  forwarded_from_regex text NOT NULL,
  note                 text
);

INSERT INTO tori.booking_source (code, label, sender_regex, forwarded_from_regex, note)
SELECT 'playo', 'Playo',
       coalesce((SELECT value FROM tori.setting WHERE key = 'playo_sender_regex'), '(^|[@.])playo\.(co|io|club|in)$'),
       coalesce((SELECT value FROM tori.setting WHERE key = 'playo_forwarded_from_regex'), '(^|\n)[>\s]*from:[^\n]*playo\.(co|io|club|in)'),
       'lower-cased From address must match sender_regex; confirm against the pilot''s real emails'
UNION ALL
SELECT 'district', 'District',
       '(^|[@.])district\.in$',
       '(^|\n)[>\s]*from:[^\n]*district\.in',
       'District by Zomato. Sender domain is a guess until a real District email arrives';

DELETE FROM tori.setting WHERE key IN ('playo_sender_regex', 'playo_forwarded_from_regex');

-- raw_message: kind says what the email is, source says which platform sent it.
ALTER TABLE tori.raw_message DROP CONSTRAINT raw_message_kind_check;
ALTER TABLE tori.raw_message ADD COLUMN source text REFERENCES tori.booking_source (code);
UPDATE tori.raw_message
   SET source = CASE WHEN kind IN ('playo', 'playo_manual_forward') THEN 'playo' END,
       kind = CASE kind WHEN 'playo' THEN 'booking_email' WHEN 'playo_manual_forward' THEN 'manual_forward' ELSE kind END;
ALTER TABLE tori.raw_message ADD CONSTRAINT raw_message_kind_check
  CHECK (kind IN ('booking_email', 'manual_forward', 'gmail_verification', 'other'));

-- booking: the same ID on two platforms is two different bookings.
ALTER TABLE tori.booking ADD COLUMN source text NOT NULL DEFAULT 'playo' REFERENCES tori.booking_source (code);
ALTER TABLE tori.booking ALTER COLUMN source DROP DEFAULT;
ALTER TABLE tori.booking RENAME COLUMN playo_booking_id TO source_booking_id;
ALTER TABLE tori.booking DROP CONSTRAINT booking_venue_id_playo_booking_id_key;
ALTER TABLE tori.booking ADD CONSTRAINT booking_venue_id_source_booking_key UNIQUE (venue_id, source, source_booking_id);

ALTER TABLE tori.venue RENAME COLUMN last_playo_email_at TO last_booking_email_at;

ALTER TABLE tori.court RENAME COLUMN playo_name TO name;
ALTER TABLE tori.court RENAME CONSTRAINT court_venue_id_playo_name_key TO court_venue_id_name_key;
