import { Plus, Trash2 } from 'lucide-react'
import type { Control, UseFormRegister, UseFormSetValue } from 'react-hook-form'
import { useWatch } from 'react-hook-form'

import { EmptyState } from '@/components/shared/empty-state'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'

interface StaplesListProps {
  fields: Array<{ id: string }>
  register: UseFormRegister<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  control: Control<any> // eslint-disable-line @typescript-eslint/no-explicit-any
  append: (value: Record<string, unknown>) => void
  remove: (index: number) => void
  setValue: UseFormSetValue<any> // eslint-disable-line @typescript-eslint/no-explicit-any
}

export function StaplesList({ fields, register, control, append, remove, setValue }: StaplesListProps) {
  const watchedStaples = useWatch({ control, name: 'staples' })

  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between gap-4">
        <div>
          <CardTitle>Staples</CardTitle>
          <CardDescription>Excluded from grocery regeneration.</CardDescription>
        </div>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => append({ staple_name: '', normalized_name: '', notes: '', is_active: true })}
        >
          <Plus className="size-3.5" /> Add
        </Button>
      </CardHeader>
      <CardContent className="space-y-3">
        {fields.length === 0 ? (
          <EmptyState title="No staples" description="Add pantry constants so grocery regeneration stays clean." />
        ) : null}
        {fields.map((field, index) => (
          <div key={field.id} className="theme-surface-soft rounded-lg border border-stone-200 dark:border-stone-700 p-3">
            <div className="grid gap-3 sm:grid-cols-[1fr_1fr_auto]">
              <div>
                <Label htmlFor={`staple_name_${field.id}`}>Staple</Label>
                <Input id={`staple_name_${field.id}`} className="mt-1.5" {...register(`staples.${index}.staple_name`)} />
              </div>
              <div>
                <Label htmlFor={`normalized_name_${field.id}`}>Normalized</Label>
                <Input id={`normalized_name_${field.id}`} className="mt-1.5" {...register(`staples.${index}.normalized_name`)} />
              </div>
              <div className="flex items-end">
                <Button type="button" variant="ghost" size="sm" onClick={() => remove(index)}>
                  <Trash2 className="size-3.5" /> Remove
                </Button>
              </div>
            </div>
            <div className="mt-3 grid gap-3 sm:grid-cols-[1fr_auto]">
              <div>
                <Label htmlFor={`notes_${field.id}`}>Notes</Label>
                <Input id={`notes_${field.id}`} className="mt-1.5" {...register(`staples.${index}.notes`)} />
              </div>
              <label className="mt-7 inline-flex items-center gap-2 text-sm font-medium text-stone-600 dark:text-stone-400">
                <Checkbox
                  checked={watchedStaples?.[index]?.is_active ?? false}
                  onCheckedChange={(checked) => setValue(`staples.${index}.is_active`, checked === true)}
                />
                Active
              </label>
            </div>
          </div>
        ))}
      </CardContent>
    </Card>
  )
}
