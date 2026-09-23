import { useState, type FormEvent } from 'react'
import { Link, Navigate, useLocation } from 'react-router-dom'
import { CheckCircle2, LockKeyhole, ShieldCheck } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { BrandMark } from '@/components/layout/BrandMark'
import { useAuth } from '@/features/auth/AuthProvider'
import { useSupabaseClient } from '@/lib/supabase/client'

const SIGN_IN_FAILURE = 'Email or password is incorrect. Please try again.'

/** First-party Supabase email/password and Google sign-in. */
export function SignInPage() {
  const supabase = useSupabaseClient()
  const { session, loading: authLoading } = useAuth()
  const location = useLocation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const googleEnabled = import.meta.env.VITE_ENABLE_GOOGLE_AUTH === 'true'

  const requestedDestination = (location.state as { from?: string } | null)?.from
  const destination = requestedDestination?.startsWith('/') ? requestedDestination : '/dashboard'
  if (!authLoading && session) return <Navigate to={destination} replace />

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setBusy(true)
    setError(null)
    const result = await supabase.auth.signInWithPassword({ email, password })
    setBusy(false)
    if (result.error) setError(SIGN_IN_FAILURE)
  }

  async function signInWithGoogle() {
    if (!supabase) return
    setBusy(true)
    setError(null)
    const { error: oauthError } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}${destination}` },
    })
    if (oauthError) {
      setBusy(false)
      setError('Google sign-in could not be started. Please try again.')
    }
  }

  return (
    <main className="min-h-dvh overflow-x-hidden bg-slate-100 lg:fixed lg:inset-0 lg:grid lg:min-h-0 lg:grid-cols-[minmax(21rem,0.9fr)_minmax(32rem,1.1fr)] lg:overflow-hidden">
      <section className="relative hidden min-h-0 overflow-hidden bg-brand-deep px-12 py-6 text-brand-deep-fg lg:flex lg:h-full lg:flex-col" aria-label="CNG Station Management">
        <div className="absolute inset-x-0 top-0 h-1 bg-brand-yellow" aria-hidden="true" />
        <div className="absolute -bottom-36 -right-36 h-96 w-96 rounded-full border border-white/10" aria-hidden="true" />
        <div className="absolute -bottom-20 -right-20 h-64 w-64 rounded-full border border-brand-yellow/20" aria-hidden="true" />

        <div className="relative flex items-center gap-5">
          <div className="flex h-28 w-24 shrink-0 items-center justify-center bg-white p-2 shadow-xl shadow-black/15">
            <BrandMark variant="full" className="h-24 w-auto" />
          </div>
          <div>
            <p className="text-xl font-semibold tracking-tight">CNG Station Management</p>
            <p className="text-sm text-white/65">Cargas NGV Operations</p>
          </div>
        </div>

        <div className="relative my-auto max-w-lg py-12">
          <p className="mb-4 text-xs font-semibold uppercase tracking-[0.2em] text-brand-yellow">Operations portal</p>
          <h1 className="text-4xl font-semibold leading-tight tracking-tight">One secure view of every station and asset.</h1>
          <p className="mt-5 max-w-md text-base leading-7 text-white/70">Monitor inspections, calibration dates and operational readiness across the Regions assigned to you.</p>

          <ul className="mt-7 space-y-3 text-sm text-white/85">
            <li className="flex items-center gap-3"><CheckCircle2 className="h-5 w-5 text-brand-yellow" aria-hidden="true" />Live operational records</li>
            <li className="flex items-center gap-3"><ShieldCheck className="h-5 w-5 text-brand-yellow" aria-hidden="true" />Role and Region controlled access</li>
            <li className="flex items-center gap-3"><LockKeyhole className="h-5 w-5 text-brand-yellow" aria-hidden="true" />Protected company information</li>
          </ul>
        </div>

      </section>

      <section className="flex min-h-dvh items-center justify-center px-5 py-8 sm:px-10 lg:h-full lg:min-h-0 lg:px-16 lg:py-6" aria-labelledby="sign-in-title">
        <div className="w-full max-w-md">
          <div className="mb-8 flex flex-col items-center text-center lg:hidden">
            <BrandMark variant="full" className="h-32 w-auto" />
            <p className="mt-3 text-lg font-semibold tracking-tight">CNG Station Management</p>
            <p className="text-sm text-muted-foreground">Cargas NGV Operations</p>
          </div>

          <div className="border border-slate-200 bg-white p-6 shadow-[0_18px_55px_-30px_rgba(15,23,42,0.35)] sm:p-8">
            <div className="mb-7">
              <p className="mb-2 text-xs font-semibold uppercase tracking-[0.16em] text-brand-strong">Secure access</p>
              <h2 id="sign-in-title" className="text-3xl font-semibold tracking-tight text-slate-950">Welcome back</h2>
              <p className="mt-2 text-sm leading-6 text-muted-foreground">Sign in with your approved company account to continue.</p>
            </div>

            <form className="space-y-5" onSubmit={submit}>
              <label className="block text-sm font-semibold text-slate-800" htmlFor="sign-in-email">Email address</label>
              <input id="sign-in-email" name="sign-in-email" className="-mt-3 h-12 w-full rounded-md border border-slate-300 bg-white px-3.5 text-base shadow-sm transition-colors placeholder:text-slate-400 hover:border-slate-400 focus:border-brand-strong" type="email" inputMode="email" autoComplete="email" placeholder="name@company.com" required value={email} onChange={(e) => setEmail(e.target.value)} />

              <label className="block text-sm font-semibold text-slate-800" htmlFor="sign-in-password">Password</label>
              <input id="sign-in-password" name="sign-in-password" className="-mt-3 h-12 w-full rounded-md border border-slate-300 bg-white px-3.5 text-base shadow-sm transition-colors placeholder:text-slate-400 hover:border-slate-400 focus:border-brand-strong" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />

              {error ? <p role="alert" className="border-l-2 border-destructive bg-red-50 px-3 py-2 text-sm text-destructive">{error}</p> : null}
              <Button className="h-12 w-full bg-brand-strong text-base font-semibold text-brand-strong-fg hover:bg-brand-deep" type="submit" disabled={busy || authLoading}>{busy ? 'Signing in…' : 'Sign in'}</Button>
            </form>

            {googleEnabled ? (
              <div className="mt-5 space-y-5">
                <div className="flex items-center gap-3 text-xs text-muted-foreground"><div className="h-px flex-1 bg-border" /><span>or continue with</span><div className="h-px flex-1 bg-border" /></div>
                <Button className="h-12 w-full" type="button" variant="outline" disabled={busy} onClick={() => void signInWithGoogle()}>Google</Button>
              </div>
            ) : null}

            <p className="mt-7 text-center text-sm text-muted-foreground">Need an account? <Link className="font-semibold text-brand-strong underline decoration-brand/35 underline-offset-4 hover:text-brand-deep" to="/sign-up">Request access</Link></p>
          </div>

          <p className="mt-5 flex items-center justify-center gap-2 text-center text-xs text-slate-500"><LockKeyhole className="h-3.5 w-3.5" aria-hidden="true" />Your session is encrypted and access controlled.</p>
        </div>
      </section>
    </main>
  )
}
