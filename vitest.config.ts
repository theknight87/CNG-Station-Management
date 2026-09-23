import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  test: {
    // Vitest 4 removed environmentMatchGlobs. The suite is predominantly UI
    // integration coverage, so jsdom is the safe default; individual pure-node
    // files can opt out with an @vitest-environment annotation if needed.
    environment: 'jsdom',
    globals: false,
    setupFiles: ['src/test/setup.ts'],
    exclude: ['e2e/**', 'node_modules/**', 'dist/**'],
  },
})
