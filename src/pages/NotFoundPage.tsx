import { Link } from 'react-router-dom'

import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'

export function NotFoundPage() {
  return (
    <div className="mx-auto max-w-md space-y-4 py-16 text-center">
      <h1 className="text-2xl font-semibold tracking-tight">Page not found</h1>
      <p className="text-sm text-muted-foreground">
        This route does not exist in the CNG Station Management System.
      </p>
      <Link to="/" className={cn(buttonVariants({ variant: 'outline' }))}>
        Back to dashboard
      </Link>
    </div>
  )
}
