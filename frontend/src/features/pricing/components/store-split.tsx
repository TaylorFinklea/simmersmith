import { useState } from 'react'

import { FeedbackEntryForm } from '@/components/shared/feedback-entry-form'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { bestPriceEntry, formatCurrency, quantityLabel, retailerLabels } from '@/lib/simmersmith'
import type { FeedbackEntryPayload, GroceryItemOut } from '@/lib/types'

interface StoreSplitProps {
  storeSplit: Record<string, GroceryItemOut[]>
  splitTotals: Record<string, number>
  onSaveFeedback: (payload: FeedbackEntryPayload) => Promise<void>
}

export function StoreSplit({ storeSplit, splitTotals, onSaveFeedback }: StoreSplitProps) {
  const [expandedItemId, setExpandedItemId] = useState<string | null>(null)

  return (
    <Card>
      <CardHeader>
        <CardTitle>Shopping list by store</CardTitle>
        <CardDescription>The grouped recommendation — your actual shopping list.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {Object.entries(storeSplit).map(([retailer, items]) => (
          <div key={retailer} className="rounded-xl border border-stone-200 dark:border-stone-700 p-4">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{retailerLabels[retailer] ?? retailer}</p>
                <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{formatCurrency(splitTotals[retailer] ?? 0)} total</p>
              </div>
              <Badge variant="outline">{items.length} items</Badge>
            </div>

            <div className="mt-3 space-y-2">
              {items.map((item) => (
                <div key={item.grocery_item_id} className="theme-surface-soft rounded-lg p-3">
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{item.ingredient_name}</p>
                      <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{quantityLabel(item)}</p>
                    </div>
                    <Badge>{formatCurrency(bestPriceEntry(item)?.line_price)}</Badge>
                  </div>
                  <div className="mt-2">
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      onClick={() => setExpandedItemId((c) => (c === item.grocery_item_id ? null : item.grocery_item_id))}
                    >
                      {expandedItemId === item.grocery_item_id ? 'Hide feedback' : 'Feedback'}
                    </Button>
                  </div>
                  {expandedItemId === item.grocery_item_id ? (
                    <div className="mt-3">
                      <FeedbackEntryForm
                        title="Shopping feedback"
                        defaultTargetType="shopping_item"
                        defaultTargetName={item.ingredient_name}
                        groceryItemId={item.grocery_item_id}
                        defaultRetailer={retailer}
                        allowedTargetTypes={['shopping_item', 'brand']}
                        saveLabel="Save item feedback"
                        onSave={onSaveFeedback}
                      />
                    </div>
                  ) : null}
                </div>
              ))}
            </div>

            <div className="mt-3">
              <FeedbackEntryForm
                title="Store feedback"
                defaultTargetType="store"
                defaultTargetName={retailerLabels[retailer] ?? retailer}
                defaultRetailer={retailer}
                allowedTargetTypes={['store']}
                saveLabel="Save store feedback"
                onSave={onSaveFeedback}
              />
            </div>
          </div>
        ))}
      </CardContent>
    </Card>
  )
}
