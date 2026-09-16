-- ---------------------------------------------------------------------------
-- 0032 — Daily alert generation schedule (Prompt 15). Additive only.
--
-- NO HTTP, AND NO SECRET IN THIS REPOSITORY.
--
-- The obvious Supabase pattern is pg_cron -> net.http_post -> Edge Function,
-- but that requires storing an invocation secret somewhere the migration can
-- read, and no secret belongs in a migration or anywhere else in this repo.
-- `cng_generate_alerts()` is a plain SQL function, so pg_cron can call it
-- IN-DATABASE and the whole class of problem disappears: no URL, no bearer
-- token, no outbound request, nothing to leak or rotate.
--
-- The `generate-alerts` Edge Function remains as an authenticated MANUAL
-- trigger (and as a path for a future hosted scheduler); it is not required for
-- the daily run.
--
-- WHY 01:00 UTC. The function derives its own calendar date from
-- `cng_business_date()`, which is Africa/Cairo — so the schedule only has to
-- land safely inside the Cairo day, not define it. pg_cron schedules in the
-- database timezone (UTC here). Cairo is UTC+2 in winter and UTC+3 in summer,
-- so 01:00 UTC is 03:00 or 04:00 Cairo: comfortably clear of the midnight
-- boundary in BOTH DST states. A schedule near 22:00 UTC would land on the
-- following Cairo day for half the year, which is exactly the kind of silent
-- off-by-one-day this avoids.
--
-- IDEMPOTENCY means the schedule is not load-bearing for correctness. A missed
-- run, a double run, or two overlapping runs cannot duplicate an alert
-- (alerts_dedupe_uq + ON CONFLICT DO NOTHING), so a retry is always safe. The
-- only cost of a missed run is that an exact-day threshold is not recorded for
-- that day.
--
-- CONDITIONAL: pg_cron ships on hosted Supabase but is not present in the local
-- verification database. Rather than fail the migration there, this schedules
-- the job where the extension exists and says so where it does not.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron is unavailable here; the daily alert job is not scheduled in this database. On the hosted project it is created by this migration.';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_cron;

  -- Re-running the migration must not stack duplicate schedules.
  PERFORM cron.unschedule(jobid)
    FROM cron.job
   WHERE jobname = 'cng-generate-alerts';

  PERFORM cron.schedule(
    'cng-generate-alerts',
    '0 1 * * *',                       -- 01:00 UTC daily; see note above
    $job$SELECT public.cng_generate_alerts();$job$
  );

  RAISE NOTICE 'Scheduled cng-generate-alerts daily at 01:00 UTC.';
END $$;
