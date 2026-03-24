import { zodResolver } from '@hookform/resolvers/zod'
import { ChevronDown } from 'lucide-react'
import { useState } from 'react'
import { Controller, useForm } from 'react-hook-form'
import { z } from 'zod'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import type { FeedbackEntryPayload } from '@/lib/types'
import { cn } from '@/lib/utils'

const sentimentOptions = [
  { value: '2', label: 'Loved it' },
  { value: '1', label: 'Worked well' },
  { value: '0', label: 'Neutral' },
  { value: '-1', label: 'Needs work' },
  { value: '-2', label: 'Do not repeat' },
]

const feedbackSchema = z.object({
  targetType: z.string(),
  targetName: z.string().min(1),
  retailer: z.string(),
  sentiment: z.string(),
  reasons: z.string(),
  notes: z.string(),
})

type FeedbackFormValues = z.infer<typeof feedbackSchema>

interface FeedbackEntryFormProps {
  title: string
  defaultTargetType: FeedbackEntryPayload['target_type']
  defaultTargetName: string
  defaultRetailer?: string
  mealId?: string | null
  groceryItemId?: string | null
  allowedTargetTypes: FeedbackEntryPayload['target_type'][]
  onSave: (payload: FeedbackEntryPayload) => Promise<void>
  saveLabel?: string
}

export function FeedbackEntryForm({
  title,
  defaultTargetType,
  defaultTargetName,
  defaultRetailer = '',
  mealId = null,
  groceryItemId = null,
  allowedTargetTypes,
  onSave,
  saveLabel = 'Save feedback',
}: FeedbackEntryFormProps) {
  const [open, setOpen] = useState(false)
  const [isSaving, setIsSaving] = useState(false)

  const form = useForm<FeedbackFormValues>({
    resolver: zodResolver(feedbackSchema),
    defaultValues: {
      targetType: defaultTargetType,
      targetName: defaultTargetName,
      retailer: defaultRetailer,
      sentiment: '1',
      reasons: '',
      notes: '',
    },
  })

  async function handleSave(values: FeedbackFormValues) {
    setIsSaving(true)
    try {
      await onSave({
        meal_id: mealId,
        grocery_item_id: groceryItemId,
        target_type: values.targetType as FeedbackEntryPayload['target_type'],
        target_name: values.targetName,
        retailer: values.retailer,
        sentiment: Number(values.sentiment),
        reason_codes: values.reasons.split(',').map(v => v.trim()).filter(Boolean),
        notes: values.notes,
      })
      form.reset({ ...form.getValues(), reasons: '', notes: '', sentiment: '1' })
      setOpen(false)
    } finally {
      setIsSaving(false)
    }
  }

  return (
    <div className="rounded-lg border border-stone-200 dark:border-stone-700">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="flex w-full items-center justify-between px-4 py-3 text-left text-sm font-medium text-stone-700 hover:bg-stone-50 dark:text-stone-300 dark:hover:bg-stone-800/50"
      >
        {title}
        <ChevronDown className={cn('size-4 text-stone-400 transition-transform', open && 'rotate-180')} />
      </button>
      {open ? (
        <form onSubmit={form.handleSubmit(handleSave)} className="space-y-3 border-t border-stone-200 dark:border-stone-700 p-4">
          <div className="grid gap-3 md:grid-cols-2">
            <div>
              <Label>Target type</Label>
              <Controller
                control={form.control}
                name="targetType"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger className="mt-1.5"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {allowedTargetTypes.map((value) => (
                        <SelectItem key={value} value={value}>{value.replace(/_/g, ' ')}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
            </div>
            <div>
              <Label>Sentiment</Label>
              <Controller
                control={form.control}
                name="sentiment"
                render={({ field }) => (
                  <Select value={field.value} onValueChange={field.onChange}>
                    <SelectTrigger className="mt-1.5"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {sentimentOptions.map((opt) => (
                        <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              />
            </div>
          </div>
          <div className="grid gap-3 md:grid-cols-2">
            <div>
              <Label>Target name</Label>
              <Input className="mt-1.5" {...form.register('targetName')} />
            </div>
            <div>
              <Label>Retailer</Label>
              <Input className="mt-1.5" {...form.register('retailer')} placeholder="Optional" />
            </div>
          </div>
          <div>
            <Label>Reason codes</Label>
            <Input className="mt-1.5" {...form.register('reasons')} placeholder="Comma-separated, e.g. kid_favorite, too_fussy" />
          </div>
          <div>
            <Label>Notes</Label>
            <Textarea className="mt-1.5" {...form.register('notes')} placeholder="Why did this work or fail?" />
          </div>
          <Button type="submit" disabled={isSaving || !form.watch('targetName').trim()}>
            {isSaving ? 'Saving...' : saveLabel}
          </Button>
        </form>
      ) : null}
    </div>
  )
}
