import { useState } from 'react'

import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'

interface RecipeImportDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  onImport: (url: string) => Promise<void>
  importing?: boolean
}

export function RecipeImportDialog({ open, onOpenChange, onImport, importing = false }: RecipeImportDialogProps) {
  const [url, setUrl] = useState('')

  async function handleImport() {
    await onImport(url)
    setUrl('')
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Import recipe from URL</DialogTitle>
          <DialogDescription>
            Fetch the structured recipe from the page, drop article junk, and open it in the editor for review before saving.
          </DialogDescription>
        </DialogHeader>

        <div className="px-6 py-1">
          <Label htmlFor="recipe-import-url">Recipe URL</Label>
          <Input
            id="recipe-import-url"
            className="mt-1.5"
            placeholder="https://example.com/your-favorite-recipe"
            value={url}
            onChange={(event) => setUrl(event.target.value)}
          />
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => {
              setUrl('')
              onOpenChange(false)
            }}
          >
            Cancel
          </Button>
          <Button type="button" onClick={() => void handleImport()} disabled={importing || !url.trim()}>
            {importing ? 'Importing…' : 'Import recipe'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
