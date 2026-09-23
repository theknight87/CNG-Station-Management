import { expect, test } from 'playwright/test'
const surfaces = [{ route: '/alerts', region: 'alerts-region', station: 'alerts-station' }, { route: '/manage/hoses', region: 'hoses-region', station: 'hoses-station' }, { route: '/manage/gas-detectors', region: 'gas-detectors-region', station: 'gas-detectors-station' }]
for (const surface of surfaces) test(`defers and scopes station options on ${surface.route}`, async ({ page }) => {
  test.skip(!process.env.E2E_EMAIL || !process.env.E2E_PASSWORD, 'E2E credentials are absent; authenticated routes are intentionally skipped.')
  const stationRequests: string[] = []
  page.on('request', request => { if (request.url().includes('v_station_summary')) stationRequests.push(request.url()) })
  await page.goto(surface.route)
  await expect(page.getByRole('heading').first()).toBeVisible()
  await page.waitForLoadState('networkidle')
  expect(stationRequests).toEqual([])
  const region = page.locator(`#${surface.region}`)
  const regionValue = await region.locator('option:not([value=""])').first().getAttribute('value')
  test.skip(!regionValue, 'The authenticated account has no selectable Region for scoped station coverage.')
  await region.selectOption(regionValue!)
  await expect(page.locator(`#${surface.station}`)).toBeVisible()
  await expect.poll(() => stationRequests.length).toBe(1)
  expect(decodeURIComponent(stationRequests[0])).toContain(`region_id=eq.${regionValue}`)
})
