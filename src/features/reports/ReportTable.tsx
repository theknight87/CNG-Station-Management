import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Eye } from 'lucide-react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { DetailGrid, DetailItem, RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { Button } from '@/components/ui/button'
import {
  mappingStatusKind, mappingStatusLabel, type MappingStatus,
} from '@/components/data/statusSemantics'
import { DueBadge, PrecisionDate, Serial } from '@/features/units/assetDisplay'
import type { DatePrecision, DueStatus } from '@/features/units/useUnitWorkspace'
import type { ReportColumn, ReportRow, ReportSpec } from './reportSpecs'
import { humanizeAssetType, humanizeParentKind, humanizeTechnicalValue } from '@/lib/presentation/humanize'

/**
 * The report table.
 *
 * Every technical value is rendered by the SAME components the Unit workspace
 * and the management registries use — `DueBadge`, `PrecisionDate`, `Serial` —
 * so a due state, a year-only date or a serial means exactly what it means
 * everywhere else. A report that rendered its own dates would be a second
 * opinion about compliance, and there is only one.
 *
 * NULL renders as the product's quiet marker, never as `N/A`, `-` or `0`.
 */
export function ReportTable({
  spec, rows,
}: { spec: ReportSpec; rows: ReportRow[] }) {
  const [selected, setSelected] = useState<ReportRow | null>(null)
  const visible = spec.columns.filter((column) => summaryKeys(spec.id).includes(column.key))
  const selectedHref = selected && spec.drillThrough ? spec.drillThrough(selected) : null
  return (
    <>
    <TableScroll label={`${spec.label} report`}>
      <DataTable className="responsive-records compact-records" caption={`${spec.label}. ${spec.description}`}>
        <TableHead>
          <TableRow>
            {visible.map((c) => (
              <TableHeader key={c.key} align={c.align ?? 'left'}>{c.header}</TableHeader>
            ))}
            <TableHeader className="w-20">Details</TableHeader>
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((row) => {
            return (
              <TableRow key={String(row[spec.idColumn])} onClick={() => setSelected(row)} className="cursor-pointer">
                {visible.map((c) => (
                  <TableCell
                    key={c.key}
                    align={c.align ?? 'left'}
                    numeric={c.kind === 'number'}
                    dataLabel={c.header}
                  >
                    <Cell column={c} row={row} />
                  </TableCell>
                ))}
                <TableCell dataLabel="Details">
                  <Button type="button" variant="ghost" size="sm" className="h-7" onClick={(event) => { event.stopPropagation(); setSelected(row) }}>
                    <Eye className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> View
                  </Button>
                  <span className="hidden" aria-hidden="true">
                    {spec.columns.filter((column) => !visible.includes(column)).map((column) => <span key={column.key}><Cell column={column} row={row} /></span>)}
                  </span>
                </TableCell>
              </TableRow>
            )
          })}
        </TableBody>
      </DataTable>
    </TableScroll>
    <RecordDetailsDialog
      open={selected !== null}
      title={selected ? recordTitle(spec, selected) : spec.label}
      description={spec.description}
      onClose={() => setSelected(null)}
      actions={selectedHref ? <Link className="inline-flex h-9 items-center rounded bg-primary px-3 text-sm font-medium text-primary-foreground" to={selectedHref}>Open Unit workspace</Link> : undefined}
    >
      {selected ? (
        <DetailGrid>
          {spec.columns.map((column) => (
            <DetailItem key={column.key} label={column.header}><Cell column={column} row={selected} /></DetailItem>
          ))}
        </DetailGrid>
      ) : null}
    </RecordDetailsDialog>
    </>
  )
}

const SUMMARY_KEYS: Record<ReportSpec['id'], string[]> = {
  due: ['asset_type', 'station_display', 'serial_number', 'next_due_date', 'days_left', 'due_status'],
  srv: ['station_display', 'serial_number', 'manufacturer', 'next_calibration_date', 'due_status', 'mapping_status'],
  'srv-warehouse': ['serial_number', 'warehouse_code', 'availability_status', 'next_calibration_date', 'due_status'],
  vessels: ['asset_type', 'station_name', 'serial_number', 'next_inspection_date', 'due_status', 'mapping_status'],
  'gas-detectors': ['station_name', 'area_type', 'serial_number', 'next_calibration_date', 'due_status', 'mapping_status'],
  hoses: ['station_name', 'serial_number', 'description', 'next_test_date', 'due_status', 'mapping_status'],
  'data-quality': ['issue_kind', 'asset_type', 'station_name', 'severity', 'observed_at'],
  activity: ['generated_at', 'subject', 'asset_serial', 'station_name', 'state', 'email_status'],
}

function summaryKeys(id: ReportSpec['id']) { return SUMMARY_KEYS[id] }

function recordTitle(spec: ReportSpec, row: ReportRow) {
  const identity = row.serial_number ?? row.asset_serial ?? row.station_name ?? row.station_display ?? row[spec.idColumn]
  return `${spec.label}: ${String(identity ?? 'record')}`
}

function Cell({ column, row }: { column: ReportColumn; row: ReportRow }) {
  const value = row[column.key]

  switch (column.render) {
    case 'due_status':
      return <DueBadge status={(value as DueStatus | null) ?? null} />

    case 'mapping_status': {
      if (!value) return <NullValue />
      const status = value as MappingStatus
      return (
        <StatusBadge
          kind={mappingStatusKind(status)}
          label={mappingStatusLabel(status)}
          // The badge borrows a colour from compliance; the description says
          // plainly that it describes MAPPING, not whether anything is due.
          description={`Mapping state: ${mappingStatusLabel(status)}. This describes the hierarchy evidence, not a calibration state.`}
        />
      )
    }

    case 'date_display':
      return (
        <span className="whitespace-nowrap"><PrecisionDate
          display={(column.displayKey ? row[column.displayKey] : null) as string | null}
          precision={(row[`${column.key.replace(/_date$/, '')}_precision`] as DatePrecision | null) ?? null}
        /></span>
      )

    case 'serial':
      return (
        <Serial
          value={(value as string | null) ?? null}
          status={(column.statusKey ? row[column.statusKey] : null) as string | null}
        />
      )

    default: {
      if (value === null || value === undefined || value === '') return <NullValue />
      if (typeof value === 'boolean') return <>{value ? 'Yes' : 'No'}</>
      if (column.kind === 'date') return <span className="whitespace-nowrap tabular">{String(value).replace('T', ' ').slice(0, 19)}</span>
      if (column.key === 'asset_type') return <>{humanizeAssetType(String(value))}</>
      if (column.key === 'parent_kind') return <>{humanizeParentKind(String(value))}</>
      if (/(issue_kind|severity|state|subject)/.test(column.key)) return <>{humanizeTechnicalValue(String(value))}</>
      return <>{String(value)}</>
    }
  }
}

