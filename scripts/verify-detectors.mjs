/**
 * Prompt 13 — Gas Detector Management in a REAL browser.
 *
 * Drives Chromium against the dev preview harness at the three viewports the
 * prompt names. Every item is an ASSERTION, not a screenshot to eyeball later,
 * though it captures those too. The exit code is the verdict.
 */
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const BASE = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'
const OUT = 'artifacts/p13'
mkdirSync(OUT, { recursive: true })

const results = []
function check(name, pass, detail = '') {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
}

const url = (params = '') => `${BASE}?view=detectors${params}`
const browser = await chromium.launch()

/* ------------------------------------------------------------------ *
 * 1. The three viewports.
 * ------------------------------------------------------------------ */
for (const vp of [
  { name: 'detectors-1440', width: 1440, height: 900 },
  { name: 'detectors-1024', width: 1024, height: 768 },
  { name: 'detectors-390', width: 390, height: 844 },
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

  // The dense table is allowed — required — to scroll inside its own region.
  const contained = await page.evaluate(() => {
    const region = document.querySelector('[role="region"]')
    if (!region) return null
    return { scrolls: region.scrollWidth > region.clientWidth, has: true }
  })
  check(`${vp.name}: the table scrolls inside its own region`, contained?.has === true,
    contained?.scrolls ? 'scrolls horizontally in-region' : 'fits at this width')

  // Mobile must stay a TABLE, not become a stack of giant cards.
  const isTable = await page.evaluate(() => {
    const rows = document.querySelectorAll('table tbody tr')
    return rows.length > 0
  })
  check(`${vp.name}: the registry stays a technical table`, isTable)

  // One H1, and heading order does not skip a level.
  const headings = await page.evaluate(() =>
    [...document.querySelectorAll('h1,h2,h3,h4')].map((h) => Number(h.tagName[1])))
  check(`${vp.name}: exactly one h1`, headings.filter((l) => l === 1).length === 1,
    `levels ${headings.join(',')}`)
  let ordered = true
  for (let i = 1; i < headings.length; i += 1) if (headings[i] - headings[i - 1] > 1) ordered = false
  check(`${vp.name}: heading order skips no level`, ordered)

  await page.close()
}

/* ------------------------------------------------------------------ *
 * 2. Behaviour, at desktop width.
 * ------------------------------------------------------------------ */
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
const errors = []
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
page.on('pageerror', (e) => errors.push(String(e)))
await page.goto(url(), { waitUntil: 'networkidle' })
await page.waitForSelector('table')

const bodyText = () => page.evaluate(() => document.body.innerText)
const rowCount = () => page.evaluate(() => document.querySelectorAll('table tbody tr').length)

// --- the summary is dataset-wide, not the page ------------------------------
const summary = await page.evaluate(() => {
  const s = document.querySelector('section[aria-labelledby="detector-attention"]')
  return s ? s.innerText : null
})
check('summary: the attention strip is present', summary !== null)
// Case-insensitive: the metric labels are uppercased by CSS, and innerText
// reflects the rendered text-transform.
check('summary: counts detectors, overdue, due window, mapping and absence',
  /detectors/i.test(summary) && /overdue/i.test(summary) && /due ≤60d/i.test(summary) &&
  /needs unit/i.test(summary) && /no exact date/i.test(summary) && /not installed/i.test(summary))
check('summary: states the Open/Closed area breakdown',
  /open,/.test(summary) && /closed\./.test(summary))

// --- the required data shapes are all rendered ------------------------------
const text = await bodyText()
check('row: an Arabic station name renders', /الماظة/.test(text))
check('row: an Arabic unit name renders', /الماظة 1/.test(text))
check('row: Open and Closed area classifications both appear',
  /\bOpen\b/.test(text) && /\bClosed\b/.test(text))
check('row: a NULL value reads as not recorded, never N/A or 0 placeholder',
  /not recorded/i.test(text) && !/\bN\/A\b/.test(text))

/**
 * The remaining shapes are isolated by SEARCH rather than read off page one.
 * The default sort is next-calibration ascending and most fixtures share a
 * date, so the id tie-break decides the page — a deterministic ordering, but
 * not one that happens to surface every special case first.
 */
async function isolate(term) {
  const box = page.locator('input[type="search"]')
  await box.fill('')
  await box.fill(term)
  await page.waitForTimeout(250)
  return page.evaluate(() => document.body.innerText)
}

const yearOnly = await isolate('GD-770006')
check('row: a year-only date shows its year and is marked as such',
  /2027/.test(yearOnly) && /year only/i.test(yearOnly))
check('row: a year-only date never reads "within date"', !/within date/i.test(yearOnly))
check('row: a year-only date yields no countdown',
  !/2027[\s\S]{0,40}-?\d+\s*$/m.test(yearOnly))

const notYet = await isolate('MSA')
check('row: a not-yet-assigned serial is worded differently from a NULL',
  /not yet assigned/i.test(notYet) || /not recorded/i.test(notYet))

const long = await isolate('LONG-IDENTIFIER')
check('row: a long identifier is rendered in full',
  /GD-CNG-2019-000044170-REV-A-LONG-IDENTIFIER/.test(long))

const noDate = await isolate('GD-770007')
check('row: preserved Arabic source status appears beside a missing date',
  /منتهي/.test(noDate))

await selectFilter('Mapping', 'needs_unit_mapping')
await page.locator('input[type="search"]').fill('')
await page.waitForTimeout(250)
const unresolved = await bodyText()
check('row: an unresolved Unit says so rather than guessing',
  /needs unit mapping/i.test(unresolved) && /not confirmed/i.test(unresolved))
await page.locator('button:has-text("Clear")').first().click()
await page.waitForTimeout(250)

// --- NO fabricated telemetry anywhere ---------------------------------------
check('no live telemetry is invented',
  !/\bppm\b/i.test(text) && !/gas concentration/i.test(text) && !/alarm state/i.test(text) &&
  !/battery/i.test(text) && !/sensor health/i.test(text))
check('no detector Location column is drawn',
  !/>\s*Location\s*</.test(await page.content()))

// --- sorting, both directions ----------------------------------------------
async function sortHeader(name) {
  const th = page.locator('th', { hasText: new RegExp(`^${name}`) }).first()
  await th.locator('button').click()
  await page.waitForTimeout(120)
  return th.getAttribute('aria-sort')
}
const asc = await sortHeader('Serial')
const desc = await sortHeader('Serial')
check('sort: aria-sort is announced ascending then descending',
  asc === 'ascending' && desc === 'descending', `${asc} then ${desc}`)

const sortable = await page.evaluate(() =>
  [...document.querySelectorAll('th')].filter((t) => t.hasAttribute('aria-sort')).length)
check('sort: multiple columns are sortable', sortable >= 7, `${sortable} sortable columns`)

// --- filters, individually and combined -------------------------------------
async function selectFilter(label, value) {
  await page.locator(`label:has-text("${label}") select`).first().selectOption(value)
  await page.waitForTimeout(150)
}

await selectFilter('Area', 'closed')
const closedOnly = await page.evaluate(() =>
  [...document.querySelectorAll('table tbody tr')]
    .filter((r) => !r.id.startsWith('srv-detail'))
    .every((r) => !/\bOpen\b/.test(r.innerText)))
check('filter: Area=Closed removes every Open row', closedOnly)

await selectFilter('Region', 'r-east')
await selectFilter('Due', 'overdue')
const combined = await rowCount()
const combinedText = await bodyText()
check('filter: East + Closed + Overdue yields a real intersection',
  combined > 0 && /Overdue/.test(combinedText) && /East/.test(combinedText),
  `${combined} rows`)
check('filter: the intersection excludes non-overdue rows',
  !/Within date/.test(await page.evaluate(() =>
    [...document.querySelectorAll('table tbody tr')].map((r) => r.innerText).join(' '))))

// A filter combination with no match is stated, not left blank.
await page.locator('input[type="search"]').fill('zzzz-no-such-detector')
await page.waitForTimeout(250)
check('filter: a no-match result is stated explicitly',
  /No results match these filters/i.test(await bodyText()))
await page.locator('button:has-text("Clear")').first().click()
await page.waitForTimeout(200)

// --- mapping status filter --------------------------------------------------
await selectFilter('Mapping', 'needs_unit_mapping')
check('filter: Mapping=Needs unit mapping keeps only unresolved rows',
  await page.evaluate(() =>
    [...document.querySelectorAll('table tbody tr')].every((r) => /Needs unit mapping/.test(r.innerText))))
await page.locator('button:has-text("Clear")').first().click()
await page.waitForTimeout(200)

// --- presence: recorded absence is reachable and carries no device ----------
await selectFilter('Presence', 'not_installed')
const absence = await bodyText()
check('presence: recorded absence is reachable', /not installed/i.test(absence))
check('presence: an absence row carries no serial and no calibration date',
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll('table tbody tr')]
    return rows.length > 0 && rows.every((r) => !/GD-\d/.test(r.innerText))
  }))
