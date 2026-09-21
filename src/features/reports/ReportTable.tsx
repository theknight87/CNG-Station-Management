import { Link } from 'react-router-dom'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import {
  mappingStatusKind, mappingStatusLabel, type MappingStatus,
} from '@/components/data/statusSemantics'
import { DueBadge, PrecisionDate, Serial } from '@/features/units/assetDisplay'
import type { DatePrecision, DueStatus } from '@/features/units/useUnitWorkspace'
import type { ReportColumn, ReportRow, ReportSpec } from './reportSpecs'

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
  return (
    <TableScroll label={`${spec.label} report`}>
      <DataTable className="responsive-records" caption={`${spec.label}. ${spec.description}`}>
        <TableHead>
          <TableRow>
            {spec.columns.map((c) => (
              <TableHeader key={c.key} align={c.align ?? 'left'}>{c.header}</TableHeader>
            ))}
            {spec.drillThrough ? <TableHeader>Open</TableHeader> : null}
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((row) => {
            const href = spec.drillThrough ? spec.drillThrough(row) : null
            return (
              <TableRow key={String(row[spec.idColumn])}>
                {spec.columns.map((c) => (
                  <TableCell
                    key={c.key}
                    align={c.align ?? 'left'}
                    numeric={c.kind === 'number'}
                    dataLabel={c.header}
                  >
                    <Cell column={c} row={row} />
                  </TableCell>
                ))}
                {spec.drillThrough ? (
                  <TableCell dataLabel="Open">
                    {href ? (
                      <Link
                        to={href}
                        className="underline underline-offset-2"
                        // The row identifies itself, so a link list read on its
                        // own is not thirty identical "Open" links.
                        aria-label={`Open the Unit workspace for ${
                          row.unit_name ?? row.station_name ?? 'this record'
                        }`}
                      >
                        Unit
                      </Link>
                    ) : (
                      // No canonical Unit to open. Stated, not left blank and
                      // not linked to a page that would 404.
                      <span className="text-xs text-muted-foreground">
                        No confirmed Unit
                      </span>
                    )}
                  </TableCell>
                ) : null}
              </TableRow>
            )
          })}
        </TableBody>
      </DataTable>
    </TableScroll>
  )
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
        <PrecisionDate
          display={(column.displayKey ? row[column.displayKey] : null) as string | null}
          precision={(row[`${column.key.replace(/_date$/, '')}_precision`] as DatePrecision | null) ?? null}
        />
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
      return <>{String(value)}</>
    }
  }
}

