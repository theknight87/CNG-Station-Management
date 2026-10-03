-- Undo an issue of a hose or a gas detector, part 2 of 2 (see 20261003090000): the Log takes an 'issue_undone'
-- entry, the history an 'issue_undone' event, and an item is open in the Log at most once among entries that are
-- not closed (the replacement indexes were created in part 1). No row is touched: every existing entry is
-- 'replaced_on_issue' and every existing event is already allowed.
ALTER TABLE equipment_field_log DROP CONSTRAINT equipment_field_log_reason_check;
ALTER TABLE equipment_field_log ADD CONSTRAINT equipment_field_log_reason_check
  CHECK (reason IN ('replaced_on_issue', 'issue_undone'));
DROP INDEX efl_open_hose_uq;
DROP INDEX efl_open_detector_uq;
ALTER TABLE equipment_history DROP CONSTRAINT equipment_history_event_check;
ALTER TABLE equipment_history ADD CONSTRAINT equipment_history_event_check
  CHECK (event IN ('added', 'issued', 'replaced', 'received', 'sent_to_calibration', 'returned_from_calibration',
                   'certified', 'issue_undone'));
