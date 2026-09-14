import { SignUp } from '@clerk/clerk-react'

/**
 * TEMPORARY Prompt-5 sign-up route.
 *
 * Signing up grants NOTHING (CLAUDE.md §10): the webhook creates the row as
 * role='viewer', is_active=false, and an administrator must activate it.
 */
export function SignUpPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <SignUp
        routing="path"
        path="/sign-up"
        signInUrl="/sign-in"
        forceRedirectUrl="/auth-test"
      />
    </div>
  )
}
