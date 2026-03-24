import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { RotateCcw } from 'lucide-react'

import { EmptyState } from '@/components/shared/empty-state'
import { PageHeader } from '@/components/shared/page-header'
import { PageSkeleton } from '@/components/shared/skeleton'
import { Button } from '@/components/ui/button'
import { api } from '@/lib/api'
import { groupGroceryByCategory } from '@/lib/simmersmith'
import { useRegenerateGrocery } from '@/hooks/use-week-mutations'

import { CategorySection } from './components/category-section'
import { GroceryFilters } from './components/grocery-filters'

export function GroceryPage() {
  const [query, setQuery] = useState('')
  const [reviewOnly, setReviewOnly] = useState(false)

  const { data: week, isLoading } = useQuery({
    queryKey: ['current-week'],
    queryFn: api.getCurrentWeek,
  })

  const regenerateMutation = useRegenerateGrocery()

  const filteredItems = useMemo(() => {
    if (!week) return []
    return week.grocery_items.filter((item) => {
      const matchesQuery = !query || [item.ingredient_name, item.category, item.source_meals, item.notes].join(' ').toLowerCase().includes(query.toLowerCase())
      const matchesReview = !reviewOnly || Boolean(item.review_flag)
      return matchesQuery && matchesReview
    })
  }, [query, reviewOnly, week])

  const grouped = groupGroceryByCategory(filteredItems)

  if (isLoading) return <PageSkeleton />

  if (!week) {
    return <EmptyState title="No grocery list yet" description="Approve or save a week first so grocery regeneration has something to build from." />
  }

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Grocery review"
        title="Grocery list"
        description="Items with quantities, source meals, and review flags — all visible for quick decisions."
        badge={`${week.grocery_items.length} items`}
        actions={
          <Button onClick={() => regenerateMutation.mutate(week.week_id)} disabled={regenerateMutation.isPending}>
            <RotateCcw className="size-3.5" />
            {regenerateMutation.isPending ? 'Regenerating…' : 'Regenerate'}
          </Button>
        }
      />

      <GroceryFilters query={query} onQueryChange={setQuery} reviewOnly={reviewOnly} onReviewOnlyChange={setReviewOnly} />

      {filteredItems.length === 0 ? (
        <EmptyState title="No items match" description="Try a broader search or disable the review-only filter." />
      ) : null}

      <div className="space-y-4">
        {Object.entries(grouped).map(([category, items]) => (
          <CategorySection key={category} category={category} items={items} />
        ))}
      </div>
    </div>
  )
}
