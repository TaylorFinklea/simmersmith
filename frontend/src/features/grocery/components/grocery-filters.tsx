import { Search } from 'lucide-react'

import { Checkbox } from '@/components/ui/checkbox'
import { Card, CardContent } from '@/components/ui/card'
import { Input } from '@/components/ui/input'

interface GroceryFiltersProps {
  query: string
  onQueryChange: (value: string) => void
  reviewOnly: boolean
  onReviewOnlyChange: (value: boolean) => void
}

export function GroceryFilters({ query, onQueryChange, reviewOnly, onReviewOnlyChange }: GroceryFiltersProps) {
  return (
    <Card>
      <CardContent className="grid gap-3 p-4 md:grid-cols-[1fr_auto]">
        <label className="relative block">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-stone-400" />
          <Input
            value={query}
            onChange={(e) => onQueryChange(e.target.value)}
            placeholder="Search ingredient, category, notes, or source meal"
            className="pl-9"
          />
        </label>
        <label className="inline-flex items-center gap-2 rounded-lg border border-stone-200 dark:border-stone-700 bg-white dark:bg-stone-900 px-3 py-1.5 text-sm font-medium text-stone-600 dark:text-stone-400">
          <Checkbox
            checked={reviewOnly}
            onCheckedChange={(checked) => onReviewOnlyChange(checked === true)}
          />
          Review only
        </label>
      </CardContent>
    </Card>
  )
}
