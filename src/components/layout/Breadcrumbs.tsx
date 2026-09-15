import { Fragment } from 'react'
import { Link } from 'react-router-dom'
import { ChevronRight } from 'lucide-react'

import { EntityName } from '@/components/data/TechnicalText'

/**
 * Breadcrumbs (prompt §10).
 *
 * Built to carry ENTITY labels, not just route names, because the paths this
 * product needs look like:
 *
 *   Stations › East › الماظة › الماظة 1 › Compressor
 *
 * so a crumb must render an Arabic station name correctly inside otherwise
 * left-to-right chrome. `EntityName` handles that with dir="auto" and bidi
 * isolation; no crumb is hard-coded with a station or unit that does not exist.
 */

import type { Crumb } from './breadcrumbPaths'

export type { Crumb }

export function Breadcrumbs({ crumbs }: { crumbs: Crumb[] }) {
  if (crumbs.length === 0) return null

  return (
    // The trail SCROLLS rather than truncating. `truncate` on a crumb would
    // clip an Arabic station name mid-word into something ambiguous (§11.3),
    // and at 390px with a five-crumb path something has to give. Scrolling
    // this one strip keeps every name intact and readable; the page body
    // still never scrolls sideways.
    <nav
      aria-label="Breadcrumb"
      className="scrollbar-none min-w-0 overflow-x-auto"
    >
      <ol className="flex w-max items-center gap-1 whitespace-nowrap text-sm">
        {crumbs.map((crumb, i) => {
          const isLast = i === crumbs.length - 1
          const label = crumb.isEntity ? <EntityName name={crumb.label} /> : crumb.label

          return (
            <Fragment key={`${crumb.label}-${i}`}>
              {i > 0 ? (
                <ChevronRight className="h-3.5 w-3.5 shrink-0 text-muted-foreground/50" aria-hidden="true" />
              ) : null}
              <li className="shrink-0">
                {isLast || !crumb.to ? (
                  // The current page is marked for assistive technology, not
                  // only by colour.
                  <span aria-current={isLast ? 'page' : undefined} className="font-medium text-foreground">
                    {label}
                  </span>
                ) : (
                  <Link
                    to={crumb.to}
                    className="text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
                  >
                    {label}
                  </Link>
                )}
              </li>
            </Fragment>
          )
        })}
      </ol>
    </nav>
  )
}
