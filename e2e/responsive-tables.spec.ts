import { expect, test } from 'playwright/test'

test('sign in never creates document-level horizontal overflow', async ({ page }) => {
  await page.goto('/sign-in')
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy()
})

for (const route of ['/reports/due', '/alerts']) test(`responsive authenticated layout contains ${route}`, async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  await page.goto(route)
  await expect(page.getByRole('heading').first()).toBeVisible()
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy()
  const toolbar = page.getByRole('search')
  await expect(toolbar).toBeVisible()
  await expect.poll(async () => {
    const box = await toolbar.boundingBox()
    return box !== null && box.x >= 0 && box.x + box.width <= (await page.evaluate(() => window.innerWidth))
  }).toBeTruthy()

  const table = page.getByRole('table').first()
  test.skip(await table.count() === 0, `The authorized ${route} dataset has no rendered table, so responsive table containment cannot be measured.`)
  await expect(table).toBeVisible()
  await expect.poll(async () => {
    const box = await table.boundingBox()
    return box !== null && box.x >= 0 && box.x <= (await page.evaluate(() => window.innerWidth))
  }).toBeTruthy()

  const pager = page.getByRole('navigation', { name: /pagination/i })
  await expect(pager).toBeVisible()
})

test('mobile navigation dialog fits the visual viewport', async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  await page.goto('/alerts')
  const open = page.getByRole('button', { name: 'Open navigation' })
  test.skip(await open.count() === 0, 'This desktop project has no mobile navigation trigger.')
  await open.click()
  const dialog = page.getByRole('dialog', { name: 'Main navigation' })
  await expect(dialog).toBeVisible()
  await expect.poll(async () => {
    const box = await dialog.boundingBox()
    const viewport = await page.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight }))
    return box !== null && box.x >= 0 && box.y >= 0 && box.width <= viewport.width && box.height <= viewport.height
  }).toBeTruthy()
})
