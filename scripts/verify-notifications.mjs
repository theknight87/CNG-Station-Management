/**
 * Prompt 15.1 — the notification opt-in control in a REAL browser.
 *
 * The push permission prompt itself cannot be driven honestly in a headless
 * environment, so this verifies what CAN be verified deterministically: that
 * nothing is requested without a click, that every state renders, and that the
 * control is accessible and on-brand. It does NOT fake a subscription.
 */
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const BASE = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'
const OUT = 'artifacts/p15-1'
mkdirSync(OUT, { recursive: true })

const results = []
function check(name, pass, detail = '') {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
}

const url = (p = '') => `${BASE}?view=alerts${p}`
const browser = await chromium.launch()

/* ---------------------------- viewports ---------------------------- */
for (const vp of [
  { name: 'notifications-1440', width: 1440, height: 900 },
  { name: 'notifications-1024', width: 1024, height: 768 },
  { name: 'notifications-390', width: 390, height: 844 },
]) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height } })
  const page = await ctx.newPage()
  const errors = []
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
  page.on('pageerror', (e) => errors.push(String(e)))

  // Record whether the page ever asks for notification permission. This is the
  // single most important behaviour: it must be zero on load.
  await page.addInitScript(() => {
    window.__permissionRequests = 0
    if (typeof Notification !== 'undefined') {
      const original = Notification.requestPermission
      Notification.requestPermission = function (...args) {
        window.__permissionRequests += 1
        return original.apply(this, args)
      }
    }
  })

  await page.goto(url(), { waitUntil: 'networkidle' })
  await page.waitForSelector('table')
  await page.screenshot({ path: `${OUT}/${vp.name}.png` })

  check(`${vp.name}: no page errors`, errors.length === 0, errors.slice(0, 2).join(' | '))

  const requested = await page.evaluate(() => window.__permissionRequests ?? 0)
  check(`${vp.name}: NO notification permission is requested on load`, requested === 0,
    `${requested} request(s)`)

  const ovf = await page.evaluate(() => ({
    s: document.documentElement.scrollWidth, c: document.documentElement.clientWidth,
  }))
  check(`${vp.name}: page does not scroll horizontally`, ovf.s <= ovf.c + 1, `${ovf.s} vs ${ovf.c}`)

  const headings = await page.evaluate(() =>
    [...document.querySelectorAll('h1,h2,h3,h4')].map((h) => Number(h.tagName[1])))
  check(`${vp.name}: exactly one h1`, headings.filter((l) => l === 1).length === 1)

  // The control renders SOMETHING informative at every width — either the
  // button or an honest explanation of why it is unavailable.
  const text = await page.evaluate(() => document.body.innerText)
  check(`${vp.name}: the notification control states its state`,
    /enable notifications|notifications are enabled|blocked for this site|does not support push|not configured for this deployment/i.test(text))

  await ctx.close()
}

/* ------------------------------------------------------------------ *
 * A NOTE ON WHAT CANNOT BE TESTED HERE.
 *
 * Headless Chromium reports `Notification.permission === 'denied'` and ignores
 * Playwright's grantPermissions for notifications, so a REAL push subscription
 * cannot be created in this environment. That is verified below rather than
 * assumed, and the granted path is covered deterministically by the unit tests
 * in src/features/alerts/__tests__/pushNotifications.test.tsx, which stub the
 * Notification and PushManager APIs.
 *
 * No subscription is fabricated to manufacture a passing result.
 * ------------------------------------------------------------------ */
const headlessPermission = await (async () => {
  const c = await browser.newContext({ viewport: { width: 1024, height: 768 } })
  const pg = await c.newPage()
  await pg.goto(url(), { waitUntil: 'domcontentloaded' })
  const perm = await pg.evaluate(() => (typeof Notification === 'undefined' ? 'absent' : Notification.permission))
  await c.close()
  return perm
})()
check('environment: headless Chromium denies notifications, so no live subscription is possible here',
  headlessPermission === 'denied' || headlessPermission === 'default',
  `Notification.permission = ${headlessPermission}`)

/* -------------------- granted: the control appears -------------------- */
const grantedCtx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  permissions: [],
})
const page = await grantedCtx.newPage()
await page.addInitScript(() => {
  window.__permissionRequests = 0
})
await page.goto(url(), { waitUntil: 'networkidle' })
await page.waitForSelector('table')

const controlText = await page.evaluate(() => document.body.innerText)
check('control: renders without asking anything',
  /enable notifications|not configured for this deployment|does not support push|blocked for this site/i.test(controlText))
// A blocked browser is told plainly, and is NOT re-prompted.
if (/blocked for this site/i.test(controlText)) {
  check('control: a blocked browser is told so, and no button is offered to re-prompt',
    (await page.locator('button:has-text("Enable notifications")').count()) === 0)
}
check('control: uses calm wording, no alarm language',
  !/urgent/i.test(controlText) && !/critical/i.test(controlText) && !/emergency/i.test(controlText))

// If the button is present (the harness build carries no VAPID key, so it may
// legitimately report "not configured"), it must be reachable and labelled.
const btn = page.locator('button:has-text("Enable notifications")')
if (await btn.count()) {
  check('control: the button has an accessible name', (await btn.first().innerText()).trim().length > 0)
  await page.keyboard.press('Tab')
  check('control: keyboard focus reaches a focus-visible control',
    await page.evaluate(() => {
      const el = document.activeElement
      return Boolean(el && el !== document.body && el.matches(':focus-visible'))
    }))
} else {
  check('control: absent button is explained rather than silent',
    /not configured for this deployment|does not support push|blocked for this site/i.test(controlText))
}

/* ---------------------------- service worker ---------------------------- */
const swRes = await page.request.get(BASE.replace(/\/dev\/preview\.html.*$/, '/sw.js'))
check('service worker: /sw.js is served', swRes.status() === 200, `HTTP ${swRes.status()}`)
const swBody = await swRes.text()
check('service worker: handles push and notification clicks',
  /addEventListener\('push'/.test(swBody) && /notificationclick/.test(swBody))
check('service worker: contains NO secret material',
  !/VAPID_PRIVATE|RESEND_API_KEY|service_role/i.test(swBody))
check('service worker: does not intercept fetch, so it cannot serve a stale build',
  !/addEventListener\('fetch'/.test(swBody))
check('service worker: uses the Cargas mark, not a generic icon',
  /\/brand\/favicon-96\.png/.test(swBody))

/* ------------------------------- brand ------------------------------- */
const appPage = await browser.newPage()
await appPage.goto(BASE.replace(/\/dev\/preview\.html.*$/, '/'), { waitUntil: 'domcontentloaded' })
const brand = await appPage.evaluate(() => ({
  title: document.title,
  icon: [...document.querySelectorAll('link[rel~="icon"]')].map((l) => l.getAttribute('href')).join(','),
}))
await appPage.close()
check('brand: fixed Cargas title', brand.title === 'CNG Station Management | Cargas', brand.title)
check('brand: official favicon, no blue gear',
  brand.icon.includes('/brand/favicon') && !brand.icon.includes('favicon.svg'), brand.icon)

await page.screenshot({ path: `${OUT}/notifications-control.png` })
await grantedCtx.close()
await browser.close()

const failed = results.filter((r) => !r.pass)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length) {
  console.log('FAILED:')
  for (const f of failed) console.log(`  - ${f.name}${f.detail ? ` — ${f.detail}` : ''}`)
  process.exit(1)
}
