import { SignIn } from '@clerk/clerk-react'

/**
 * TEMPORARY Prompt-5 sign-in route.
 *
 * Exists only so the first real Clerk sign-in can be performed and the
 * Clerk -> Supabase -> RLS path exercised end to end. It is deliberately
 * unstyled beyond centering: the real authentication experience is Prompt 7+.
 */
export function SignInPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <SignIn
        routing="path"
        path="/sign-in"
        signUpUrl="/sign-up"
        forceRedirectUrl="/auth-test"
      />
    </div>
  )
}
