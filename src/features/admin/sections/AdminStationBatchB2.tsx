import { AdminStationBatchSection } from './AdminStationBatchSection'
import { STAGE_B2_BATCH } from '../useStationBatch'

/** Route element for /admin/station-batch: the Stage B2 batch only (Stage B is committed). */
export function AdminStationBatchB2() {
  return <AdminStationBatchSection batch={STAGE_B2_BATCH} />
}
