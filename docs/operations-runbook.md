# Operations runbook — backup, restore, monitoring

Project: Supabase `cng-station-management` (ref `ypkggegquetvpsflkaxg`), Cloudflare Pages
`cng-station-management`. Check the ref before every command (CLAUDE.md §2 rule 6).

## 1. Backups

The project is on the **Free plan, which has no automatic backups**. Until it moves to Pro (daily backups,
7-day retention), take manual dumps.

**When:** weekly, and always **before** any approved production write (a batch commit, an import, a
migration).

```bash
# Get the connection string: Dashboard → Project Settings → Database → Connection string (Session pooler).
# Keep it in your shell only. Never commit it or paste it into a document.
export DB_URL='postgresql://...'
stamp=$(date +%Y%m%d-%H%M)
npx supabase db dump --db-url "$DB_URL" --role-only -f "cng-$stamp-roles.sql"
npx supabase db dump --db-url "$DB_URL"             -f "cng-$stamp-schema.sql"
npx supabase db dump --db-url "$DB_URL" --data-only --use-copy -f "cng-$stamp-data.sql"
```

- The dumps contain personal data (`app_users`, `auth.users`) and must be treated as confidential.
  Store them encrypted, outside the repository (for example an encrypted drive or a private bucket).
- Keep at least the last 4 weekly dumps and every pre-change dump.
- **Check each dump**: the files are non-empty, and `grep -c 'COPY public.stations' cng-*-data.sql` returns 1.

## 2. Restore

The schema is rebuildable from the repository. The **data is only in the dumps**.

**Into a new project (disaster recovery):**
1. Create a new Supabase project in this project's own organization (never the Coding System's).
2. Apply the schema: `supabase/migrations/*` in order (`npx supabase db push --db-url "$NEW_DB_URL"`).
   `20260920204210_bootstrap_initial_admin.sql` is a no-op placeholder for production's one-off first-admin
   step; after restoring a data dump the admin already exists. On an EMPTY new project, follow §2a.
3. Load data: `psql "$NEW_DB_URL" -v ON_ERROR_STOP=1 -f cng-<stamp>-data.sql`.
4. Re-create Edge Function secrets (docs/alerts-notifications.md), re-deploy `generate-alerts` and
   `send-notifications`, and point the Cloudflare `VITE_SUPABASE_*` variables at the new project,
   then redeploy Pages.
5. Verify: run the row counts in §3, sign in as the admin, and open Dashboard, Alerts and Reports.

### 2a. First administrator on an empty project

1. Sign up once through the app's `/sign-up` page and confirm the email. The account becomes an inactive viewer.
2. As the database owner (SQL editor or `psql`, never from the browser), run, replacing the address:

   ```sql
   do $$ declare n int; begin
     update public.app_users p set role = 'admin', is_active = true, updated_at = now()
       from auth.users u
      where p.auth_user_id = u.id and lower(u.email) = lower('owner@example.com') and u.email_confirmed_at is not null;
     get diagnostics n = row_count;
     if n <> 1 then raise exception 'expected exactly one confirmed account, updated %', n; end if;
   end $$;
   ```
3. Sign in; every further user is activated from Admin → Users (audited).

**Restore test:** once a quarter, restore the latest dump into a scratch database
(`bash scripts/verify-all.sh` also builds one from migrations) and compare the §3 counts.
A backup that has never been restored is not known to work.

## 3. Health checks

Run in the SQL editor (read-only):

```sql
select (select count(*) from stations) stations, (select count(*) from units) units,
       (select count(*) from storage_vessels) sv, (select count(*) from recovery_tanks) rt,
       (select count(*) from gas_detectors) gd, (select count(*) from hoses) hoses,
       (select count(*) from installed_relief_valves) irv, (select count(*) from warehouse_relief_valves) wrv;

-- Daily alert generation ran in the last 26 hours
select jobname, status, start_time from cron.job_run_details d join cron.job j using (jobid)
 where jobname = 'cng-generate-alerts' order by start_time desc limit 3;

-- Tables without RLS (must be 0)
select count(*) from pg_tables where schemaname='public' and not rowsecurity;
```

## 4. Monitoring

| What | Where | How often |
| --- | --- | --- |
| Security and performance advisors | Dashboard → Advisors | weekly, and after every migration |
| Failed alert runs | `cron.job_run_details` (§3) | weekly |
| Failed notification deliveries | Admin → Notification Activity report | weekly |
| Edge Function errors | Dashboard → Edge Functions → Logs | when a delivery fails |
| Auth errors and sign-up spikes | Dashboard → Logs → Auth | weekly |
| CI gate | GitHub → Actions → `verify` | every push |
| Pages build | Cloudflare → Pages → Deployments | every merge to `main` |

Pending accounts (new sign-ups are inactive viewers) appear in Admin → Users. Check them weekly and activate
only people you know.
