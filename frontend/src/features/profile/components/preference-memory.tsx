import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import type { PreferenceSummary } from '@/lib/types'

interface PreferenceMemoryProps {
  summary: PreferenceSummary
}

export function PreferenceMemory({ summary }: PreferenceMemoryProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Preference memory</CardTitle>
        <CardDescription>The recommendation baseline chat uses when drafting meals.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="flex flex-wrap gap-1.5">
          {summary.strong_likes.map((v) => <Badge key={v}>{v}</Badge>)}
          {summary.hard_avoids.map((v) => <Badge key={v} variant="warning">Avoid {v}</Badge>)}
          {summary.brands.map((v) => <Badge key={v} variant="secondary">{v}</Badge>)}
        </div>
        <Separator />
        <div className="space-y-2">
          {summary.rules.map((rule) => (
            <div key={rule} className="theme-surface-muted rounded-lg p-3 text-sm leading-6 text-stone-600 dark:text-stone-400">{rule}</div>
          ))}
        </div>
      </CardContent>
    </Card>
  )
}
