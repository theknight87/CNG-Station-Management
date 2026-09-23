import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { ImagePlus, Pencil, Trash2 } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { useOptionalAppUser } from '@/hooks/useAppUser'
import { useSupabaseClient } from '@/lib/supabase/client'
import {
  MAX_PHOTO_BYTES, PHOTO_BUCKET, PHOTO_TYPES, asText, columnLabel, toValue,
  type ColumnMeta, type RecordRef, type Row,
} from './recordTools'

/**
 * Admin editing and photos for one record, shown inside the shared details dialog.
 *
 * THE DATABASE DECIDES. The Edit button is hidden from non-admins for UX only;
 * `cng_admin_update_record` re-checks the admin, refuses any field outside its
 * derived allowlist (hierarchy links, mapping state and raw source text are never
 * editable), refuses a stale version and writes the audit row. Photos are read
 * under each table's own RLS; only an admin can add or remove one, and removing
 * archives it.
 */

function friendly(error: { code?: string; message?: string } | null): string {
  if (!error) return 'The change could not be saved.'
  if (error.code === 'PT409' || error.code === '40001') return 'Someone else changed this record after you opened it. Close and reopen it, then try again.'
  if (error.code === '42501') return error.message?.includes('cannot be edited') ? error.message : 'Only an active administrator can do this.'
  if (error.code === '23514' || error.code === '22P02' || error.code === '23505') return `The value was refused: ${error.message}`
  return error.message ?? 'The change could not be saved.'
}

export function RecordAdminTools({ record, onSaved }: { record: RecordRef; onSaved?: () => void }) {
  const appUser = useOptionalAppUser()
  const isAdmin = appUser?.status === 'active' && appUser.user.role === 'admin'
  return (
    <div className="mt-4 space-y-4 border-t pt-4">
      <PhotosPanel record={record} isAdmin={isAdmin} />
      {isAdmin ? <EditPanel record={record} onSaved={onSaved} /> : null}
    </div>
  )
}

function EditPanel({ record, onSaved }: { record: RecordRef; onSaved?: () => void }) {
  const supabase = useSupabaseClient()
  const [open, setOpen] = useState(false)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [row, setRow] = useState<Row | null>(null)
  const [columns, setColumns] = useState<ColumnMeta[]>([])
  const [draft, setDraft] = useState<Record<string, string>>({})
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null)

  const load = useCallback(async () => {
    if (!supabase) return
    setLoadError(null)
    const { data, error } = await supabase.rpc('cng_admin_record_for_edit', { p_table: record.table, p_id: record.id })
    if (error) { setLoadError(friendly(error)); return }
    const payload = data as { row: Row; columns: ColumnMeta[] }
    setRow(payload.row)
    setColumns(payload.columns)
    setDraft(Object.fromEntries(payload.columns.map((c) => [c.name, asText(payload.row[c.name])])))
  }, [supabase, record.table, record.id])

  async function save(event: FormEvent) {
    event.preventDefault()
    if (!supabase || !row) return
    const changes: Record<string, unknown> = {}
    for (const c of columns) {
      if (draft[c.name] !== asText(row[c.name])) changes[c.name] = toValue(c, draft[c.name])
    }
    // A date typed in full is an exact date; keep its precision column in step.
    for (const name of Object.keys(changes)) {
      const precision = name.replace(/_date$/, '_precision')
      if (name.endsWith('_date') && precision !== name && columns.some((c) => c.name === precision) && !(precision in changes)) {
        changes[precision] = changes[name] === null ? 'unknown' : 'exact_date'
      }
    }
    if (Object.keys(changes).length === 0) { setMessage({ kind: 'error', text: 'Nothing was changed.' }); return }
    setSaving(true)
    setMessage(null)
    const { data, error } = await supabase.rpc('cng_admin_update_record', {
      p_table: record.table, p_id: record.id, p_expected_updated_at: row.updated_at, p_changes: changes,
    })
    setSaving(false)
    if (error) { setMessage({ kind: 'error', text: friendly(error) }); return }
    setRow(data as Row)
    setMessage({ kind: 'ok', text: `Saved ${Object.keys(changes).length} field(s). The change is in the audit log.` })
    onSaved?.()
  }

  if (!open) {
    return (
      <Button type="button" variant="outline" size="sm" onClick={() => { setOpen(true); void load() }}>
        <Pencil className="mr-1.5 h-3.5 w-3.5" aria-hidden="true" />Edit record
      </Button>
    )
  }
  if (loadError) return <p role="alert" className="text-sm text-destructive">{loadError}</p>
  if (!row) return <p role="status" className="text-sm text-muted-foreground">Loading the editable fields…</p>

  return (
    <form onSubmit={save} className="space-y-3" aria-label="Edit record">
      <p className="text-xs text-muted-foreground">
        Hierarchy links, mapping state and the original source text are not editable here. Leave a field empty to clear it.
      </p>
      <div className="grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-2">
        {columns.map((c) => {
          const id = `edit-${c.name}`
          const common = 'h-8 w-full rounded border bg-background px-2 text-sm'
          return (
            <label key={c.name} htmlFor={id} className="flex flex-col gap-0.5 text-xs text-muted-foreground">
              {columnLabel(c.name)}
              {c.type === 'enum' ? (
                <select id={id} className={common} value={draft[c.name]} onChange={(e) => setDraft({ ...draft, [c.name]: e.target.value })}>
                  {c.nullable ? <option value="">(not recorded)</option> : null}
                  {(c.enum_values ?? []).map((v) => <option key={v} value={v}>{v}</option>)}
                </select>
              ) : c.type === 'boolean' ? (
                <select id={id} className={common} value={draft[c.name]} onChange={(e) => setDraft({ ...draft, [c.name]: e.target.value })}>
                  {c.nullable ? <option value="">(not recorded)</option> : null}
                  <option value="true">Yes</option>
                  <option value="false">No</option>
                </select>
              ) : (
                <input
                  id={id} dir="auto" className={common}
                  type={c.type === 'date' ? 'date' : c.type === 'integer' || c.type === 'numeric' ? 'number' : 'text'}
                  step={c.type === 'numeric' ? 'any' : undefined}
                  value={draft[c.name]} onChange={(e) => setDraft({ ...draft, [c.name]: e.target.value })}
                />
              )}
            </label>
          )
        })}
      </div>
      {message ? (
        <p role={message.kind === 'error' ? 'alert' : 'status'} className={message.kind === 'error' ? 'text-sm text-destructive' : 'text-sm'}>
          {message.text}
        </p>
      ) : null}
      <div className="flex gap-2">
        <Button type="submit" size="sm" disabled={saving}>{saving ? 'Saving…' : 'Save changes'}</Button>
        <Button type="button" size="sm" variant="outline" onClick={() => setOpen(false)}>Close editor</Button>
      </div>
    </form>
  )
}

