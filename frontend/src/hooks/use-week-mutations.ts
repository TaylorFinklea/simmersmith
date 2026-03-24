import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { api } from '@/lib/api'
import type { FeedbackEntryPayload, MealUpdatePayload } from '@/lib/types'

function useInvalidateWeek() {
  const queryClient = useQueryClient()
  return async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ['current-week'] }),
      queryClient.invalidateQueries({ queryKey: ['weeks'] }),
      queryClient.invalidateQueries({ queryKey: ['pricing'] }),
      queryClient.invalidateQueries({ queryKey: ['week-changes'] }),
      queryClient.invalidateQueries({ queryKey: ['week-feedback'] }),
      queryClient.invalidateQueries({ queryKey: ['week-exports'] }),
      queryClient.invalidateQueries({ queryKey: ['preferences'] }),
    ])
  }
}

export function useSaveMeals() {
  const invalidate = useInvalidateWeek()
  return useMutation({
    mutationFn: ({ weekId, payload }: { weekId: string; payload: MealUpdatePayload[] }) =>
      api.updateWeekMeals(weekId, payload),
    onSuccess: async () => {
      toast.success('Changes saved')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to save changes', { description: error.message })
    },
  })
}

export function useCreateWeek() {
  const invalidate = useInvalidateWeek()
  return useMutation({
    mutationFn: api.createWeek,
    onSuccess: async () => {
      toast.success('Week created')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to create week', { description: error.message })
    },
  })
}

export function useReadyForAI() {
  const invalidate = useInvalidateWeek()
  return useMutation({
    mutationFn: (weekId: string) => api.readyWeekForAI(weekId),
    onSuccess: async () => {
      toast.success('Marked ready for AI')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to mark ready', { description: error.message })
    },
  })
}

export function useApproveWeek() {
  const invalidate = useInvalidateWeek()
  return useMutation({
    mutationFn: (weekId: string) => api.approveWeek(weekId),
    onSuccess: async () => {
      toast.success('Week approved')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to approve', { description: error.message })
    },
  })
}

export function useExportWeek() {
  const invalidate = useInvalidateWeek()
  return useMutation({
    mutationFn: ({ weekId, exportType }: { weekId: string; exportType: 'meal_plan' | 'shopping_split' }) =>
      api.createWeekExport(weekId, exportType),
    onSuccess: async (_data, variables) => {
      toast.success(`Export queued: ${variables.exportType.replace('_', ' ')}`)
      await invalidate()
    },
    onError: (error) => {
      toast.error('Export failed', { description: error.message })
    },
  })
}

export function useWeekFeedback() {
  const invalidate = useInvalidateWeek()
  return useMutation({
    mutationFn: ({ weekId, payload }: { weekId: string; payload: FeedbackEntryPayload[] }) =>
      api.saveWeekFeedback(weekId, payload),
    onSuccess: async () => {
      toast.success('Feedback saved')
      await invalidate()
    },
    onError: (error) => {
      toast.error('Failed to save feedback', { description: error.message })
    },
  })
}

export function useRegenerateGrocery() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: api.regenerateGrocery,
    onSuccess: async () => {
      toast.success('Grocery list regenerated')
      await queryClient.invalidateQueries({ queryKey: ['current-week'] })
    },
    onError: (error) => {
      toast.error('Failed to regenerate', { description: error.message })
    },
  })
}
