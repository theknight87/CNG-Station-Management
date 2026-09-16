import { describe, expect, it } from 'vitest'

import {
  CSV_BOM, cairoBusinessDate, escapeCsvCell, exportFilename, toCsv,
} from '@/features/reports/csv'

/**
 * CSV export safety.
 *
 * The export is a file that leaves this application and is opened in Excel or
 * LibreOffice by someone who trusts it. Two things must hold: a cell must never
 * execute, and an identifier must survive the round trip unchanged.
 */

describe('formula injection', () => {
  it('neutralizes every spreadsheet formula lead character', () => {
    for (const lead of ['=', '+', '-', '@', '\t', '\r']) {
      const cell = escapeCsvCell(`${lead}cmd|' /C calc'!A0`)
      // Quoted AND apostrophe-prefixed: a spreadsheet reads it as literal text.
      expect(cell.startsWith(`"'${lead}`)).toBe(true)
    }
  })

  it('neutralizes the classic DDE payload', () => {
    const cell = escapeCsvCell('=HYPERLINK("http://evil.test","click")')
    expect(cell).toBe(`"'=HYPERLINK(""http://evil.test"",""click"")"`)
    expect(cell.startsWith('"=')).toBe(false)
  })

  it('does not mangle an ordinary value', () => {
    expect(escapeCsvCell('Abnub')).toBe('Abnub')
    expect(escapeCsvCell('ابنوب')).toBe('ابنوب')
  })

  it('quotes values containing a delimiter, quote or newline', () => {
    expect(escapeCsvCell('a,b')).toBe('"a,b"')
    expect(escapeCsvCell('say "hi"')).toBe('"say ""hi"""')
    expect(escapeCsvCell('line1\nline2')).toBe('"line1\nline2"')
  })
})

describe('numbers versus text', () => {
  it('emits a genuine number bare, so a numeric column still sorts numerically', () => {
    expect(escapeCsvCell(-5, 'number')).toBe('-5')
    expect(escapeCsvCell(0, 'number')).toBe('0')
    expect(escapeCsvCell(12.5, 'number')).toBe('12.5')
  })

  it('falls back to the text guard for a non-number in a numeric column', () => {
    // A value that is not actually a number is not trusted just because the
    // column says so.
    expect(escapeCsvCell('-1+1', 'number')).toBe(`"'-1+1"`)
    expect(escapeCsvCell('=SUM(A1)', 'number')).toBe(`"'=SUM(A1)"`)
  })
})

describe('identifiers survive unchanged', () => {
  it('preserves leading zeros', () => {
    // Principle #11 and #15: identifiers are TEXT and are never padded,
    // trimmed or "corrected".
    expect(escapeCsvCell('0012345')).toBe('0012345')
    expect(escapeCsvCell('00-12-B')).toBe('00-12-B')
  })

  it('preserves the owner-confirmed part number verbatim', () => {
    expect(escapeCsvCell('SS-4R3A')).toBe('SS-4R3A')
  })

  it('guards but does not alter an identifier that begins with a dash', () => {
    const cell = escapeCsvCell('-0012')
    expect(cell).toBe(`"'-0012"`)
    // The prefix is additive: strip the guard and the original is intact.
    expect(cell.slice(2, -1)).toBe('-0012')
  })
})

describe('the file itself', () => {
  interface Row { serial: string | null; days: number | null }
  const columns = [
    { header: 'Serial', kind: 'text' as const, value: (r: Row) => r.serial },
    { header: 'Days Remaining', kind: 'number' as const, value: (r: Row) => r.days },
  ]

  it('is UTF-8 with a BOM, so Arabic names open correctly', () => {
    const csv = toCsv(columns, [{ serial: 'ابنوب-1', days: 3 }])
    expect(csv.startsWith(CSV_BOM)).toBe(true)
    expect(csv).toContain('ابنوب-1')
  })

  it('has a stable header row in the declared column order', () => {
    const csv = toCsv(columns, [])
    expect(csv.slice(CSV_BOM.length).split('\r\n')[0]).toBe('Serial,Days Remaining')
  })

  it('leaves NULL blank — never N/A, never 0', () => {
    const csv = toCsv(columns, [{ serial: null, days: null }])
    const row = csv.slice(CSV_BOM.length).split('\r\n')[1]
    expect(row).toBe(',')
    expect(csv).not.toMatch(/N\/A|Unknown/)
  })

  it('uses CRLF line endings', () => {
    const csv = toCsv(columns, [{ serial: 'A', days: 1 }])
    expect(csv.endsWith('\r\n')).toBe(true)
    expect(csv.slice(CSV_BOM.length).split('\r\n')).toHaveLength(3)
  })
})

describe('the filename', () => {
  it('carries the report type and the export date', () => {
    expect(exportFilename('due', '2026-09-16')).toBe('cng-due-2026-09-16.csv')
  })

  it('cannot be steered out of its own name', () => {
    expect(exportFilename('../../etc/passwd', '2026-09-16'))
      .toBe('cng-------etc-passwd-2026-09-16.csv')
  })

  it('dates the export by the Cairo business date, not the browser', () => {
    // 22:30 UTC on the 16th is already the 17th in Cairo (UTC+2/+3).
    expect(cairoBusinessDate(new Date('2026-09-16T22:30:00Z'))).toBe('2026-09-17')
    expect(cairoBusinessDate(new Date('2026-09-16T09:00:00Z'))).toBe('2026-09-16')
  })
})