interface Photo { id: string; storage_path: string; caption: string | null; uploaded_at: string; url?: string }

function PhotosPanel({ record, isAdmin }: { record: RecordRef; isAdmin: boolean }) {
  const supabase = useSupabaseClient()
  const [photos, setPhotos] = useState<Photo[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [caption, setCaption] = useState('')

  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])

  useEffect(() => {
    let cancelled = false
    async function load() {
    if (!supabase) return
    try {
    const { data, error: e } = await supabase
      .from('asset_photos')
      .select('id, storage_path, caption, uploaded_at')
      .eq('entity_table', record.table).eq('entity_id', record.id).is('archived_at', null)
      .order('uploaded_at', { ascending: true })
    if (cancelled) return
    if (e) { setError('Photos could not be loaded.'); return }
    const rows = (data ?? []) as Photo[]
    const withUrls = await Promise.all(rows.map(async (p) => {
      const { data: signed } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(p.storage_path, 3600)
      return { ...p, url: signed?.signedUrl }
    }))
    if (!cancelled) setPhotos(withUrls)
    } catch {
      if (!cancelled) setError('Photos could not be loaded.')
    }
    }
    void load()
    return () => { cancelled = true }
  }, [supabase, record.table, record.id, nonce])

  async function upload(file: File) {
    if (!supabase) return
    setError(null)
    if (!PHOTO_TYPES.includes(file.type)) { setError('Use a JPG, PNG or WebP image.'); return }
    if (file.size > MAX_PHOTO_BYTES) { setError('The image is larger than 5 MB.'); return }
    setBusy(true)
    const ext = file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : 'jpg'
    const path = `${record.table}/${record.id}/${crypto.randomUUID()}.${ext}`
    const up = await supabase.storage.from(PHOTO_BUCKET).upload(path, file, { contentType: file.type, upsert: false })
    if (up.error) { setBusy(false); setError(`Upload failed: ${up.error.message}`); return }
    const { error: e } = await supabase.rpc('cng_admin_add_photo', {
      p_table: record.table, p_id: record.id, p_storage_path: path, p_content_type: file.type,
      p_byte_size: file.size, p_caption: caption || null,
    })
    setBusy(false)
    if (e) { setError(friendly(e)); return }
    setCaption('')
    reload()
  }

  async function remove(photo: Photo) {
    if (!supabase || !window.confirm('Remove this photo from the record? It is archived, not deleted.')) return
    const { error: e } = await supabase.rpc('cng_admin_archive_photo', { p_photo_id: photo.id })
    if (e) { setError(friendly(e)); return }
    reload()
  }

  return (
    <section aria-label="Photos" className="space-y-2">
      <h3 className="text-sm font-medium">Photos</h3>
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      {photos === null && !error ? <p className="text-sm text-muted-foreground">Loading photos…</p> : null}
      {photos && photos.length === 0 ? <p className="text-sm text-muted-foreground">No photos yet.</p> : null}
      {photos && photos.length > 0 ? (
        <ul className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {photos.map((p) => (
            <li key={p.id} className="space-y-1">
              {p.url ? (
                <a href={p.url} target="_blank" rel="noreferrer">
                  <img src={p.url} alt={p.caption ?? 'Record photo'} loading="lazy" className="aspect-square w-full rounded border object-cover" />
                </a>
              ) : <div className="aspect-square w-full rounded border bg-muted" />}
              <div className="flex items-start justify-between gap-1">
                <span className="break-words text-xs text-muted-foreground" dir="auto">{p.caption ?? ''}</span>
                {isAdmin ? (
                  <button type="button" onClick={() => void remove(p)} className="text-muted-foreground hover:text-destructive" aria-label="Remove photo">
                    <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
                  </button>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      ) : null}
      {isAdmin ? (
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`photo-caption-${record.id}`}>
            Caption (optional)
            <input id={`photo-caption-${record.id}`} dir="auto" className="h-8 w-48 rounded border bg-background px-2 text-sm"
                   value={caption} onChange={(e) => setCaption(e.target.value)} />
          </label>
          <label className="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded border px-3 text-sm hover:bg-muted">
            <ImagePlus className="h-3.5 w-3.5" aria-hidden="true" />{busy ? 'Uploading…' : 'Add photo'}
            <input type="file" accept={PHOTO_TYPES.join(',')} className="sr-only" disabled={busy}
                   onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void upload(f) }} />
          </label>
        </div>
      ) : null}
    </section>
  )
}
