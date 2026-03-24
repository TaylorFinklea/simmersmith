import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import type { PreferenceSignal } from '@/lib/types'

interface ActiveSignalsProps {
  signals: PreferenceSignal[]
}

export function ActiveSignals({ signals }: ActiveSignalsProps) {
  const active = signals.filter((s) => s.active)
  return (
    <Card>
      <CardHeader>
        <CardTitle>Active signals</CardTitle>
        <CardDescription>Stronger signals carry more weight in meal scoring.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {active.map((signal) => (
          <div key={signal.preference_id} className="rounded-lg border border-stone-200 dark:border-stone-700 p-3">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{signal.name}</p>
                <p className="mt-0.5 text-xs text-stone-500 dark:text-stone-400">{signal.signal_type}</p>
              </div>
              <Badge variant={signal.score < 0 ? 'warning' : 'default'}>
                {signal.score >= 0 ? '+' : ''}{signal.score} / {signal.weight}
              </Badge>
            </div>
            {signal.rationale ? (
              <p className="mt-2 text-xs leading-5 text-stone-500 dark:text-stone-400">{signal.rationale}</p>
            ) : null}
          </div>
        ))}
      </CardContent>
    </Card>
  )
}
