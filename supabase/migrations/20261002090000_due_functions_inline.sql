-- Due-date functions: same logic, now inlinable (owner report 2026-10-02: tiles and due filters load slowly).
--
-- cng_business_date(), cng_days_left() and cng_due_status() each carried `SET search_path`. PostgreSQL never
-- inlines a function that sets a configuration parameter, so every row of every view paid for a real function
-- call — and cng_due_status() calls cng_business_date() up to six times. Measured in production under the
-- owner's RLS: counting the 334 overdue installed valves took 411 ms through the function and 4 ms with the
-- identical CASE written inline (same 334 rows). Filtering any registry or report by due state paid this cost.
--
-- The bodies below are the SAME expressions, every name schema-qualified (pg_catalog.now(), public.cng_business_date(),
-- public.due_status, public.date_precision) so name resolution no longer depends on the caller's search_path, and
-- the SET clause is dropped so the planner can inline them. All three are SECURITY INVOKER and remain so; the
-- pinned-search_path rule (CLAUDE.md §10) is for SECURITY DEFINER functions, which are untouched. Volatility,
-- signatures, return types, grants and comments are unchanged; CREATE OR REPLACE keeps ownership and privileges.

CREATE OR REPLACE FUNCTION public.cng_business_date()
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (pg_catalog.now() AT TIME ZONE 'Africa/Cairo')::date;
$$;

CREATE OR REPLACE FUNCTION public.cng_days_left(p_date date, p_precision public.date_precision)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
           WHEN p_precision = 'exact_date'::public.date_precision AND p_date IS NOT NULL
             THEN (p_date - public.cng_business_date())
           ELSE NULL
         END;
$$;

CREATE OR REPLACE FUNCTION public.cng_due_status(p_date date, p_precision public.date_precision)
RETURNS public.due_status
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
           WHEN p_precision <> 'exact_date'::public.date_precision OR p_date IS NULL THEN 'unknown'::public.due_status
           WHEN p_date <  public.cng_business_date() THEN 'overdue'::public.due_status
           WHEN p_date =  public.cng_business_date() THEN 'due_today'::public.due_status
           WHEN p_date <= public.cng_business_date() + 7   THEN 'due_7'::public.due_status
           WHEN p_date <= public.cng_business_date() + 15  THEN 'due_15'::public.due_status
           WHEN p_date <= public.cng_business_date() + 30  THEN 'due_30'::public.due_status
           WHEN p_date <= public.cng_business_date() + 60  THEN 'due_60'::public.due_status
           ELSE 'valid'::public.due_status
         END;
$$;
