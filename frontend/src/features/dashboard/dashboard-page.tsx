import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'

import { EmptyState } from '@/components/shared/empty-state'
import { PageHeader } from '@/components/shared/page-header'
import { PageSkeleton } from '@/components/shared/skeleton'
import { Button } from '@/components/ui/button'
import { api } from '@/lib/api'

import { QuickLinks } from './components/quick-links'
import { RecentWeeks } from './components/recent-weeks'
import { StagingPulse } from './components/staging-pulse'
import { WeekMetrics } from './components/week-metrics'

export function DashboardPage() {
  const { data: currentWeek, isLoading: weekLoading } = useQuery({
    queryKey: ['current-week'],
    queryFn: api.getCurrentWeek,
  })
  const { data: recentWeeks = [] } = useQuery({
    queryKey: ['weeks', 6],
    queryFn: () => api.getWeeks(6),
  })
  const { data: changeBatches = [] } = useQuery({
    queryKey: ['week-changes', currentWeek?.week_id ?? 'none'],
    queryFn: () => api.getWeekChanges(currentWeek!.week_id),
    enabled: Boolean(currentWeek?.week_id),
  })
  const { data: feedback } = useQuery({
    queryKey: ['week-feedback', currentWeek?.week_id ?? 'none'],
    queryFn: () => api.getWeekFeedback(currentWeek!.week_id),
    enabled: Boolean(currentWeek?.week_id),
  })
  const { data: exports = [] } = useQuery({
    queryKey: ['week-exports', currentWeek?.week_id ?? 'none'],
    queryFn: () => api.getWeekExports(currentWeek!.week_id),
    enabled: Boolean(currentWeek?.week_id),
  })

  const retailerCount = useMemo(
    () =>
      currentWeek
        ? new Set(currentWeek.grocery_items.flatMap((item) => item.retailer_prices.map((price) => price.retailer))).size
        : 0,
    [currentWeek],
  )

  if (weekLoading) return <PageSkeleton />

  if (!currentWeek) {
    return (
      <div className="space-y-5">
        <PageHeader eyebrow="Current week" title="No planning week yet" description="Create a weekly draft from chat, then come back to stage, review, and export." />
        <EmptyState
          title="Nothing planned yet"
          description="Start the week in the workspace, save a partial plan, and use AI later to fill gaps."
          action={<Button asChild><Link to="/weeks/current">Plan this week</Link></Button>}
        />
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Current week"
        title="Week overview"
        description="Stage edits, review feedback, and queue exports for the current week."
        badge={currentWeek.status}
        actions={
          <>
            <Button asChild><Link to="/weeks/current">Open week</Link></Button>
            <Button variant="outline" asChild><Link to="/pricing/current">Open pricing</Link></Button>
          </>
        }
      />
      <WeekMetrics week={currentWeek} />
      <section className="grid gap-5 xl:grid-cols-[1.15fr_0.85fr]">
        <QuickLinks notes={currentWeek.notes} />
        <StagingPulse week={currentWeek} changeBatches={changeBatches} feedback={feedback} exports={exports} retailerCount={retailerCount} />
      </section>
      <RecentWeeks weeks={recentWeeks} />
    </div>
  )
}
