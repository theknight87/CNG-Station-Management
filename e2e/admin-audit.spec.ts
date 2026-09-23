import { expect, test } from 'playwright/test'

test('admin audit route remains read-only when the account may access it', async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  await page.goto('/admin/audit-log')
  test.skip(await page.getByText(/restricted to administrators/i).count() > 0, 'The configured account is not an administrator.')
  await expect(page.getByRole('heading', { name: 'Audit log' })).toBeVisible()
  await expect(page.getByText(/append-only/i)).toBeVisible()
  await expect(page.getByRole('button', { name: /edit|delete|remove/i })).toHaveCount(0)
})
