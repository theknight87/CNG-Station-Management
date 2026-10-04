import type { Whereabout } from '@/features/relief-valves/serialWhereabouts'

/** One serial's places in the system: red when it cannot be added again, muted for an old store-sheet record. */
export function SerialWhereaboutsNote({ places, closes }: { places: Whereabout[] | undefined; closes?: boolean }) {
  if (!places?.length) return null
  const blocking = places.filter((w) => w.blocking)
  if (blocking.length) {
    return (
      <p className="text-xs text-destructive" role="alert" dir="auto">
        Already recorded — {blocking.map((w) => w.place).join(', ')}
      </p>
    )
  }
  return (
    <p className="text-xs text-muted-foreground" dir="auto">
      {places.map((w) => w.place).join(', ')}{closes ? ' — that old record will be closed when you add this valve.' : ''}
    </p>
  )
}
