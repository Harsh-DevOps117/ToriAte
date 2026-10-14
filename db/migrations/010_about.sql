-- "About you" (recommended, optional onboarding step): what someone says about themselves, typed or as a
-- WhatsApp voice note (transcribed by Whisper in workflow 06). The LLM turns it into a short summary for
-- match cards, a skill level (used by matching when a request doesn't state one) and extra interests.
-- Functions: 006_profile_functions.repeatable.sql (tori_save_about), 009_matching_v2.repeatable.sql (cards, matching).

ALTER TABLE public.tori_users
  ADD COLUMN IF NOT EXISTS about_text    text CHECK (length(about_text) <= 4000),   -- as typed or transcribed
  ADD COLUMN IF NOT EXISTS about_source  text CHECK (about_source IN ('text', 'voice')),
  ADD COLUMN IF NOT EXISTS about_summary text CHECK (length(about_summary) <= 200),  -- shown on match cards
  ADD COLUMN IF NOT EXISTS skill_level   text CHECK (skill_level IN ('beginner', 'intermediate', 'advanced'));
