import { expect, test } from 'playwright/test'

// A skip decided by an instant count races the data load and silently drops
// coverage. Wait for the element first; only a genuine absence skips.
async function presentWithin(locator: import('playwright/test').Locator, ms = 10_000): Promise<boolean> {
  return locator.first().waitFor({ state: 'attached', timeout: ms }).then(() => true, () => false)
}

const requireCredentials = () => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
}

test('Alerts exposes its accessible bell and record details when rows are available', async ({ page }) => {
  requireCredentials()
  const failures: string[] = []
  page.on('response', response => {
    if (response.status() >= 400 && /(supabase|\/rest\/v1\/)/.test(response.url())) failures.push(`${response.status()} ${response.url()}`)
  })

  await page.goto('/alerts')
  await expect(page.getByRole('heading', { name: 'Alerts' })).toBeVisible()
  // The bell lives in the page header; the sidebar also has a plain "Alerts" link.
  await expect(page.getByRole('banner').getByRole('link', { name: /^Alerts(?: — \d+\+? unread(?:; exact count \d+)?)?$/ })).toBeVisible()
  const details = page.getByRole('button', { name: /show the full technical record/i }).first()
  test.skip(!(await presentWithin(details)), 'The authorized Alerts dataset has no rows, so a details dialog cannot be exercised.')
  await details.click()
  await expect(page.getByRole('dialog')).toBeVisible()
  await expect(page.getByRole('button', { name: /close details/i })).toBeVisible()
  expect(failures, failures.join('\n')).toEqual([])
})

test('Installed SRV pagination uses a real pager when the authorized dataset spans pages', async ({ page }) => {
  requireCredentials()
  const requests: { url: string; range?: string }[] = []
  page.on('request', request => {
    if (request.url().includes('/rest/v1/')) requests.push({ url: decodeURIComponent(request.url()), range: request.headers().range })
  })

  await page.goto('/manage/srvs/installed')
  await expect(page.getByRole('heading').first()).toBeVisible()
  const selector = page.getByLabel('Installed relief valves page number')
  await expect(selector).toBeVisible()
  test.skip(await selector.locator('option').count() < 2, 'The authorized Installed SRV dataset has fewer than 51 rows, so its second page does not exist.')
  await selector.selectOption({ value: '1' })
  await expect(selector).toHaveValue('1')
  await expect.poll(() => requests.some(request => request.range === '50-99' || /offset=50|range=50-99/i.test(request.url))).toBeTruthy()
})
