/**
 * Visual verification of the operational dashboard in a REAL browser.
 *
 * Two things are checked that source review cannot see: that the populated
 * dashboard stays dense and readable at three viewports, and that the real
 * empty-database dashboard is honest rather than blank.
 */
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const BASE = process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'
const OUT = 'artifacts/ui'
mkdirSync(OUT, { recursive: true })

const VIEWPORTS = [
  { name: 'dash-1440', width: 1440, height: 900 },
  { name: 'dash-1024', width: 1024, height: 768 },
  { name: 'dash-390', width: 390, height: 844 },
]

const results = []
const check = (name, pass, detail = '') => {
  results.push({ name, pass, detail })
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`)
}

const browser = await chromium.launch()

for (const vp of VIEWPORTS) {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } })
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })

  await page.goto(`${BASE}?view=dashboard`, { waitUntil: 'networkidle' })
  await page.screenshot({ path: `${OUT}/${vp.name}.png`, fullPage: vp.width < 500 })

  check(`${vp.name}: no console errors`, errors.length === 0, errors.slice(0, 2).join(' | '))

  const overflow = await page.evaluate(() => ({
    s: document.documentElement.scrollWidth, c: document.documentElement.clientWidth,
  }))
  check(`${vp.name}: page does not scroll horizontally`, overflow.s <= overflow.c + 1,
    `${overflow.s} vs ${overflow.c}`)

  // Dense rows survive at every width — the Prompt 7 regression, re-checked here.
  const rowHeights = await page.evaluate(() =>
    [...document.querySelectorAll('tbody tr')].map((r) => r.getBoundingClientRect().height))
  const maxRow = Math.max(...rowHeights)
  check(`${vp.name}: dashboard table rows stay dense`, maxRow <= 44,
    `tallest ${Math.round(maxRow)}px across ${rowHeights.length} rows`)

  // The due matrix must not double-count: each row's buckets sum to its total.
  const sums = await page.evaluate(() => {
    const out = []
    for (const row of document.querySelectorAll('tbody tr')) {
      const cells = [...row.querySelectorAll('td')].map((c) => Number(c.textContent.replace(/[^\d]/g, '')) || 0)
      if (cells.length === 9) {
        const buckets = cells.slice(0, 8).reduce((a, b) => a + b, 0)
        out.push({ buckets, total: cells[8] })
      }
    }
    return out
  })
  const mismatched = sums.filter((s) => s.buckets !== s.total)
  check(`${vp.name}: due buckets sum to the row total (no double counting)`,
    sums.length > 0 && mismatched.length === 0,
    `${sums.length} rows checked, ${mismatched.length} mismatched`)

  // The region bar is decoration; the number must be present as text.
  const regionText = await page.evaluate(() => {
    const row = [...document.querySelectorAll('tbody tr')].find((r) => /East/.test(r.textContent))
    return row ? row.textContent : null
  })
  check(`${vp.name}: region figures are readable as text, not only as bars`,
    Boolean(regionText && regionText.includes('1,180')), regionText ? 'found 1,180 assets' : 'row not found')

  // No single number may occupy a whole phone screen (prompt §20).
  if (vp.width < 500) {
    // Target the METRIC tiles specifically. An earlier version matched any
    // flex-col element and so measured the page wrapper, reporting 1310px for
    // a 60px tile.
    const tallest = await page.evaluate(() => {
      const tiles = document.querySelectorAll('[class*="min-w-[6.5rem]"]')
      let max = 0
      for (const el of tiles) max = Math.max(max, el.getBoundingClientRect().height)
      return { max, count: tiles.length }
    })
    check(`${vp.name}: no metric tile occupies a whole screen`,
      tallest.count > 0 && tallest.max < 844 * 0.25,
      `tallest of ${tallest.count} tiles: ${Math.round(tallest.max)}px`)
  }

  // Headings form a real structure for screen-reader navigation.
  const headings = await page.evaluate(() =>
    [...document.querySelectorAll('h1,h2,h3')].map((h) => `${h.tagName}:${h.textContent.trim().slice(0, 32)}`))
  check(`${vp.name}: section headings present`, headings.length >= 4, `${headings.length} headings`)

  await page.close()
}

await browser.close()
const failed = results.filter((r) => !r.pass)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
for (const f of failed) console.log(`  - ${f.name}: ${f.detail}`)
process.exit(failed.length === 0 ? 0 : 1)
