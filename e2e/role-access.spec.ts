import { expect, test, type Page } from 'playwright/test'

/*
 * Phase 2 multi-role coverage. Each role needs its OWN dedicated test account,
 * supplied only through environment variables (never in source, logs or docs):
 *   E2E_VIEWER_EMAIL / E2E_VIEWER_PASSWORD
 *   E2E_ENGINEER_EMAIL / E2E_ENGINEER_PASSWORD
 *   E2E_MANAGER_EMAIL / E2E_MANAGER_PASSWORD
 *   E2E_INACTIVE_EMAIL / E2E_INACTIVE_PASSWORD
 * A role whose variables are absent is skipped and reported as skipped.
 *
 * These are read-only checks. The database is the authority (RLS is proved in
 * supabase/tests/rls_authorization.sql); this proves the browser shows each
 * role the right thing and never offers administration to a non-admin.
 */

test.use({ storageState: { cookies: [], origins: [] } })

function account(prefix: string) {
  const email = process.env[`E2E_${prefix}_EMAIL`]
  const password = process.env[`E2E_${prefix}_PASSWORD`]
  return email && password ? { email, password } : null
}

async function signIn(page: Page, creds: { email: string; password: string }) {
  await page.goto('/sign-in')
  await page.getByLabel('Email address').fill(creds.email)
  await page.getByLabel('Password', { exact: true }).fill(creds.password)
  await page.getByRole('button', { name: /^sign in$/i }).click()
}

for (const [prefix, label] of [['VIEWER', 'viewer'], ['ENGINEER', 'station engineer'], ['MANAGER', 'regional manager']] as const) {
  test.describe(`active ${label}`, () => {
    const creds = account(prefix)
    test.skip(!creds, `E2E_${prefix}_EMAIL / E2E_${prefix}_PASSWORD not supplied`)

    test('reaches the dashboard but is never offered administration', async ({ page }) => {
      await signIn(page, creds!)
      await expect(page).toHaveURL(/dashboard/)
      await expect(page.getByRole('link', { name: /^admin$/i })).toHaveCount(0)

      await page.goto('/admin/users')
      await expect(page.getByText(/restricted to administrators/i)).toBeVisible()
      await expect(page.getByRole('table')).toHaveCount(0)
    })
  })
}

test.describe('inactive account', () => {
  const creds = account('INACTIVE')
  test.skip(!creds, 'E2E_INACTIVE_EMAIL / E2E_INACTIVE_PASSWORD not supplied')

  test('sees Awaiting approval and no application data', async ({ page }) => {
    await signIn(page, creds!)
    await expect(page.getByText('Awaiting approval')).toBeVisible()
    await expect(page.getByRole('navigation')).toHaveCount(0)

    await page.goto('/stations')
    await expect(page.getByText('Awaiting approval')).toBeVisible()
    await expect(page.getByRole('table')).toHaveCount(0)
  })
})
