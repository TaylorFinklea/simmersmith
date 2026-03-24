import type { Control, UseFormRegister, UseFormSetValue } from 'react-hook-form'

import { AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion'
import { Badge } from '@/components/ui/badge'
import { formatDate } from '@/lib/simmersmith'
import type { FeedbackEntry, FeedbackEntryPayload, RecipeOut } from '@/lib/types'

import { MealCard } from './meal-card'

interface DaySectionProps {
  dayName: string
  meals: Array<{ id: string; meal_date: string; slot: string; recipe_name: string; [key: string]: any }> // eslint-disable-line @typescript-eslint/no-explicit-any
  allFields: Array<{ id: string }>
  control: Control<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  register: UseFormRegister<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  setValue: UseFormSetValue<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  recipes: RecipeOut[]
  feedbackEntries: FeedbackEntry[]
  onSaveFeedback: (payload: FeedbackEntryPayload) => Promise<void>
}

export function DaySection({ dayName, meals, allFields, control, register, setValue, recipes, feedbackEntries, onSaveFeedback }: DaySectionProps) {
  const plannedCount = meals.filter((meal) => meal.recipe_name?.trim()).length

  return (
    <AccordionItem value={dayName}>
      <AccordionTrigger>
        <div className="flex flex-1 items-center justify-between gap-3 pr-3 text-left">
          <div>
            <p className="font-serif text-lg text-stone-900 dark:text-stone-100">{dayName}</p>
            <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{formatDate(meals[0].meal_date)}</p>
          </div>
          <Badge variant="muted">{plannedCount}/{meals.length} planned</Badge>
        </div>
      </AccordionTrigger>
      <AccordionContent className="space-y-3">
        {meals.map((mealField) => {
          const index = allFields.findIndex((field) => field.id === mealField.id)
          const existingFeedback = feedbackEntries.filter((entry) => entry.meal_id === mealField.id)
          return (
            <MealCard
              key={mealField.id}
              index={index}
              fieldId={mealField.id}
              control={control}
              register={register}
              setValue={setValue}
              recipes={recipes}
              existingFeedback={existingFeedback}
              onSaveFeedback={onSaveFeedback}
            />
          )
        })}
      </AccordionContent>
    </AccordionItem>
  )
}
