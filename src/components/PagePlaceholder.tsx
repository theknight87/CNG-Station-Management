import type { ReactNode } from 'react'

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

interface PagePlaceholderProps {
  title: string
  description: string
  /** What this screen will do once its phase is implemented. */
  plannedFor: string
  children?: ReactNode
}

/**
 * Scaffolding placeholder. Screens show no data until the schema and data
 * layer exist — deliberately empty rather than populated with sample data,
 * which would violate the "never fabricate" principle even in a demo.
 */
export function PagePlaceholder({
  title,
  description,
  plannedFor,
  children,
}: PagePlaceholderProps) {
  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
        <p className="text-sm text-muted-foreground">{description}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Not implemented yet</CardTitle>
          <CardDescription>{plannedFor}</CardDescription>
        </CardHeader>
        {children ? <CardContent>{children}</CardContent> : null}
      </Card>
    </div>
  )
}
