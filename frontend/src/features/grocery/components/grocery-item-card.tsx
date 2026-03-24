import { ReviewFlagBadge } from '@/components/shared/review-flag-badge'
import { Badge } from '@/components/ui/badge'
import { quantityLabel, uniqueMealSources } from '@/lib/simmersmith'
import type { GroceryItemOut } from '@/lib/types'

interface GroceryItemCardProps {
  item: GroceryItemOut
}

export function GroceryItemCard({ item }: GroceryItemCardProps) {
  return (
    <div className="theme-surface-soft rounded-lg border border-stone-200 dark:border-stone-700 p-3">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{item.ingredient_name}</p>
          <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{quantityLabel(item)}</p>
        </div>
        <ReviewFlagBadge flag={item.review_flag} />
      </div>
      <div className="mt-2 flex flex-wrap gap-1">
        {uniqueMealSources(item.source_meals).map((source) => (
          <Badge key={source} variant="outline">{source}</Badge>
        ))}
      </div>
      {item.notes ? <p className="mt-2 text-xs leading-5 text-stone-500 dark:text-stone-400">{item.notes}</p> : null}
    </div>
  )
}
