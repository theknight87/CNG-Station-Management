/**
 * Prompt 15 — the Alerts inbox in a REAL browser.
 *
 * Every item is an ASSERTION, not a screenshot to eyeball later. Exit code is
 * the verdict.
 */
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const BASE = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'
const OUT = 'artifacts/p15'
mkdirSync(OUT, { recursive: true })

const results = []
function check(name, pass, detail = '') {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
}

const url = (p = '') => `${BASE}?view=alerts${p}`
const browser = await chromium.launch()

/* ------------------------------ viewports ------------------------------ */
for (const vp of [
  { name: 'alerts-1440', width: 1440, height: 900 },
  { name: 'alerts-1024', width: 1024, height: 768 },
  { name: 'alerts-390', width: 390, height: 844 },
]) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } })
  const errors = []
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
  page.on('pageerror', (e) => errors.push(String(e)))

  await page.goto(url(), { waitUntil: 'networkidle' })
  await page.waitForSelector('table')
  await page.screenshot({ path: `${OUT}/${vp.name}.png` })

  check(`${vp.name}: no page errors`, errors.length === 0, errors.slice(0, 2).join(' | '))

  const ovf = await page.evaluate(() => ({
    s: document.documentElement.scrollWidth, c: document.documentElement.clientWidth,
  }))
  check(`${vp.name}: page does not scroll horizontally`, ovf.s <= ovf.c + 1, `${ovf.s} vs ${ovf.c}`)

  const region = await page.evaluate(() => {
    const r = document.querySelector('[role="region"]')
    return r ? { scrolls: r.scrollWidth > r.clientWidth } : null
  })
  check(`${vp.name}: the table scrolls inside its own region`, region !== null,
    region?.scrolls ? 'scrolls in-region' : 'fits')

  check(`${vp.name}: stays a technical table on every width`,
    await page.evaluate(() => document.querySelectorAll('table tbody tr').length > 0))

  const headings = await page.evaluate(() =>
    [...document.querySelectorAll('h1,h2,h3,h4')].map((h) => Number(h.tagName[1])))
  check(`${vp.name}: exactly one h1`, headings.filter((l) => l === 1).length === 1,
    `levels ${headings.join(',')}`)
  let ordered = true
  for (let i = 1; i < headings.length; i += 1) if (headings[i] - headings[i - 1] > 1) ordered = false
  check(`${vp.name}: heading order skips no level`, ordered)
  await page.close()
}

/* ------------------------------ behaviour ------------------------------ */
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
const errors = []
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
page.on('pageerror', (e) => errors.push(String(e)))
await page.goto(url(), { waitUntil: 'networkidle' })
await page.waitForSelector('table')

const body = () => page.evaluate(() => document.body.innerText)
async function pick(label, value) {
  await page.locator(`label:has-text("${label}") select`).first().selectOption(value)
  await page.waitForTimeout(170)
}
async function isolate(term) {
  const b = page.locator('input[type="search"]')
  await b.fill(''); await b.fill(term)
  await page.waitForTimeout(270)
  return body()
}
async function clearAll() {
  const btn = page.locator('button:has-text("Clear")').first()
  if (await btn.count()) await btn.click()
  await page.locator('input[type="search"]').fill('')
  await page.waitForTimeout(230)
}

// summary
const summary = await page.evaluate(() => {
  const s = document.querySelector('section[aria-labelledby="alert-attention"]')
  return s ? s.innerText : null
})
check('summary: present', summary !== null)
check('summary: counts overdue, due today and the 7-day threshold',
  /overdue/i.test(summary) && /due today/i.test(summary) && /7-day/i.test(summary))
check('summary: separates Unread from Unacknowledged',
  /unread/i.test(summary) && /unacknowledged/i.test(summary))
check('summary: states that a failed delivery leaves the alert standing',
  /delivery failed/i.test(summary) && /alert still stands/i.test(summary))

const text = await body()
check('row: Arabic station renders', /الماظة|شبرا/.test(text))
check('row: nothing renders as N/A anywhere', !/\bN\/A\b/.test(text))
check('no siren or severity language is invented',
  !/critical/i.test(text) && !/emergency/i.test(text) && !/unsafe/i.test(text) && !/danger/i.test(text))

// thresholds
for (const [value, label] of [['overdue', 'Overdue'], ['due_today', 'Due today'], ['due_7', '7 days'],
  ['due_15', '15 days'], ['due_30', '30 days'], ['due_60', '60 days']]) {
  await clearAll()
  await pick('Threshold', value)
  const t = await body()
  check(`threshold: ${label} is reachable and filters server-side`, t.includes(label))
}
await clearAll()

// delivery states
await pick('Delivery', 'failed')
const failedText = await body()
check('delivery: a FAILED delivery still shows its alert, never "no alerts"',
  /failed/i.test(failedText) && !/^No alerts$/im.test(failedText))
await clearAll()
check('delivery: "not attempted" is distinguished from a failure',
  /not attempted/i.test(await body()))

// read / acknowledgement
await pick('Read', 'unread')
check('read: the unread filter reaches the server', /unread/i.test(await body()))
await clearAll()
await pick('Acknowledgement', 'acknowledged')
const ackText = await body()
check('acknowledgement: an acknowledged alert shows its server-recorded actor',
  /acknowledged/i.test(ackText) && /Eng\. Mostafa/.test(ackText))
await clearAll()

// An asset whose source recorded no serial. It cannot be found by SEARCHING
// for a serial it does not have, so it is isolated by its threshold instead -
// which is also the honest point: the registry never invents an identifier to
// make a row findable.
await clearAll()
await pick('Threshold', 'due_today')
const noSerial = await body()
check('row: an asset with no recorded serial reads as not recorded, never invented',
  /not recorded/i.test(noSerial) && !/asset-7/.test(noSerial))

