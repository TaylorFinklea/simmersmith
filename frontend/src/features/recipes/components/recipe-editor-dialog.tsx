import { zodResolver } from '@hookform/resolvers/zod'
import { Plus, Trash2 } from 'lucide-react'
import { useEffect, useId, useMemo, useState } from 'react'
import { Controller, useFieldArray, useForm } from 'react-hook-form'
import { z } from 'zod'

import { Badge } from '@/components/ui/badge'
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
import { api } from '@/lib/api'
import type { BaseIngredient, IngredientVariation, RecipeIngredientPayload, RecipeOut, RecipePayload } from '@/lib/types'

const mealTypeOptions = [
  { value: 'breakfast', label: 'Breakfast' },
  { value: 'lunch', label: 'Lunch' },
  { value: 'dinner', label: 'Dinner' },
  { value: 'snack', label: 'Snack' },
]

const ingredientSchema = z.object({
  ingredient_id: z.string().nullable(),
  ingredient_name: z.string(),
  normalized_name: z.string().nullable(),
  quantity: z.union([z.number(), z.nan()]).transform((value) => (Number.isNaN(value) ? null : value)).nullable(),
  unit: z.string(),
  category: z.string(),
  prep: z.string(),
  notes: z.string(),
  base_ingredient_id: z.string().nullable(),
  base_ingredient_name: z.string().nullable(),
  ingredient_variation_id: z.string().nullable(),
  ingredient_variation_name: z.string().nullable(),
  resolution_status: z.enum(['unresolved', 'suggested', 'resolved', 'locked']),
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
    normalized_name: null,
    quantity: null,
    unit: '',
    category: '',
    prep: '',
    notes: '',
    base_ingredient_id: null,
    base_ingredient_name: null,
    ingredient_variation_id: null,
    ingredient_variation_name: null,
    resolution_status: 'unresolved' as const,
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
        normalized_name: ingredient.normalized_name ?? null,
        quantity: ingredient.quantity ?? null,
        unit: ingredient.unit ?? '',
        category: ingredient.category ?? '',
        prep: ingredient.prep ?? '',
        notes: ingredient.notes ?? '',
        base_ingredient_id: ingredient.base_ingredient_id ?? null,
        base_ingredient_name: ingredient.base_ingredient_name ?? null,
        ingredient_variation_id: ingredient.ingredient_variation_id ?? null,
        ingredient_variation_name: ingredient.ingredient_variation_name ?? null,
        resolution_status: ingredient.resolution_status ?? 'unresolved',
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
        normalized_name: ingredient.normalized_name,
        quantity: ingredient.quantity,
        unit: ingredient.unit.trim(),
        category: ingredient.category.trim(),
        prep: ingredient.prep.trim(),
        notes: ingredient.notes.trim(),
        base_ingredient_id: ingredient.base_ingredient_id,
        base_ingredient_name: ingredient.base_ingredient_name,
        ingredient_variation_id: ingredient.ingredient_variation_id,
        ingredient_variation_name: ingredient.ingredient_variation_name,
        resolution_status: ingredient.resolution_status,
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
  const [reviewingIngredientIndex, setReviewingIngredientIndex] = useState<number | null>(null)

  const reviewIngredient =
    reviewingIngredientIndex !== null ? form.watch(`ingredients.${reviewingIngredientIndex}`) : null

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
                    <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                      <div className="flex flex-wrap items-center gap-2">
                        <IngredientResolutionBadge status={form.watch(`ingredients.${index}.resolution_status`)} />
                        {form.watch(`ingredients.${index}.base_ingredient_name`) ? (
                          <Badge variant="outline">{form.watch(`ingredients.${index}.base_ingredient_name`)}</Badge>
                        ) : null}
                        {form.watch(`ingredients.${index}.ingredient_variation_name`) ? (
                          <Badge variant="secondary">{form.watch(`ingredients.${index}.ingredient_variation_name`)}</Badge>
                        ) : null}
                      </div>
                      <Button type="button" variant="outline" size="sm" onClick={() => setReviewingIngredientIndex(index)}>
                        Review match
                      </Button>
                    </div>
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

      <IngredientReviewDialog
        open={reviewingIngredientIndex !== null && reviewIngredient !== null}
        ingredient={reviewIngredient}
        onOpenChange={(open) => {
          if (!open) setReviewingIngredientIndex(null)
        }}
        onApply={(resolved) => {
          if (reviewingIngredientIndex === null) return
          form.setValue(`ingredients.${reviewingIngredientIndex}.base_ingredient_id`, resolved.baseIngredientId, { shouldDirty: true })
          form.setValue(`ingredients.${reviewingIngredientIndex}.base_ingredient_name`, resolved.baseIngredientName, { shouldDirty: true })
          form.setValue(`ingredients.${reviewingIngredientIndex}.ingredient_variation_id`, resolved.ingredientVariationId, { shouldDirty: true })
          form.setValue(`ingredients.${reviewingIngredientIndex}.ingredient_variation_name`, resolved.ingredientVariationName, { shouldDirty: true })
          form.setValue(`ingredients.${reviewingIngredientIndex}.resolution_status`, resolved.resolutionStatus, { shouldDirty: true })
          setReviewingIngredientIndex(null)
        }}
      />
    </Dialog>
  )
}

