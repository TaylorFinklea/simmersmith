import { cn } from '@/lib/utils'

interface SectionProps {
  title: string
  description?: string
  children: React.ReactNode
  className?: string
  actions?: React.ReactNode
}

export function Section({ title, description, children, className, actions }: SectionProps) {
  return (
    <section className={cn('space-y-3', className)}>
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="text-sm font-medium text-stone-900 dark:text-stone-100">{title}</h3>
          {description ? <p className="mt-0.5 text-xs text-stone-500">{description}</p> : null}
        </div>
        {actions}
      </div>
      {children}
    </section>
  )
}
