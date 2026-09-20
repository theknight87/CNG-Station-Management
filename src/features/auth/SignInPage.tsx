import { useState, type FormEvent } from 'react'
import { Link, Navigate, useLocation } from 'react-router-dom'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/features/auth/AuthProvider'
import { useSupabaseClient } from '@/lib/supabase/client'

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
    if (result.error) setError(result.error.message)
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
      setError(oauthError.message)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>Sign in</CardTitle>
          <CardDescription>Use your approved CNG Station Management account.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <form className="space-y-3" onSubmit={submit}>
            <label className="block text-sm font-medium">Email
              <input className="mt-1 h-10 w-full rounded-md border bg-background px-3" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
            </label>
            <label className="block text-sm font-medium">Password
              <input className="mt-1 h-10 w-full rounded-md border bg-background px-3" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
            </label>
            {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
            <Button className="w-full" type="submit" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</Button>
          </form>
          {googleEnabled ? (
            <>
              <div className="relative text-center text-xs text-muted-foreground"><span className="bg-card px-2">or</span><div className="absolute left-0 right-0 top-1/2 -z-10 border-t" /></div>
              <Button className="w-full" type="button" variant="outline" disabled={busy} onClick={() => void signInWithGoogle()}>Continue with Google</Button>
            </>
          ) : null}
          <p className="text-center text-sm text-muted-foreground">Need an account? <Link className="underline" to="/sign-up">Sign up</Link></p>
        </CardContent>
      </Card>
    </div>
  )
}
