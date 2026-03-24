import { zodResolver } from '@hookform/resolvers/zod'
import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useFieldArray, useForm } from 'react-hook-form'
import { z } from 'zod'

import { PageHeader } from '@/components/shared/page-header'
import { PageSkeleton } from '@/components/shared/skeleton'
import { Accordion } from '@/components/ui/accordion'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { api } from '@/lib/api'
import { dayOrder, groupMealsByDay, slotOrder } from '@/lib/simmersmith'
import type { MealUpdatePayload, WeekOut } from '@/lib/types'
import { useApproveWeek, useCreateWeek, useExportWeek, useReadyForAI, useSaveMeals, useWeekFeedback } from '@/hooks/use-week-mutations'

import { ChangeHistory } from './components/change-history'
import { DaySection } from './components/day-section'
import { ExportQueue } from './components/export-queue'
import { FeedbackSummary } from './components/feedback-summary'
import { StagingStatus } from './components/staging-status'
import { WeekActionBar } from './components/week-action-bar'

const mealSchema = z.object({
  meal_id: z.string().nullable(),
  day_name: z.string(),
  meal_date: z.string(),
  slot: z.string(),
  recipe_id: z.string().nullable(),
  recipe_name: z.string(),
  servings: z.union([z.number(), z.nan()]).transform((v) => (Number.isNaN(v) ? null : v)).nullable(),
  notes: z.string(),
  approved: z.boolean(),
})

const formSchema = z.object({ meals: z.array(mealSchema) })
type WeekFormValues = z.infer<typeof formSchema>

const createWeekSchema = z.object({
  week_start: z.string().min(1),
  notes: z.string(),
})
type CreateWeekValues = z.infer<typeof createWeekSchema>

function startOfWeekMonday(today = new Date()) {
  const date = new Date(today)
  const day = date.getDay()
  const diff = day === 0 ? -6 : 1 - day
  date.setDate(date.getDate() + diff)
  return date
}

function toIsoDate(date: Date) {
  const year = date.getFullYear()
  const month = `${date.getMonth() + 1}`.padStart(2, '0')
  const day = `${date.getDate()}`.padStart(2, '0')
  return `${year}-${month}-${day}`
}

function buildPlannerMeals(week: WeekOut): WeekFormValues['meals'] {
  const mealsBySlot = new Map(
    week.meals.map((meal) => [`${meal.day_name}:${meal.slot}`, meal]),
  )

  return dayOrder.flatMap((dayName, index) => {
    const mealDate = new Date(week.week_start)
    mealDate.setDate(mealDate.getDate() + index)
    const mealDateValue = toIsoDate(mealDate)

    return slotOrder.map((slot) => {
      const existing = mealsBySlot.get(`${dayName}:${slot}`)
      return {
        meal_id: existing?.meal_id ?? null,
        day_name: dayName,
        meal_date: existing?.meal_date ?? mealDateValue,
        slot,
        recipe_id: existing?.recipe_id ?? null,
        recipe_name: existing?.recipe_name ?? '',
        servings: existing?.servings ?? null,
        notes: existing?.notes ?? '',
        approved: existing?.approved ?? slot === 'snack',
      }
    })
  })
}

function toFormValues(week: WeekOut): WeekFormValues {
  return { meals: buildPlannerMeals(week) }
}

