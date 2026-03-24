import { Bot, Save, SendToBack } from 'lucide-react'
import { Link } from 'react-router-dom'

import { Button } from '@/components/ui/button'

interface WeekActionBarProps {
  weekId: string
  status: string
  onSave: () => void
  onReady: () => void
  onApprove: () => void
  onExport: () => void
  savePending: boolean
  readyPending: boolean
  approvePending: boolean
  exportPending: boolean
}

export function WeekActionBar({ status, onSave, onReady, onApprove, onExport, savePending, readyPending, approvePending, exportPending }: WeekActionBarProps) {
  return (
    <div className="theme-glass-panel fixed bottom-3 left-1/2 z-20 w-[calc(100%-1.5rem)] max-w-4xl -translate-x-1/2 rounded-xl border p-3 backdrop-blur-lg sm:bottom-3">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <p className="text-sm text-stone-600 dark:text-stone-400">Save edits, mark ready, or approve.</p>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" asChild size="sm">
            <Link to="/grocery/current">Grocery</Link>
          </Button>
          <Button variant="ghost" size="sm" onClick={onExport} disabled={exportPending}>
            <SendToBack className="size-3.5" />
            {exportPending ? 'Exporting…' : 'Export'}
          </Button>
          <Button variant="secondary" size="sm" onClick={onReady} disabled={readyPending || status === 'ready_for_ai'}>
            <Bot className="size-3.5" />
            {readyPending ? 'Marking…' : 'Ready for AI'}
          </Button>
          {status !== 'approved' ? (
            <Button variant="outline" size="sm" onClick={onApprove} disabled={approvePending}>
              {approvePending ? 'Approving…' : 'Approve'}
            </Button>
          ) : null}
          <Button size="sm" onClick={onSave} disabled={savePending}>
            <Save className="size-3.5" />
            {savePending ? 'Saving…' : 'Save'}
          </Button>
        </div>
      </div>
    </div>
  )
}
