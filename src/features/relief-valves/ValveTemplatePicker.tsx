import { templateLabel, type ValveTemplate } from '@/features/relief-valves/valveTemplates'

/**
 * What the add-valve forms say about valves already recorded with the same manufacturer and set pressure: one
 * combination was filled in by itself; several are offered as choices; nothing is shown before both are typed.
 */
export function ValveTemplatePicker({ templates, loading, asked, filled, onPick }: {
  templates: ValveTemplate[]
  loading: boolean
  asked: boolean
  /** The template last put into the form, if any. */
  filled: ValveTemplate | null
  onPick: (t: ValveTemplate) => void
}) {
  if (!asked) {
    return <p className="text-xs text-muted-foreground">Type the manufacturer and set pressure to fill the rest from valves already recorded.</p>
  }
  if (loading) return <p className="text-xs text-muted-foreground" role="status">Looking for valves of the same manufacturer and pressure…</p>
  if (templates.length === 0) return <p className="text-xs text-muted-foreground">No valve of this manufacturer and pressure is recorded yet — fill the fields in.</p>
  if (templates.length === 1) {
    const t = templates[0]
    return (
      <p className="text-xs text-muted-foreground" role="status">
        Filled from {t.count} recorded valve{t.count === 1 ? '' : 's'} of the same manufacturer and pressure:{' '}
        <span className="font-technical text-foreground" dir="ltr">{templateLabel(t)}</span>.
      </p>
    )
  }
  return (
    <div className="flex flex-col gap-1" role="group" aria-label="Valves of the same manufacturer and pressure">
      <p className="text-xs text-muted-foreground">
        Valves of this manufacturer and pressure come in {templates.length} versions — choose one to fill the fields:
      </p>
      <div className="flex flex-wrap gap-1.5">
        {templates.map((t) => {
          const active = filled !== null && templateLabel(filled) === templateLabel(t)
          return (
            <button key={templateLabel(t)} type="button" aria-pressed={active} onClick={() => onPick(t)}
                    className={`rounded border px-2 py-1 text-left text-xs ${active ? 'border-brand-strong bg-brand-strong/10 font-medium text-brand-strong' : 'hover:bg-muted'}`}>
              <span className="font-technical" dir="ltr">{templateLabel(t)}</span>
              <span className="ml-1.5 text-muted-foreground">— {t.count} valve{t.count === 1 ? '' : 's'}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
