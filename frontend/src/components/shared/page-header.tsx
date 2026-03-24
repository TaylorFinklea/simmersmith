import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'

interface PageHeaderProps {
  eyebrow?: string
  title: string
  description?: string
  badge?: string
  actions?: React.ReactNode
  className?: string
}

export function PageHeader({ eyebrow, title, description, badge, actions, className }: PageHeaderProps) {
  return (
    <div className={cn('flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between', className)}>
      <div className="min-w-0 space-y-1">
        {eyebrow ? (
          <p className="text-xs font-medium uppercase tracking-wider text-stone-400 dark:text-stone-500">{eyebrow}</p>
        ) : null}
        <div className="flex items-center gap-3">
          <h1 className="font-serif text-2xl font-semibold text-stone-900 dark:text-stone-100">{title}</h1>
          {badge ? <Badge variant="muted">{badge}</Badge> : null}
        </div>
        {description ? (
          <p className="text-sm leading-6 text-stone-500 dark:text-stone-400">{description}</p>
        ) : null}
      </div>
      {actions ? <div className="flex shrink-0 flex-wrap gap-2">{actions}</div> : null}
    </div>
  )
}
