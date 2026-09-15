/**
 * Brand token contrast verification.
 *
 * The Cargas brand colours were sampled from the official logo, and two of them
 * cannot legally carry text: #089B4B reaches only 3.62:1 against white, and
 * #FFEB00 reaches 1.17:1 on our working ground. Derivatives exist to fix that,
 * and a derivative is only worth anything if it keeps measuring what it claimed
 * to. This reads the real values out of src/index.css — not a copy of them —
 * and fails if any pairing the UI actually uses drops below its WCAG floor.
 *
 * Run: node scripts/verify-brand.mjs
 */
import { readFileSync } from 'node:fs'

const css = readFileSync(new URL('../src/index.css', import.meta.url), 'utf8')

/** Pull `--name: H S% L%;` out of either the :root or the .dark block. */
function token(name, theme = 'light') {
  const root = css.slice(
    theme === 'dark' ? css.indexOf('.dark {') : css.indexOf(':root {'),
    theme === 'dark' ? css.length : css.indexOf('.dark {'),
  )
  const m = root.match(new RegExp(`--${name}:\\s*([\\d.]+)\\s+([\\d.]+)%\\s+([\\d.]+)%`))
  if (!m) throw new Error(`token --${name} not found in the ${theme} block`)
  return [Number(m[1]), Number(m[2]), Number(m[3])]
}

function hslToRgb([h, s, l]) {
  s /= 100; l /= 100
  const k = (n) => (n + h / 30) % 12
  const a = s * Math.min(l, 1 - l)
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)))
  return [f(0), f(8), f(4)].map((v) => Math.round(v * 255))
}
const channel = (c) => {
  c /= 255
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
}
const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
function contrast(a, b) {
  const [x, y] = [luminance(a), luminance(b)]
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}
const hex = ([r, g, b]) => '#' + [r, g, b].map((v) => v.toString(16).padStart(2, '0').toUpperCase()).join('')

let failures = 0
function check(label, fg, bg, floor) {
  const ratio = contrast(hslToRgb(fg), hslToRgb(bg))
  const ok = ratio >= floor
  if (!ok) failures++
  console.log(
    `${ok ? 'PASS' : 'FAIL'}  ${ratio.toFixed(2).padStart(6)}:1  (needs ${floor})  ` +
      `${hex(hslToRgb(fg))} on ${hex(hslToRgb(bg))}  ${label}`,
  )
}

// WCAG floors: 4.5 normal text, 3.0 large text and non-text UI components.
for (const theme of ['light', 'dark']) {
  const t = (n) => token(n, theme)
  const bg = t('background')
  console.log(`\n--- ${theme} theme ---`)

  // Everything that puts text on brand colour must clear 4.5:1.
  check('on-brand text on --brand-strong (buttons, active nav)', t('brand-strong-fg'), t('brand-strong'), 4.5)
  check('--brand-strong as text on the working ground (links)', t('brand-strong'), bg, 4.5)
  check('on-deep text in the sidebar brand block', t('brand-deep-fg'), t('brand-deep'), 4.5)
  check('near-black on NGV yellow (yellow used as a fill)', t('brand-yellow-fg'), t('brand-yellow'), 4.5)
  check('NGV yellow as a mark on the deep brand ground', t('brand-yellow'), t('brand-deep'), 4.5)
  check('--brand-yellow-ink as text on the working ground', t('brand-yellow-ink'), bg, 4.5)

  // Non-text UI: the selection rail and the focus ring must still be seen.
  check('selection rail against the working ground', t('brand-rail'), bg, 3.0)
  check('focus ring against the working ground', t('brand-ring'), bg, 3.0)

  // Status colours are a separate system and must stay legible on their own.
  for (const s of ['ok', 'due-soon', 'overdue', 'unmapped', 'conflict', 'inactive']) {
    check(`status ${s} on its own background`, t(`status-${s}`), t(`status-${s}-bg`), 4.5)
  }
}

// The brand/semantic separation is a colour-distance claim, so measure it.
// Hue alone is what makes "Cargas green" and "compliant" read as different
// things; if they converge the split has quietly failed.
const brandHue = token('brand')[0]
const okHue = token('status-ok')[0]
const dist = Math.min(Math.abs(brandHue - okHue), 360 - Math.abs(brandHue - okHue))
const sepOk = dist >= 20
if (!sepOk) failures++
console.log(
  `\n${sepOk ? 'PASS' : 'FAIL'}  brand green (${brandHue}°) vs status-ok (${okHue}°) = ${dist}° apart ` +
    `(needs 20°, so brand identity never reads as a compliance state)`,
)

console.log(failures === 0 ? '\nAll brand contrast checks passed.' : `\n${failures} FAILED`)
process.exit(failures === 0 ? 0 : 1)
