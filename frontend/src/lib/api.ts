import type {
  ExportRunOut,
  FeedbackEntryPayload,
  MealUpdatePayload,
  PreferenceContextResponse,
  PricingResponse,
  RecipeImportRequest,
  RecipePayload,
  ProfileResponse,
  ProfileUpdateRequest,
  RecipeOut,
  WeekCreateRequest,
  WeekChangeBatchOut,
  WeekFeedbackResponse,
  WeekOut,
  WeekSummaryOut,
} from '@/lib/types'

async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    headers: {
      'Content-Type': 'application/json',
      ...(init?.headers ?? {}),
    },
    ...init,
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(text || `Request failed with status ${response.status}`)
  }

  return (await response.json()) as T
}

export const api = {
  getProfile: () => fetchJson<ProfileResponse>('/api/profile'),
  updateProfile: (payload: ProfileUpdateRequest) =>
    fetchJson<ProfileResponse>('/api/profile', {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  getPreferences: () => fetchJson<PreferenceContextResponse>('/api/preferences'),
  getRecipes: (includeArchived = false) =>
    fetchJson<RecipeOut[]>(`/api/recipes${includeArchived ? '?include_archived=true' : ''}`),
  saveRecipe: (payload: RecipePayload) =>
    fetchJson<RecipeOut>('/api/recipes', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  importRecipeFromUrl: (payload: RecipeImportRequest) =>
    fetchJson<RecipePayload>('/api/recipes/import-from-url', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  archiveRecipe: (recipeId: string) =>
    fetchJson<RecipeOut>(`/api/recipes/${recipeId}/archive`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  restoreRecipe: (recipeId: string) =>
    fetchJson<RecipeOut>(`/api/recipes/${recipeId}/restore`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  deleteRecipe: async (recipeId: string) => {
    const response = await fetch(`/api/recipes/${recipeId}`, {
      method: 'DELETE',
    })
    if (!response.ok) {
      const text = await response.text()
      throw new Error(text || `Request failed with status ${response.status}`)
    }
  },
  getWeeks: (limit = 6) => fetchJson<WeekSummaryOut[]>(`/api/weeks?limit=${limit}`),
  getCurrentWeek: () => fetchJson<WeekOut | null>('/api/weeks/current'),
  createWeek: (payload: WeekCreateRequest) =>
    fetchJson<WeekOut>('/api/weeks', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  getWeekChanges: (weekId: string) => fetchJson<WeekChangeBatchOut[]>(`/api/weeks/${weekId}/changes`),
  readyWeekForAI: (weekId: string) =>
    fetchJson<WeekOut>(`/api/weeks/${weekId}/ready-for-ai`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  updateWeekMeals: (weekId: string, payload: MealUpdatePayload[]) =>
    fetchJson<WeekOut>(`/api/weeks/${weekId}/meals`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  getWeekFeedback: (weekId: string) => fetchJson<WeekFeedbackResponse>(`/api/weeks/${weekId}/feedback`),
  saveWeekFeedback: (weekId: string, payload: FeedbackEntryPayload[]) =>
    fetchJson<WeekFeedbackResponse>(`/api/weeks/${weekId}/feedback`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  approveWeek: (weekId: string) =>
    fetchJson<WeekOut>(`/api/weeks/${weekId}/approve`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  regenerateGrocery: (weekId: string) =>
    fetchJson<WeekOut>(`/api/weeks/${weekId}/grocery/regenerate`, {
      method: 'POST',
      body: JSON.stringify({}),
    }),
  getWeekExports: (weekId: string) => fetchJson<ExportRunOut[]>(`/api/weeks/${weekId}/exports`),
  createWeekExport: (weekId: string, exportType: 'meal_plan' | 'shopping_split') =>
    fetchJson<ExportRunOut>(`/api/weeks/${weekId}/exports`, {
      method: 'POST',
      body: JSON.stringify({ destination: 'apple_reminders', export_type: exportType }),
    }),
  getPricing: (weekId: string) => fetchJson<PricingResponse>(`/api/weeks/${weekId}/pricing`),
}
