import { Clock3, Heart, Pencil, RotateCcw, Trash2, UtensilsCrossed } from 'lucide-react'

import { AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import type { RecipeOut } from '@/lib/types'

import { IngredientList } from './ingredient-list'

interface RecipeCardProps {
  recipe: RecipeOut
  onEdit: (recipe: RecipeOut) => void
  onToggleFavorite: (recipe: RecipeOut) => Promise<void>
  onArchive: (recipe: RecipeOut) => Promise<void>
  onRestore: (recipe: RecipeOut) => Promise<void>
  onDelete: (recipe: RecipeOut) => Promise<void>
  actionsDisabled?: boolean
}

export function RecipeCard({ recipe, onEdit, onToggleFavorite, onArchive, onRestore, onDelete, actionsDisabled = false }: RecipeCardProps) {
  const metadata = [
    recipe.meal_type,
    recipe.cuisine,
    recipe.source_label ? `Source: ${recipe.source_label}` : null,
    recipe.servings ? `Serves ${recipe.servings}` : null,
    recipe.prep_minutes ? `Prep ${recipe.prep_minutes}m` : null,
    recipe.cook_minutes ? `Cook ${recipe.cook_minutes}m` : null,
  ].filter(Boolean)

  return (
    <AccordionItem value={recipe.recipe_id}>
      <AccordionTrigger>
        <div className="flex flex-1 flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <div className="text-left">
            <p className="font-serif text-lg text-stone-900 dark:text-stone-100">{recipe.name}</p>
            <div className="mt-1.5 flex flex-wrap gap-1.5">
              {metadata.map((item) => (
                <Badge key={item} variant="muted">{item}</Badge>
              ))}
              {recipe.archived ? <Badge variant="warning">Archived</Badge> : null}
              {recipe.favorite ? (
                <Badge variant="secondary" className="gap-1">
                  <Heart className="size-3 fill-current" /> Favorite
                </Badge>
              ) : null}
            </div>
          </div>
        </div>
      </AccordionTrigger>
      <AccordionContent className="space-y-4">
        <div className="flex flex-wrap gap-2">
          {!recipe.archived ? (
            <>
              <Button type="button" variant="outline" size="sm" onClick={() => onEdit(recipe)} disabled={actionsDisabled}>
                <Pencil className="size-3.5" />
                Edit
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => void onToggleFavorite(recipe)} disabled={actionsDisabled}>
                <Heart className="size-3.5" />
                {recipe.favorite ? 'Unfavorite' : 'Favorite'}
              </Button>
              <Button type="button" variant="ghost" size="sm" onClick={() => void onArchive(recipe)} disabled={actionsDisabled}>
                Archive
              </Button>
            </>
          ) : (
            <Button type="button" variant="outline" size="sm" onClick={() => void onRestore(recipe)} disabled={actionsDisabled}>
              <RotateCcw className="size-3.5" />
              Restore
            </Button>
          )}
          <Button type="button" variant="ghost" size="sm" onClick={() => void onDelete(recipe)} disabled={actionsDisabled}>
            <Trash2 className="size-3.5" />
            Delete
          </Button>
        </div>

        <div className="grid gap-4 lg:grid-cols-[1.05fr_0.95fr]">
          <Card className="theme-surface-soft">
            <CardHeader>
              <CardTitle>Notes</CardTitle>
              <CardDescription>Summary, tags, and timing.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              {recipe.instructions_summary ? (
                <p className="text-sm leading-6 text-stone-600 dark:text-stone-400">{recipe.instructions_summary}</p>
              ) : (
                <p className="text-sm text-stone-400 dark:text-stone-500">No summary saved.</p>
              )}
              <div className="flex flex-wrap gap-2 text-xs text-stone-500 dark:text-stone-400">
                <span className="inline-flex items-center gap-1.5 rounded-md bg-white dark:bg-stone-800 px-2 py-1">
                  <Clock3 className="size-3.5 text-olive-700 dark:text-olive-300" />
                  {recipe.prep_minutes || 0}m prep / {recipe.cook_minutes || 0}m cook
                </span>
                <span className="inline-flex items-center gap-1.5 rounded-md bg-white dark:bg-stone-800 px-2 py-1">
                  <UtensilsCrossed className="size-3.5 text-olive-700 dark:text-olive-300" />
                  {recipe.tags || 'No tags'}
                </span>
                {recipe.source_url ? (
                  <a
                    href={recipe.source_url}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1.5 rounded-md bg-white px-2 py-1 text-olive-700 hover:text-olive-800 underline-offset-2 hover:underline dark:bg-stone-800 dark:text-olive-300"
                  >
                    Original source
                  </a>
                ) : null}
              </div>
            </CardContent>
          </Card>
          <IngredientList ingredients={recipe.ingredients} />
        </div>
      </AccordionContent>
    </AccordionItem>
  )
}
