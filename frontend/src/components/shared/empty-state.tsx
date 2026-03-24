import { Inbox } from 'lucide-react'

import { cn } from '@/lib/utils'

interface EmptyStateProps {
  icon?: React.ReactNode
  title: string
  description?: string
  action?: React.ReactNode
  className?: string
}

export function EmptyState({ icon, title, description, action, className }: EmptyStateProps) {
  return (
    <div className={cn('flex flex-col items-center justify-center rounded-xl border border-dashed border-stone-300 dark:border-stone-700 p-10 text-center', className)}>
      <div className="flex size-12 items-center justify-center rounded-full bg-stone-100 text-stone-400 dark:bg-stone-800 dark:text-stone-500">
        {icon ?? <Inbox className="size-5" />}
      </div>
      <p className="mt-4 text-sm font-medium text-stone-900 dark:text-stone-100">{title}</p>
      {description ? (
        <p className="mt-1 max-w-sm text-xs leading-5 text-stone-500 dark:text-stone-400">{description}</p>
      ) : null}
      {action ? <div className="mt-4">{action}</div> : null}
    </div>
  )
}
