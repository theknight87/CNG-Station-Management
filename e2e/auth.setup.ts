import { expect, test as setup } from 'playwright/test'

const authFile = 'playwright/.auth/user.json'
setup('authenticate test user', async ({ page }) => {
  // The six public projects still need a valid storage-state path when no
  // credentials are supplied. Persisting the empty context is intentional;
  // authenticated specs make their own explicit skip decision.
  if (!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD) {
    await page.context().storageState({ path: authFile })
    return
  }
  await page.goto('/sign-in')
  await page.getByLabel('Email address').fill(process.env.E2E_EMAIL!)
  await page.getByLabel('Password').fill(process.env.E2E_PASSWORD!)
  await page.getByRole('button', { name: /^sign in$/i }).click()
  await expect(page).toHaveURL(/dashboard/)
  await page.context().storageState({ path: authFile })
})
