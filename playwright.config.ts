import { readFileSync } from 'node:fs'
import { defineConfig, devices } from 'playwright/test'

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:4173'

// OPT-IN, for sandboxed build environments whose egress proxy re-signs TLS
// with its own CA that Playwright's bundled Chromium does not trust. The file
// holds a comma-separated list of SPKI sha256 hashes derived from that
// environment's CA bundle. Chromium then trusts exactly those keys; it does NOT
// disable certificate verification. Unset (the default, and in CI): no effect.
const trustedSpkiFile = process.env.E2E_CHROMIUM_TRUSTED_SPKI_FILE
const chromiumArgs = trustedSpkiFile
  ? [`--ignore-certificate-errors-spki-list=${readFileSync(trustedSpkiFile, 'utf8').trim()}`]
  : []
export default defineConfig({
  testDir: './e2e', timeout: 30_000, retries: 1, workers: 1,
  use: { baseURL, trace: 'on-first-retry', screenshot: 'only-on-failure', launchOptions: { args: chromiumArgs } },
  // This is intentionally a loopback-only, non-secret browser configuration.
  // It exists solely to render public UI in an isolated local preview; tests
  // intercept the one invalid-password request and never contact this address.
  webServer: process.env.E2E_BASE_URL ? undefined : {
    command: 'npm run build && npm run preview -- --host 127.0.0.1 --port 4173',
    url: baseURL,
    // The managed local preview must fail when 4173 is occupied: reusing an
    // arbitrary preview can test a different build or configuration.
    reuseExistingServer: false,
    env: {
      VITE_SUPABASE_URL: process.env.VITE_SUPABASE_URL ?? 'http://127.0.0.1:54321',
      VITE_SUPABASE_PUBLISHABLE_KEY: process.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? 'e2e-local-preview-publishable-key',
    },
  },
  projects: [
    { name: 'auth-setup', testMatch: /auth\.setup\.ts/, use: { browserName: 'chromium' } },
    { name: 'chromium-desktop', dependencies: ['auth-setup'], testIgnore: /auth\.setup\.ts/, use: { browserName: 'chromium', viewport: { width: 1440, height: 900 }, storageState: 'playwright/.auth/user.json' } },
    { name: 'firefox-desktop', dependencies: ['auth-setup'], testIgnore: /auth\.setup\.ts/, use: { browserName: 'firefox', viewport: { width: 1440, height: 900 }, storageState: 'playwright/.auth/user.json' } },
    { name: 'webkit-desktop', dependencies: ['auth-setup'], testIgnore: /auth\.setup\.ts/, use: { browserName: 'webkit', viewport: { width: 1440, height: 900 }, storageState: 'playwright/.auth/user.json' } },
    { name: 'chromium-mobile', dependencies: ['auth-setup'], testIgnore: /auth\.setup\.ts/, use: { ...devices['iPhone 13'], browserName: 'chromium', storageState: 'playwright/.auth/user.json' } },
    { name: 'firefox-narrow', dependencies: ['auth-setup'], testIgnore: /auth\.setup\.ts/, use: { browserName: 'firefox', viewport: { width: 390, height: 844 }, storageState: 'playwright/.auth/user.json' } },
    { name: 'webkit-mobile', dependencies: ['auth-setup'], testIgnore: /auth\.setup\.ts/, use: { ...devices['iPhone 13'], browserName: 'webkit', storageState: 'playwright/.auth/user.json' } },
  ],
})
