import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDateTime } from '@/lib/simmersmith'
import type { WeekChangeBatchOut } from '@/lib/types'

interface ChangeHistoryProps {
  batches: WeekChangeBatchOut[]
}

export function ChangeHistory({ batches }: ChangeHistoryProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Change history</CardTitle>
        <CardDescription>Field-level diffs of staged edits.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {batches.length === 0 ? (
          <div className="theme-surface-soft rounded-lg p-3 text-sm text-stone-600 dark:text-stone-400">No history yet.</div>
        ) : (
          batches.slice(0, 5).map((batch) => (
            <div key={batch.change_batch_id} className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{batch.summary}</p>
                  <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">
                    {batch.actor_label || batch.actor_type} · {formatDateTime(batch.created_at)}
                  </p>
                </div>
                <Badge variant="outline">{batch.events.length}</Badge>
              </div>
              <div className="mt-2 space-y-1.5">
                {batch.events.slice(0, 4).map((event) => (
                  <div key={event.change_event_id} className="theme-surface-soft rounded-md px-2.5 py-1.5 text-xs text-stone-600 dark:text-stone-400">
                    <span className="font-medium text-stone-800 dark:text-stone-200">{event.field_name}</span>: {event.before_value || 'empty'} → {event.after_value || 'empty'}
                  </div>
                ))}
              </div>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}