export function WeekPage() {
  const { data: week, isLoading } = useQuery({ queryKey: ['current-week'], queryFn: api.getCurrentWeek })
  const { data: recipes = [] } = useQuery({ queryKey: ['recipes'], queryFn: () => api.getRecipes() })
  const { data: changeBatches = [] } = useQuery({
    queryKey: ['week-changes', week?.week_id ?? 'none'],
    queryFn: () => api.getWeekChanges(week!.week_id),
    enabled: Boolean(week?.week_id),
  })
  const { data: feedback } = useQuery({
    queryKey: ['week-feedback', week?.week_id ?? 'none'],
    queryFn: () => api.getWeekFeedback(week!.week_id),
    enabled: Boolean(week?.week_id),
  })
  const { data: exports = [] } = useQuery({
    queryKey: ['week-exports', week?.week_id ?? 'none'],
    queryFn: () => api.getWeekExports(week!.week_id),
    enabled: Boolean(week?.week_id),
  })

  const saveMutation = useSaveMeals()
  const createWeekMutation = useCreateWeek()
  const readyMutation = useReadyForAI()
  const approveMutation = useApproveWeek()
  const exportMutation = useExportWeek()
  const feedbackMutation = useWeekFeedback()

  const form = useForm<WeekFormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: { meals: [] },
  })
  const { fields } = useFieldArray({ control: form.control, name: 'meals' })
  const createWeekForm = useForm<CreateWeekValues>({
    resolver: zodResolver(createWeekSchema),
    defaultValues: {
      week_start: toIsoDate(startOfWeekMonday()),
      notes: '',
    },
  })

  useEffect(() => {
    if (week) form.reset(toFormValues(week))
  }, [form, week])

  if (isLoading) return <PageSkeleton />

  if (!week) {
    return (
      <div className="space-y-6">
        <PageHeader
          eyebrow="Week workspace"
          title="Create this week"
          description="Start the week manually, leave slots empty where you want flexibility, and use AI later to fill the gaps."
        />
        <Card className="max-w-2xl">
          <CardHeader>
            <CardTitle>New planning week</CardTitle>
            <CardDescription>Create an empty week in the UI. You can fill only the slots you want and save the rest for later.</CardDescription>
          </CardHeader>
          <CardContent>
            <form
              className="space-y-4"
              onSubmit={createWeekForm.handleSubmit(async (values) => {
                await createWeekMutation.mutateAsync(values)
              })}
            >
              <div className="grid gap-4 sm:grid-cols-[200px_1fr]">
                <div>
                  <Label htmlFor="week-start">Week start</Label>
                  <Input id="week-start" type="date" className="mt-1.5" {...createWeekForm.register('week_start')} />
                </div>
                <div>
                  <Label htmlFor="week-notes">Planning notes</Label>
                  <Textarea id="week-notes" className="mt-1.5 min-h-24" placeholder="Portable lunch days, pantry restock needs, scheduling notes, or budget constraints." {...createWeekForm.register('notes')} />
                </div>
              </div>
              <div className="flex flex-wrap gap-3">
                <Button type="submit" disabled={createWeekMutation.isPending}>
                  {createWeekMutation.isPending ? 'Creating…' : 'Create week'}
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => createWeekForm.reset({ week_start: toIsoDate(startOfWeekMonday()), notes: '' })}
                >
                  Reset
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      </div>
    )
  }

  const groupedFields = groupMealsByDay(fields)

  const handleSave = form.handleSubmit(async (values) => {
    const payload: MealUpdatePayload[] = values.meals
      .filter((meal) => meal.recipe_name.trim())
      .map((meal) => ({
        meal_id: meal.meal_id,
        day_name: meal.day_name,
        meal_date: meal.meal_date,
        slot: meal.slot,
        recipe_id: meal.recipe_id,
        recipe_name: meal.recipe_name.trim(),
        servings: meal.servings,
        notes: meal.notes,
        approved: meal.slot === 'snack' ? true : meal.approved,
      }))
    await saveMutation.mutateAsync({ weekId: week.week_id, payload })
  })

  return (
    <div className="space-y-6 pb-24">
      <PageHeader
        eyebrow="Week workspace"
        title="Plan the week"
        description="Author the week directly in the UI, leave open slots when needed, and save the current plan whenever you want."
        badge={`${week.status} week`}
      />

      <section className="grid gap-5 xl:grid-cols-[0.95fr_1.05fr]">
        <StagingStatus
          week={week}
          latestBatch={changeBatches[0]}
          onReady={() => readyMutation.mutate(week.week_id)}
          onApprove={() => approveMutation.mutate(week.week_id)}
          readyPending={readyMutation.isPending}
          approvePending={approveMutation.isPending}
        />
        <ChangeHistory batches={changeBatches} />
      </section>

      <Accordion type="multiple" defaultValue={dayOrder} className="space-y-3">
        {groupedFields.map((day) => (
          <DaySection
            key={day.dayName}
            dayName={day.dayName}
            meals={day.meals as any} // eslint-disable-line @typescript-eslint/no-explicit-any
            allFields={fields}
            control={form.control as any} // eslint-disable-line @typescript-eslint/no-explicit-any
            register={form.register as any} // eslint-disable-line @typescript-eslint/no-explicit-any
            setValue={form.setValue as any} // eslint-disable-line @typescript-eslint/no-explicit-any
            recipes={recipes}
            feedbackEntries={feedback?.entries ?? []}
            onSaveFeedback={async (payload) => {
              await feedbackMutation.mutateAsync({ weekId: week.week_id, payload: [payload] })
            }}
          />
        ))}
      </Accordion>

      <section className="grid gap-5 xl:grid-cols-[0.95fr_1.05fr]">
        <FeedbackSummary feedback={feedback} />
        <ExportQueue exports={exports} />
      </section>

      <WeekActionBar
        weekId={week.week_id}
        status={week.status}
        onSave={handleSave}
        onReady={() => readyMutation.mutate(week.week_id)}
        onApprove={() => approveMutation.mutate(week.week_id)}
        onExport={() => exportMutation.mutate({ weekId: week.week_id, exportType: 'meal_plan' })}
        savePending={saveMutation.isPending}
        readyPending={readyMutation.isPending}
        approvePending={approveMutation.isPending}
        exportPending={exportMutation.isPending}
      />
    </div>
  )
}
