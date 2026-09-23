import { ChevronLeft, ChevronRight } from 'lucide-react'

import { Button } from '@/components/ui/button'
function pageCount(total: number, pageSize: number): number {
  return Math.max(1, Math.ceil(total / pageSize))
}

export function PaginationControls({ label, page, pageSize, total, visibleRows, loading = false, onPage }: {
  label: string
  page: number
  pageSize: number
  total: number
  visibleRows: number
  loading?: boolean
  onPage: (page: number) => void
}) {
  const pages = pageCount(total, pageSize)
  const safePage = Math.min(Math.max(page, 0), pages - 1)
  const selectId = `${label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}-page`
  const first = total === 0 ? 0 : safePage * pageSize + 1
  const last = total === 0 ? 0 : first + visibleRows - 1
  return <nav aria-label={`${label} pagination`} className="flex flex-wrap items-center justify-between gap-2 text-sm">
    <p className="text-muted-foreground" aria-live="polite">Showing <span className="tabular">{first.toLocaleString()}–{last.toLocaleString()} of {total.toLocaleString()}</span></p>
    <div className="flex flex-wrap items-center gap-1.5">
      <Button variant="outline" size="sm" className="h-7" disabled={loading || safePage === 0} onClick={() => onPage(safePage - 1)}><ChevronLeft className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Previous</Button>
      <label className="flex items-center gap-1 text-xs text-muted-foreground" htmlFor={selectId}><span>Page</span><select id={selectId} aria-label={`${label} page number`} name={selectId} value={safePage} onChange={(event) => onPage(Number(event.target.value))} className="h-7 rounded border bg-background px-1.5 text-foreground">{Array.from({ length: pages }, (_, index) => <option key={index} value={index}>{index + 1}</option>)}</select><span>of {pages}</span></label>
      <Button variant="outline" size="sm" className="h-7" disabled={loading || safePage + 1 >= pages} onClick={() => onPage(safePage + 1)}>Next<ChevronRight className="ml-1 h-3.5 w-3.5" aria-hidden="true" /></Button>
    </div>
  </nav>
}
