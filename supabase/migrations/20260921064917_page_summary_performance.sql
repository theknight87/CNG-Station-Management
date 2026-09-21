-- Collapse the seven independent count requests made by Alerts and Hoses into
-- one RLS-bounded aggregate per page.  Both views are SECURITY INVOKER: the
-- source-table policies remain the authorization boundary.

create view public.v_alert_summary
with (security_invoker = true) as
with actor as materialized (
  select public.cng_current_app_user_id() as id
)
select
  count(*)::integer as total,
  count(*) filter (where a.threshold = 'overdue')::integer as overdue,
  count(*) filter (where a.threshold = 'due_today')::integer as due_today,
  count(*) filter (where a.threshold = 'due_7')::integer as due_7,
  count(*) filter (where ar.alert_id is null)::integer as unread,
  count(*) filter (where a.acknowledged_at is null)::integer as unacknowledged,
  count(*) filter (where exists (
    select 1
      from public.notification_deliveries nd
     where nd.alert_id = a.id
       and nd.channel = 'email'
       and nd.status = 'failed'
  ))::integer as delivery_failed
from public.alerts a
cross join actor
left join public.alert_reads ar
  on ar.alert_id = a.id
 and ar.app_user_id = actor.id;

comment on view public.v_alert_summary is
  'One-pass Alerts page metrics. SECURITY INVOKER preserves alerts and alert_reads RLS.';

revoke all on public.v_alert_summary from public, anon;
grant select on public.v_alert_summary to authenticated;

create view public.v_hose_summary
with (security_invoker = true) as
with classified as (
  select
    h.id,
    h.mapping_status,
    h.serial_number,
    count(*) filter (where h.serial_number is not null)
      over (partition by h.serial_number) > 1 as serial_duplicate,
    public.cng_due_status(h.next_test_date, h.next_test_precision) as due_status
  from public.hoses h
  where h.archived_at is null
)
select
  count(*)::integer as total,
  count(*) filter (where due_status = 'overdue')::integer as overdue,
  count(*) filter (where due_status in (
    'overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60'
  ))::integer as attention,
  count(*) filter (where mapping_status = 'needs_unit_mapping')::integer as needs_unit_mapping,
  count(*) filter (where due_status = 'unknown')::integer as unknown_date,
  count(*) filter (where serial_number is null)::integer as serial_missing,
  count(*) filter (where serial_number is not null and serial_duplicate)::integer as serial_duplicate
from classified;

comment on view public.v_hose_summary is
  'One-pass Hoses page metrics. SECURITY INVOKER preserves hoses RLS.';

revoke all on public.v_hose_summary from public, anon;
grant select on public.v_hose_summary to authenticated;