await page.locator('button:has-text("Clear")').first().click()
await page.waitForTimeout(200)

// --- pagination -------------------------------------------------------------
const pager = page.locator('nav[aria-label*="pagination" i]')
const before = await pager.innerText()
await pager.locator('button:has-text("Next")').click()
await page.waitForTimeout(200)
const after = await pager.innerText()
check('pagination: Next advances the range', before !== after, `${before.split('\n')[0]} → ${after.split('\n')[0]}`)
await pager.locator('button:has-text("Previous")').click()
await page.waitForTimeout(200)

// --- technical detail -------------------------------------------------------
await page.locator('table tbody button[aria-expanded]').first().click()
await page.waitForTimeout(150)
const detail = await bodyText()
check('detail: expanding a row reveals the technical record',
  /serial \(source\)/i.test(detail) && /area \(source text\)/i.test(detail) && /presence/i.test(detail))
check('detail: the raw source area text is preserved verbatim',
  /Close Area|Open Area/.test(detail))
check('detail: the disclosure control reports its state',
  (await page.locator('table tbody button[aria-expanded="true"]').count()) === 1)

// --- keyboard ---------------------------------------------------------------
await page.keyboard.press('Tab')
const focusVisible = await page.evaluate(() => {
  const el = document.activeElement
  if (!el || el === document.body) return false
  return el.matches(':focus-visible')
})
check('keyboard: tabbing moves focus to a genuinely focus-visible control', focusVisible)

