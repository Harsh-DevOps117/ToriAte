INSERT INTO tori.staff (id, name, whatsapp, email, copy_bookings, is_ops_default)
VALUES (1, 'Ravi', '+91 90000 00099', 'ravi@toridesk.com', true, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO tori.tenant (id, name, owner_name, owner_whatsapp, account_manager_id)
VALUES (1, 'Smash Arena Sports LLP', 'Anil Mehta', '+91 90000 00001', 1)
ON CONFLICT (id) DO NOTHING;

INSERT INTO tori.venue (id, tenant_id, slug, name, inbound_address, owner_gmail, calendar_id,
                        opens_at, closes_at, status, calendar_status)
VALUES (1, 1, 'smash-arena', 'Smash Arena', 'smash-arena-demo0001@in.toridesk.com', 'owner.smasharena@gmail.com',
        'smasharena-bookings@group.calendar.google.com', '06:00', '23:00', 'live', 'unknown'),
       (2, 1, 'smash-arena-2', 'Smash Arena Annexe', 'smash-arena-2-demo0002@in.toridesk.com', NULL, NULL,
        '06:00', '01:00', 'onboarding', 'unknown')
ON CONFLICT (id) DO NOTHING;

INSERT INTO tori.court (venue_id, playo_name, display_name, aliases, sort) VALUES
  (1, 'Court 1', NULL, '{"Badminton Court 1"}', 1),
  (1, 'Court 2', NULL, '{"Badminton Court 2"}', 2),
  (1, 'Court 3', NULL, '{"Badminton Court 3"}', 3),
  (2, 'Turf A', NULL, '{}', 1)
ON CONFLICT (venue_id, playo_name) DO NOTHING;

DO $$ BEGIN
  PERFORM setval('tori.staff_id_seq', greatest((SELECT max(id) FROM tori.staff), 1));
  PERFORM setval('tori.tenant_id_seq', greatest((SELECT max(id) FROM tori.tenant), 1));
  PERFORM setval('tori.venue_id_seq', greatest((SELECT max(id) FROM tori.venue), 1));
END $$;
