import type { ReactNode } from 'react'

import { NotImplemented } from '@/components/states/AppStates'
import { PageContainer, PageHeader } from '@/components/layout/PageContainer'

/**
 * A route that exists so the shell is complete, whose feature is not built yet.
 *
 * Rewritten for Prompt 7 onto the shared page primitives. It shows NO data,
 * no counts and no sample records: an unbuilt feature must never be dressed up
 * to look like a successful empty result (prompt §20, §21).
 */
export function PagePlaceholder({
  title,
  description,
  plannedFor,
  children,
}: {
  title: string
  description: string
  /** The phase that will build this, stated plainly to the reader. */
  plannedFor: string
  children?: ReactNode
}) {
  return (
    <PageContainer>
      <PageHeader title={title} description={description} />
      <NotImplemented feature={title} phase={plannedFor}>
        {children}
      </NotImplemented>
    </PageContainer>
  )
}
