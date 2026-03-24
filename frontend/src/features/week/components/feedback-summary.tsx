import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import type { WeekFeedbackResponse } from '@/lib/types'

interface FeedbackSummaryProps {
  feedback: WeekFeedbackResponse | undefined
}

export function FeedbackSummary({ feedback }: FeedbackSummaryProps) {
  const items = [
    { label: 'Meal', value: feedback?.summary.meal_entries ?? 0 },
    { label: 'Ingredient', value: feedback?.summary.ingredient_entries ?? 0 },
    { label: 'Brand', value: feedback?.summary.brand_entries ?? 0 },
  ]

  return (
    <Card>
      <CardHeader>
        <CardTitle>Feedback summary</CardTitle>
        <CardDescription>Structured feedback flows into planning memory.</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3 md:grid-cols-3">
        {items.map((item) => (
          <div key={item.label} className="theme-surface-soft rounded-lg p-3">
            <p className="text-xs font-medium text-stone-500 dark:text-stone-400">{item.label}</p>
            <p className="mt-1 font-serif text-2xl text-stone-900 dark:text-stone-100">{item.value}</p>
          </div>
        ))}
      </CardContent>
    </Card>
  )
}
