import { expect, test } from 'playwright/test'

function isPagedViewResponse(response: import('playwright/test').Response, view: string, range: string) {
  const request = response.request()
  return response.url().includes(`/rest/v1/${view}`) && request.headers().range === range
}

for (const { route, view } of [
  { route: '/reports/due', view: 'v_report_due_compliance' },
  { route: '/admin/audit-log', view: 'v_admin_audit_log' },
]) test(`moves ${route} to the exact second server page`, async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  await page.goto(route)
  if (route === '/admin/audit-log') {
    test.skip(await page.getByText(/restricted to administrators/i).count() > 0, 'The configured account is not an administrator.')
  }
  const selector = page.getByLabel(/page number/i)
  await expect(selector).toBeVisible()
  const options = await selector.locator('option').count()
  test.skip(options < 2, 'This authorized dataset has fewer than 51 rows, so no second page exists to select.')
  const secondPage = page.waitForResponse(response => isPagedViewResponse(response, view, '50-99'))
  await selector.selectOption({ value: '1' })
  await expect(selector).toHaveValue('1')
  await expect((await secondPage).ok()).toBeTruthy()
})

test('changing an applied Due report filter returns the page selector to page 1', async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  await page.goto('/reports/due')
  const selector = page.getByLabel('Due & Overdue report page number')
  await expect(selector).toBeVisible()
  test.skip(await selector.locator('option').count() < 2, 'This authorized report has fewer than 51 rows, so reset-after-page-change cannot be exercised.')
  await selector.selectOption({ value: '1' })
  await expect(selector).toHaveValue('1')
  await page.getByLabel('Due state').selectOption('overdue')
  const resetToFirstPage = page.waitForResponse(response => isPagedViewResponse(response, 'v_report_due_compliance', '0-49'))
  await page.getByRole('button', { name: 'Apply' }).click()
  await expect(selector).toHaveValue('0')
  await expect((await resetToFirstPage).ok()).toBeTruthy()
})

test('changing an Audit filter returns the page selector to page 1', async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  await page.goto('/admin/audit-log')
  test.skip(await page.getByText(/restricted to administrators/i).count() > 0, 'The configured account is not an administrator.')
  const selector = page.getByLabel('Audit log page number')
  await expect(selector).toBeVisible()
  test.skip(await selector.locator('option').count() < 2, 'This authorized audit log has fewer than 51 rows, so reset-after-filter-change cannot be exercised.')
  const secondPage = page.waitForResponse(response => isPagedViewResponse(response, 'v_admin_audit_log', '50-99'))
  await selector.selectOption({ value: '1' })
  await expect(selector).toHaveValue('1')
  await expect((await secondPage).ok()).toBeTruthy()
  const resetToFirstPage = page.waitForResponse(response => isPagedViewResponse(response, 'v_admin_audit_log', '0-49'))
  await page.getByLabel('Action').selectOption('user_role_changed')
  await expect(selector).toHaveValue('0')
  await expect((await resetToFirstPage).ok()).toBeTruthy()
})
