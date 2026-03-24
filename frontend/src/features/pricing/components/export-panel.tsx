import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDateTime } from '@/lib/simmersmith'
import type { ExportRunOut, WeekFeedbackResponse } from '@/lib/types'

interface ExportPanelProps {
  shoppingExports: ExportRunOut[]
  feedback: WeekFeedbackResponse | undefined
}

export function ExportPanel({ shoppingExports, feedback }: ExportPanelProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Export handoff</CardTitle>
        <CardDescription>Queue a snapshot, then complete it with the Reminders helper.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="grid gap-3 md:grid-cols-3">
          {[
            { label: 'Exports', value: shoppingExports.length },
            { label: 'Store feedback', value: feedback?.summary.store_entries ?? 0 },
            { label: 'Shopping feedback', value: feedback?.summary.shopping_entries ?? 0 },
          ].map((item) => (
            <div key={item.label} className="theme-surface-soft rounded-lg p-3">
              <p className="text-xs font-medium text-stone-500 dark:text-stone-400">{item.label}</p>
              <p className="mt-1 font-serif text-xl text-stone-900 dark:text-stone-100">{item.value}</p>
            </div>
          ))}
        </div>
        {shoppingExports.length === 0 ? (
          <div className="theme-surface-muted rounded-lg p-3 text-sm text-stone-600 dark:text-stone-400">
            No shopping export queued yet.
          </div>
        ) : (
          shoppingExports.slice(0, 4).map((run) => (
            <div key={run.export_id} className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{run.destination}</p>
                  <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{formatDateTime(run.created_at)} · {run.item_count} items</p>
                  <p className="mt-1 text-xs text-stone-400 dark:text-stone-500">ID: {run.export_id}</p>
                </div>
                <Badge variant={run.status === 'completed' ? 'default' : run.status === 'failed' ? 'warning' : 'outline'}>{run.status}</Badge>
              </div>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}
