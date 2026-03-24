import { zodResolver } from '@hookform/resolvers/zod'
import { Plus, Trash2 } from 'lucide-react'
import { useEffect, useId } from 'react'
import { Controller, useFieldArray, useForm } from 'react-hook-form'
import { z } from 'zod'

import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import type { RecipeOut, RecipePayload } from '@/lib/types'

const mealTypeOptions = [
  { value: 'breakfast', label: 'Breakfast' },
  { value: 'lunch', label: 'Lunch' },
  { value: 'dinner', label: 'Dinner' },
  { value: 'snack', label: 'Snack' },
]

const ingredientSchema = z.object({
  ingredient_id: z.string().nullable(),
  ingredient_name: z.string(),
  quantity: z.union([z.number(), z.nan()]).transform((value) => (Number.isNaN(value) ? null : value)).nullable(),
  unit: z.string(),
  category: z.string(),
  prep: z.string(),
  notes: z.string(),
})

const recipeSchema = z.object({
  recipe_id: z.string().nullable(),
  name: z.string().trim().min(1, 'Recipe name is required'),
  source: z.string(),
  source_label: z.string(),
  source_url: z.string(),
  meal_type: z.string(),
  cuisine: z.string(),
  servings: z.union([z.number(), z.nan()]).transform((value) => (Number.isNaN(value) ? null : value)).nullable(),
  prep_minutes: z.union([z.number(), z.nan()]).transform((value) => (Number.isNaN(value) ? null : value)).nullable(),
  cook_minutes: z.union([z.number(), z.nan()]).transform((value) => (Number.isNaN(value) ? null : value)).nullable(),
  tags: z.string(),
  instructions_summary: z.string(),
  favorite: z.boolean(),
  notes: z.string(),
  ingredients: z.array(ingredientSchema),
})

type RecipeEditorValues = z.infer<typeof recipeSchema>

function buildEmptyIngredient() {
  return {
    ingredient_id: null,
    ingredient_name: '',
    quantity: null,
    unit: '',
    category: '',
    prep: '',
    notes: '',
  }
}

function toEditorValues(recipe?: Partial<RecipePayload> | RecipeOut | null): RecipeEditorValues {
  return {
    recipe_id: recipe?.recipe_id ?? null,
    name: recipe?.name ?? '',
    source: recipe?.source ?? 'ui',
    source_label: recipe?.source_label ?? '',
    source_url: recipe?.source_url ?? '',
    meal_type: recipe?.meal_type ?? '',
    cuisine: recipe?.cuisine ?? '',
    servings: recipe?.servings ?? null,
    prep_minutes: recipe?.prep_minutes ?? null,
    cook_minutes: recipe?.cook_minutes ?? null,
    tags: recipe?.tags ?? '',
    instructions_summary: recipe?.instructions_summary ?? '',
    favorite: recipe?.favorite ?? false,
    notes: recipe?.notes ?? '',
    ingredients:
      recipe?.ingredients?.map((ingredient) => ({
        ingredient_id: ingredient.ingredient_id ?? null,
        ingredient_name: ingredient.ingredient_name ?? '',
        quantity: ingredient.quantity ?? null,
        unit: ingredient.unit ?? '',
        category: ingredient.category ?? '',
        prep: ingredient.prep ?? '',
        notes: ingredient.notes ?? '',
      })) ?? [],
  }
}

function toPayload(values: RecipeEditorValues): RecipePayload {
  return {
    recipe_id: values.recipe_id,
    name: values.name.trim(),
    source: values.source,
    source_label: values.source_label.trim(),
    source_url: values.source_url.trim(),
    meal_type: values.meal_type,
    cuisine: values.cuisine.trim(),
    servings: values.servings,
    prep_minutes: values.prep_minutes,
    cook_minutes: values.cook_minutes,
    tags: values.tags.trim(),
    instructions_summary: values.instructions_summary.trim(),
    favorite: values.favorite,
    notes: values.notes.trim(),
    ingredients: values.ingredients
      .filter((ingredient) => ingredient.ingredient_name.trim())
      .map((ingredient) => ({
        ingredient_id: ingredient.ingredient_id,
        ingredient_name: ingredient.ingredient_name.trim(),
        quantity: ingredient.quantity,
        unit: ingredient.unit.trim(),
        category: ingredient.category.trim(),
        prep: ingredient.prep.trim(),
        notes: ingredient.notes.trim(),
      })),
  }
}

