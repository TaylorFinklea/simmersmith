import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDateTime } from '@/lib/simmersmith'
import type { ExportRunOut, WeekChangeBatchOut, WeekFeedbackResponse, WeekOut } from '@/lib/types'

interface StagingPulseProps {
  week: WeekOut
  changeBatches: WeekChangeBatchOut[]
  feedback: WeekFeedbackResponse | undefined
  exports: ExportRunOut[]
  retailerCount: number
}

function InfoCell({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
      <p className="text-xs font-medium text-stone-500 dark:text-stone-400">{label}</p>
      <p className="mt-1 text-sm text-stone-700 dark:text-stone-300">{value}</p>
    </div>
  )
}

export function StagingPulse({ week, changeBatches, feedback, exports, retailerCount }: StagingPulseProps) {
  const latestBatch = changeBatches[0]
  const latestExport = exports[0]

  return (
    <Card>
      <CardHeader>
        <CardTitle>Staging pulse</CardTitle>
        <CardDescription>Recent changes and pending handoffs.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3 text-sm text-stone-600 dark:text-stone-400">
        <div className="theme-surface-muted rounded-lg p-3">
          <p className="text-xs font-medium text-stone-500 dark:text-stone-400">Current stage</p>
          <p className="mt-1 font-serif text-2xl text-stone-900 dark:text-stone-100">{week.status}</p>
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          <InfoCell
            label="Latest change"
            value={latestBatch ? `${latestBatch.summary} · ${formatDateTime(latestBatch.created_at)}` : 'None yet'}
          />
          <InfoCell
            label="Latest export"
            value={latestExport ? `${latestExport.export_type.replace('_', ' ')} · ${latestExport.status}` : 'None yet'}
          />
          <InfoCell
            label="Pricing"
            value={week.priced_at ? `${retailerCount} retailers · ${formatDateTime(week.priced_at)}` : 'No pricing yet'}
          />
          <InfoCell
            label="Feedback"
            value={feedback ? `${feedback.summary.meal_entries} meal · ${feedback.summary.shopping_entries} shopping · ${feedback.summary.store_entries} store` : 'None recorded'}
          />
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          <InfoCell label="Approved" value={week.approved_at ? formatDateTime(week.approved_at) : 'Not yet'} />
          <InfoCell label="Ready for AI" value={week.ready_for_ai_at ? formatDateTime(week.ready_for_ai_at) : 'Not yet'} />
        </div>
      </CardContent>
    </Card>
  )
}
