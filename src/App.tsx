import { RouterProvider } from 'react-router-dom'

import { AuthGate } from '@/features/auth'
import { router } from '@/routes'

export function App() {
  return (
    <AuthGate>
      <RouterProvider router={router} />
    </AuthGate>
  )
}