interface RecipeEditorDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  initialRecipe?: Partial<RecipePayload> | RecipeOut | null
  title?: string
  description?: string
  submitLabel?: string
  onSave: (payload: RecipePayload) => Promise<RecipeOut>
  onSaved?: (recipe: RecipeOut) => void
}

export function RecipeEditorDialog({
  open,
  onOpenChange,
  initialRecipe,
  title = 'Recipe editor',
  description = 'Save a lightweight recipe now and flesh it out later when you actually need the details.',
  submitLabel = 'Save recipe',
  onSave,
  onSaved,
}: RecipeEditorDialogProps) {
  const formId = useId()
  const form = useForm<RecipeEditorValues>({
    resolver: zodResolver(recipeSchema),
    defaultValues: toEditorValues(initialRecipe),
  })
  const { fields, append, remove } = useFieldArray({
    control: form.control,
    name: 'ingredients',
  })

  useEffect(() => {
    if (open) {
      form.reset(toEditorValues(initialRecipe))
    }
  }, [form, initialRecipe, open])

  async function handleSubmit(values: RecipeEditorValues) {
    const savedRecipe = await onSave(toPayload(values))
    onSaved?.(savedRecipe)
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>

        <form id={formId} onSubmit={form.handleSubmit(handleSubmit)} className="overflow-y-auto px-6 py-1">
          <div className="space-y-6 pb-5">
            <div className="grid gap-4 md:grid-cols-[1.2fr_0.8fr]">
              <div>
                <Label htmlFor="recipe-name">Recipe name</Label>
                <Input id="recipe-name" className="mt-1.5" placeholder="Sheet-pan tacos" {...form.register('name')} />
                {form.formState.errors.name ? (
                  <p className="mt-1.5 text-xs text-red-600">{form.formState.errors.name.message}</p>
                ) : null}
              </div>
              <div className="flex items-end">
                <label className="inline-flex items-center gap-2 text-sm font-medium text-stone-700 dark:text-stone-300">
                  <Controller
                    control={form.control}
                    name="favorite"
                    render={({ field }) => (
                      <Checkbox checked={field.value} onCheckedChange={(checked) => field.onChange(checked === true)} />
                    )}
                  />
                  Favorite
                </label>
              </div>
            </div>

            <div className="grid gap-4 md:grid-cols-4">
              <div>
                <Label>Meal type</Label>
                <Controller
                  control={form.control}
                  name="meal_type"
                  render={({ field }) => (
                    <Select value={field.value || '__none__'} onValueChange={(value) => field.onChange(value === '__none__' ? '' : value)}>
                      <SelectTrigger className="mt-1.5">
                        <SelectValue placeholder="Optional" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="__none__">No meal type</SelectItem>
                        {mealTypeOptions.map((option) => (
                          <SelectItem key={option.value} value={option.value}>
                            {option.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  )}
                />
              </div>
              <div>
                <Label htmlFor="recipe-cuisine">Cuisine</Label>
                <Input id="recipe-cuisine" className="mt-1.5" placeholder="Mexican, Italian, comfort food" {...form.register('cuisine')} />
              </div>
              <div>
                <Label htmlFor="recipe-servings">Servings</Label>
                <Input id="recipe-servings" type="number" step="0.5" min="0" className="mt-1.5" {...form.register('servings', { valueAsNumber: true })} />
              </div>
              <div>
                <Label htmlFor="recipe-tags">Tags</Label>
                <Input id="recipe-tags" className="mt-1.5" placeholder="quick, freezer, kid_favorite" {...form.register('tags')} />
              </div>
            </div>

            <div className="grid gap-4 md:grid-cols-2">
              <div>
                <Label htmlFor="recipe-prep">Prep minutes</Label>
                <Input id="recipe-prep" type="number" min="0" className="mt-1.5" {...form.register('prep_minutes', { valueAsNumber: true })} />
              </div>
              <div>
                <Label htmlFor="recipe-cook">Cook minutes</Label>
                <Input id="recipe-cook" type="number" min="0" className="mt-1.5" {...form.register('cook_minutes', { valueAsNumber: true })} />
              </div>
            </div>

            <div>
              <Label htmlFor="recipe-summary">Instructions summary</Label>
              <Textarea
                id="recipe-summary"
                className="mt-1.5 min-h-24"
                placeholder="Keep the prep note short. You can expand this later."
                {...form.register('instructions_summary')}
              />
            </div>

            <div>
              <Label htmlFor="recipe-notes">Notes</Label>
              <Textarea
                id="recipe-notes"
                className="mt-1.5 min-h-24"
                placeholder="Store notes, swap ideas, or family-specific reminders."
                {...form.register('notes')}
              />
            </div>

            <section className="space-y-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <h3 className="text-sm font-semibold text-stone-900 dark:text-stone-100">Ingredients</h3>
                  <p className="text-xs text-stone-500 dark:text-stone-400">Keep this loose. Add only the rows you actually want to remember.</p>
                </div>
                <Button type="button" variant="outline" size="sm" onClick={() => append(buildEmptyIngredient())}>
                  <Plus className="size-3.5" />
                  Add ingredient
                </Button>
              </div>

              {fields.length === 0 ? (
                <div className="rounded-xl border border-dashed border-stone-300 px-4 py-6 text-sm text-stone-500 dark:border-stone-700 dark:text-stone-400">
                  No ingredients yet.
                </div>
              ) : null}

              <div className="space-y-3">
                {fields.map((field, index) => (
                  <div key={field.id} className="rounded-xl border border-stone-200 p-3 dark:border-stone-800">
                    <div className="grid gap-3 md:grid-cols-[1.5fr_0.6fr_0.7fr_0.8fr_auto]">
                      <div>
                        <Label htmlFor={`ingredient-name-${field.id}`}>Ingredient</Label>
                        <Input id={`ingredient-name-${field.id}`} className="mt-1.5" {...form.register(`ingredients.${index}.ingredient_name`)} />
                      </div>
                      <div>
                        <Label htmlFor={`ingredient-quantity-${field.id}`}>Qty</Label>
                        <Input
                          id={`ingredient-quantity-${field.id}`}
                          type="number"
                          step="0.25"
                          min="0"
                          className="mt-1.5"
                          {...form.register(`ingredients.${index}.quantity`, { valueAsNumber: true })}
                        />
                      </div>
                      <div>
                        <Label htmlFor={`ingredient-unit-${field.id}`}>Unit</Label>
                        <Input id={`ingredient-unit-${field.id}`} className="mt-1.5" {...form.register(`ingredients.${index}.unit`)} />
                      </div>
                      <div>
                        <Label htmlFor={`ingredient-category-${field.id}`}>Category</Label>
                        <Input id={`ingredient-category-${field.id}`} className="mt-1.5" {...form.register(`ingredients.${index}.category`)} />
                      </div>
                      <div className="flex items-end">
                        <Button type="button" variant="ghost" size="sm" onClick={() => remove(index)}>
                          <Trash2 className="size-3.5" />
                          Remove
                        </Button>
                      </div>
                    </div>
                    <div className="mt-3 grid gap-3 md:grid-cols-2">
                      <div>
                        <Label htmlFor={`ingredient-prep-${field.id}`}>Prep</Label>
                        <Input id={`ingredient-prep-${field.id}`} className="mt-1.5" placeholder="diced, thawed, shredded" {...form.register(`ingredients.${index}.prep`)} />
                      </div>
                      <div>
                        <Label htmlFor={`ingredient-notes-${field.id}`}>Notes</Label>
                        <Input id={`ingredient-notes-${field.id}`} className="mt-1.5" placeholder="brand, backup option, or pantry note" {...form.register(`ingredients.${index}.notes`)} />
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          </div>
        </form>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button type="submit" form={formId} disabled={form.formState.isSubmitting}>
            {form.formState.isSubmitting ? 'Saving…' : submitLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
