-- The public partner board (web/): what anyone may see about a partner request.
-- Re-applied by db/migrate.sh whenever this file changes.
--
-- Privacy: no phone numbers, no raw message text, no profile details (age, gender) and only a first
-- name. Only requests that went live (opened_at, 006) are shown: never drafts, requests still waiting
-- for the person's profile, or ones dropped before they were complete. People are put
-- in touch only through the bot, after both say yes, exactly as before.
-- Who joined (011): accepted board joins and confirmed matches, first names only, in order. A game whose
-- spots (players_needed) are all taken shows as 'matched' (Full).
-- New columns go at the end: CREATE OR REPLACE VIEW can only append.
CREATE OR REPLACE VIEW public.v_partner_board AS
WITH joined AS (
  SELECT j.request_id AS id, nullif(split_part(trim(coalesce(ju.name, '')), ' ', 1), '') AS first_name, j.decided_at AS at
    FROM public.partner_joins j
    LEFT JOIN public.tori_users ju ON ju.phone = '+' || j.joiner_wa
   WHERE j.status = 'accepted'
  UNION ALL
  SELECT r.id, nullif(split_part(trim(coalesce(ou.name, o.profile_name, '')), ' ', 1), ''), m.decided_at
    FROM public.partner_matches m
    JOIN public.partner_requests r ON r.id IN (m.request_a, m.request_b)
    JOIN public.partner_requests o ON o.id = CASE WHEN m.request_a = r.id THEN m.request_b ELSE m.request_a END
    LEFT JOIN public.tori_users ou ON ou.phone = '+' || o.wa_id
   WHERE m.status = 'confirmed'),
agg AS (
  SELECT id, count(*)::int AS n, array_agg(coalesce(first_name, 'Someone') ORDER BY at) AS names
    FROM joined GROUP BY id)
SELECT r.id,
       -- what they told the bot, else their WhatsApp name; first word only
       nullif(split_part(trim(coalesce(u.name, r.profile_name, '')), ' ', 1), '') AS first_name,
       r.activity,
       r.city,
       r.area,
       r.play_date,
       r.time_exact,
       r.time_label,
       coalesce(r.part_of_day,
                CASE WHEN r.time_exact < '12:00' THEN 'morning'
                     WHEN r.time_exact < '16:00' THEN 'afternoon'
                     WHEN r.time_exact < '20:00' THEN 'evening'
                     ELSE 'night' END) AS day_part,
       r.window_start,
       r.window_end,
       coalesce(r.skill_level, u.skill_level) AS skill_level,
       r.players_needed,
       left(r.notes, 140) AS notes,
       CASE WHEN r.status = 'matched' THEN 'matched'
            WHEN r.window_end <= now() OR r.status NOT IN ('open', 'proposed') THEN 'closed'
            WHEN coalesce(a.n, 0) >= r.players_needed THEN 'matched'
            WHEN r.status = 'proposed' THEN 'in_talks'
            ELSE 'looking' END AS board_status,
       r.opened_at AS created_at,
       r.updated_at,
       r.join_code,
       coalesce(a.n, 0) AS joined_count,
       coalesce(a.names, '{}') AS joined_names
  FROM public.partner_requests r
  LEFT JOIN public.tori_users u ON u.phone = '+' || r.wa_id
  LEFT JOIN agg a ON a.id = r.id
 WHERE r.opened_at IS NOT NULL
   AND r.status IN ('open', 'proposed', 'matched', 'expired', 'cancelled')
   AND r.activity IS NOT NULL AND r.play_date IS NOT NULL AND r.window_start IS NOT NULL;

-- Supabase: not over the anon / authenticated REST API either.
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.v_partner_board FROM %I', r);
    END IF;
  END LOOP;
END $$;
