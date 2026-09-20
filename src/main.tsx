import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import { App } from '@/App'
import { AuthProvider } from '@/features/auth/AuthProvider'
import { AppUserProvider } from '@/hooks/useAppUser'
import { readSupabaseConfig } from '@/lib/supabase/config'
import '@/index.css'

const rootElement = document.getElementById('root')
if (!rootElement) {
  throw new Error('Root element #root not found in index.html')
}

const supabaseConfig = readSupabaseConfig()

createRoot(rootElement).render(
  <StrictMode>
    {supabaseConfig ? (
      <AuthProvider>
        <AppUserProvider>
          <App />
        </AppUserProvider>
      </AuthProvider>
    ) : (
      <div style={{ padding: 24, fontFamily: 'system-ui', maxWidth: 640 }}>
        <h1 style={{ fontSize: 18, fontWeight: 600 }}>Configuration required</h1>
        <p>
          Supabase is not configured. Copy <code>.env.example</code> to{' '}
          <code>.env.local</code> and set <code>VITE_SUPABASE_URL</code> and{' '}
          <code>VITE_SUPABASE_PUBLISHABLE_KEY</code>.
        </p>
      </div>
    )}
  </StrictMode>,
)
