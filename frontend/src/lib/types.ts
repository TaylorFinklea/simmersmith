export interface StaplePayload {
  staple_name: string
  normalized_name: string
  notes: string
  is_active: boolean
}

export interface ProfileResponse {
  settings: Record<string, string>
  staples: StaplePayload[]
}

export interface ProfileUpdateRequest {
  settings: Record<string, string>
  staples?: StaplePayload[]
}

export interface PreferenceSignal {
  preference_id: string
  signal_type: string
  name: string
  normalized_name?: string | null
  score: number
  weight: number
  rationale: string
  source: string
  active: boolean
}

export interface PreferenceSummary {
  hard_avoids: string[]
  strong_likes: string[]
  brands: string[]
  rules: string[]
}

export interface PreferenceContextResponse {
  signals: PreferenceSignal[]
  summary: PreferenceSummary
}

export interface RecipeIngredientPayload {
  ingredient_id?: string | null
  ingredient_name: string
  normalized_name?: string | null
  quantity?: number | null
  unit: string
  prep: string
  category: string
  notes: string
}

export interface RecipeOut {
  recipe_id: string
  name: string
  meal_type: string
  cuisine: string
  servings?: number | null
  prep_minutes?: number | null
  cook_minutes?: number | null
  tags: string
  instructions_summary: string
  favorite: boolean
  archived: boolean
  source: string
  source_label: string
  source_url: string
  notes: string
  last_used?: string | null
  archived_at?: string | null
  ingredients: RecipeIngredientPayload[]
}

export interface RecipePayload {
  recipe_id?: string | null
  name: string
  meal_type: string
  cuisine: string
  servings?: number | null
  prep_minutes?: number | null
  cook_minutes?: number | null
  tags: string
  instructions_summary: string
  favorite: boolean
  source?: string
  source_label?: string
  source_url?: string
  notes: string
  ingredients: RecipeIngredientPayload[]
}

export interface RecipeImportRequest {
  url: string
}

export interface RetailerPriceOut {
  retailer: string
  status: 'matched' | 'review' | 'unavailable' | string
  store_name: string
  product_name: string
  package_size: string
  unit_price?: number | null
  line_price?: number | null
  product_url: string
  availability: string
  candidate_score?: number | null
  review_note: string
  raw_query: string
  scraped_at?: string | null
}

export interface GroceryItemOut {
  grocery_item_id: string
  ingredient_name: string
  normalized_name: string
  total_quantity?: number | null
  unit: string
  quantity_text: string
  category: string
  source_meals: string
  notes: string
  review_flag: string
  retailer_prices: RetailerPriceOut[]
}

export interface WeekMealOut {
  meal_id: string
  day_name: string
  meal_date: string
  slot: string
  recipe_id?: string | null
  recipe_name: string
  servings?: number | null
  source: string
  approved: boolean
  notes: string
  ai_generated: boolean
  ingredients: RecipeIngredientPayload[]
}

export interface WeekOut {
  week_id: string
  week_start: string
  week_end: string
  status: string
  notes: string
  ready_for_ai_at?: string | null
  approved_at?: string | null
  priced_at?: string | null
  staged_change_count: number
  feedback_count: number
  export_count: number
  meals: WeekMealOut[]
  grocery_items: GroceryItemOut[]
}

export interface WeekSummaryOut {
  week_id: string
  week_start: string
  week_end: string
  status: string
  notes: string
  ready_for_ai_at?: string | null
  approved_at?: string | null
  priced_at?: string | null
  meal_count: number
  grocery_item_count: number
  staged_change_count: number
  feedback_count: number
  export_count: number
}

export interface PricingResponse {
  week_id: string
  week_start: string
  totals: Record<string, number>
  items: GroceryItemOut[]
}

export interface MealUpdatePayload {
  meal_id?: string | null
  day_name: string
  meal_date: string
  slot: string
  recipe_id?: string | null
  recipe_name: string
  servings?: number | null
  notes: string
  approved: boolean
}

export interface WeekCreateRequest {
  week_start: string
  notes: string
}

export interface WeekChangeEventOut {
  change_event_id: string
  entity_type: string
  entity_id: string
  field_name: string
  before_value: string
  after_value: string
  created_at: string
}

export interface WeekChangeBatchOut {
  change_batch_id: string
  actor_type: string
  actor_label: string
  summary: string
  created_at: string
  events: WeekChangeEventOut[]
}

export interface FeedbackEntry {
  feedback_id: string
  meal_id?: string | null
  grocery_item_id?: string | null
  target_type: 'meal' | 'ingredient' | 'brand' | 'shopping_item' | 'store' | 'week'
  target_name: string
  normalized_name?: string | null
  retailer: string
  sentiment: number
  reason_codes: string[]
  notes: string
  source: string
  active: boolean
  created_at: string
  updated_at: string
}

export interface FeedbackEntryPayload {
  feedback_id?: string | null
  meal_id?: string | null
  grocery_item_id?: string | null
  target_type: 'meal' | 'ingredient' | 'brand' | 'shopping_item' | 'store' | 'week'
  target_name: string
  normalized_name?: string | null
  retailer?: string
  sentiment: number
  reason_codes: string[]
  notes: string
  source?: string
  active?: boolean
}

export interface WeekFeedbackSummary {
  total_entries: number
  meal_entries: number
  ingredient_entries: number
  brand_entries: number
  shopping_entries: number
  store_entries: number
  week_entries: number
}

export interface WeekFeedbackResponse {
  week_id: string
  summary: WeekFeedbackSummary
  entries: FeedbackEntry[]
}

export interface ExportItemOut {
  export_item_id: string
  sort_order: number
  list_name: string
  title: string
  notes: string
  metadata_json: string
  status: string
}

export interface ExportRunOut {
  export_id: string
  destination: string
  export_type: 'meal_plan' | 'shopping_split' | string
  status: 'pending' | 'completed' | 'failed' | string
  item_count: number
  payload_json: string
  error: string
  external_ref: string
  created_at: string
  completed_at?: string | null
  items: ExportItemOut[]
}
