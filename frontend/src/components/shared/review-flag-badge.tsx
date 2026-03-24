import { AlertTriangle, CheckCircle2, HelpCircle } from 'lucide-react'

import { Badge } from '@/components/ui/badge'

interface ReviewFlagBadgeProps {
  flag: string
}

export function ReviewFlagBadge({ flag }: ReviewFlagBadgeProps) {
  if (!flag) {
    return (
      <Badge variant="outline" className="gap-1 text-stone-400">
        <CheckCircle2 className="size-3" />
        OK
      </Badge>
    )
  }

  const isWarning = flag.includes('missing') || flag.includes('unavailable') || flag.includes('review')

  return (
    <Badge variant={isWarning ? 'warning' : 'muted'} className="gap-1">
      {isWarning ? <AlertTriangle className="size-3" /> : <HelpCircle className="size-3" />}
      {flag.replace(/_/g, ' ')}
    </Badge>
  )
}
