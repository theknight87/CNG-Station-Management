import { useState, type FormEvent, type ReactNode } from 'react'
import { Link, useNavigate } from 'react-router-dom'

import { Button } from '@/components/ui/button'
import { BrandMark } from '@/components/layout/BrandMark'
import { useAuth } from '@/features/auth/AuthProvider'
import { useSupabaseClient } from '@/lib/supabase/client'

/** Minimum length matches the Supabase Auth project setting. */
export const MIN_PASSWORD_LENGTH = 8

/**
 * The same sentence is shown whether or not the address has an account, and
 * whether or not the request succeeded, so the form cannot be used to find out
 * who has an account.
 */
export const RESET_REQUESTED =
  'If an account exists for that address, a password reset link has been sent. Check your inbox.'

const INPUT = 'h-12 w-full rounded-md border border-slate-300 bg-white px-3.5 text-base shadow-sm hover:border-slate-400 focus:border-brand-strong'
const LINK = 'font-semibold text-brand-strong underline decoration-brand/35 underline-offset-4 hover:text-brand-deep'

function AuthCard({ titleId, title, children }: { titleId: string; title: string; children: ReactNode }) {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-slate-100 px-5 py-8">
      <section className="w-full max-w-md" aria-labelledby={titleId}>
        <div className="mb-6 flex flex-col items-center text-center">
          <BrandMark variant="full" className="h-24 w-auto" />
          <p className="mt-3 text-lg font-semibold tracking-tight">CNG Station Management</p>
        </div>
        <div className="border border-slate-200 bg-white p-6 sm:p-8">
          <h1 id={titleId} className="mb-5 text-2xl font-semibold tracking-tight text-slate-950">{title}</h1>
          {children}
        </div>
      </section>
    </main>
  )
}

export function ForgotPasswordPage() {
  const supabase = useSupabaseClient()
  const [email, setEmail] = useState('')
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setBusy(true)
    await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/reset-password` })
    setBusy(false)
    setSent(true)
  }

  return (
    <AuthCard titleId="forgot-title" title="Reset your password">
      {sent ? (
        <p role="status" className="text-sm leading-6">{RESET_REQUESTED}</p>
      ) : (
        <form className="space-y-4" onSubmit={submit}>
          <label className="block text-sm font-semibold text-slate-800" htmlFor="forgot-email">Email address</label>
          <input id="forgot-email" className={INPUT} type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <Button className="h-12 w-full bg-brand-strong text-brand-strong-fg hover:bg-brand-deep" type="submit" disabled={busy}>{busy ? 'Sending…' : 'Send reset link'}</Button>
        </form>
      )}
      <p className="mt-6 text-center text-sm text-muted-foreground"><Link className={LINK} to="/sign-in">Back to sign in</Link></p>
    </AuthCard>
  )
}

export function ResetPasswordPage() {
  const supabase = useSupabaseClient()
  const { session, loading } = useAuth()
  const navigate = useNavigate()
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    if (password.length < MIN_PASSWORD_LENGTH) return setError(`Use at least ${MIN_PASSWORD_LENGTH} characters.`)
    if (password !== confirm) return setError('The two passwords do not match.')
    setBusy(true)
    setError(null)
    const result = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (result.error) setError('The password could not be changed. The link may have expired; request a new one.')
    else navigate('/dashboard', { replace: true })
  }

  if (loading) return <AuthCard titleId="reset-title" title="Choose a new password"><p role="status" className="text-sm">Checking your reset link…</p></AuthCard>

  // The recovery link signs the browser in. Without that session there is nothing to update.
  if (!session) {
    return (
      <AuthCard titleId="reset-title" title="Choose a new password">
        <p role="alert" className="text-sm leading-6">This reset link is invalid or has expired.</p>
        <p className="mt-6 text-center text-sm"><Link className={LINK} to="/forgot-password">Request a new link</Link></p>
      </AuthCard>
    )
  }

  return (
    <AuthCard titleId="reset-title" title="Choose a new password">
      <form className="space-y-4" onSubmit={submit}>
        <label className="block text-sm font-semibold text-slate-800" htmlFor="reset-password">New password</label>
        <input id="reset-password" className={INPUT} type="password" autoComplete="new-password" required minLength={MIN_PASSWORD_LENGTH} value={password} onChange={(e) => setPassword(e.target.value)} />
        <label className="block text-sm font-semibold text-slate-800" htmlFor="reset-confirm">Confirm new password</label>
        <input id="reset-confirm" className={INPUT} type="password" autoComplete="new-password" required value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        {error ? <p role="alert" className="border-l-2 border-destructive bg-red-50 px-3 py-2 text-sm text-destructive">{error}</p> : null}
        <Button className="h-12 w-full bg-brand-strong text-brand-strong-fg hover:bg-brand-deep" type="submit" disabled={busy}>{busy ? 'Saving…' : 'Save new password'}</Button>
      </form>
    </AuthCard>
  )
}
