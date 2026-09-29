import type { DueStatus } from '@/features/units/useUnitWorkspace'

/** Due status in words. Shared by the badge and by exports, so a file never words a status differently from the screen. */
export const DUE_LABEL: Record<DueStatus, string> = {
  overdue: 'Overdue',
  due_today: 'Due today',
  due_7: 'Due ≤7d',
  due_15: 'Due ≤15d',
  due_30: 'Due ≤30d',
  due_60: 'Due ≤60d',
  valid: 'Within date',
  unknown: 'No exact date',
}
