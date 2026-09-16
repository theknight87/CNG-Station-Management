import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { useAdminAlertRules } from '../useAdminSettings'

/**
 * Alert settings.
 *
 * The only editable property is whether a rule is ACTIVE. Subject, threshold and
 * days_before are rule identity: alerts already raised carry the threshold they
 * were raised under, and editing the window would retroactively change what
 * those alerts meant. They are shown, not offered for edit, and no function
 * exists to change them.
 */
export function AdminAlertSettingsSection() {
  const { rules, loadError, actionError, busy, setEnabled } = useAdminAlertRules()

  if (loadError) {
    return <ErrorState title="Alert settings could not be loaded" message={loadError} />
  }
  if (!rules) return <LoadingState label="Loading alert settings" />

  return (
    <section className="space-y-3" aria-labelledby="admin-alerts-heading">
      <SectionHeader
        id="admin-alerts-heading"
        title="Alert settings"
        description="Which rules generate alerts. Disabling a rule stops FUTURE generation only — an alert that was already raised stays raised and stays acknowledgeable."
      />

      {actionError ? <ErrorState title="That change was refused" message={actionError} /> : null}

      {rules.length === 0 ? (
        <EmptyState
          title="No alert rules"
          description="Alert rules are defined by migration. None is present in this database."
        />
      ) : (
        <TableScroll label="Alert rules">
          <DataTable caption="Alert rules, with the threshold each raises and whether it is active">
            <TableHead>
              <TableRow>
                <TableHeader>Subject</TableHeader>
                <TableHeader>Threshold</TableHeader>
                <TableHeader>Days before due</TableHeader>
                <TableHeader>State</TableHeader>
                <TableHeader>Action</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {rules.map((rule) => (
                <TableRow key={rule.id}>
                  <TableCell>{rule.subject}</TableCell>
                  <TableCell>{rule.threshold}</TableCell>
                  <TableCell className="tabular">
                    {rule.days_before === null ? <NullValue /> : rule.days_before}
                  </TableCell>
                  <TableCell>
                    <StatusBadge
                      kind={rule.is_enabled ? 'ok' : 'unmapped'}
                      label={rule.is_enabled ? 'Active' : 'Disabled'}
                      description={
                        rule.is_enabled
                          ? 'This rule raises alerts on the next generation run'
                          : 'This rule raises no new alert; alerts it raised before remain'
                      }
                    />
                  </TableCell>
                  <TableCell>
                    <Button
                      type="button" variant="outline" size="sm" disabled={busy}
                      aria-label={`${rule.is_enabled ? 'Disable' : 'Enable'} ${rule.subject} ${rule.threshold}`}
                      onClick={() => void setEnabled(rule, !rule.is_enabled)}
                    >
                      {rule.is_enabled ? 'Disable' : 'Enable'}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}
    </section>
  )
}
