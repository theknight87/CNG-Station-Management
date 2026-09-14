import { PagePlaceholder } from '@/components/PagePlaceholder'

export function AdminView() {
  return (
    <PagePlaceholder
      title="Admin"
      description="User roles and regional scope, data quality queue, and source imports."
      plannedFor="Phases 6-7 — user management and import tooling."
    >
          <p className="text-sm text-muted-foreground">
          Includes the Data Quality queue: SRVs and other imported records whose Station, Unit or
          parent equipment could not be determined from the source, retained for human resolution
          rather than guessed or discarded.
        </p>
    </PagePlaceholder>
  )
}
