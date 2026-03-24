import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { api } from '@/lib/api'
import type { RecipePayload } from '@/lib/types'

function useInvalidateRecipes() {
  const queryClient = useQueryClient()
  return async () => {
    await queryClient.invalidateQueries({ queryKey: ['recipes'] })
  }
}

export function useSaveRecipe() {
  const invalidate = useInvalidateRecipes()
  return useMutation({
    mutationFn: (payload: RecipePayload) => api.saveRecipe(payload),
    onSuccess: async () => {
      toast.success('Recipe saved')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to save recipe', { description: error.message })
    },
  })
}

export function useArchiveRecipe() {
  const invalidate = useInvalidateRecipes()
  return useMutation({
    mutationFn: (recipeId: string) => api.archiveRecipe(recipeId),
    onSuccess: async () => {
      toast.success('Recipe archived')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to archive recipe', { description: error.message })
    },
  })
}

export function useRestoreRecipe() {
  const invalidate = useInvalidateRecipes()
  return useMutation({
    mutationFn: (recipeId: string) => api.restoreRecipe(recipeId),
    onSuccess: async () => {
      toast.success('Recipe restored')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to restore recipe', { description: error.message })
    },
  })
}

export function useDeleteRecipe() {
  const invalidate = useInvalidateRecipes()
  return useMutation({
    mutationFn: (recipeId: string) => api.deleteRecipe(recipeId),
    onSuccess: async () => {
      toast.success('Recipe deleted')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to delete recipe', { description: error.message })
    },
  })
}
