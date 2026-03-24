import type { ColumnDef } from '@tanstack/react-table'

import { DataTable } from '@/components/shared/data-table'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatDate } from '@/lib/simmersmith'
import type { WeekSummaryOut } from '@/lib/types'

const columns: ColumnDef<WeekSummaryOut>[] = [
  {
    header: 'Week',
    accessorKey: 'week_start',
    cell: ({ row }) => (
      <div>
        <p className="font-medium text-stone-900 dark:text-stone-100">{formatDate(row.original.week_start)}</p>
        <p className="text-xs text-stone-500 dark:text-stone-400">{formatDate(row.original.week_end)}</p>
      </div>
    ),
  },
  { header: 'Status', accessorKey: 'status', cell: ({ row }) => <Badge variant="muted">{row.original.status}</Badge> },
  { header: 'Changes', accessorKey: 'staged_change_count' },
  { header: 'Exports', accessorKey: 'export_count' },
]

interface RecentWeeksProps {
  weeks: WeekSummaryOut[]
}

export function RecentWeeks({ weeks }: RecentWeeksProps) {
  return (
    <>
      {/* Mobile cards */}
      <section className="grid gap-3 xl:hidden">
        {weeks.map((week) => (
          <Card key={week.week_id}>
            <CardContent className="flex items-center justify-between gap-4 p-4">
              <div>
                <p className="text-sm font-medium text-stone-900 dark:text-stone-100">{formatDate(week.week_start)}</p>
                <p className="text-xs text-stone-500 dark:text-stone-400">
                  {week.staged_change_count} changes · {week.export_count} exports
                </p>
              </div>
              <Badge variant="outline">{week.status}</Badge>
            </CardContent>
          </Card>
        ))}
      </section>

      {/* Desktop table */}
      <section className="hidden xl:block">
        <Card>
          <CardHeader>
            <CardTitle>Recent weeks</CardTitle>
            <CardDescription>Planning history at a glance.</CardDescription>
          </CardHeader>
          <CardContent>
            <DataTable columns={columns} data={weeks} />
          </CardContent>
        </Card>
      </section>
    </>
  )
}
