import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDateTime } from '@/lib/simmersmith'
import type { ExportRunOut } from '@/lib/types'

interface ExportQueueProps {
  exports: ExportRunOut[]
}

export function ExportQueue({ exports }: ExportQueueProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Queued exports</CardTitle>
        <CardDescription>Queued here, completed by the Reminders helper.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {exports.length === 0 ? (
          <div className="theme-surface-soft rounded-lg p-3 text-sm text-stone-600 dark:text-stone-400">
            No exports yet. Queue meal or shopping reminders from the action bar.
          </div>
        ) : (
          exports.slice(0, 4).map((run) => (
            <div key={run.export_id} className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{run.export_type.replace('_', ' ')}</p>
                  <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">
                    {run.destination} · {formatDateTime(run.created_at)}
                  </p>
                </div>
                <Badge variant={run.status === 'completed' ? 'default' : run.status === 'failed' ? 'warning' : 'outline'}>
                  {run.status}
                </Badge>
              </div>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}
