import { CalendarDays, MessageSquareQuote, Rows3, SendToBack } from 'lucide-react'

import { MetricCard } from '@/components/shared/metric-card'
import { formatDate, formatDateTime } from '@/lib/simmersmith'
import type { WeekOut } from '@/lib/types'

interface WeekMetricsProps {
  week: WeekOut
}

export function WeekMetrics({ week }: WeekMetricsProps) {
  return (
    <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      <MetricCard
        label="Week"
        value={formatDate(week.week_start)}
        detail={`Ends ${formatDate(week.week_end)}`}
        icon={<CalendarDays className="size-4" />}
      />
      <MetricCard
        label="Stage"
        value={week.status}
        detail={week.ready_for_ai_at ? `Ready ${formatDateTime(week.ready_for_ai_at)}` : 'Not ready for AI yet'}
        icon={<Rows3 className="size-4" />}
      />
      <MetricCard
        label="Feedback"
        value={String(week.feedback_count)}
        detail="Memory entries this week"
        icon={<MessageSquareQuote className="size-4" />}
      />
      <MetricCard
        label="Exports"
        value={String(week.export_count)}
        detail="Handoff snapshots"
        icon={<SendToBack className="size-4" />}
      />
    </section>
  )
}
