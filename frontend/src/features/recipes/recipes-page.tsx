import { useMemo, useState } from 'react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { toast } from 'sonner'

import { EmptyState } from '@/components/shared/empty-state'
import { PageHeader } from '@/components/shared/page-header'
import { PageSkeleton } from '@/components/shared/skeleton'
import { Accordion } from '@/components/ui/accordion'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useArchiveRecipe, useDeleteRecipe, useRestoreRecipe, useSaveRecipe } from '@/hooks/use-recipe-mutations'
import { api } from '@/lib/api'
import type { RecipeOut, RecipePayload } from '@/lib/types'

import { RecipeCard } from './components/recipe-card'
import { RecipeEditorDialog } from './components/recipe-editor-dialog'
import { RecipeImportDialog } from './components/recipe-import-dialog'
import { RecipeSearch } from './components/recipe-search'

export function RecipesPage() {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<'active' | 'all' | 'archived'>('active')
  const [editorOpen, setEditorOpen] = useState(false)
  const [importDialogOpen, setImportDialogOpen] = useState(false)
  const [editingRecipe, setEditingRecipe] = useState<RecipeOut | RecipePayload | null>(null)
  const { data: recipes, isLoading } = useQuery({
    queryKey: ['recipes', 'library'],
    queryFn: () => api.getRecipes(true),
  })
  const saveRecipeMutation = useSaveRecipe()
  const archiveRecipeMutation = useArchiveRecipe()
  const restoreRecipeMutation = useRestoreRecipe()
  const deleteRecipeMutation = useDeleteRecipe()
  const importRecipeMutation = useMutation({
    mutationFn: (url: string) => api.importRecipeFromUrl({ url }),
    onError: (error) => {
      toast.error('Failed to import recipe', { description: error.message })
    },
  })

  const filteredRecipes = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    if (!recipes) return []
    const visibleRecipes = recipes.filter((recipe) => {
      if (filter === 'active') return !recipe.archived
      if (filter === 'archived') return recipe.archived
      return true
    })
    if (!normalizedQuery) return visibleRecipes
    return visibleRecipes.filter((recipe) =>
      [recipe.name, recipe.cuisine, recipe.meal_type, recipe.tags, recipe.instructions_summary, recipe.source_label, recipe.ingredients.map((i) => i.ingredient_name).join(' ')]
        .join(' ')
        .toLowerCase()
        .includes(normalizedQuery),
    )
  }, [filter, query, recipes])

  const activeCount = recipes?.filter((recipe) => !recipe.archived).length ?? 0
  const archivedCount = recipes?.filter((recipe) => recipe.archived).length ?? 0
  const actionsDisabled =
    saveRecipeMutation.isPending ||
    archiveRecipeMutation.isPending ||
    restoreRecipeMutation.isPending ||
    deleteRecipeMutation.isPending ||
    importRecipeMutation.isPending

  const sourceCounts = useMemo(() => {
    if (!recipes) return []
    const counts = new Map<string, number>()
    for (const recipe of recipes) {
      const label = recipe.source_label || recipe.source || 'manual'
      counts.set(label, (counts.get(label) ?? 0) + 1)
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
  }, [recipes])

  function openNewRecipe() {
    setEditingRecipe(null)
    setEditorOpen(true)
  }

  const isEditingExistingRecipe = Boolean(editingRecipe && 'recipe_id' in editingRecipe && editingRecipe.recipe_id)

  if (isLoading) return <PageSkeleton />

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Recipes"
        title="Recipe library"
        description="Build a reusable library from scratch, keep archived ideas out of the way, and save custom planner meals when they prove useful."
        badge={`${filteredRecipes.length} recipes`}
        actions={
          <>
            <Button type="button" variant="outline" onClick={() => setImportDialogOpen(true)}>
              Import from URL
            </Button>
            <Button type="button" onClick={openNewRecipe}>
              New recipe
            </Button>
          </>
        }
      />

      <RecipeSearch query={query} onQueryChange={setQuery} />
      <Tabs value={filter} onValueChange={(value) => setFilter(value as 'active' | 'all' | 'archived')}>
        <TabsList>
          <TabsTrigger value="active">Active {activeCount}</TabsTrigger>
          <TabsTrigger value="all">All {recipes?.length ?? 0}</TabsTrigger>
          <TabsTrigger value="archived">Archived {archivedCount}</TabsTrigger>
        </TabsList>
      </Tabs>
      {sourceCounts.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {sourceCounts.slice(0, 6).map(([label, count]) => (
            <Badge key={label} variant="outline">
              {label} {count}
            </Badge>
          ))}
        </div>
      ) : null}

      {filteredRecipes.length === 0 ? (
        <EmptyState
          title={query.trim() ? 'No matching recipes' : filter === 'archived' ? 'No archived recipes' : 'No recipes yet'}
          description={
            query.trim()
              ? 'Try a broader query, or start a new recipe from here.'
              : filter === 'archived'
                ? 'Archived recipes will land here when you want them out of the active rotation.'
                : 'Start with a name only. You can fill in ingredients and notes when the recipe becomes a keeper.'
          }
          action={
            filter !== 'archived' ? (
              <div className="flex flex-wrap justify-center gap-2">
                <Button type="button" variant="outline" onClick={() => setImportDialogOpen(true)}>
                  Import from URL
                </Button>
                <Button type="button" onClick={openNewRecipe}>
                  New recipe
                </Button>
              </div>
            ) : undefined
          }
        />
      ) : null}

      <Accordion type="multiple" className="space-y-3">
        {filteredRecipes.map((recipe) => (
          <RecipeCard
            key={recipe.recipe_id}
            recipe={recipe}
            actionsDisabled={actionsDisabled}
            onEdit={(currentRecipe) => {
              setEditingRecipe(currentRecipe)
              setEditorOpen(true)
            }}
            onToggleFavorite={async (currentRecipe) => {
              await saveRecipeMutation.mutateAsync({
                recipe_id: currentRecipe.recipe_id,
                name: currentRecipe.name,
                meal_type: currentRecipe.meal_type,
                cuisine: currentRecipe.cuisine,
                servings: currentRecipe.servings,
                prep_minutes: currentRecipe.prep_minutes,
                cook_minutes: currentRecipe.cook_minutes,
                tags: currentRecipe.tags,
                instructions_summary: currentRecipe.instructions_summary,
                favorite: !currentRecipe.favorite,
                source: currentRecipe.source,
                source_label: currentRecipe.source_label,
                source_url: currentRecipe.source_url,
                notes: currentRecipe.notes,
                ingredients: currentRecipe.ingredients,
              })
            }}
            onArchive={async (currentRecipe) => {
              if (!window.confirm(`Archive "${currentRecipe.name}"?`)) return
              await archiveRecipeMutation.mutateAsync(currentRecipe.recipe_id)
            }}
            onRestore={async (currentRecipe) => {
              await restoreRecipeMutation.mutateAsync(currentRecipe.recipe_id)
            }}
            onDelete={async (currentRecipe) => {
              if (!window.confirm(`Delete "${currentRecipe.name}" permanently?`)) return
              await deleteRecipeMutation.mutateAsync(currentRecipe.recipe_id)
            }}
          />
        ))}
      </Accordion>

      <RecipeEditorDialog
        open={editorOpen}
        onOpenChange={(open) => {
          setEditorOpen(open)
          if (!open) setEditingRecipe(null)
        }}
        initialRecipe={editingRecipe}
        title={isEditingExistingRecipe && editingRecipe ? `Edit ${editingRecipe.name}` : editingRecipe ? 'Review imported recipe' : 'New recipe'}
        description={
          isEditingExistingRecipe
            ? 'Update the reusable library entry. Planned meals keep their existing copies until you intentionally swap them.'
            : editingRecipe
              ? 'The import kept structured recipe data and dropped page chrome. Review it before adding it to your library.'
            : 'Start with the bare minimum now. Name is enough.'
        }
        submitLabel={isEditingExistingRecipe ? 'Save changes' : 'Create recipe'}
        onSave={(payload) => saveRecipeMutation.mutateAsync(payload)}
      />

      <RecipeImportDialog
        open={importDialogOpen}
        onOpenChange={setImportDialogOpen}
        importing={importRecipeMutation.isPending}
        onImport={async (url) => {
          const importedRecipe = await importRecipeMutation.mutateAsync(url)
          setImportDialogOpen(false)
          setEditingRecipe(importedRecipe)
          setEditorOpen(true)
          toast.success('Recipe imported', { description: 'Review the cleaned recipe and save it when ready.' })
        }}
      />
    </div>
  )
}
