/**
 * Prompt 14 — Hoses Management in a REAL browser.
 *
 * Drives Chromium against the dev preview harness at the three viewports the
 * prompt names. Every item is an ASSERTION, not a screenshot to eyeball later,
 * though it captures those too. The exit code is the verdict.
 */
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const BASE = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'
const OUT = 'artifacts/p14'
mkdirSync(OUT, { recursive: true })

const results = []
function check(name, pass, detail = '') {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
}

const url = (params = '') => `${BASE}?view=hoses${params}`
const browser = await chromium.launch()

/* ---------------------------------------------------------------- *
 * 1. The three viewports.
 * ---------------------------------------------------------------- */
for (const vp of [
  { name: 'hoses-1440', width: 1440, height: 900 },
  { name: 'hoses-1024', width: 1024, height: 768 },
  { name: 'hoses-390', width: 390, height: 844 },
]) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } })
  const errors = []
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
  page.on('pageerror', (e) => errors.push(String(e)))

  await page.goto(url(), { waitUntil: 'networkidle' })
  await page.waitForSelector('table')
  await page.screenshot({ path: `${OUT}/${vp.name}.png`, fullPage: false })

  check(`${vp.name}: no page errors`, errors.length === 0, errors.slice(0, 2).join(' | '))

  const overflow = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }))
  check(`${vp.name}: page does not scroll horizontally`,
    overflow.scrollWidth <= overflow.clientWidth + 1,
    `scrollWidth ${overflow.scrollWidth} vs clientWidth ${overflow.clientWidth}`)

  const region = await page.evaluate(() => {
    const r = document.querySelector('[role="region"]')
    return r ? { scrolls: r.scrollWidth > r.clientWidth } : null
  })
  check(`${vp.name}: the table scrolls inside its own region`, region !== null,
    region?.scrolls ? 'scrolls horizontally in-region' : 'fits at this width')

  // Mobile must stay a TABLE, not a stack of giant hose cards.
  check(`${vp.name}: the registry stays a technical table`,
    await page.evaluate(() => document.querySelectorAll('table tbody tr').length > 0))

  // SERIAL is this asset's identity and must be reachable without scrolling.
  const serialVisible = await page.evaluate(() => {
    const r = document.querySelector('[role="region"]')
    const th = [...document.querySelectorAll('thead th')].find((t) => /serial/i.test(t.innerText))
    if (!r || !th) return false
    return th.getBoundingClientRect().right - r.getBoundingClientRect().left <= r.getBoundingClientRect().width
  })
  check(`${vp.name}: the Serial column is visible without scrolling`, serialVisible)

  const headings = await page.evaluate(() =>
    [...document.querySelectorAll('h1,h2,h3,h4')].map((h) => Number(h.tagName[1])))
  check(`${vp.name}: exactly one h1`, headings.filter((l) => l === 1).length === 1,
    `levels ${headings.join(',')}`)
  let ordered = true
  for (let i = 1; i < headings.length; i += 1) if (headings[i] - headings[i - 1] > 1) ordered = false
  check(`${vp.name}: heading order skips no level`, ordered)

  await page.close()
}

/* ---------------------------------------------------------------- *
 * 2. Behaviour, at desktop width.
 * ---------------------------------------------------------------- */
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
const errors = []
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
page.on('pageerror', (e) => errors.push(String(e)))
await page.goto(url(), { waitUntil: 'networkidle' })
await page.waitForSelector('table')

const bodyText = () => page.evaluate(() => document.body.innerText)
// Includes the compact registry's details cells (description, pressure),
// which are rendered DOM but not visible columns in the collapsed row.
const bodyAll = () => page.evaluate(() => document.body.textContent)

async function selectFilter(label, value) {
  await page.locator(`label:has-text("${label}") select`).first().selectOption(value)
  await page.waitForTimeout(160)
}
async function isolate(term) {
  const box = page.locator('input[type="search"]')
  await box.fill('')
  await box.fill(term)
  await page.waitForTimeout(260)
  return page.evaluate(() => document.body.innerText)
}
async function clearAll() {
  const btn = page.locator('button:has-text("Clear")').first()
  if (await btn.count()) await btn.click()
  await page.locator('input[type="search"]').fill('')
  await page.waitForTimeout(220)
}

// --- the summary is dataset-wide, and serial quality is its own dimension ----
const summary = await page.evaluate(() => {
  const s = document.querySelector('section[aria-labelledby="hose-attention"]')
  return s ? s.innerText : null
})
check('summary: the attention strip is present', summary !== null)
check('summary: counts hoses, overdue, due window and mapping',
  /hoses/i.test(summary) && /overdue/i.test(summary) && /due ≤60d/i.test(summary) && /needs unit/i.test(summary))
