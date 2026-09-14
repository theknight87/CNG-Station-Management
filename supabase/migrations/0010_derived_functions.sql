-- 0010_derived_functions.sql
-- Days Left and due status, derived — never stored.
--
-- Excel `Days Left` columns are never imported (principle #12): they are stale
-- snapshots, and the source contains -44257 on a row whose next calibration is
-- the text '2022'. These functions are the only way the system computes it.

-- Days Left in business days-of-calendar from the Africa/Cairo business date.
-- Returns NULL unless the date is exact_date precision, so a year-only,
-- unknown or invalid date can never produce a number.
CREATE OR REPLACE FUNCTION cng_days_left(p_date date, p_precision date_precision)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
           WHEN p_precision = 'exact_date' AND p_date IS NOT NULL
             THEN (p_date - cng_business_date())
           ELSE NULL
         END;
$$;

COMMENT ON FUNCTION cng_days_left(date, date_precision) IS
  'Days until a due date, or NULL unless precision is exact_date. Never 0 for an unknown date.';

-- Operational status. 'unknown' is returned for every non-exact date and is
-- deliberately distinct from 'valid': an unknown date must never read as
-- compliant, and must never read as overdue.
CREATE OR REPLACE FUNCTION cng_due_status(p_date date, p_precision date_precision)
RETURNS due_status
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
           WHEN p_precision <> 'exact_date' OR p_date IS NULL THEN 'unknown'::due_status
           WHEN p_date <  cng_business_date() THEN 'overdue'
           WHEN p_date =  cng_business_date() THEN 'due_today'
           WHEN p_date <= cng_business_date() + 7   THEN 'due_7'
           WHEN p_date <= cng_business_date() + 15  THEN 'due_15'
           WHEN p_date <= cng_business_date() + 30  THEN 'due_30'
           WHEN p_date <= cng_business_date() + 60  THEN 'due_60'
           ELSE 'valid'
         END;
$$;

COMMENT ON FUNCTION cng_due_status(date, date_precision) IS
  'overdue | due_today | due_7 | due_15 | due_30 | due_60 | valid, or unknown when the date is not exact_date.';

-- Human-readable date for the UI: the exact date, or the raw source value
-- labelled by its precision. Keeps year-only evidence visible without ever
-- letting it masquerade as a date.
CREATE OR REPLACE FUNCTION cng_date_display(p_date date, p_precision date_precision, p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE p_precision
           WHEN 'exact_date' THEN to_char(p_date, 'YYYY-MM-DD')
           WHEN 'year_only'  THEN coalesce(p_raw, '') || ' (year only)'
           WHEN 'invalid'    THEN coalesce(nullif(p_raw, ''), 'unreadable') || ' (unreadable)'
           ELSE NULL
         END;
$$;
