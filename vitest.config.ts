import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  test: {
    // jsdom only where a component test needs it; the import-pipeline suites
    // run in plain node and must not pay for a DOM.
    environmentMatchGlobs: [['src/components/**', 'jsdom'], ['src/features/**', 'jsdom']],
    globals: false,
    setupFiles: ['src/test/setup.ts'],
  },
})
