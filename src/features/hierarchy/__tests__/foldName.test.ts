import { describe, expect, it } from 'vitest'

import { foldName } from '../foldName'

/**
 * These are the SAME cases asserted in SQL by supabase/tests/schema_scenarios.sql
 * (N1-N8). Two implementations of one rule will drift unless something pins
 * them together, and drift here means a search that silently stops finding a
 * station. If one side changes, both suites must.
 */
describe('foldName mirrors cng_normalize_name', () => {
  it('N1: taa marbuta and haa spellings fold together', () => {
    expect(foldName('الماظة')).toBe(foldName('الماظه'))
  })

  it('N2: hamzated alef folds to bare alef and is never deleted', () => {
    expect(foldName('إبراهيم')).toBe(foldName('ابراهيم'))
    expect(foldName('آمال')).toBe(foldName('امال'))
    // The defect in migration 0001 DELETED these letters. Length proves it does not.
    expect(foldName('إبراهيم')).toHaveLength('ابراهيم'.length)
  })

  it('N3: alef maqsura folds to yaa', () => {
    expect(foldName('مصطفى')).toBe(foldName('مصطفي'))
  })

  it('N4: tatweel is removed, never substituted with a letter', () => {
    expect(foldName('طاليــا')).toBe(foldName('طاليا'))
    // 0001 turned this into طاليااا by mapping tatweel onto alef.
    expect(foldName('طاليــا')).not.toContain('ااا')
  })

  it('N5: diacritics are removed without inserting characters', () => {
    expect(foldName('شَبرا')).toBe(foldName('شبرا'))
  })

  it('N6: case folded, edges trimmed, internal whitespace collapsed', () => {
    expect(foldName('  East   Station ')).toBe('east station')
  })

  it('N7: an empty or whitespace-only name folds to an empty string', () => {
    expect(foldName('   ')).toBe('')
    expect(foldName('')).toBe('')
  })

  it('N8: folding never merges genuinely different names', () => {
    // This is the load-bearing half. A folder that over-merges would quietly
    // combine two real Stations in a search result.
    expect(foldName('ابنوب')).not.toBe(foldName('ابنوب اسيوط'))
    expect(foldName('شبرا 1')).not.toBe(foldName('شبرا 2'))
  })

  it('leaves Latin and mixed Arabic/Latin/numeric names usable', () => {
    expect(foldName('Shobra 1')).toBe('shobra 1')
    expect(foldName('الماظة 2')).toBe(foldName('الماظه 2'))
  })
})
