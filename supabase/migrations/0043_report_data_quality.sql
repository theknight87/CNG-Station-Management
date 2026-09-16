-- ---------------------------------------------------------------------------
-- 0043 — Two corrections to the Reports module (Prompt 20A). Additive.
--
-- DEFECT 1: the Data Quality report read `v_data_quality_queue` alone, which
-- covers CANONICAL assets only. Production has committed no canonical assets
-- yet, so the report read "clean" while the staged import carried real,
-- unresolved data-quality evidence — including the `stale_source_decision`
-- state Prompt 19B added precisely so a lapsed ruling stays visible. A
-- compliance report that says "nothing to see" while the evidence exists is
-- worse than no report.
--
-- DEFECT 2: `v_gas_detector_management` deliberately UNIONs installed detectors
-- with recorded ABSENCE — a "not installed" row is EVIDENCE, not a device, and
-- carries `detector_id IS NULL`. Migration 0042 filtered those out of the due
-- report but the gas-detector ASSET report did not, so recorded absence could
-- render as an installed detector with no serial, and a NULL identity column
-- makes pagination non-deterministic.
--
-- AUTHORIZATION IS NOT WEAKENED TO FIX EITHER.
--
--   `import_staging_rows`, `import_issues` and `import_mapping_decisions` are
--   all manager/admin-only by their existing SELECT policies, because raw
--   source text is never an authorization boundary (CLAUDE.md §10) and a record
--   whose Station is unconfirmed has no proven Region to scope it by.
--
--   Because `v_report_data_quality` is `security_invoker`, each UNION branch is
--   bounded by ITS OWN source's RLS. The layering is therefore automatic:
--
--     viewer / engineer -> the canonical branch, within their Regions, and
--                          NOTHING from staging or import issues
--     manager / admin   -> all three layers, company-wide
--
--   No policy is relaxed, no grant widened, and no Admin-only view is exposed
--   to a Region-scoped role. The view simply inherits what each source already
--   decided.
-- ---------------------------------------------------------------------------

CREATE VIEW v_report_data_quality
WITH (security_invoker = true) AS

-- ---- LAYER 1: canonical assets ------------------------------------------
-- Region-scoped by the asset tables' own policies. This is the layer a viewer
-- or engineer sees, and the only one.
SELECT
  'canonical'::text          AS source_layer,
  -- A key that is unique ACROSS layers, so pagination has a stable, non-null
  -- tiebreak even though the three branches come from three tables.
  'canonical:' || q.asset_id::text AS dq_key,
  q.asset_id                 AS record_id,
  q.asset_type::text         AS asset_type,
  q.mapping_status           AS issue_kind,
  q.region_id, r.name        AS region_name,
  q.station_id, s.station_name,
  q.unit_id,
  q.review_reason            AS detail,
  NULL::text                 AS severity,
  NULL::text                 AS source_file,
  NULL::text                 AS source_sheet,
  NULL::integer              AS source_row,
  NULL::text                 AS raw_station,
  q.needs_review,
  q.updated_at               AS observed_at
FROM v_data_quality_queue q
LEFT JOIN regions  r ON r.id = q.region_id
LEFT JOIN stations s ON s.id = q.station_id

UNION ALL

-- ---- LAYER 2: staged rows awaiting, or carrying, a pre-import decision ----
-- Manager/admin only, via `import_staging_rows_select`. `stale_source_decision`
-- is kept DISTINCT from "awaiting" and from "decided": a decision that lapsed
-- because the workbook changed is a different fact from never having decided,
-- and collapsing them would hide why a previous ruling stopped counting.
SELECT
  'staged',
  'staged:' || m.staging_row_id::text,
  m.staging_row_id,
  CASE m.target_table
    WHEN 'storage_vessels' THEN 'storage_vessel'
    WHEN 'recovery_tanks'  THEN 'recovery_tank'
    WHEN 'gas_detectors'   THEN 'gas_detector'
    WHEN 'hoses'           THEN 'hose'
    ELSE m.target_table
  END,
  CASE
    WHEN m.decision_is_stale_source THEN 'stale_source_decision'
    WHEN m.decision_id IS NULL      THEN 'staged_awaiting_decision'
    ELSE 'staged_decision_recorded'
  END,
  -- A staged row has no CONFIRMED Region or Station — that is the whole point
  -- of it being staged — so the hierarchy columns are NULL and the raw source
  -- Station name is carried separately, as evidence rather than as identity.
  NULL::uuid, NULL::text,
  m.confirmed_station_id, m.confirmed_station_name,
  m.confirmed_unit_id,
  m.source_row_key,
  NULL::text,
  m.source_file, m.source_sheet, m.source_row,
  m.raw_station,
  (m.decision_id IS NULL OR m.decision_is_stale_source),
  m.updated_at
FROM v_admin_staged_mapping_queue m

UNION ALL

-- ---- LAYER 3: the import issue taxonomy ----------------------------------
-- Manager/admin only, via `import_issues_select`. `issue_type` is the EXISTING
-- enum, exposed as it is: no issue type is invented here to match a wording,
-- and none is renamed.
SELECT
  'import_issue',
  'issue:' || i.id::text,
  i.id,
  i.entity_type::text,
  i.issue_type::text,
  i.region_id, r.name,
  i.station_id, s.station_name,
  NULL::uuid,
  i.detail,
  i.severity::text,
  i.source_file, i.source_sheet, i.source_row,
  i.source_value,
  (i.status = 'open'),
  i.updated_at
FROM import_issues i
LEFT JOIN regions  r ON r.id = i.region_id
LEFT JOIN stations s ON s.id = i.station_id
WHERE i.status = 'open';

COMMENT ON VIEW v_report_data_quality IS
  'Unified READ-ONLY data-quality reporting across three layers: canonical assets (Region-scoped), staged pre-import rows and open import issues (both manager/admin only by their sources'' own policies). security_invoker, so each branch keeps its own RLS and a viewer sees the canonical layer alone. Reports never mutate: mapping corrections remain in Admin -> Data Quality.';

GRANT SELECT ON v_report_data_quality TO authenticated;

-- ---------------------------------------------------------------------------
-- Installed gas detectors only.
--
-- `v_gas_detector_management` UNIONs installed assets with recorded ABSENCE, so
-- the registry can state "this area has no detector" as evidence. That row is
-- not a device: it has no serial, no calibration and `detector_id IS NULL`.
--
-- Filtering that in the client would be a presentation decision about what is
-- and is not a physical asset, and would leave a NULL identity column in a
-- paginated result — where a non-deterministic sort key silently duplicates or
-- omits rows. The filter therefore lives here, in the database, and the report
-- orders by a column that cannot be NULL.
-- ---------------------------------------------------------------------------
CREATE VIEW v_report_gas_detectors
WITH (security_invoker = true) AS
SELECT g.*
FROM v_gas_detector_management g
WHERE g.detector_id IS NOT NULL;

COMMENT ON VIEW v_report_gas_detectors IS
  'Installed gas detectors only. Recorded ABSENCE (detector_id IS NULL) is evidence that an area has no detector, never a device, and is excluded here so it cannot be reported as an installed asset or destabilise pagination. security_invoker: the underlying detector policies still decide.';

GRANT SELECT ON v_report_gas_detectors TO authenticated;

-- No new index. Both views are thin wrappers over sources whose predicates and
-- orderings are already indexed; `import_issues_open_idx` already covers the
-- `status = 'open'` filter this view applies.
