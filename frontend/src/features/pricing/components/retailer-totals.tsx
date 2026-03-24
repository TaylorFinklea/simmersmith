import { Store } from 'lucide-react'

import { MetricCard } from '@/components/shared/metric-card'
import { formatCurrency, retailerLabels } from '@/lib/simmersmith'

interface RetailerTotalsProps {
  totals: Record<string, number>
}

export function RetailerTotals({ totals }: RetailerTotalsProps) {
  return (
    <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      {Object.entries(totals).map(([retailer, total]) => (
        <MetricCard
          key={retailer}
          label={retailerLabels[retailer] ?? retailer}
          value={formatCurrency(total)}
          detail="Imported total"
          icon={<Store className="size-4" />}
        />
      ))}
    </section>
  )
}