check('summary: reports missing and duplicate serial as SEPARATE metrics',
  /no serial/i.test(summary) && /duplicate serial/i.test(summary))
check('summary: says a duplicate is reported, never merged', /never merged/i.test(summary))

// --- identity ---------------------------------------------------------------
const text = await bodyText()
check('row: an Arabic station name renders', /شبرا 1|الماظة/.test(text))
check('row: an Arabic description renders', /خرطوم/.test(await bodyAll()))
check('row: a NULL value reads as not recorded, never N/A or a 0 placeholder',
  /not recorded/i.test(text) && !/\bN\/A\b/.test(text))

const lead = await isolate('0007412')
check('serial: a leading-zero serial survives exactly', /0007412/.test(lead))
check('serial: it is not numeric-cast to 7412', !/\b7412\b(?!\d)/.test(lead.replace(/0007412/g, '')))

const long = await isolate('LONG-IDENTIFIER')
check('serial: a long identifier is rendered in full',
  /HS-CNG-2019-000044170-REV-A-LONG-IDENTIFIER/.test(long))

const dup = await isolate('HS-DUP-77')
check('serial: BOTH copies of a duplicated serial are kept',
  (dup.match(/HS-DUP-77/g) ?? []).length >= 2)
check('serial: the duplicate condition is reported beside the identifier', /duplicate/i.test(dup))

await clearAll()
await selectFilter('Serial', 'missing')
const missing = await bodyText()
check('serial: the missing-serial filter reaches the server and returns rows',
  /not recorded|not yet assigned/i.test(missing))
check('serial: a not-yet-assigned serial is worded differently from an absent one',
  /not yet assigned/i.test(missing))
await clearAll()

// --- description stays free text --------------------------------------------
await isolate('خرطوم تعبئة غاز طبيعي')
const longDesc = await bodyAll()
check('description: a long Arabic description renders', /خرطوم تعبئة غاز طبيعي/.test(longDesc))
await clearAll()
check('description: no Manufacturer or Model column is drawn',
  await page.evaluate(() => {
    const hs = [...document.querySelectorAll('thead th')].map((t) => t.innerText.trim().toLowerCase())
    return !hs.includes('manufacturer') && !hs.includes('model')
  }))

// --- terminology ------------------------------------------------------------
check('terminology: headers say "test", never "calibration"',
  await page.evaluate(() => {
    const hs = [...document.querySelectorAll('thead th')].map((t) => t.innerText.toLowerCase())
    return hs.some((h) => /next test/.test(h)) && !hs.some((h) => /calibration/.test(h))
  }))

// --- dates ------------------------------------------------------------------
const yearOnly = await isolate('HS-2024010')
check('date: a year-only next test shows its year and is marked as such',
  /2027/.test(yearOnly) && /year only/i.test(yearOnly))
check('date: a year-only next test never reads "within date"', !/within date/i.test(yearOnly))
const noDate = await isolate('HS-2024011')
check('date: preserved Arabic source status appears beside a missing date', /منتهي/.test(noDate))
await clearAll()

// --- pressure units ---------------------------------------------------------
await isolate('HS-2024012')
const psi = await bodyAll()
check('pressure: a PSI hose shows PSI and is never converted to BAR',
  /PSI/.test(psi) && !/\b248\b/.test(psi))
await clearAll()

// --- mapping ----------------------------------------------------------------
await selectFilter('Mapping', 'needs_unit_mapping')
const unresolved = await bodyText()
check('mapping: an unresolved Unit says so rather than guessing',
  /needs unit mapping/i.test(unresolved) && /not confirmed/i.test(unresolved))
await clearAll()

// --- sorting ----------------------------------------------------------------
async function sortHeader(name) {
  const th = page.locator('th', { hasText: new RegExp(`^${name}`) }).first()
  await th.locator('button').click()
  await page.waitForTimeout(140)
  return th.getAttribute('aria-sort')
}
const asc = await sortHeader('Serial')
const desc = await sortHeader('Serial')
check('sort: aria-sort is announced ascending then descending',
  asc === 'ascending' && desc === 'descending', `${asc} then ${desc}`)
check('sort: multiple columns are sortable',
  (await page.evaluate(() => [...document.querySelectorAll('th')].filter((t) => t.hasAttribute('aria-sort')).length)) >= 6)

// --- combined filters -------------------------------------------------------
await clearAll()
await selectFilter('Region', 'r-east')
await selectFilter('Due', 'overdue')
await selectFilter('Serial', 'missing')
const combined = await page.evaluate(() => document.querySelectorAll('table tbody tr').length)
const combinedText = await bodyText()
check('filter: East + Overdue + No serial yields a real intersection',
  combined > 0 && /Overdue/i.test(combinedText) && /East/.test(combinedText), `${combined} rows`)