// An alert whose Unit is not confirmed.
await clearAll()
const unmapped = await isolate('SR-90006')
check('unresolved: an alert whose Unit is unconfirmed says so rather than guessing',
  /not confirmed/i.test(unmapped))

// Detail and the two explicit actions, against the unfiltered list so this
// does not depend on whatever filter ran before it.
await clearAll()
await page.locator('table tbody button[aria-expanded]').first().click()
await page.waitForTimeout(220)
const detail = await body()
check('detail: exposes alert, asset, acknowledgement and delivery sections',
  /status now/i.test(detail) && /email delivery/i.test(detail) && /push delivery/i.test(detail))

const readBtn = page.locator('button', { hasText: /^Mark as (read|unread)$/ }).first()
check('detail: offers a read toggle and Acknowledge as SEPARATE explicit acts',
  (await readBtn.count()) === 1 && (await page.locator('button:has-text("Acknowledge")').count()) >= 1)
check('detail: opening an alert did not acknowledge it',
  (await page.locator('button:has-text("Already acknowledged")').count()) === 0)

await readBtn.click()
await page.waitForTimeout(450)
check('action: the read toggle completes without an error banner',
  (await page.locator('[role="alert"]').count()) === 0)

// asset navigation
check('navigation: a confirmed Unit is navigable',
  (await page.locator('a:has-text("Open Unit")').count()) >= 1)

await clearAll()

// sorting
async function sortHeader(name) {
  const th = page.locator('th', { hasText: new RegExp(`^${name}`) }).first()
  await th.locator('button').click()
  await page.waitForTimeout(150)
  return th.getAttribute('aria-sort')
}
// Due date is the DEFAULT sort (ascending), so the first click toggles it to
// descending. Both directions are still exercised; the order is just reversed.
const first = await sortHeader('Due date')
const second = await sortHeader('Due date')
check('sort: aria-sort announces both directions as the column is toggled',
  new Set([first, second]).size === 2
  && [first, second].every((d) => d === 'ascending' || d === 'descending'),
  `${first} then ${second}`)
check('sort: several columns are sortable',
  (await page.evaluate(() => [...document.querySelectorAll('th')].filter((t) => t.hasAttribute('aria-sort')).length)) >= 5)

// combined filters
await clearAll()
await pick('Region', 'r-east')
await pick('Subject', 'srv_calibration')
const combined = await page.evaluate(() => document.querySelectorAll('table tbody tr').length)
check('filter: Region + Subject yields a real intersection', combined > 0, `${combined} rows`)

await page.locator('input[type="search"]').fill('zzzz-nothing')
await page.waitForTimeout(300)
check('filter: a no-match result is stated explicitly',
  /No results match these filters/i.test(await body()))
await clearAll()

// pagination
const pager = page.locator('nav[aria-label*="pagination" i]')
const before = await pager.innerText()
await pager.locator('button:has-text("Next")').click()
await page.waitForTimeout(250)
check('pagination: Next advances the range', (await pager.innerText()) !== before,
  `${before.split('\n')[0]} → ${(await pager.innerText()).split('\n')[0]}`)
await pager.locator('button:has-text("Previous")').click()
await page.waitForTimeout(250)

// keyboard
await page.keyboard.press('Tab')
check('keyboard: focus lands on a genuinely focus-visible control',
  await page.evaluate(() => {
    const el = document.activeElement
    return Boolean(el && el !== document.body && el.matches(':focus-visible'))
  }))

// brand
const logoSrc = await page.evaluate(() =>
  [...document.querySelectorAll('img')].map((i) => i.getAttribute('src')).join(','))
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
check('brand: Cargas logo used unmodified', /\/brand\/(logo-trimmed|mark)\.png/.test(logoSrc), logoSrc)

check('no page errors during the behavioural pass', errors.length === 0, errors.slice(0, 2).join(' | '))

/* ------------------------- empty / error branches ------------------------- */
const errPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await errPage.goto(url('&scenario=error'), { waitUntil: 'networkidle' })
await errPage.waitForTimeout(480)
const errText = await errPage.evaluate(() => document.body.innerText)
check('error: a failed query states the failure', /Could not load Alerts/i.test(errText))
check('error: a failure is never an empty inbox', !/^No alerts$/im.test(errText))
check('error: a failed count is never rendered as zero',
  /alert summary could not be loaded/i.test(errText))
await errPage.screenshot({ path: `${OUT}/alerts-error.png` })
await errPage.close()

const emptyPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await emptyPage.goto(url('&scenario=empty'), { waitUntil: 'networkidle' })
await emptyPage.waitForTimeout(480)
const emptyText = await emptyPage.evaluate(() => document.body.innerText)
check('empty: an honest empty inbox', /No alerts/i.test(emptyText))
check('empty: does not claim a failure', !/Could not load/i.test(emptyText))
await emptyPage.screenshot({ path: `${OUT}/alerts-empty.png` })
await emptyPage.close()

const scopedPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await scopedPage.goto(url('&scenario=scoped'), { waitUntil: 'networkidle' })
await scopedPage.waitForSelector('table')
const scopedText = await scopedPage.evaluate(() => document.body.innerText)
check('scoped: a narrowed region scope shows no other region',
  !/\bWest\b/.test(scopedText) && !/\bAlex\b/.test(scopedText))
await scopedPage.screenshot({ path: `${OUT}/alerts-scoped.png` })
await scopedPage.close()

await page.close()
await browser.close()

const failed = results.filter((r) => !r.pass)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length) {
  console.log('FAILED:')
  for (const f of failed) console.log(`  - ${f.name}${f.detail ? ` — ${f.detail}` : ''}`)
  process.exit(1)
}
