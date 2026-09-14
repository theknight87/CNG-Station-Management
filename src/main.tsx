import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ClerkProvider } from '@clerk/clerk-react'

import { App } from '@/App'
import { readClerkPublishableKey } from '@/lib/clerk/config'
import '@/index.css'

const rootElement = document.getElementById('root')
if (!rootElement) {
  throw new Error('Root element #root not found in index.html')
}

const publishableKey = readClerkPublishableKey()

createRoot(rootElement).render(
  <StrictMode>
    {publishableKey ? (
      // ClerkProvider sits at the application root so the session is available
      // to the Supabase client factory and to every route guard.
      <ClerkProvider publishableKey={publishableKey} afterSignOutUrl="/">
        <App />
      </ClerkProvider>
    ) : (
      <div style={{ padding: 24, fontFamily: 'system-ui', maxWidth: 640 }}>
        <h1 style={{ fontSize: 18, fontWeight: 600 }}>Configuration required</h1>
        <p>
          <code>VITE_CLERK_PUBLISHABLE_KEY</code> is not set. Copy{' '}
          <code>.env.example</code> to <code>.env.local</code> and fill in this
          project&apos;s own Clerk and Supabase values.
        </p>
      </div>
    )}
  </StrictMode>,
)
