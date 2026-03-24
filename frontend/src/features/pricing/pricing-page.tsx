import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { SendToBack } from 'lucide-react'

import { EmptyState } from '@/components/shared/empty-state'
import { MetricCard } from '@/components/shared/metric-card'
import { PageHeader } from '@/components/shared/page-header'
import { PageSkeleton } from '@/components/shared/skeleton'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { api } from '@/lib/api'
import {
  bestPriceEntry,
  formatCurrency,
  groupedStoreSplit,
  pricingRetailers,
  quantityLabel,
  recommendedTotals,
  retailerLabels,
  retailerMetadata,
  unresolvedItems,
} from '@/lib/simmersmith'
import type { FeedbackEntryPayload } from '@/lib/types'
import { useExportWeek, useWeekFeedback } from '@/hooks/use-week-mutations'

import { ComparisonTable } from './components/comparison-table'
import { ExportPanel } from './components/export-panel'
import { RetailerTotals } from './components/retailer-totals'
import { ReviewItems } from './components/review-items'
import { StoreSplit } from './components/store-split'

export function PricingPage() {
  const { data: week, isLoading: weekLoading } = useQuery({
    queryKey: ['current-week'],
    queryFn: api.getCurrentWeek,
  })
  const { data: pricing } = useQuery({
    queryKey: ['pricing', week?.week_id ?? 'none'],
    queryFn: () => api.getPricing(week!.week_id),
    enabled: Boolean(week?.week_id),
  })
  const { data: exports = [] } = useQuery({
    queryKey: ['week-exports', week?.week_id ?? 'none'],
    queryFn: () => api.getWeekExports(week!.week_id),
    enabled: Boolean(week?.week_id),
  })
  const { data: feedback } = useQuery({
    queryKey: ['week-feedback', week?.week_id ?? 'none'],
    queryFn: () => api.getWeekFeedback(week!.week_id),
    enabled: Boolean(week?.week_id),
  })

  const exportMutation = useExportWeek()
  const feedbackMutation = useWeekFeedback()

  const splitTotals = useMemo(() => recommendedTotals(pricing), [pricing])
  const storeSplit = useMemo(() => groupedStoreSplit(pricing), [pricing])
  const reviewItems = useMemo(() => unresolvedItems(pricing), [pricing])
  const shoppingExports = useMemo(() => exports.filter((run) => run.export_type === 'shopping_split'), [exports])

  const handleFeedback = async (payload: FeedbackEntryPayload) => {
    if (!week) return
    await feedbackMutation.mutateAsync({ weekId: week.week_id, payload: [payload] })
  }

  if (weekLoading) return <PageSkeleton />

  if (!week) {
    return <EmptyState title="No current week" description="Pricing appears after a week exists and retailer results are imported." />
  }

  if (!pricing || pricing.items.length === 0) {
    return (
      <div className="space-y-5">
        <PageHeader eyebrow="Pricing review" title="Waiting for pricing data" description="Import retailer results to unlock comparison and store split." />
        <EmptyState title="No pricing imported yet" description="Ask Codex to scrape retailers and import the results." />
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Pricing review"
        title="Store split & shopping handoff"
        description="Compare retailers, lock in the split, capture feedback, and queue the export."
        badge={`${pricing.items.length} items`}
        actions={
          <Button
            onClick={() => exportMutation.mutate({ weekId: week.week_id, exportType: 'shopping_split' })}
            disabled={exportMutation.isPending}
          >
            <SendToBack className="size-3.5" />
            {exportMutation.isPending ? 'Queueing…' : 'Queue shopping export'}
          </Button>
        }
      />

      <RetailerTotals totals={pricing.totals} />

      <Tabs defaultValue="split" className="space-y-4">
        <TabsList>
          <TabsTrigger value="split">Store split</TabsTrigger>
          <TabsTrigger value="comparison">Full comparison</TabsTrigger>
          <TabsTrigger value="review">
            Needs review
            {reviewItems.length > 0 ? (
              <Badge variant="warning" className="ml-1.5 px-1.5 py-0 text-[10px]">{reviewItems.length}</Badge>
            ) : null}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="split" className="space-y-5">
          <section className="grid gap-5 xl:grid-cols-[0.95fr_1.05fr]">
            <div className="space-y-4">
              <Card>
                <CardContent className="grid gap-3 p-4 sm:grid-cols-2">
                  {Object.entries(splitTotals).map(([retailer, total]) => (
                    <MetricCard key={retailer} label={retailerLabels[retailer] ?? retailer} value={formatCurrency(total)} detail="Winner total" />
                  ))}
                </CardContent>
              </Card>
              <ExportPanel shoppingExports={shoppingExports} feedback={feedback} />
            </div>
            <StoreSplit storeSplit={storeSplit} splitTotals={splitTotals} onSaveFeedback={handleFeedback} />
          </section>

          {/* Mobile pricing cards */}
          <section className="grid gap-3 lg:hidden">
            {pricing.items.map((item) => {
              const best = bestPriceEntry(item)
              return (
                <Card key={item.grocery_item_id}>
                  <CardContent className="space-y-3 p-4">
                    <div className="flex items-start justify-between gap-2">
                      <div>
                        <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{item.ingredient_name}</p>
                        <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{quantityLabel(item)}</p>
                      </div>
                    </div>
                    <div className="flex flex-wrap gap-1.5">
                      {best ? (
                        <Badge>Best: {retailerLabels[best.retailer] ?? best.retailer} {formatCurrency(best.line_price)}</Badge>
                      ) : (
                        <Badge variant="warning">Needs review</Badge>
                      )}
                    </div>
                    <div className="space-y-1.5">
                      {pricingRetailers(pricing).map((retailer) => {
                        const price = item.retailer_prices.find((e) => e.retailer === retailer)
                        return (
                          <div key={retailer} className="rounded-md border border-stone-200 dark:border-stone-700 p-2.5 text-sm text-stone-600 dark:text-stone-400">
                            <div className="flex items-center justify-between gap-2">
                              <span className="font-medium text-stone-900 dark:text-stone-100">{retailerLabels[retailer] ?? retailer}</span>
                              <span>{formatCurrency(price?.line_price)}</span>
                            </div>
                            <p className="mt-1 text-xs text-stone-500 dark:text-stone-400">{retailerMetadata(price)}</p>
                          </div>
                        )
                      })}
                    </div>
                  </CardContent>
                </Card>
              )
            })}
          </section>
        </TabsContent>

        <TabsContent value="comparison" className="hidden lg:block">
          <ComparisonTable pricing={pricing} />
        </TabsContent>

        <TabsContent value="review">
          <ReviewItems items={reviewItems} onSaveFeedback={handleFeedback} />
        </TabsContent>
      </Tabs>
    </div>
  )
}
