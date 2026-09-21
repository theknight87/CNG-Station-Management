-- The default Reports landing page previously counted the same 2,941-row
-- union once per metric.  Aggregate every metric in one RLS-bounded scan.
create view public.v_report_due_summary
with (security_invoker = true) as
select
  count(*)::integer as total,
  count(*) filter (where due_status = 'overdue')::integer as overdue,
  count(*) filter (where due_status = 'due_today')::integer as due_today,
  count(*) filter (where due_status = 'due_7')::integer as due_7,
  count(*) filter (where due_status = 'due_30')::integer as due_30,
  count(*) filter (where due_status = 'unknown')::integer as unknown,
  count(*) filter (where mapping_status <> 'resolved')::integer as unresolved
from public.v_report_due_compliance;

comment on view public.v_report_due_summary is
  'One-pass default Due and Overdue report metrics. SECURITY INVOKER preserves source RLS.';

revoke all on public.v_report_due_summary from public, anon;
grant select on public.v_report_due_summary to authenticated;
