import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import type { RecipeIngredientPayload } from '@/lib/types'

interface IngredientListProps {
  ingredients: RecipeIngredientPayload[]
}

export function IngredientList({ ingredients }: IngredientListProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Ingredients</CardTitle>
        <CardDescription>Available for grocery regeneration.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {ingredients.map((ingredient) => (
          <div
            key={ingredient.ingredient_id ?? ingredient.ingredient_name}
            className="rounded-lg border border-stone-200 dark:border-stone-700 bg-white dark:bg-stone-900 p-3"
          >
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{ingredient.ingredient_name}</p>
              <Badge variant="outline">{ingredient.quantity ?? '—'} {ingredient.unit}</Badge>
            </div>
            <div className="mt-1 flex flex-wrap gap-1.5 text-xs text-stone-500 dark:text-stone-400">
              {ingredient.category ? <span>{ingredient.category}</span> : null}
              {ingredient.prep ? <span>· {ingredient.prep}</span> : null}
              {ingredient.notes ? <span>· {ingredient.notes}</span> : null}
            </div>
          </div>
        ))}
      </CardContent>
    </Card>
  )
}
