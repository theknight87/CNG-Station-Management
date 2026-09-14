import { NavLink, Outlet } from 'react-router-dom'

import { cn } from '@/lib/utils'
import { NAV_SECTIONS } from './navigation'

export function AppLayout() {
  const appName = import.meta.env.VITE_APP_NAME ?? 'CNG Station Management'

  return (
    <div className="flex min-h-screen bg-background">
      <aside className="hidden w-64 shrink-0 border-r bg-card md:block">
        <div className="flex h-14 items-center border-b px-5">
          <span className="text-sm font-semibold tracking-tight">{appName}</span>
        </div>

        <nav className="space-y-6 p-4">
          {NAV_SECTIONS.map((section) => (
            <div key={section.heading}>
              <p className="px-2 pb-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                {section.heading}
              </p>
              <ul className="space-y-0.5">
                {section.items.map((item) => (
                  <li key={item.to}>
                    <NavLink
                      to={item.to}
                      end={item.to === '/'}
                      className={({ isActive }) =>
                        cn(
                          'block rounded-md px-2 py-1.5 text-sm transition-colors',
                          isActive
                            ? 'bg-accent font-medium text-accent-foreground'
                            : 'text-muted-foreground hover:bg-accent/60 hover:text-accent-foreground',
                        )
                      }
                    >
                      {item.label}
                    </NavLink>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-14 items-center justify-between border-b px-6">
          <span className="text-sm font-semibold md:hidden">{appName}</span>
          <span className="hidden text-sm text-muted-foreground md:inline">
            Equipment, maintenance and safety-relief compliance
          </span>
        </header>

        <main className="flex-1 overflow-y-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
