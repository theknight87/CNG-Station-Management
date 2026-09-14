-- 0013_seed_reference_data.sql
-- Reference data only. NO production, sample, or fabricated asset data.
--
-- Two things are seeded, both of which are definitions rather than observations:
--   1. the six canonical regions
--   2. the default alert thresholds for every alert subject
--
-- No station, unit, or asset rows are seeded. No analytical figure from the
-- source analysis (such as the 41% overdue-vessel finding) appears anywhere.

INSERT INTO regions (code, name, sort_order) VALUES
  ('east',  'East',  1),
  ('west',  'West',  2),
  ('canal', 'Canal', 3),
  ('delta', 'Delta', 4),
  ('alex',  'Alex',  5),
  ('upper', 'Upper', 6)
ON CONFLICT (code) DO NOTHING;

-- Default alert thresholds: 60 / 30 / 15 / 7 / due today / overdue, for every
-- subject. Seeding all five subjects up front is what keeps the engine generic —
-- adding a new asset type later needs no schema change, only rows.
INSERT INTO alert_rules (subject, threshold, days_before, description)
SELECT s.subject, t.threshold, t.days_before,
       format('%s — %s', s.subject, t.threshold)
FROM (VALUES
        ('srv_calibration'::alert_subject),
        ('storage_inspection'),
        ('recovery_tank_inspection'),
        ('gas_detector_calibration'),
        ('hose_hydrotest')
     ) AS s(subject)
CROSS JOIN (VALUES
        ('due_60'::alert_threshold, 60),
        ('due_30', 30),
        ('due_15', 15),
        ('due_7',   7),
        ('due_today', NULL),
        ('overdue',   NULL)
     ) AS t(threshold, days_before)
ON CONFLICT (subject, threshold) DO NOTHING;
