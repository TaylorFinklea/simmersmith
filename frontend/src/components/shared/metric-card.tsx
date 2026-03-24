import { Card, CardContent } from '@/components/ui/card'
import { Skeleton } from '@/components/shared/skeleton'
import { cn } from '@/lib/utils'

interface MetricCardProps {
  label: string
  value: string
  detail?: string
  icon?: React.ReactNode
  className?: string
  loading?: boolean
}

export function MetricCard({ label, value, detail, icon, className, loading }: MetricCardProps) {
  if (loading) {
    return (
      <Card className={cn('p-4', className)}>
        <CardContent className="space-y-2 p-0">
          <Skeleton className="h-3 w-16" />
          <Skeleton className="h-7 w-24" />
          <Skeleton className="h-3 w-32" />
        </CardContent>
      </Card>
    )
  }

  return (
    <Card className={cn('p-4', className)}>
      <CardContent className="p-0">
        <div className="flex items-center gap-2">
          {icon ? (
            <div className="flex size-7 items-center justify-center rounded-lg bg-stone-100 text-stone-500 dark:bg-stone-800 dark:text-stone-400">
              {icon}
            </div>
          ) : null}
          <p className="text-xs font-medium text-stone-500 dark:text-stone-400">{label}</p>
        </div>
        <p className="mt-2 font-serif text-2xl font-semibold text-stone-900 dark:text-stone-100">{value}</p>
        {detail ? <p className="mt-0.5 text-xs text-stone-400 dark:text-stone-500">{detail}</p> : null}
      </CardContent>
    </Card>
  )
}
