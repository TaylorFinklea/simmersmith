import type { ColumnDef } from '@tanstack/react-table'
import { useMemo } from 'react'

import { DataTable } from '@/components/shared/data-table'
import { ReviewFlagBadge } from '@/components/shared/review-flag-badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { bestPriceEntry, formatCurrency, pricingRetailers, quantityLabel, retailerLabels, retailerMetadata } from '@/lib/simmersmith'
import type { PricingResponse } from '@/lib/types'

interface PricingRow {
  ingredient_name: string
  quantity: string
  best_store: string
  best_price: string
  review_flag: string
  [key: string]: string
}

interface ComparisonTableProps {
  pricing: PricingResponse
}

export function ComparisonTable({ pricing }: ComparisonTableProps) {
  const retailers = useMemo(() => pricingRetailers(pricing), [pricing])

  const columns = useMemo<ColumnDef<PricingRow>[]>(() => {
    const cols: ColumnDef<PricingRow>[] = [
      { header: 'Ingredient', accessorKey: 'ingredient_name' },
      { header: 'Quantity', accessorKey: 'quantity' },
      { header: 'Best store', accessorKey: 'best_store' },
      { header: 'Best price', accessorKey: 'best_price' },
    ]
    retailers.forEach((retailer) => {
      cols.push(
        { header: `${retailerLabels[retailer] ?? retailer} price`, accessorKey: `${retailer}_price` },
        { header: `${retailerLabels[retailer] ?? retailer} listing`, accessorKey: `${retailer}_listing` },
      )
    })
    cols.push({
      header: 'Review',
      accessorKey: 'review_flag',
      cell: ({ row }) => <ReviewFlagBadge flag={row.original.review_flag} />,
    })
    return cols
  }, [retailers])

  const rows = useMemo<PricingRow[]>(() => {
    return pricing.items.map((item) => {
      const best = bestPriceEntry(item)
      const row: PricingRow = {
        ingredient_name: item.ingredient_name,
        quantity: quantityLabel(item),
        best_store: best ? retailerLabels[best.retailer] ?? best.retailer : 'Needs review',
        best_price: best ? formatCurrency(best.line_price) : 'n/a',
        review_flag: item.review_flag,
      }
      retailers.forEach((retailer) => {
        const match = item.retailer_prices.find((p) => p.retailer === retailer)
        row[`${retailer}_price`] = match ? formatCurrency(match.line_price) : 'No result'
        row[`${retailer}_listing`] = retailerMetadata(match)
      })
      return row
    })
  }, [pricing, retailers])

  return (
    <Card>
      <CardHeader>
        <CardTitle>Full comparison</CardTitle>
        <CardDescription>All prices and listings side by side.</CardDescription>
      </CardHeader>
      <CardContent>
        <DataTable columns={columns} data={rows} />
      </CardContent>
    </Card>
  )
}
