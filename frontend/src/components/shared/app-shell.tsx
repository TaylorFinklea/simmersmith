import {
  CalendarRange,
  ChefHat,
  LayoutDashboard,
  Menu,
  MoonStar,
  ShoppingBasket,
  Store,
  SunMedium,
  UserRound,
  X,
} from 'lucide-react'
import { useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'

import { useTheme } from '@/app/theme-provider'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

const navigation = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard },
  { to: '/weeks/current', label: 'Week', icon: CalendarRange },
  { to: '/grocery/current', label: 'Grocery', icon: ShoppingBasket },
  { to: '/pricing/current', label: 'Pricing', icon: Store },
  { to: '/recipes', label: 'Recipes', icon: ChefHat },
  { to: '/profile', label: 'Profile', icon: UserRound },
]

function NavItem({ to, label, icon: Icon, onClick }: { to: string; label: string; icon: typeof LayoutDashboard; onClick?: () => void }) {
  return (
    <NavLink
      to={to}
      onClick={onClick}
      className={({ isActive }) =>
        cn(
          'inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-[13px] font-medium transition',
          isActive
            ? 'bg-olive-800 text-cream-50'
            : 'text-stone-500 hover:bg-stone-100 hover:text-stone-900 dark:hover:bg-stone-800 dark:hover:text-stone-100',
        )
      }
    >
      <Icon className="size-3.5" />
      <span className="hidden sm:inline">{label}</span>
    </NavLink>
  )
}

function MobileNavItem({ to, label, icon: Icon, onClick }: { to: string; label: string; icon: typeof LayoutDashboard; onClick?: () => void }) {
  return (
    <NavLink
      to={to}
      onClick={onClick}
      className={({ isActive }) =>
        cn(
          'flex flex-col items-center gap-0.5 py-1.5 text-[10px] font-medium transition',
          isActive
            ? 'text-olive-800 dark:text-olive-300'
            : 'text-stone-400 dark:text-stone-500',
        )
      }
    >
      <Icon className="size-5" />
      <span>{label}</span>
    </NavLink>
  )
}

export function AppShell() {
  const { resolvedTheme, toggleTheme } = useTheme()
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)

  return (
    <div className="theme-shell-bg min-h-screen">
      <div className="mx-auto flex min-h-screen w-full max-w-[1280px] flex-col px-4 pb-20 pt-3 sm:px-6 sm:pb-6 lg:px-8">
        {/* Desktop header */}
        <header className="theme-glass-panel sticky top-3 z-30 mb-5 rounded-2xl border px-4 py-3 backdrop-blur-lg sm:px-5">
          <div className="flex items-center justify-between gap-4">
            <div className="flex items-center gap-6">
              <h1 className="font-serif text-xl text-stone-950 dark:text-stone-50">SimmerSmith</h1>
              {/* Desktop nav */}
              <nav className="hidden sm:flex">
                <div className="flex gap-1">
                  {navigation.map((item) => (
                    <NavItem key={item.to} {...item} />
                  ))}
                </div>
              </nav>
              {/* Mobile hamburger */}
              <Button
                variant="ghost"
                size="sm"
                className="sm:hidden"
                onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
                aria-label="Toggle navigation"
              >
                {mobileMenuOpen ? <X className="size-4" /> : <Menu className="size-4" />}
              </Button>
            </div>
            <button
              type="button"
              aria-label={`Switch to ${resolvedTheme === 'dark' ? 'light' : 'dark'} mode`}
              aria-pressed={resolvedTheme === 'dark'}
              onClick={toggleTheme}
              className="inline-flex items-center gap-1.5 rounded-lg border border-stone-200 dark:border-stone-700 px-3 py-1.5 text-[13px] font-medium text-stone-500 transition hover:bg-stone-100 hover:text-stone-900 dark:hover:bg-stone-800 dark:hover:text-stone-100"
            >
              {resolvedTheme === 'dark' ? <MoonStar className="size-3.5" /> : <SunMedium className="size-3.5" />}
              <span className="hidden sm:inline">{resolvedTheme === 'dark' ? 'Dark' : 'Light'}</span>
            </button>
          </div>
          {/* Mobile dropdown menu */}
          {mobileMenuOpen ? (
            <nav className="mt-3 flex flex-col gap-1 border-t border-stone-200 dark:border-stone-700 pt-3 sm:hidden">
              {navigation.map((item) => (
                <NavItem key={item.to} {...item} onClick={() => setMobileMenuOpen(false)} />
              ))}
            </nav>
          ) : null}
        </header>

        <main className="flex-1 animate-page-enter">
          <Outlet />
        </main>
      </div>

      {/* Mobile bottom tab bar */}
      <nav className="theme-glass-panel fixed bottom-0 left-0 right-0 z-30 border-t backdrop-blur-lg sm:hidden">
        <div className="mx-auto grid max-w-md grid-cols-6">
          {navigation.map((item) => (
            <MobileNavItem key={item.to} {...item} />
          ))}
        </div>
      </nav>
    </div>
  )
}
