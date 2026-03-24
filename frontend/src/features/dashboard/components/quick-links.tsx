import { Link } from 'react-router-dom'

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

const links = [
  { title: 'Week workspace', href: '/weeks/current', copy: 'Edit meals, capture feedback, mark ready for AI.' },
  { title: 'Grocery review', href: '/grocery/current', copy: 'Review items, quantities, and review flags.' },
  { title: 'Pricing & exports', href: '/pricing/current', copy: 'Store split, item feedback, and Reminders handoff.' },
  { title: 'Profile & memory', href: '/profile', copy: 'Household defaults, staples, and preference signals.' },
]

export function QuickLinks({ notes }: { notes?: string }) {
  return (
    <Card className="theme-hero-panel overflow-hidden">
      <CardHeader>
        <CardTitle>Quick links</CardTitle>
        <CardDescription>{notes || 'Jump into any workspace to continue planning.'}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3 md:grid-cols-2">
        {links.map(({ title, href, copy }) => (
          <Link
            key={href}
            to={href}
            className="rounded-xl border border-stone-200 dark:border-stone-700 bg-white/75 dark:bg-stone-900/50 p-4 transition hover:-translate-y-0.5 hover:border-olive-300 dark:hover:border-olive-700 hover:bg-stone-50 dark:hover:bg-stone-800"
          >
            <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{title}</p>
            <p className="mt-1 text-xs leading-5 text-stone-500 dark:text-stone-400">{copy}</p>
          </Link>
        ))}
      </CardContent>
    </Card>
  )
}
