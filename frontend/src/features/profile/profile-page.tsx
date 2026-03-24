import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useFieldArray, useForm } from 'react-hook-form'
import { toast } from 'sonner'
import { z } from 'zod'

import { PageHeader } from '@/components/shared/page-header'
import { PageSkeleton } from '@/components/shared/skeleton'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { api } from '@/lib/api'
import type { ProfileResponse } from '@/lib/types'

import { ActiveSignals } from './components/active-signals'
import { PreferenceMemory } from './components/preference-memory'
import { SettingsSection } from './components/settings-section'
import { StaplesList } from './components/staples-list'

const stapleSchema = z.object({
  staple_name: z.string(),
  normalized_name: z.string(),
  notes: z.string(),
  is_active: z.boolean(),
})

const profileFormSchema = z.object({
  settings: z.record(z.string(), z.string()),
  staples: z.array(stapleSchema),
})

type ProfileFormValues = z.infer<typeof profileFormSchema>

const settingSections = [
  {
    title: 'Household',
    description: 'Core planning context.',
    fields: [
      ['household_name', 'Household name'],
      ['household_adults', 'Adults'],
      ['household_kids', 'Kids'],
      ['monthly_grocery_budget_usd', 'Monthly budget'],
      ['currency', 'Currency'],
      ['timezone', 'Timezone'],
    ] as [string, string][],
  },
  {
    title: 'Planning rules',
    description: 'Rules that shape what gets drafted.',
    fields: [
      ['dietary_constraints', 'Dietary constraints'],
      ['cuisine_preferences', 'Cuisine preferences'],
      ['food_principles', 'Food principles'],
      ['convenience_rules', 'Convenience rules'],
      ['breakfast_strategy', 'Breakfast strategy'],
      ['lunch_strategy', 'Lunch strategy'],
      ['snack_strategy', 'Snack strategy'],
      ['leftovers_policy', 'Leftovers policy'],
      ['portable_lunch_days', 'Portable lunch days'],
      ['brand_preferences', 'Brand preferences'],
      ['planning_avoids', 'Planning avoids'],
      ['saturday_dinner_plan', 'Saturday dinner plan'],
      ['budget_notes', 'Budget notes'],
    ] as [string, string][],
  },
  {
    title: 'Store defaults',
    description: 'Retailer context for pricing and reminders.',
    fields: [
      ['aldi_store_name', 'Aldi store'],
      ['aldi_store_zip', 'Aldi ZIP'],
      ['aldi_store_id', 'Aldi store ID'],
      ['walmart_store_name', 'Walmart store'],
      ['walmart_store_zip', 'Walmart ZIP'],
      ['walmart_store_id', 'Walmart store ID'],
    ] as [string, string][],
  },
]

function toFormValues(data: ProfileResponse): ProfileFormValues {
  return {
    settings: { ...data.settings },
    staples: data.staples.map((s) => ({ ...s })),
  }
}

export function ProfilePage() {
  const queryClient = useQueryClient()
  const { data: profile, isLoading: profileLoading } = useQuery({ queryKey: ['profile'], queryFn: api.getProfile })
  const { data: preferences, isLoading: prefsLoading } = useQuery({ queryKey: ['preferences'], queryFn: api.getPreferences })

  const form = useForm<ProfileFormValues>({
    resolver: zodResolver(profileFormSchema),
    defaultValues: { settings: {}, staples: [] },
  })

  const { fields, append, remove } = useFieldArray({ control: form.control, name: 'staples' })

  useEffect(() => {
    if (profile) form.reset(toFormValues(profile))
  }, [form, profile])

  const saveMutation = useMutation({
    mutationFn: api.updateProfile,
    onSuccess: async () => {
      toast.success('Profile saved')
      await queryClient.invalidateQueries({ queryKey: ['profile'] })
    },
    onError: (err) => {
      toast.error('Failed to save profile', { description: err.message })
    },
  })

  if (profileLoading || prefsLoading) return <PageSkeleton />
  if (!profile || !preferences) return <PageSkeleton />

  const onSubmit = form.handleSubmit(async (values) => {
    await saveMutation.mutateAsync(values)
  })

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Profile"
        title="Household & preferences"
        description="Settings and staples are editable here. Preference signals are read-only — managed through chat."
        badge={`${preferences.signals.filter((s) => s.active).length} signals`}
        actions={
          <Button onClick={onSubmit} disabled={saveMutation.isPending}>
            {saveMutation.isPending ? 'Saving…' : 'Save profile'}
          </Button>
        }
      />

      <Tabs defaultValue="settings" className="space-y-4">
        <TabsList>
          <TabsTrigger value="settings">Settings</TabsTrigger>
          <TabsTrigger value="staples">Staples</TabsTrigger>
          <TabsTrigger value="preferences">Preferences</TabsTrigger>
        </TabsList>

        <TabsContent value="settings">
          <form className="space-y-4" onSubmit={onSubmit}>
            {settingSections.map((section) => (
              // eslint-disable-next-line @typescript-eslint/no-explicit-any -- RHF generics don't compose across component boundaries
              <SettingsSection key={section.title} title={section.title} description={section.description} fields={section.fields} register={form.register as any} />
            ))}
          </form>
        </TabsContent>

        <TabsContent value="staples">
          {/* eslint-disable-next-line @typescript-eslint/no-explicit-any -- RHF generics don't compose across component boundaries */}
          <StaplesList fields={fields} register={form.register as any} control={form.control as any} append={append as any} remove={remove} setValue={form.setValue as any} />
        </TabsContent>

        <TabsContent value="preferences" className="space-y-4">
          <PreferenceMemory summary={preferences.summary} />
          <ActiveSignals signals={preferences.signals} />
        </TabsContent>
      </Tabs>
    </div>
  )
}
