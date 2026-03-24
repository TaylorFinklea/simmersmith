import type { UseFormRegister } from 'react-hook-form'

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'

interface SettingsSectionProps {
  title: string
  description: string
  fields: [string, string][]
  register: UseFormRegister<any> // eslint-disable-line @typescript-eslint/no-explicit-any
}

export function SettingsSection({ title, description, fields, register }: SettingsSectionProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>{description}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2">
        {fields.map(([key, label]) => {
          const isLongText = key.includes('strategy') || key.includes('principles') || key.includes('rules') || key.includes('preferences') || key.includes('notes') || key.includes('avoids')
          return (
            <div key={key} className={isLongText ? 'sm:col-span-2' : undefined}>
              <Label htmlFor={key}>{label}</Label>
              {isLongText ? (
                <Textarea id={key} className="mt-1.5" {...register(`settings.${key}`)} />
              ) : (
                <Input id={key} className="mt-1.5" {...register(`settings.${key}`)} />
              )}
            </div>
          )
        })}
      </CardContent>
    </Card>
  )
}
