import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { useAdminAlertRules } from '../useAdminSettings'
import {
  CHANNEL_LABELS, MANDATORY_CHANNELS, useChannelPolicy, type ChannelPolicyRow,
} from '../useChannelPolicy'

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
    <div className="space-y-6">
    <ChannelPolicySection />
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
    </div>
  )
}

/**
 * Delivery channel policy — the organization-level question, kept visibly apart
 * from the per-user opt-in at /settings.
 */
function ChannelPolicySection() {
  const { policy, loadError, actionError, busy, setEnabled } = useChannelPolicy()

  return (
    <section className="space-y-3" aria-labelledby="admin-channels-heading">
      <SectionHeader
        id="admin-channels-heading"
        title="Delivery channels"
        description="Whether a channel is available to the organization at all. This is not a user preference: a user still has to opt in at Settings, and disabling a channel here changes nobody's preference — re-enabling restores the same audience."
      />
      {actionError ? <ErrorState title="That change was refused" message={actionError} /> : null}
      {loadError ? (
        <ErrorState title="Channel policy could not be loaded" message={loadError} />
      ) : !policy ? (
        <LoadingState label="Loading channel policy" />
      ) : (
        <TableScroll label="Delivery channel policy">
          <DataTable caption="Organization delivery channel policy, and whether each channel may be turned off">
            <TableHead>
              <TableRow>
                <TableHeader>Channel</TableHeader>
                <TableHeader>Organization policy</TableHeader>
                <TableHeader>Effective delivery requires</TableHeader>
                <TableHeader>Action</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {policy.map((row) => (
                <ChannelRow key={row.channel} row={row} busy={busy}
                            onToggle={(next) => void setEnabled(row, next)} />
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}
    </section>
  )
}

function ChannelRow({
  row, busy, onToggle,
}: { row: ChannelPolicyRow; busy: boolean; onToggle: (next: boolean) => void }) {
  const mandatory = MANDATORY_CHANNELS.includes(row.channel)
  return (
    <TableRow>
      <TableCell>{CHANNEL_LABELS[row.channel] ?? row.channel}</TableCell>
      <TableCell>
        <StatusBadge
          kind={row.is_enabled ? 'ok' : 'unmapped'}
          label={row.is_enabled ? (mandatory ? 'Always on' : 'Available') : 'Disabled'}
          description={
            mandatory
              ? 'In-app alerts are the read surface for compliance state and cannot be switched off'
              : row.is_enabled
                ? 'The organization permits this channel; each user still chooses whether to receive it'
                : 'Suppressed for everyone. No user preference was changed'
          }
        />
      </TableCell>
      <TableCell wrap className="text-xs text-muted-foreground">
        {mandatory
          ? 'Nothing — every user who may read an alert sees it in the application.'
          : 'This policy AND the user\'s own opt-in at Settings.'}
      </TableCell>
      <TableCell>
        {mandatory ? (
          // A toggle that always refuses would be a lie in the shape of a
          // control. The reason is stated instead.
          <span className="text-xs text-muted-foreground">
            Cannot be disabled — it is the alert read surface, not a delivery channel
          </span>
        ) : (
          <Button
            type="button" variant="outline" size="sm" disabled={busy}
            aria-label={`${row.is_enabled ? 'Disable' : 'Enable'} ${CHANNEL_LABELS[row.channel] ?? row.channel} delivery for the organization`}
            onClick={() => onToggle(!row.is_enabled)}
          >
            {row.is_enabled ? 'Disable' : 'Enable'}
          </Button>
        )}
      </TableCell>
    </TableRow>
  )
}