function IngredientResolutionBadge({ status }: { status: RecipeIngredientPayload['resolution_status'] }) {
  const resolvedStatus = status ?? 'unresolved'
  if (resolvedStatus === 'locked') {
    return <Badge variant="secondary">Locked product</Badge>
  }
  if (resolvedStatus === 'resolved') {
    return <Badge variant="outline">Resolved</Badge>
  }
  if (resolvedStatus === 'suggested') {
    return <Badge variant="warning">Suggested match</Badge>
  }
  return <Badge variant="warning">Needs review</Badge>
}

interface IngredientReviewDialogProps {
  open: boolean
  ingredient: RecipeIngredientPayload | null
  onOpenChange: (open: boolean) => void
  onApply: (resolved: {
    baseIngredientId: string | null
    baseIngredientName: string | null
    ingredientVariationId: string | null
    ingredientVariationName: string | null
    resolutionStatus: 'unresolved' | 'suggested' | 'resolved' | 'locked'
  }) => void
}

function IngredientReviewDialog({ open, ingredient, onOpenChange, onApply }: IngredientReviewDialogProps) {
  const [searchText, setSearchText] = useState('')
  const [searchResults, setSearchResults] = useState<BaseIngredient[]>([])
  const [isSearching, setIsSearching] = useState(false)
  const [searchError, setSearchError] = useState<string | null>(null)
  const [selectedBaseIngredient, setSelectedBaseIngredient] = useState<BaseIngredient | null>(null)
  const [variations, setVariations] = useState<IngredientVariation[]>([])
  const [isLoadingVariations, setIsLoadingVariations] = useState(false)
  const [selectedVariationId, setSelectedVariationId] = useState<string>('__none__')
  const [lockToVariation, setLockToVariation] = useState(false)
  const [createBaseOpen, setCreateBaseOpen] = useState(false)
  const [createVariationOpen, setCreateVariationOpen] = useState(false)
  const [newBaseName, setNewBaseName] = useState('')
  const [newBaseCategory, setNewBaseCategory] = useState('')
  const [newBaseUnit, setNewBaseUnit] = useState('')
  const [newBaseNotes, setNewBaseNotes] = useState('')
  const [newVariationName, setNewVariationName] = useState('')
  const [newVariationBrand, setNewVariationBrand] = useState('')
  const [newVariationPackageAmount, setNewVariationPackageAmount] = useState('')
  const [newVariationPackageUnit, setNewVariationPackageUnit] = useState('')
  const [newVariationNotes, setNewVariationNotes] = useState('')
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [isSavingBase, setIsSavingBase] = useState(false)
  const [isSavingVariation, setIsSavingVariation] = useState(false)

  const selectedVariation = useMemo(
    () => variations.find((variation) => variation.ingredient_variation_id === selectedVariationId) ?? null,
    [selectedVariationId, variations],
  )

  useEffect(() => {
    if (!open || !ingredient) return
    setSearchText(ingredient.base_ingredient_name ?? ingredient.ingredient_name ?? '')
    setSearchResults([])
    setSearchError(null)
    setSubmitError(null)
    setCreateBaseOpen(false)
    setCreateVariationOpen(false)
    setNewBaseName(ingredient.base_ingredient_name ?? ingredient.ingredient_name ?? '')
    setNewBaseCategory(ingredient.category ?? '')
    setNewBaseUnit(ingredient.unit ?? '')
    setNewBaseNotes('')
    setNewVariationName(ingredient.ingredient_variation_name ?? ingredient.ingredient_name ?? '')
    setNewVariationBrand('')
    setNewVariationPackageAmount(ingredient.quantity ? String(ingredient.quantity) : '')
    setNewVariationPackageUnit(ingredient.unit ?? '')
    setNewVariationNotes(ingredient.notes ?? '')
    setLockToVariation(ingredient.resolution_status === 'locked')
    setSelectedVariationId(ingredient.ingredient_variation_id ?? '__none__')

    if (ingredient.base_ingredient_id && ingredient.base_ingredient_name) {
      const base: BaseIngredient = {
        base_ingredient_id: ingredient.base_ingredient_id,
        name: ingredient.base_ingredient_name,
        normalized_name: ingredient.normalized_name ?? '',
        category: ingredient.category ?? '',
        default_unit: ingredient.unit ?? '',
        notes: '',
        nutrition_reference_amount: null,
        nutrition_reference_unit: '',
        calories: null,
      }
      setSelectedBaseIngredient(base)
    } else {
      setSelectedBaseIngredient(null)
      setVariations([])
      setSelectedVariationId('__none__')
    }
  }, [open, ingredient])

  useEffect(() => {
    if (!open || !selectedBaseIngredient) return
    void loadVariations(selectedBaseIngredient.base_ingredient_id)
  }, [open, selectedBaseIngredient])

  async function loadVariations(baseIngredientId: string) {
    try {
      setIsLoadingVariations(true)
      const nextVariations = await api.getIngredientVariations(baseIngredientId)
      setVariations(nextVariations)
    } catch (error) {
      setSubmitError(error instanceof Error ? error.message : 'Failed to load product variations')
      setVariations([])
    } finally {
      setIsLoadingVariations(false)
    }
  }

  async function runSearch() {
    const trimmed = searchText.trim()
    if (!trimmed) {
      setSearchResults([])
      setSearchError(null)
      return
    }

    try {
      setIsSearching(true)
      setSearchError(null)
      const results = await api.searchBaseIngredients(trimmed)
      setSearchResults(results)
    } catch (error) {
      setSearchError(error instanceof Error ? error.message : 'Failed to search ingredients')
      setSearchResults([])
    } finally {
      setIsSearching(false)
    }
  }

  async function handleCreateBaseIngredient() {
    try {
      setIsSavingBase(true)
      setSubmitError(null)
      const created = await api.createBaseIngredient({
        name: newBaseName.trim(),
        category: newBaseCategory.trim(),
        default_unit: newBaseUnit.trim(),
        notes: newBaseNotes.trim(),
      })
      setSelectedBaseIngredient(created)
      setSearchText(created.name)
      setSearchResults([created])
      setCreateBaseOpen(false)
    } catch (error) {
      setSubmitError(error instanceof Error ? error.message : 'Failed to create base ingredient')
    } finally {
      setIsSavingBase(false)
    }
  }

  async function handleCreateVariation() {
    if (!selectedBaseIngredient) return
    try {
      setIsSavingVariation(true)
      setSubmitError(null)
      const created = await api.createIngredientVariation(selectedBaseIngredient.base_ingredient_id, {
        name: newVariationName.trim(),
        brand: newVariationBrand.trim(),
        package_size_amount: newVariationPackageAmount.trim() ? Number(newVariationPackageAmount) : null,
        package_size_unit: newVariationPackageUnit.trim(),
        notes: newVariationNotes.trim(),
      })
      const nextVariations = await api.getIngredientVariations(selectedBaseIngredient.base_ingredient_id)
      setVariations(nextVariations)
      setSelectedVariationId(created.ingredient_variation_id)
      setLockToVariation(true)
      setCreateVariationOpen(false)
    } catch (error) {
      setSubmitError(error instanceof Error ? error.message : 'Failed to create product variation')
    } finally {
      setIsSavingVariation(false)
    }
  }

  function applySelection() {
    if (!selectedBaseIngredient) {
      onApply({
        baseIngredientId: null,
        baseIngredientName: null,
        ingredientVariationId: null,
        ingredientVariationName: null,
        resolutionStatus: 'unresolved',
      })
      return
    }

    const resolutionStatus = selectedVariation && lockToVariation
      ? 'locked'
      : selectedVariation
        ? 'resolved'
        : 'resolved'

    onApply({
      baseIngredientId: selectedBaseIngredient.base_ingredient_id,
      baseIngredientName: selectedBaseIngredient.name,
      ingredientVariationId: selectedVariation?.ingredient_variation_id ?? null,
      ingredientVariationName: selectedVariation?.name ?? null,
      resolutionStatus,
    })
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="w-[min(92vw,760px)]">
        <DialogHeader>
          <DialogTitle>Review ingredient match</DialogTitle>
          <DialogDescription>
            Link the recipe text to a canonical ingredient so shopping, brand preference, and nutrition can resolve cleanly.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-5 overflow-y-auto px-6 py-1">
          <div className="rounded-xl border border-stone-200 bg-stone-50 p-4 dark:border-stone-800 dark:bg-stone-900/60">
            <p className="text-xs font-medium uppercase tracking-[0.2em] text-stone-500">Recipe text</p>
            <p className="mt-2 text-sm font-medium text-stone-900 dark:text-stone-100">{ingredient?.ingredient_name || 'Unnamed ingredient'}</p>
            <div className="mt-2 flex flex-wrap gap-2 text-xs text-stone-500 dark:text-stone-400">
              {ingredient?.quantity ? <span>Qty {ingredient.quantity}</span> : null}
              {ingredient?.unit ? <span>Unit {ingredient.unit}</span> : null}
              {ingredient?.category ? <span>Category {ingredient.category}</span> : null}
              {ingredient?.prep ? <span>Prep {ingredient.prep}</span> : null}
            </div>
          </div>

          <section className="space-y-3">
            <div className="flex items-end gap-3">
              <div className="flex-1">
                <Label htmlFor="ingredient-review-search">Find canonical ingredient</Label>
                <Input
                  id="ingredient-review-search"
                  className="mt-1.5"
                  value={searchText}
                  onChange={(event) => setSearchText(event.target.value)}
                  placeholder="Search for whole milk, refrigerated biscuits, yellow mustard…"
                />
              </div>
              <Button type="button" variant="outline" onClick={() => void runSearch()} disabled={isSearching}>
                {isSearching ? 'Searching…' : 'Search'}
              </Button>
            </div>

            {searchError ? <p className="text-sm text-red-600">{searchError}</p> : null}

            {searchResults.length > 0 ? (
              <div className="grid gap-2">
                {searchResults.map((result) => {
                  const isSelected = selectedBaseIngredient?.base_ingredient_id === result.base_ingredient_id
                  return (
                    <button
                      key={result.base_ingredient_id}
                      type="button"
                      className={`rounded-xl border px-3 py-3 text-left transition ${
                        isSelected
                          ? 'border-olive-500 bg-olive-50 dark:border-olive-400 dark:bg-olive-950/30'
                          : 'border-stone-200 hover:border-stone-300 dark:border-stone-800 dark:hover:border-stone-700'
                      }`}
                      onClick={() => {
                        setSelectedBaseIngredient(result)
                        setSelectedVariationId('__none__')
                        setLockToVariation(false)
                        setSubmitError(null)
                      }}
                    >
                      <div className="flex items-center justify-between gap-3">
                        <p className="font-medium text-stone-900 dark:text-stone-100">{result.name}</p>
                        {result.category ? <Badge variant="outline">{result.category}</Badge> : null}
                      </div>
                      <p className="mt-1 text-xs text-stone-500 dark:text-stone-400">
                        Default unit: {result.default_unit || 'none'}{result.notes ? ` • ${result.notes}` : ''}
                      </p>
                    </button>
                  )
                })}
              </div>
            ) : null}

            {!searchResults.length && searchText.trim() ? (
              <Button type="button" variant="outline" onClick={() => setCreateBaseOpen((current) => !current)}>
                {createBaseOpen ? 'Hide base ingredient form' : 'Create base ingredient'}
              </Button>
            ) : null}

            {createBaseOpen ? (
              <div className="rounded-xl border border-dashed border-stone-300 p-4 dark:border-stone-700">
                <div className="grid gap-3 md:grid-cols-2">
                  <div>
                    <Label htmlFor="new-base-name">Name</Label>
                    <Input id="new-base-name" className="mt-1.5" value={newBaseName} onChange={(event) => setNewBaseName(event.target.value)} />
                  </div>
                  <div>
                    <Label htmlFor="new-base-category">Category</Label>
                    <Input id="new-base-category" className="mt-1.5" value={newBaseCategory} onChange={(event) => setNewBaseCategory(event.target.value)} />
                  </div>
                  <div>
                    <Label htmlFor="new-base-unit">Default unit</Label>
                    <Input id="new-base-unit" className="mt-1.5" value={newBaseUnit} onChange={(event) => setNewBaseUnit(event.target.value)} />
                  </div>
                  <div>
                    <Label htmlFor="new-base-notes">Notes</Label>
                    <Input id="new-base-notes" className="mt-1.5" value={newBaseNotes} onChange={(event) => setNewBaseNotes(event.target.value)} />
                  </div>
                </div>
                <div className="mt-3 flex justify-end">
                  <Button type="button" onClick={() => void handleCreateBaseIngredient()} disabled={isSavingBase || !newBaseName.trim()}>
                    {isSavingBase ? 'Creating…' : 'Create base ingredient'}
                  </Button>
                </div>
              </div>
            ) : null}
          </section>

          {selectedBaseIngredient ? (
            <section className="space-y-3 rounded-xl border border-stone-200 p-4 dark:border-stone-800">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="text-sm font-semibold text-stone-900 dark:text-stone-100">Product variation</p>
                  <p className="text-xs text-stone-500 dark:text-stone-400">
                    Optional. Pick a specific product or keep the recipe generic at the base-ingredient level.
                  </p>
                </div>
                <Button type="button" variant="outline" onClick={() => setCreateVariationOpen((current) => !current)}>
                  {createVariationOpen ? 'Hide variation form' : 'Create product variation'}
                </Button>
              </div>

              <Select value={selectedVariationId} onValueChange={setSelectedVariationId}>
                <SelectTrigger>
                  <SelectValue placeholder={isLoadingVariations ? 'Loading variations…' : 'Select a product variation'} />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none__">Keep generic</SelectItem>
                  {variations.map((variation) => (
                    <SelectItem key={variation.ingredient_variation_id} value={variation.ingredient_variation_id}>
                      {variation.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>

              {selectedVariation ? (
                <div className="rounded-lg bg-stone-50 px-3 py-2 text-xs text-stone-600 dark:bg-stone-900/60 dark:text-stone-300">
                  {selectedVariation.brand ? `${selectedVariation.brand} • ` : ''}
                  {selectedVariation.package_size_amount ? `${selectedVariation.package_size_amount} ` : ''}
                  {selectedVariation.package_size_unit || ''}
                  {selectedVariation.notes ? ` • ${selectedVariation.notes}` : ''}
                </div>
              ) : null}

              <label className="inline-flex items-center gap-2 text-sm text-stone-700 dark:text-stone-300">
                <Checkbox
                  checked={lockToVariation}
                  disabled={!selectedVariation}
                  onCheckedChange={(checked) => setLockToVariation(checked === true)}
                />
                Lock this recipe to the selected product
              </label>

              {createVariationOpen ? (
                <div className="rounded-xl border border-dashed border-stone-300 p-4 dark:border-stone-700">
                  <div className="grid gap-3 md:grid-cols-2">
                    <div>
                      <Label htmlFor="new-variation-name">Variation name</Label>
                      <Input id="new-variation-name" className="mt-1.5" value={newVariationName} onChange={(event) => setNewVariationName(event.target.value)} />
                    </div>
                    <div>
                      <Label htmlFor="new-variation-brand">Brand</Label>
                      <Input id="new-variation-brand" className="mt-1.5" value={newVariationBrand} onChange={(event) => setNewVariationBrand(event.target.value)} />
                    </div>
                    <div>
                      <Label htmlFor="new-variation-amount">Package amount</Label>
                      <Input id="new-variation-amount" className="mt-1.5" value={newVariationPackageAmount} onChange={(event) => setNewVariationPackageAmount(event.target.value)} />
                    </div>
                    <div>
                      <Label htmlFor="new-variation-unit">Package unit</Label>
                      <Input id="new-variation-unit" className="mt-1.5" value={newVariationPackageUnit} onChange={(event) => setNewVariationPackageUnit(event.target.value)} />
                    </div>
                    <div className="md:col-span-2">
                      <Label htmlFor="new-variation-notes">Notes</Label>
                      <Input id="new-variation-notes" className="mt-1.5" value={newVariationNotes} onChange={(event) => setNewVariationNotes(event.target.value)} />
                    </div>
                  </div>
                  <div className="mt-3 flex justify-end">
                    <Button type="button" onClick={() => void handleCreateVariation()} disabled={isSavingVariation || !newVariationName.trim()}>
                      {isSavingVariation ? 'Creating…' : 'Create variation'}
                    </Button>
                  </div>
                </div>
              ) : null}
            </section>
          ) : null}

          {submitError ? <p className="text-sm text-red-600">{submitError}</p> : null}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button type="button" onClick={applySelection}>
            Apply review
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
