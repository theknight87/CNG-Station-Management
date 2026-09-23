// Phase 3 browser measurement (read-only). Signs in once with E2E_EMAIL / E2E_PASSWORD (environment only),
// then loads each route in a fresh page RUNS times, recording FCP, LCP, CLS, time until the page has no
// pending requests ("data ready"), request count, duplicate requests and the slowest API call.
// Usage: E2E_BASE_URL=... E2E_EMAIL=... E2E_PASSWORD=... [E2E_CHROMIUM_TRUSTED_SPKI_FILE=...] node scripts/measure-routes.mjs
import { readFileSync } from 'node:fs'
import { chromium } from 'playwright'

const base = process.env.E2E_BASE_URL
if (!base || !process.env.E2E_EMAIL || !process.env.E2E_PASSWORD) {
  console.error('E2E_BASE_URL, E2E_EMAIL and E2E_PASSWORD are required'); process.exit(2)
}
const RUNS = Number(process.env.RUNS ?? 3)
const ROUTES = ['/dashboard', '/alerts', '/manage/hoses', '/manage/gas-detectors', '/reports/due', '/admin/audit-log',
  '/manage/srvs/installed', '/manage/srvs/warehouse']
const spki = process.env.E2E_CHROMIUM_TRUSTED_SPKI_FILE
const browser = await chromium.launch({ args: spki ? [`--ignore-certificate-errors-spki-list=${readFileSync(spki, 'utf8').trim()}`] : [] })

const vitals = `
  window.__v = { lcp: 0, cls: 0 };
  new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__v.lcp = e.startTime }).observe({ type: 'largest-contentful-paint', buffered: true });
  new PerformanceObserver((l) => { for (const e of l.getEntries()) if (!e.hadRecentInput) window.__v.cls += e.value }).observe({ type: 'layout-shift', buffered: true });
`

async function measure(context, path) {
  const page = await context.newPage()
  await page.addInitScript(vitals)
  const reqs = []
  page.on('requestfinished', async (r) => {
    const t = r.timing()
    reqs.push({ url: r.url().split('?')[0], full: r.url(), ms: t.responseEnd })
  })
  const t0 = Date.now()
  await page.goto(base + path, { waitUntil: 'networkidle', timeout: 60_000 })
  const ready = Date.now() - t0
  await page.waitForTimeout(300)
  const v = await page.evaluate(() => ({
    fcp: performance.getEntriesByName('first-contentful-paint')[0]?.startTime ?? null, ...window.__v,
  }))
  const api = reqs.filter((r) => r.url.includes('/rest/v1/') || r.url.includes('/auth/v1/'))
  const seen = new Map()
  for (const r of api) seen.set(r.full, (seen.get(r.full) ?? 0) + 1)
  const dup = [...seen.values()].filter((n) => n > 1).reduce((a, n) => a + n - 1, 0)
  const slow = api.sort((a, b) => b.ms - a.ms)[0]
  await page.close()
  return { ready, fcp: Math.round(v.fcp ?? 0), lcp: Math.round(v.lcp), cls: +v.cls.toFixed(3), requests: reqs.length,
    api: api.length, dup, slowest: slow ? `${slow.url.replace(/^.*\/(rest|auth)\/v1\//, '')} ${Math.round(slow.ms)}ms` : '' }
}

// Sign-in page, anonymous, cold.
const anon = await browser.newContext()
const signIn = []
for (let i = 0; i < RUNS; i++) signIn.push(await measure(anon, '/sign-in'))
await anon.close()

const context = await browser.newContext()
const page = await context.newPage()
await page.goto(base + '/sign-in')
await page.getByLabel('Email address').fill(process.env.E2E_EMAIL)
await page.getByLabel('Password').fill(process.env.E2E_PASSWORD)
await page.getByRole('button', { name: /^sign in$/i }).click()
await page.waitForURL(/dashboard/, { timeout: 30_000 })
await page.close()

const results = { '/sign-in': signIn }
for (const r of ROUTES) {
  results[r] = []
  for (let i = 0; i < RUNS; i++) results[r].push(await measure(context, r))
}
await browser.close()

for (const [route, runs] of Object.entries(results)) {
  console.log(route)
  for (const m of runs) console.log('  ', JSON.stringify(m))
}
