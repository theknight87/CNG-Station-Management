import { useState, type FormEvent } from 'react'
import { Link, Navigate } from 'react-router-dom'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/features/auth/AuthProvider'
import { useSupabaseClient } from '@/lib/supabase/client'

/** Signing up grants no application access until an administrator activates it. */
export function SignUpPage() {
  const supabase = useSupabaseClient()
  const { session, loading: authLoading } = useAuth()
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  if (!authLoading && session) return <Navigate to="/dashboard" replace />

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setBusy(true)
    setError(null)
    setMessage(null)
    const { data, error: signUpError } = await supabase.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: `${window.location.origin}/dashboard`,
        data: { full_name: fullName.trim() || null },
      },
    })
    setBusy(false)
    if (signUpError) setError(signUpError.message)
    else if (!data.session) setMessage('Check your email to confirm the account, then sign in. An administrator must activate your access.')
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>Create account</CardTitle>
          <CardDescription>New accounts remain inactive until an administrator approves them.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-3" onSubmit={submit}>
            <label className="block text-sm font-medium">Full name
              <input id="sign-up-name" name="sign-up-name" className="mt-1 h-10 w-full rounded-md border bg-background px-3" autoComplete="name" required value={fullName} onChange={(e) => setFullName(e.target.value)} />
            </label>
            <label className="block text-sm font-medium">Email
              <input id="sign-up-email" name="sign-up-email" className="mt-1 h-10 w-full rounded-md border bg-background px-3" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
            </label>
            <label className="block text-sm font-medium">Password
              <input id="sign-up-password" name="sign-up-password" className="mt-1 h-10 w-full rounded-md border bg-background px-3" type="password" autoComplete="new-password" minLength={8} required value={password} onChange={(e) => setPassword(e.target.value)} />
            </label>
            {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
            {message ? <p role="status" className="text-sm text-muted-foreground">{message}</p> : null}
            <Button className="w-full" type="submit" disabled={busy}>{busy ? 'Creating account…' : 'Create account'}</Button>
            <p className="text-center text-sm text-muted-foreground">Already registered? <Link className="underline" to="/sign-in">Sign in</Link></p>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
