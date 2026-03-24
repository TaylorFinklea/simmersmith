import { Bot, CheckCircle2 } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDateTime } from '@/lib/simmersmith'
import type { WeekChangeBatchOut, WeekOut } from '@/lib/types'

interface StagingStatusProps {
  week: WeekOut
  latestBatch: WeekChangeBatchOut | undefined
  onReady: () => void
  onApprove: () => void
  readyPending: boolean
  approvePending: boolean
}

export function StagingStatus({ week, latestBatch, onReady, onApprove, readyPending, approvePending }: StagingStatusProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Staging status</CardTitle>
        <CardDescription>Chat reads this state before finalizing.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="theme-surface-muted rounded-lg p-3">
          <p className="text-xs font-medium text-stone-500 dark:text-stone-400">Current stage</p>
          <p className="mt-1 font-serif text-2xl text-stone-900 dark:text-stone-100">{week.status}</p>
        </div>
        <div className="grid gap-3 md:grid-cols-3">
          {[
            { label: 'Changes', value: week.staged_change_count },
            { label: 'Feedback', value: week.feedback_count },
            { label: 'Exports', value: week.export_count },
          ].map((item) => (
            <div key={item.label} className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
              <p className="text-xs font-medium text-stone-500 dark:text-stone-400">{item.label}</p>
              <p className="mt-1 font-serif text-2xl text-stone-900 dark:text-stone-100">{item.value}</p>
            </div>
          ))}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            onClick={onReady}
            disabled={readyPending || week.status === 'ready_for_ai'}
          >
            <Bot className="size-3.5" />
            {readyPending ? 'Marking…' : week.status === 'ready_for_ai' ? 'Ready for chat' : 'Mark ready for AI'}
          </Button>
          {week.status !== 'approved' ? (
            <Button variant="outline" onClick={onApprove} disabled={approvePending}>
              <CheckCircle2 className="size-3.5" />
              {approvePending ? 'Approving…' : 'Approve week'}
            </Button>
          ) : null}
        </div>
        <div className="grid gap-3 md:grid-cols-2">
          <div className="rounded-lg border border-stone-200 dark:border-stone-700 p-3 text-sm text-stone-600 dark:text-stone-400">
            <p className="text-xs font-medium text-stone-500 dark:text-stone-400">Ready for AI</p>
            <p className="mt-1">{week.ready_for_ai_at ? formatDateTime(week.ready_for_ai_at) : 'Not yet'}</p>
          </div>
          <div className="rounded-lg border border-stone-200 dark:border-stone-700 p-3 text-sm text-stone-600 dark:text-stone-400">
            <p className="text-xs font-medium text-stone-500 dark:text-stone-400">Latest change</p>
            <p className="mt-1">{latestBatch ? `${latestBatch.summary} · ${formatDateTime(latestBatch.created_at)}` : 'None yet'}</p>
          </div>
        </div>
      </CardContent>
    </Card>
  )
}