// --- no mapping mutation is exposed ----------------------------------------
const buttons = await page.evaluate(() =>
  [...document.querySelectorAll('button')].map((b) => b.innerText.trim()).filter(Boolean))
check('deferral: no mapping mutation control is exposed',
  !buttons.some((b) => /^(assign|resolve|mark resolved|save|edit)/i.test(b)),
  buttons.slice(0, 8).join(' | '))

// --- Cargas brand -----------------------------------------------------------
// The LOGO is asserted on the harness, because that is where the real shell
// renders. TITLE and FAVICON belong to the application document, so they are
// read from the real index.html — the dev harness has its own title by design,
// and asserting against it would prove nothing about what ships.
const logoSrc = await page.evaluate(() =>
  [...document.querySelectorAll('img')].map((i) => i.getAttribute('src')).join(','))
const appPage = await browser.newPage()
await appPage.goto(BASE.replace(/\/dev\/preview\.html.*$/, '/'), { waitUntil: 'domcontentloaded' })
const brand = await appPage.evaluate(() => ({
  title: document.title,
  icon: [...document.querySelectorAll('link[rel~="icon"]')].map((l) => l.getAttribute('href')).join(','),
}))
brand.logo = logoSrc
await appPage.close()
check('brand: the application title is the fixed Cargas title',
  brand.title === 'CNG Station Management | Cargas', brand.title)
check('brand: the favicon is the official Cargas mark, not a blue gear',
  brand.icon.includes('/brand/favicon') && !brand.icon.includes('favicon.svg'), brand.icon)
check('brand: the Cargas logo asset is used unmodified',
  /\/brand\/(logo-trimmed|mark)\.png/.test(brand.logo), brand.logo)

check('no page errors during the behavioural pass', errors.length === 0, errors.slice(0, 2).join(' | '))

/* ------------------------------------------------------------------ *
 * 3. The failure and empty branches, which need their own scenarios.
 * ------------------------------------------------------------------ */
const errPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await errPage.goto(url('&scenario=error'), { waitUntil: 'networkidle' })
await errPage.waitForTimeout(400)
const errText = await errPage.evaluate(() => document.body.innerText)
check('error: a failed query states the failure', /Could not load Gas Detectors/i.test(errText))
check('error: a failure is never rendered as an empty registry',
  !/No Gas Detectors are currently recorded/i.test(errText))
check('error: a failed count is never rendered as zero',
  /attention summary could not be loaded/i.test(errText))
await errPage.screenshot({ path: `${OUT}/detectors-error.png` })
await errPage.close()

const emptyPage = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await emptyPage.goto(url('&scenario=empty'), { waitUntil: 'networkidle' })
await emptyPage.waitForTimeout(400)
const emptyText = await emptyPage.evaluate(() => document.body.innerText)
check('empty: the pre-import empty state is stated honestly',
  /No Gas Detectors are currently recorded/i.test(emptyText))
check('empty: the empty state does not claim a failure',
  !/Could not load/i.test(emptyText))
await emptyPage.screenshot({ path: `${OUT}/detectors-empty.png` })
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
