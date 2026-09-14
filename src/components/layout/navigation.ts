/**
 * Navigation reflects the authoritative structure: the physical hierarchy
 * (Region -> Station -> Unit -> Equipment -> SRV) plus the global aggregate
 * management modules, which are views over the same records and never own them.
 */

export interface NavItem {
  label: string
  to: string
}

export interface NavSection {
  heading: string
  items: NavItem[]
}

export const NAV_SECTIONS: NavSection[] = [
  {
    heading: 'Overview',
    items: [
      { label: 'Dashboard', to: '/' },
      { label: 'Alerts', to: '/alerts' },
      { label: 'Reports', to: '/reports' },
    ],
  },
  {
    heading: 'Hierarchy',
    items: [{ label: 'Regions', to: '/regions' }],
  },
  {
    heading: 'Management',
    items: [
      { label: 'SRV Management', to: '/manage/srvs' },
      { label: 'Vessels Management', to: '/manage/vessels' },
      { label: 'Gas Detector Management', to: '/manage/gas-detectors' },
      { label: 'Hoses Management', to: '/manage/hoses' },
    ],
  },
  {
    heading: 'Admin',
    items: [
      { label: 'Users', to: '/admin/users' },
      { label: 'Data Quality', to: '/admin/data-quality' },
      { label: 'Import', to: '/admin/import' },
    ],
  },
]
