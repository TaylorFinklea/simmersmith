import { CheckCircle2, History } from 'lucide-react'
import { useState } from 'react'
import { Controller, useWatch } from 'react-hook-form'
import type { Control, UseFormRegister, UseFormSetValue } from 'react-hook-form'

import { FeedbackEntryForm } from '@/components/shared/feedback-entry-form'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { useSaveRecipe } from '@/hooks/use-recipe-mutations'
import { slotLabels } from '@/lib/simmersmith'
import type { FeedbackEntry, FeedbackEntryPayload, RecipeOut, RecipePayload } from '@/lib/types'
import { cn } from '@/lib/utils'

import { RecipeEditorDialog } from '@/features/recipes/components/recipe-editor-dialog'

interface MealCardProps {
  index: number
  fieldId: string
  control: Control<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  register: UseFormRegister<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  setValue: UseFormSetValue<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  recipes: RecipeOut[]
  existingFeedback: FeedbackEntry[]
  onSaveFeedback: (payload: FeedbackEntryPayload) => Promise<void>
}

export function MealCard({ index, fieldId, control, register, setValue, recipes, existingFeedback, onSaveFeedback }: MealCardProps) {
  const slot = useWatch({ control, name: `meals.${index}.slot` })
  const recipeName = useWatch({ control, name: `meals.${index}.recipe_name` })
  const recipeId = useWatch({ control, name: `meals.${index}.recipe_id` })
  const servings = useWatch({ control, name: `meals.${index}.servings` })
  const notes = useWatch({ control, name: `meals.${index}.notes` })
  const isSnack = slot === 'snack'
  const hasContent = Boolean(recipeName?.trim() || recipeId || servings != null || notes?.trim())
  const [manuallyExpanded, setManuallyExpanded] = useState(hasContent)
  const [recipeDialogOpen, setRecipeDialogOpen] = useState(false)
  const [recipeDraft, setRecipeDraft] = useState<Partial<RecipePayload> | null>(null)
  const saveRecipeMutation = useSaveRecipe()
  const expanded = hasContent || manuallyExpanded

  function buildRecipeDraft(): Partial<RecipePayload> {
    return {
      name: recipeName?.trim() ?? '',
      meal_type: slot,
      servings: typeof servings === 'number' && !Number.isNaN(servings) ? servings : null,
      notes: notes?.trim() ?? '',
      favorite: false,
      cuisine: '',
      tags: '',
      instructions_summary: '',
      ingredients: [],
      source: 'ui',
    }
  }

  function openRecipeDialog() {
    setRecipeDraft(buildRecipeDraft())
    setRecipeDialogOpen(true)
  }

  if (!expanded && !hasContent) {
    return (
      <Card className="border-dashed">
        <CardContent className="flex flex-wrap items-center justify-between gap-3 p-4">
          <div className="flex items-center gap-2">
            <Badge variant={isSnack ? 'default' : 'muted'}>{slotLabels[slot] ?? slot}</Badge>
            <p className="text-sm text-stone-500 dark:text-stone-400">Empty slot</p>
          </div>
          <Button type="button" variant="outline" size="sm" onClick={() => setManuallyExpanded(true)}>
            Add meal
          </Button>
        </CardContent>
      </Card>
    )
  }

  const clearSlot = () => {
    setValue(`meals.${index}.meal_id`, null, { shouldDirty: true })
    setValue(`meals.${index}.recipe_id`, null, { shouldDirty: true })
    setValue(`meals.${index}.recipe_name`, '', { shouldDirty: true })
    setValue(`meals.${index}.servings`, null, { shouldDirty: true })
    setValue(`meals.${index}.notes`, '', { shouldDirty: true })
    setValue(`meals.${index}.approved`, isSnack, { shouldDirty: true })
    setManuallyExpanded(false)
  }

  return (
    <Card className={cn(isSnack && 'border-olive-200 dark:border-olive-800 theme-surface-accent-soft')}>
      <CardContent className="space-y-4 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant={isSnack ? 'default' : 'muted'}>{slotLabels[slot] ?? slot}</Badge>
            {isSnack ? (
              <Badge variant="outline" className="gap-1">
                <CheckCircle2 className="size-3" />
                Locked
              </Badge>
            ) : null}
            {existingFeedback.length > 0 ? (
              <Badge variant="muted">{existingFeedback.length} feedback</Badge>
            ) : null}
          </div>
          {hasContent ? (
            <Button type="button" variant="ghost" size="sm" onClick={clearSlot}>
              Clear slot
            </Button>
          ) : null}
        </div>

        <div className="grid gap-3 lg:grid-cols-[1.1fr_0.9fr_120px_100px]">
          <div>
            <Label htmlFor={`meal-name-${fieldId}`}>Meal name</Label>
            <Input id={`meal-name-${fieldId}`} className="mt-1.5" {...register(`meals.${index}.recipe_name`)} />
          </div>
          <div>
            <Label>Swap recipe</Label>
            <Controller
              control={control}
              name={`meals.${index}.recipe_id`}
              render={({ field }) => (
                <Select
                  value={field.value ?? '__custom__'}
                  onValueChange={(value) => {
                    if (value === '__new__') {
                      openRecipeDialog()
                      return
                    }
                    if (value === '__custom__') {
                      field.onChange(null)
                      return
                    }
                    field.onChange(value)
                    const selectedRecipe = recipes.find((r) => r.recipe_id === value)
                    if (selectedRecipe) {
                      setValue(`meals.${index}.recipe_name`, selectedRecipe.name, { shouldDirty: true })
                      if (selectedRecipe.servings != null) {
                        setValue(`meals.${index}.servings`, selectedRecipe.servings, { shouldDirty: true })
                      }
                    }
                  }}
                >
                  <SelectTrigger className="mt-1.5"><SelectValue placeholder="Choose recipe" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="__custom__">Keep custom meal</SelectItem>
                    <SelectItem value="__new__">Create recipe…</SelectItem>
                    {recipes.map((recipe) => (
                      <SelectItem key={recipe.recipe_id} value={recipe.recipe_id}>{recipe.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            />
          </div>
          <div>
            <Label htmlFor={`servings-${fieldId}`}>Servings</Label>
            <Input id={`servings-${fieldId}`} type="number" step="0.5" min="0" className="mt-1.5" {...register(`meals.${index}.servings`, { valueAsNumber: true })} />
          </div>
          <div className="flex items-end">
            <label className="inline-flex items-center gap-2 text-sm font-medium text-stone-700 dark:text-stone-300">
              <Controller
                control={control}
                name={`meals.${index}.approved`}
                render={({ field }) => (
                  <Checkbox checked={isSnack ? true : field.value} disabled={isSnack} onCheckedChange={(checked) => field.onChange(checked === true)} />
                )}
              />
              Approved
            </label>
          </div>
        </div>

        <div>
          <Label htmlFor={`notes-${fieldId}`}>Notes</Label>
          <Textarea id={`notes-${fieldId}`} className="mt-1.5" {...register(`meals.${index}.notes`)} />
        </div>

        {!recipeId && recipeName?.trim() ? (
          <div className="rounded-lg border border-dashed border-stone-300 px-4 py-3 dark:border-stone-700">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p className="text-sm font-medium text-stone-900 dark:text-stone-100">Custom meal</p>
                <p className="text-xs text-stone-500 dark:text-stone-400">Keep this ad hoc, or save it into the recipe library when it is worth reusing.</p>
              </div>
              <Button type="button" variant="outline" size="sm" onClick={openRecipeDialog} disabled={saveRecipeMutation.isPending}>
                Save to recipe library
              </Button>
            </div>
          </div>
        ) : null}

        <p className="flex items-center gap-1.5 text-xs text-stone-400 dark:text-stone-500">
          <History className="size-3" />
          {isSnack ? 'Snacks stay auto-approved.' : 'Saving records field-level diffs and resets stale pricing.'}
        </p>

        {!isSnack ? (
          <FeedbackEntryForm
            title="Meal feedback"
            defaultTargetType="meal"
            defaultTargetName={recipeName ?? ''}
            mealId={fieldId}
            allowedTargetTypes={['meal', 'ingredient', 'brand', 'week']}
            onSave={onSaveFeedback}
          />
        ) : null}

        <RecipeEditorDialog
          open={recipeDialogOpen}
          onOpenChange={setRecipeDialogOpen}
          initialRecipe={recipeDraft}
          title={recipeId ? 'Create a new recipe from this meal' : 'Save meal to recipe library'}
          description="Planner meals stay ad hoc until you save them. This copies the current meal into the reusable library without changing past weeks."
          submitLabel="Save recipe"
          onSave={async (payload) => {
            const recipe = await saveRecipeMutation.mutateAsync(payload)
            setValue(`meals.${index}.recipe_id`, recipe.recipe_id, { shouldDirty: true })
            setValue(`meals.${index}.recipe_name`, recipe.name, { shouldDirty: true })
            if (recipe.servings != null) {
              setValue(`meals.${index}.servings`, recipe.servings, { shouldDirty: true })
            }
            return recipe
          }}
          onSaved={(recipe) => {
            setRecipeDraft(recipe)
          }}
        />
      </CardContent>
    </Card>
  )
}
