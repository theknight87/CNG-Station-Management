import { expect, test } from 'playwright/test'

const routes = ['/dashboard', '/regions', '/stations', '/manage/srvs/installed', '/manage/srvs/warehouse', '/manage/vessels/storage', '/manage/vessels/recovery', '/manage/gas-detectors', '/manage/hoses', '/alerts', '/reports/due', '/reports/srv', '/reports/vessels', '/reports/gas-detectors', '/reports/hoses', '/reports/data-quality', '/reports/activity']
for (const route of routes) test(`read-only navigation ${route}`, async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  const pageErrors: Error[] = []
  const failedDataRequests: string[] = []
  page.on('pageerror', error => pageErrors.push(error))
  page.on('response', response => {
    if (response.status() >= 400 && /(supabase|\/rest\/v1\/|127\.0\.0\.1)/.test(response.url())) failedDataRequests.push(`${response.status()} ${response.url()}`)
  })
  await page.goto(route)
  await expect(page.getByRole('heading').first()).toBeVisible()
  await expect(page.locator('header')).toBeVisible()
  const isMobile = await page.evaluate(() => window.innerWidth < 1024)
  if (isMobile) {
    await expect(page.getByRole('button', { name: 'Open navigation' })).toBeVisible()
  } else {
    await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible()
    await expect(page.getByRole('button', { name: /collapse sidebar|expand sidebar/i })).toBeVisible()
  }
  await expect(page.locator('main')).toBeVisible()
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy()
  expect(pageErrors, pageErrors.map(String).join('\n')).toEqual([])
  expect(failedDataRequests, failedDataRequests.join('\n')).toEqual([])
})
