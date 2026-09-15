import { NullValue } from './NullValue'

/**
 * Date display with EXPLICIT precision (CLAUDE.md principle #17, §11.5).
 *
 * A `year_only` source value shows its YEAR and never a calendar date. There is
 * no code path here that turns 2021 into 1 January 2021 — the component cannot
 * render a day it was not given, because for `year_only` it never receives one.
 */

import type { PrecisionDate } from './dateSemantics'

export function DateValue({ date }: { date: PrecisionDate | null | undefined }) {
  if (!date) return <NullValue label="no date recorded" />

  switch (date.precision) {
    case 'exact_date':
      return date.value ? (
        <time dateTime={date.value} className="tabular">
          {date.value}
        </time>
      ) : (
        <NullValue label="no date recorded" />
      )

    case 'year_only':
      // The year, labelled as a year. Never expanded to a day.
      return (
        <span className="tabular" title="the source gave a year only; no exact date exists">
          {date.year ?? date.raw}
          <span className="ml-1 text-xs text-muted-foreground">(year only)</span>
        </span>
      )

    case 'invalid':
      // The raw source text is kept beside the missing date, never converted
      // into one and never turned into a computed status.
      return (
        <span className="text-muted-foreground">
          <NullValue label="no valid date in the source" />
          {date.sourceStatusRaw ? (
            <span dir="auto" className="ml-1 text-xs [unicode-bidi:isolate]">
              source: {date.sourceStatusRaw}
            </span>
          ) : null}
        </span>
      )

    case 'unknown':
    default:
      return <NullValue label="no date recorded" />
  }
}