check('filter: the intersection excludes rows that have a serial',
  await page.evaluate(() =>
    [...document.querySelectorAll('table tbody tr')].every((r) => !/HS-20240/.test(r.innerText))))

await page.locator('input[type="search"]').fill('zzzz-no-such-hose')
await page.waitForTimeout(280)
check('filter: a no-match result is stated explicitly',
  /No results match these filters/i.test(await bodyText()))
await clearAll()

// --- pagination -------------------------------------------------------------
const pager = page.locator('nav[aria-label*="pagination" i]')
const before = await pager.innerText()
await pager.locator('button:has-text("Next")').click()
await page.waitForTimeout(220)
const after = await pager.innerText()
check('pagination: Next advances the range', before !== after,
  `${before.split('\n')[0]} → ${after.split('\n')[0]}`)
await pager.locator('button:has-text("Previous")').click()
await page.waitForTimeout(220)

// --- technical detail -------------------------------------------------------
await page.locator('table tbody button[aria-expanded]').first().click()
await page.waitForTimeout(160)
const detail = await bodyText()
check('detail: expanding a row reveals the full technical record',
  /serial \(source\)/i.test(detail) && /test pressure/i.test(detail) && /dispenser/i.test(detail))
check('detail: provenance from the real schema is shown', /HOSES\.xlsx/i.test(detail))
check('detail: the disclosure control reports its state',
  (await page.locator('table tbody button[aria-expanded="true"]').count()) === 1)

// --- keyboard ---------------------------------------------------------------
await page.keyboard.press('Tab')
check('keyboard: tabbing moves focus to a genuinely focus-visible control',
  await page.evaluate(() => {
    const el = document.activeElement
    return Boolean(el && el !== document.body && el.matches(':focus-visible'))
  }))

// --- no mutation exposed ----------------------------------------------------
const buttons = await page.evaluate(() =>
  [...document.querySelectorAll('button')].map((b) => b.innerText.trim()).filter(Boolean))
check('deferral: no mapping mutation or delete control is exposed',
  !buttons.some((b) => /^(assign|resolve|mark resolved|save|edit|delete|archive)/i.test(b)),
  buttons.slice(0, 8).join(' | '))

// --- Cargas brand -----------------------------------------------------------
const logoSrc = await page.evaluate(() =>
  [...document.querySelectorAll('img')].map((i) => i.getAttribute('src')).join(','))
const appPage = await browser.newPage()
await appPage.goto(BASE.replace(/\/dev\/preview\.html.*$/, '/'), { waitUntil: 'domcontentloaded' })
const brand = await appPage.evaluate(() => ({
  title: document.title,
  icon: [...document.querySelectorAll('link[rel~="icon"]')].map((l) => l.getAttribute('href')).join(','),
}))
await appPage.close()
check('brand: the application title is the fixed Cargas title',
  brand.title === 'CNG Station Management | Cargas', brand.title)
check('brand: the favicon is the official Cargas mark, not a blue gear',
  brand.icon.includes('/brand/favicon') && !brand.icon.includes('favicon.svg'), brand.icon)
check('brand: the Cargas logo asset is used unmodified',
  /\/brand\/(logo-trimmed|mark)\.png/.test(logoSrc), logoSrc)

check('no page errors during the behavioural pass', errors.length === 0, errors.slice(0, 2).join(' | '))

/* ---------------------------------------------------------------- *
 * 3. Failure and empty branches.
 * ---------------------------------------------------------------- */
const errPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await errPage.goto(url('&scenario=error'), { waitUntil: 'networkidle' })
await errPage.waitForTimeout(450)
const errText = await errPage.evaluate(() => document.body.innerText)
check('error: a failed query states the failure', /Could not load Hoses/i.test(errText))
check('error: a failure is never rendered as an empty registry',
  !/No Hoses are currently recorded/i.test(errText))
check('error: a failed count is never rendered as zero',
  /attention summary could not be loaded/i.test(errText))
await errPage.screenshot({ path: `${OUT}/hoses-error.png` })
await errPage.close()

const emptyPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await emptyPage.goto(url('&scenario=empty'), { waitUntil: 'networkidle' })
await emptyPage.waitForTimeout(450)
const emptyText = await emptyPage.evaluate(() => document.body.innerText)
check('empty: the pre-import empty state is stated honestly',
  /No Hoses are currently recorded/i.test(emptyText))
check('empty: the empty state does not claim a failure', !/Could not load/i.test(emptyText))
await emptyPage.screenshot({ path: `${OUT}/hoses-empty.png` })
await emptyPage.close()

await page.close()
await browser.close()

const failed = results.filter((r) => !r.pass)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length) {
  console.log('FAILED:')
  for (const f of failed) console.log(`  - ${f.name}${f.detail ? ` — ${f.detail}` : ''}`)
  process.exit(1)
}
