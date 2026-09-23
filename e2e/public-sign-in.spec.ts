import { expect, test } from 'playwright/test'

const isLocalPreview = (url: string) => /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(url)

test('sign in has an identifiable, keyboard-accessible form without overflow', async ({ page, baseURL, browserName }) => {
  await page.route('**/auth/v1/token?grant_type=password', async route => {
    await route.fulfill({
      status: 400,
      contentType: 'application/json',
      body: JSON.stringify({
        error: 'invalid_grant',
        error_description: 'Provider diagnostic that must never be exposed to a user.',
        message: 'raw provider internals',
      }),
    })
  })
  await page.goto('/sign-in')
  await expect(page.getByRole('heading', { name: 'Welcome back' })).toBeVisible()
  const companyIdentity = page.getByText('CNG Station Management', { exact: true })
  await expect.poll(() => companyIdentity.evaluateAll(nodes => nodes.some(node => {
    const style = window.getComputedStyle(node)
    return style.display !== 'none' && style.visibility !== 'hidden' && node.getClientRects().length > 0
  }))).toBeTruthy()
  const logo = page.getByRole('img', { name: 'Cargas NGV' })
  // Role locators exclude the responsive layout's hidden duplicate. Running
  // this public test in both desktop and mobile projects proves the visible
  // official mark on each surface by its accessible name.
  await expect(logo).toHaveCount(1)
  await expect(logo).toBeVisible()

  const email = page.getByLabel('Email address')
  const password = page.getByLabel('Password')
  await expect(email).toHaveAttribute('id', 'sign-in-email')
  await expect(email).toHaveAttribute('name', 'sign-in-email')
  await expect(email).toHaveAttribute('autocomplete', 'email')
  await expect(password).toHaveAttribute('id', 'sign-in-password')
  await expect(password).toHaveAttribute('name', 'sign-in-password')
  await expect(password).toHaveAttribute('autocomplete', 'current-password')
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy()

  await page.keyboard.press('Tab')
  await expect(email).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(password).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(page.getByRole('button', { name: /^sign in$/i })).toBeFocused()
  const requestAccess = page.getByRole('link', { name: /request access/i })
  if (browserName === 'webkit') {
    // WebKit on this Windows runner does not enable sequential keyboard focus
    // for links. Verify the real fallback contract instead: it is a native,
    // focusable link after the submit control in DOM order.
    expect(await requestAccess.evaluate(link => link.tabIndex)).toBe(0)
    expect(await page.getByRole('button', { name: /^sign in$/i }).evaluate(
      (submit, link) => Boolean(link && submit.compareDocumentPosition(link) & Node.DOCUMENT_POSITION_FOLLOWING),
      await requestAccess.elementHandle(),
    )).toBe(true)
  } else {
    await page.keyboard.press('Tab')
    await expect(requestAccess).toBeFocused()
  }

  // Keep the public form assertions counted on hosted deployments. Only the
  // simulated invalid-password request belongs to the isolated local preview.
  if (!baseURL || !isLocalPreview(baseURL)) return
  await email.fill('e2e-invalid@example.test')
  await password.fill('not-a-real-password')
  await page.getByRole('button', { name: /^sign in$/i }).click()
  const error = page.getByRole('alert')
  await expect(error).toHaveText('Email or password is incorrect. Please try again.')
  await expect(error).not.toContainText(/provider diagnostic|raw provider|apikey|authorization: bearer|service_role/i)
})
