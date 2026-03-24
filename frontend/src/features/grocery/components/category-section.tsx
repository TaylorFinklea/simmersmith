import type { ColumnDef } from '@tanstack/react-table'

import { DataTable } from '@/components/shared/data-table'
import { ReviewFlagBadge } from '@/components/shared/review-flag-badge'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { quantityLabel, uniqueMealSources } from '@/lib/simmersmith'
import type { GroceryItemOut } from '@/lib/types'

import { GroceryItemCard } from './grocery-item-card'

const columns: ColumnDef<GroceryItemOut>[] = [
  {
    header: 'Ingredient',
    accessorKey: 'ingredient_name',
    cell: ({ row }) => (
      <div>
        <p className="font-medium text-stone-900 dark:text-stone-100">{row.original.ingredient_name}</p>
        <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{row.original.notes || 'No notes'}</p>
      </div>
    ),
  },
  { header: 'Quantity', cell: ({ row }) => quantityLabel(row.original) },
  {
    header: 'Source meals',
    cell: ({ row }) => (
      <div className="flex flex-wrap gap-1">
        {uniqueMealSources(row.original.source_meals).map((source) => (
          <Badge key={source} variant="outline">{source}</Badge>
        ))}
      </div>
    ),
  },
  { header: 'Review', cell: ({ row }) => <ReviewFlagBadge flag={row.original.review_flag} /> },
]

interface CategorySectionProps {
  category: string
  items: GroceryItemOut[]
}

export function CategorySection({ category, items }: CategorySectionProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{category}</CardTitle>
        <CardDescription>{items.length} items</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {/* Mobile cards */}
        <div className="grid gap-3 lg:hidden">
          {items.map((item) => (
            <GroceryItemCard key={item.grocery_item_id} item={item} />
          ))}
        </div>
        {/* Desktop table */}
        <div className="hidden lg:block">
          <DataTable columns={columns} data={items} />
        </div>
      </CardContent>
    </Card>
  )
}
