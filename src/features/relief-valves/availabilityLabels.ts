/**
 * Warehouse availability, as the store names it (owner request 2026-10-02). Shared by the table,
 * the filters, the exports and the Reports page. Dependency-free on purpose: the report contract
 * check loads reportSpecs.ts (which imports this) directly under Node.
 */
export const AVAILABILITY_LABEL: Record<string, string> = {
  available_new: 'NEW',
  available_calibrated: 'CALIBRATED',
  available_in_store_uc: 'UNDER CALIBRATION',
  sent_to_station_received: 'AT STATION',
  sent_to_station_not_received: 'IN TRANSIT',
}
