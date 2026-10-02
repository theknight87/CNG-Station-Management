import { useEffect } from 'react'
import { isRouteErrorResponse, Link, useRouteError } from 'react-router-dom'

import { Button, buttonVariants } from '@/components/ui/button'
import { isStaleChunkError, reloadForNewVersion } from '@/lib/app/staleChunk'

/**
 * The router's error page (replaces React Router's developer screen).
 *
 * The common case after a deployment is a stale tab asking for a file the new version no longer has: that
 * reloads once on its own and says so. Anything else is stated plainly, with Reload and a way back.
 */
export function RouteError() {
  const error = useRouteError()
  const stale = isStaleChunkError(error)

  useEffect(() => {
    if (stale) reloadForNewVersion()
  }, [stale])

  const detail = isRouteErrorResponse(error)
    ? `${error.status} ${error.statusText}`
    : error instanceof Error ? error.message : null

  return (
    <div role="alert" className="flex min-h-screen items-center justify-center bg-background p-6">
      <div className="w-full max-w-md space-y-3 rounded border bg-card p-5">
        <h1 className="text-base font-semibold">
          {stale ? 'A new version of the application is available' : 'This page could not be displayed'}
        </h1>
        <p className="text-sm text-muted-foreground">
          {stale
            ? 'This tab was opened before the latest update, so it is loading the new version. If this page stays, press Reload.'
            : 'Something went wrong while opening this page. Reloading usually fixes it; nothing was changed.'}
        </p>
        {!stale && detail ? <p className="break-words font-technical text-xs text-muted-foreground">{detail}</p> : null}
        <div className="flex gap-2">
          <Button size="sm" onClick={() => window.location.reload()}>Reload</Button>
          <Link to="/dashboard" className={buttonVariants({ size: 'sm', variant: 'outline' })}>Go to the dashboard</Link>
        </div>
      </div>
    </div>
  )
}
