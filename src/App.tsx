import { Suspense } from 'react'
import { RouterProvider } from 'react-router-dom'

import { router } from '@/routes'

export function App() {
  return (
    <Suspense
      fallback={(
        <div className="flex min-h-screen items-center justify-center bg-background p-6 text-sm text-muted-foreground" role="status">
          Loading workspace…
        </div>
      )}
    >
      <RouterProvider router={router} />
    </Suspense>
  )
}
