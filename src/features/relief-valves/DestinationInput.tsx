import { useId, useMemo, useState } from 'react'

import { destinationLabel, type Destination, type DestinationOption } from '@/features/relief-valves/destinationOptions'

/**
 * A store valve's destination: a Station or one of its Units, or nothing (owner request 2026-10-04). One searchable
 * field over the canonical Stations and Units — only a name from the list is accepted, so no Station is invented;
 * an empty field means no destination. The database derives the Region and checks the Unit belongs to the Station.
 * `onChange` receives the chosen destination, `null` for an empty field, or `undefined` while the text
 * matches no Station or Unit (the form should not save then).
 */
export function DestinationInput({ options, value, onChange, label, className }: {
  options: DestinationOption[]
  value: Destination | null
  onChange: (d: Destination | null | undefined) => void
  label: string
  className?: string
}) {
  const listId = useId()
  const known = destinationLabel(options, value)
  const [text, setText] = useState<string | null>(null)
  const shown = text ?? known
  const byLabel = useMemo(() => new Map(options.map((o) => [o.label, o])), [options])
  const unmatched = shown.trim() !== '' && !byLabel.has(shown.trim())

  function change(t: string) {
    setText(t)
    const hit = byLabel.get(t.trim())
    onChange(t.trim() === '' ? null : hit ? { station_id: hit.station_id, unit_id: hit.unit_id } : undefined)
  }

  return (
    <span className={`flex flex-col gap-0.5 ${className ?? ''}`}>
      <input dir="auto" list={listId} aria-label={label} aria-invalid={unmatched || undefined} value={shown}
             placeholder="Station or Unit (optional)" onChange={(e) => change(e.target.value)}
             className={`h-8 w-full rounded border bg-background px-2 text-sm text-foreground ${unmatched ? 'border-destructive' : ''}`} />
      <datalist id={listId}>{options.map((o) => <option key={o.label} value={o.label} />)}</datalist>
      {unmatched ? <span className="text-xs text-destructive">Choose a Station or Unit from the list, or leave it empty.</span> : null}
    </span>
  )
}
