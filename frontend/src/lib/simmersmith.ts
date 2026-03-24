import type { GroceryItemOut, PricingResponse, RetailerPriceOut } from '@/lib/types'

export const dayOrder = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
]

export const slotOrder = ['breakfast', 'lunch', 'dinner', 'snack']

export const slotLabels: Record<string, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
  snack: 'Snack',
}

export const retailerLabels: Record<string, string> = {
  aldi: 'Aldi',
  walmart: 'Walmart',
  sams_club: "Sam's Club",
}

export function formatCurrency(value?: number | null) {
  if (value == null) {
    return 'n/a'
  }

  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
  }).format(value)
}

export function formatDate(value: string) {
  return new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  }).format(new Date(value))
}

export function formatDateTime(value?: string | null) {
  if (!value) {
    return ''
  }

  return new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(value))
}

export function quantityLabel(item: Pick<GroceryItemOut, 'total_quantity' | 'unit' | 'quantity_text'>) {
  if (item.total_quantity != null) {
    return `${item.total_quantity}${item.unit ? ` ${item.unit}` : ''}`
  }

  return item.quantity_text || 'Review'
}

export function groupMealsByDay<
  T extends {
    day_name: string
    meal_date: string
    slot: string
  },
>(meals: T[]) {
  return dayOrder
    .map((dayName) => ({
      dayName,
      meals: meals
        .filter((meal) => meal.day_name === dayName)
        .sort((left, right) => slotOrder.indexOf(left.slot) - slotOrder.indexOf(right.slot)),
    }))
    .filter((entry) => entry.meals.length > 0)
}

export function groupGroceryByCategory(items: GroceryItemOut[]) {
  return items.reduce<Record<string, GroceryItemOut[]>>((groups, item) => {
    const key = item.category || 'Other'
    groups[key] ??= []
    groups[key].push(item)
    return groups
  }, {})
}

export function pricingRetailers(pricing?: PricingResponse | null) {
  if (!pricing) {
    return []
  }

  const seen = new Set(Object.keys(pricing.totals))
  pricing.items.forEach((item) => {
    item.retailer_prices.forEach((price) => seen.add(price.retailer))
  })

  return ['aldi', 'walmart', 'sams_club', ...Array.from(seen).sort()].filter(
    (retailer, index, array) => retailer && array.indexOf(retailer) === index,
  )
}

export function bestPriceEntry(item: GroceryItemOut) {
  const candidates = item.retailer_prices.filter(
    (price) => price.status === 'matched' && price.line_price != null,
  )
  return candidates.sort((left, right) => (left.line_price ?? 0) - (right.line_price ?? 0))[0] ?? null
}

export function recommendedTotals(pricing?: PricingResponse | null) {
  if (!pricing) {
    return {}
  }

  return pricing.items.reduce<Record<string, number>>((totals, item) => {
    const best = bestPriceEntry(item)
    if (!best || best.line_price == null) {
      return totals
    }
    totals[best.retailer] = Math.round(((totals[best.retailer] ?? 0) + best.line_price) * 100) / 100
    return totals
  }, {})
}

export function groupedStoreSplit(pricing?: PricingResponse | null) {
  if (!pricing) {
    return {}
  }

  return pricing.items.reduce<Record<string, GroceryItemOut[]>>((groups, item) => {
    const best = bestPriceEntry(item)
    if (!best) {
      return groups
    }
    groups[best.retailer] ??= []
    groups[best.retailer].push(item)
    return groups
  }, {})
}

export function retailerMetadata(price?: RetailerPriceOut | null) {
  if (!price) {
    return ''
  }

  return [price.product_name, price.package_size, price.availability || price.review_note]
    .filter(Boolean)
    .join(' • ')
}

export function unresolvedItems(pricing?: PricingResponse | null) {
  return pricing?.items.filter((item) => item.review_flag) ?? []
}

export function uniqueMealSources(value: string) {
  return value
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
}
