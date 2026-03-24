import { FeedbackEntryForm } from '@/components/shared/feedback-entry-form'
import { ReviewFlagBadge } from '@/components/shared/review-flag-badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { quantityLabel } from '@/lib/simmersmith'
import type { FeedbackEntryPayload, GroceryItemOut } from '@/lib/types'

interface ReviewItemsProps {
  items: GroceryItemOut[]
  onSaveFeedback: (payload: FeedbackEntryPayload) => Promise<void>
}

export function ReviewItems({ items, onSaveFeedback }: ReviewItemsProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Needs judgment</CardTitle>
        <CardDescription>Items with unresolved review flags.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {items.length === 0 ? (
          <div className="theme-surface-muted rounded-lg p-3 text-sm text-stone-600 dark:text-stone-400">No unresolved items.</div>
        ) : (
          items.map((item) => (
            <div key={item.grocery_item_id} className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{item.ingredient_name}</p>
                  <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{quantityLabel(item)}</p>
                </div>
                <ReviewFlagBadge flag={item.review_flag} />
              </div>
              <div className="mt-3">
                <FeedbackEntryForm
                  title="Shopping feedback"
                  defaultTargetType="shopping_item"
                  defaultTargetName={item.ingredient_name}
                  groceryItemId={item.grocery_item_id}
                  allowedTargetTypes={['shopping_item', 'brand', 'store']}
                  saveLabel="Save item feedback"
                  onSave={onSaveFeedback}
                />
              </div>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  )
}
