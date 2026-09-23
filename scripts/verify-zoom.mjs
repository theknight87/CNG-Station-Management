/**
 * 200% browser zoom check (Chromium). 1440x900 at 200% = 720x450 CSS px, DPR 2.
 * Per preview view: no page-level sideways scroll, no table clipped out of reach,
 * no visible text past the right edge, no collapsed search field, no page error.
 * Needs the preview server: npx vite --config vite.preview.config.ts --port 5177
 */
import { chromium } from 'playwright'
const b = await chromium.launch()
const views = ['dashboard','regions','region','stations','station','alerts','hoses','detectors','shell']
let bad = 0
for (const v of views) {
  const p = await b.newPage({ viewport: { width: 720, height: 450 }, deviceScaleFactor: 2 })
  const errs = []; p.on('pageerror', e => errs.push(String(e)))
  await p.goto(`${process.env.PREVIEW_URL ?? 'http://127.0.0.1:5177/dev/preview.html'}?view=${v}`, { waitUntil: 'networkidle' }); await p.waitForTimeout(400)
  const r = await p.evaluate(() => ({
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    clipped: [...document.querySelectorAll('.table-scroll')].filter(el => el.scrollWidth > el.clientWidth + 1 && !['auto','scroll'].includes(getComputedStyle(el).overflowX)).length,
    tallest: Math.round(Math.max(0, ...[...document.querySelectorAll('tbody tr')].filter(r => !r.closest('.responsive-records')).map(r => r.getBoundingClientRect().height))),
    pastEdge: [...document.querySelectorAll('main *')].filter(el => {
      if (el.closest('.table-scroll')) return false
      const r = el.getBoundingClientRect(); const cs = getComputedStyle(el)
      return r.width > 0 && r.right > document.documentElement.clientWidth + 1 && cs.visibility !== 'hidden' && el.children.length === 0
    }).map(el => el.tagName + ':' + (el.textContent || '').trim().slice(0, 30)).slice(0, 3),
    narrowSearch: [...document.querySelectorAll('input[type=search]')].filter(i => i.getBoundingClientRect().width > 0 && i.getBoundingClientRect().width < 150).length,
    headings: [...document.querySelectorAll('h1,h2,h3')].filter(h => h.getBoundingClientRect().height > 3 * parseFloat(getComputedStyle(h).lineHeight || '20')).length,
  }))
  const ok = r.pastEdge.length === 0 && r.narrowSearch === 0 && r.over <= 1 && r.clipped === 0 && errs.length === 0 && r.headings === 0
  if (!ok) bad++
  console.log(`${ok ? 'PASS' : 'FAIL'} ${v.padEnd(10)} pageOverflow=${r.over} clippedTables=${r.clipped} tallestRow=${r.tallest}px brokenHeadings=${r.headings} pastEdge=${JSON.stringify(r.pastEdge)} narrowSearch=${r.narrowSearch} errors=${errs.length}`)
  await p.screenshot({ path: `artifacts/ui/zoom200-${v}.png` })
  await p.close()
}
await b.close(); process.exit(bad ? 1 : 0)
