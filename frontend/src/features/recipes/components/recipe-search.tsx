import { Search } from 'lucide-react'

import { Card, CardContent } from '@/components/ui/card'
import { Input } from '@/components/ui/input'

interface RecipeSearchProps {
  query: string
  onQueryChange: (value: string) => void
}

export function RecipeSearch({ query, onQueryChange }: RecipeSearchProps) {
  return (
    <Card>
      <CardContent className="p-4">
        <label className="relative block">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-stone-400" />
          <Input
            value={query}
            onChange={(e) => onQueryChange(e.target.value)}
            placeholder="Search by meal, cuisine, ingredient, or tag"
            className="pl-9"
          />
        </label>
      </CardContent>
    </Card>
  )
}
