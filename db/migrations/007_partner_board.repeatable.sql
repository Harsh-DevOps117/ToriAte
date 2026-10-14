-- The public partner board (web/): what anyone may see about a partner request.
-- Re-applied by db/migrate.sh whenever this file changes.
--
-- Privacy: no phone numbers, no raw message text, no profile details (age, gender) and only a first
-- name. Only requests that went live (opened_at, 006) are shown: never drafts, requests still waiting
-- for the person's profile, or ones dropped before they were complete. People are put
-- in touch only through the bot, after both say yes, exactly as before.
CREATE OR REPLACE VIEW public.v_partner_board AS
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
       r.skill_level,
       r.players_needed,
       left(r.notes, 140) AS notes,
       CASE WHEN r.status = 'open' AND r.window_end > now() THEN 'looking'
            WHEN r.status = 'proposed' AND r.window_end > now() THEN 'in_talks'
            WHEN r.status = 'matched' THEN 'matched'
            ELSE 'closed' END AS board_status,
       r.opened_at AS created_at,
       r.updated_at
  FROM public.partner_requests r
  LEFT JOIN public.tori_users u ON u.phone = '+' || r.wa_id
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
