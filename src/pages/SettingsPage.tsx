import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { NotificationPreferences } from '@/features/alerts/NotificationPreferences'

export function SettingsPage() {
  return (
    <PageContainer>
      <PageHeader
        title="Settings"
        description="Notification channels for your own account. These apply only to you."
      />
      <NotificationPreferences />
    </PageContainer>
  )
}
