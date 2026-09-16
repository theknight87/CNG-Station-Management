import { readFileSync, existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Cargas brand regression.
 *
 * The blue gear scaffold placeholder was removed during Prompt 10 and must not
 * come back — by restoration, by a scaffold regeneration, or by someone adding
 * a "temporary" icon. `public/brand/favicon.svg` was DELETED rather than
 * emptied precisely so it cannot be silently re-wired, so its continued
 * absence is itself the assertion.
 *
 * Application identity is fixed by CLAUDE.md §11.6 rule 6 and is not a design
 * decision a later prompt may revisit.
 */

const root = resolve(__dirname, '../../..')
const html = readFileSync(resolve(root, 'index.html'), 'utf8')

describe('Cargas identity', () => {
  it('keeps the fixed application title', () => {
    expect(html).toContain('<title>CNG Station Management | Cargas</title>')
  })

  it('wires the favicon derived from the official logo', () => {
    expect(html).toMatch(/<link\s+rel="icon"\s+href="\/brand\/favicon\.ico"/)
    expect(html).toContain('/brand/favicon-96.png')
    expect(html).toContain('/brand/apple-touch-icon.png')
  })

  it('never restores the blue gear placeholder', () => {
    // Deleted, not blanked, so it cannot be referenced again by accident.
    expect(existsSync(resolve(root, 'public/brand/favicon.svg'))).toBe(false)
    // Comments are stripped first: index.html deliberately DOCUMENTS the
    // deletion, and that explanation is what stops it being re-added. What
    // must not exist is a live reference.
    const markup = html.replace(/<!--[\s\S]*?-->/g, '')
    expect(markup).not.toContain('favicon.svg')
    expect(markup).not.toMatch(/gear/i)
  })

  it('keeps the official logo assets present and unrenamed', () => {
    for (const asset of ['logo.png', 'logo-trimmed.png', 'mark.png', 'favicon.ico']) {
      expect(existsSync(resolve(root, 'public/brand', asset))).toBe(true)
    }
  })

  it('invents no slogan or tagline in the document head', () => {
    const head = html.slice(0, html.indexOf('</head>'))
    expect(head).not.toMatch(/tagline|slogan|smarter|powered by/i)
  })
})
