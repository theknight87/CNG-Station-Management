import path from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

/**
 * DEV-ONLY config for the visual harness at /dev/preview.html.
 *
 * It is identical to vite.config.ts except for one alias: the Supabase client
 * is swapped for a fixture-serving stub. That lets the harness mount the REAL
 * hierarchy screens - the real data hooks, the real tables, the real loading,
 * empty, filtered-empty and error states - in a browser, in an environment
 * whose egress policy blocks both Supabase and Clerk.
 *
 * The production build uses vite.config.ts and never sees this file, so the
 * stub cannot reach a shipped bundle. `npm run build` is verified to exclude
 * both the stub and the harness.
 */
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: [
      { find: /^@\/lib\/supabase\/client$/, replacement: path.resolve(import.meta.dirname, './dev/supabaseStub.ts') },
      { find: '@', replacement: path.resolve(import.meta.dirname, './src') },
    ],
  },
  server: { port: 5174 },
})
