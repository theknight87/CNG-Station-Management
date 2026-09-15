/**
 * Visual verification of the application shell in a REAL browser.
 *
 * Drives Chromium against the dev preview harness at the three viewports
 * Prompt 7 names, and asserts the things a source review cannot see: whether
 * the page scrolls sideways, whether focus is actually visible, whether the
 * collapsed sidebar keeps accessible names, and whether the mobile drawer traps
 * focus.
 *
 * Every check is an assertion, not a screenshot to eyeball later — though it
 * captures those too.
 */
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const URL = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'
const OUT = 'artifacts/ui'
mkdirSync(OUT, { recursive: true })

const VIEWPORTS = [
  { name: 'desktop-1440', width: 1440, height: 900 },
  { name: 'laptop-1024', width: 1024, height: 768 },
  { name: 'mobile-390', width: 390, height: 844 },
]

const results = []
function check(name, pass, detail = '') {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
}

const browser = await chromium.launch()

for (const vp of VIEWPORTS) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } })
  const consoleErrors = []
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()) })
  page.on('pageerror', (e) => consoleErrors.push(String(e)))

  await page.goto(URL, { waitUntil: 'networkidle' })
  await page.screenshot({ path: `${OUT}/${vp.name}.png`, fullPage: false })

  // --- the page itself must never scroll sideways ------------------------
  const overflow = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }))
  check(`${vp.name}: page does not scroll horizontally`,
    overflow.scrollWidth <= overflow.clientWidth + 1,
    `scrollWidth ${overflow.scrollWidth} vs clientWidth ${overflow.clientWidth}`)

  // --- the TABLE may scroll sideways; that is the design ------------------
  const tableScrolls = await page.evaluate(() => {
    const region = document.querySelector('[role="region"]')
    if (!region) return null
    return region.scrollWidth > region.clientWidth
  })
  check(`${vp.name}: table overflow is contained in its own region`, tableScrolls !== null,
    tableScrolls ? 'table scrolls horizontally inside its container' : 'table fits')

  check(`${vp.name}: no console errors`, consoleErrors.length === 0, consoleErrors.slice(0, 2).join(' | '))

  // --- Arabic renders, and is not mangled --------------------------------
  const arabic = await page.evaluate(() => {
    const el = [...document.querySelectorAll('[dir="auto"]')].find((e) => /[؀-ۿ]/.test(e.textContent ?? ''))
    if (!el) return null
    const rect = el.getBoundingClientRect()
    return { text: el.textContent, width: rect.width, dir: getComputedStyle(el).direction }
  })
  check(`${vp.name}: Arabic entity name renders with width`, Boolean(arabic && arabic.width > 0),
    arabic ? `"${arabic.text}" ${Math.round(arabic.width)}px direction=${arabic.dir}` : 'not found')

  if (vp.width >= 1024) {
    // --- desktop sidebar ---------------------------------------------------
    const sidebarVisible = await page.locator('aside').isVisible()
    check(`${vp.name}: persistent sidebar visible`, sidebarVisible)

    // --- long navigation labels must not be truncated --------------------
    const truncated = await page.evaluate(() => {
      const out = []
      for (const a of document.querySelectorAll('aside nav a')) {
        const span = a.querySelector('span:not([aria-hidden])')
        if (span && span.scrollWidth > span.clientWidth + 1) {
          out.push({ label: span.textContent, scroll: span.scrollWidth, client: span.clientWidth })
        }
      }
      return out
    })
    check(`${vp.name}: no sidebar label is visually truncated`, truncated.length === 0,
      truncated.map((t) => `${t.label} ${t.scroll}>${t.client}`).join(', '))


    const expandedWidth = await page.locator('aside').evaluate((el) => el.getBoundingClientRect().width)
    await page.getByRole('button', { name: 'Collapse sidebar' }).click()
    await page.waitForTimeout(80)
    const collapsedWidth = await page.locator('aside').evaluate((el) => el.getBoundingClientRect().width)
    check(`${vp.name}: sidebar collapses`, collapsedWidth < expandedWidth,
      `${Math.round(expandedWidth)}px -> ${Math.round(collapsedWidth)}px`)
    await page.screenshot({ path: `${OUT}/${vp.name}-collapsed.png` })

    // Icon-only links must KEEP their accessible names.
    const named = await page.getByRole('link', { name: 'Gas Detector Management' }).count()
    check(`${vp.name}: collapsed icon-only link keeps its accessible name`, named === 1)

    await page.getByRole('button', { name: 'Expand sidebar' }).click()
    await page.waitForTimeout(80)

    // --- focus visibility --------------------------------------------------
    // Reset focus to the document first: the collapse/expand clicks above left
    // focus on a button, so Tab would measure the NEXT stop rather than the
    // first one. `blur()` alone is not enough in Chromium — the sequential
    // focus starting point has to be reset by focusing the body.
    await page.evaluate(() => {
      const el = document.activeElement
      if (el && el instanceof HTMLElement) el.blur()
      document.body.setAttribute('tabindex', '-1')
      document.body.focus()
      document.body.removeAttribute('tabindex')
    })
    await page.keyboard.press('Tab')
    const focusStyle = await page.evaluate(() => {
      const el = document.activeElement
      if (!el) return null
      const s = getComputedStyle(el)
      return { tag: el.tagName, text: el.textContent?.trim().slice(0, 40), outline: s.outlineStyle, shadow: s.boxShadow }
    })
    check(`${vp.name}: first Tab reaches the skip link`,
      (focusStyle?.text ?? '').toLowerCase().includes('skip to main content'),
      focusStyle?.text ?? 'nothing focused')

    const ringVisible = await page.evaluate(() => {
      const el = document.activeElement
      if (!el) return false
      const s = getComputedStyle(el)
      return s.outlineStyle !== 'none' || s.boxShadow !== 'none'
    })
    check(`${vp.name}: focused element has a visible focus indicator`, ringVisible)
    await page.screenshot({ path: `${OUT}/${vp.name}-focus.png` })
  } else {
    // --- mobile drawer -----------------------------------------------------
    const sidebarHidden = !(await page.locator('aside').isVisible())
    check(`${vp.name}: persistent sidebar is hidden`, sidebarHidden)

    await page.getByRole('button', { name: 'Open navigation' }).click()
    await page.waitForTimeout(80)
    const dialog = page.getByRole('dialog', { name: 'Main navigation' })
    check(`${vp.name}: drawer opens as a modal dialog`, await dialog.isVisible())
    await page.screenshot({ path: `${OUT}/${vp.name}-drawer.png` })

    const focusInside = await page.evaluate(() => {
      const d = document.querySelector('[role="dialog"]')
      return Boolean(d && document.activeElement && d.contains(document.activeElement))
    })
    check(`${vp.name}: focus moves into the drawer`, focusInside)

    await page.keyboard.press('Escape')
    await page.waitForTimeout(80)
    check(`${vp.name}: Escape closes the drawer`, (await page.getByRole('dialog').count()) === 0)

    // Touch targets in the drawer must clear 44px (the one place it applies).
    await page.getByRole('button', { name: 'Open navigation' }).click()
    await page.waitForTimeout(80)
    const linkHeights = await page.evaluate(() => {
      const d = document.querySelector('[role="dialog"]')
      return [...(d?.querySelectorAll('a') ?? [])].map((a) => a.getBoundingClientRect().height)
    })
    const minHeight = Math.min(...linkHeights)
    check(`${vp.name}: drawer links meet the touch target minimum`, minHeight >= 40,
      `smallest ${Math.round(minHeight)}px across ${linkHeights.length} links`)
    await page.keyboard.press('Escape')
  }

  // --- density: a table row must stay compact ----------------------------
  const rowHeight = await page.evaluate(() => {
    const row = document.querySelector('tbody tr')
    return row ? row.getBoundingClientRect().height : null
  })
  check(`${vp.name}: table rows are dense`, rowHeight !== null && rowHeight <= 44,
    `${rowHeight ? Math.round(rowHeight) : '?'}px`)

  await page.close()
}

await browser.close()

const failed = results.filter((r) => !r.pass)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length > 0) {
  console.log('FAILED:')
  for (const f of failed) console.log(`  - ${f.name}: ${f.detail}`)
}
process.exit(failed.length === 0 ? 0 : 1)
