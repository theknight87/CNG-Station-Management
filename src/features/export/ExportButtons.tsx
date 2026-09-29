import { useState } from 'react'
import { Download } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import {
  EXPORT_MAX_ROWS, downloadBlob, exportFileName, sheetToCsv, toXlsx, type ExportSheet,
} from './exportData'

/**
 * "Excel" and "CSV" download buttons for any table (owner request 2026-09-29).
 *
 * `load` re-runs the screen's own query (all pages, the same filters, the caller's RLS) and returns the sheets to
 * write. A multi-sheet export (a Region / Station / Unit workbook) is Excel only, because a CSV holds one table.
 * The outcome is always stated: rows written, a file cut at the documented ceiling, or the failure.
 */
export function ExportButtons({ name, load, csv = true, label, className }: {
  /** File-name part, e.g. "installed-srvs" or the Station name. */
  name: string
  load: () => Promise<ExportSheet[]>
  /** Offer CSV too (single-table exports only). */
  csv?: boolean
  /** Visible prefix, e.g. "Export Station". Defaults to "Export". */
  label?: string
  className?: string
}) {
  const [busy, setBusy] = useState<'xlsx' | 'csv' | null>(null)
  const [note, setNote] = useState<{ error: boolean; text: string } | null>(null)

  async function run(format: 'xlsx' | 'csv') {
    setBusy(format); setNote(null)
    try {
      const sheets = await load()
      const rows = sheets.reduce((n, s) => n + s.rows.length, 0)
      if (format === 'csv') {
        const csvText = sheetToCsv(sheets[0])
        downloadBlob(exportFileName(name, 'csv'), new Blob([csvText], { type: 'text/csv;charset=utf-8' }))
      } else {
        downloadBlob(exportFileName(name, 'xlsx'), await toXlsx(sheets))
      }
      const cut = sheets.filter((s) => s.truncated).map((s) => s.name)
      setNote({
        error: false,
        text: cut.length
          ? `Exported ${rows.toLocaleString()} rows. ${cut.join(', ')} stopped at ${EXPORT_MAX_ROWS.toLocaleString()} rows — narrow the filters to export the rest; the file is not the whole list.`
          : `Exported ${rows.toLocaleString()} row${rows === 1 ? '' : 's'}.`,
      })
    } catch (e) {
      setNote({ error: true, text: `The export failed: ${e instanceof Error ? e.message : 'unknown error'}. Nothing was downloaded.` })
    } finally {
      setBusy(null)
    }
  }

  return (
    <span className={cn('inline-flex flex-wrap items-center gap-1.5', className)}>
      {label ? <span className="text-xs text-muted-foreground">{label}</span> : null}
      <Button type="button" size="sm" variant="outline" className="h-7" disabled={busy !== null} onClick={() => void run('xlsx')}
              aria-label={`${label ?? 'Export'} to Excel`}>
        <Download className="mr-1 h-3.5 w-3.5" aria-hidden="true" />{busy === 'xlsx' ? 'Preparing…' : 'Excel'}
      </Button>
      {csv ? (
        <Button type="button" size="sm" variant="outline" className="h-7" disabled={busy !== null} onClick={() => void run('csv')}
                aria-label={`${label ?? 'Export'} to CSV`}>
          <Download className="mr-1 h-3.5 w-3.5" aria-hidden="true" />{busy === 'csv' ? 'Preparing…' : 'CSV'}
        </Button>
      ) : null}
      {note ? (
        <span role={note.error ? 'alert' : 'status'} className={cn('basis-full text-xs', note.error ? 'text-destructive' : 'text-muted-foreground')}>
          {note.text}
        </span>
      ) : null}
    </span>
  )
}
