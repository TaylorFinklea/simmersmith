import * as React from 'react'

import { cn } from '@/lib/utils'

const Textarea = React.forwardRef<HTMLTextAreaElement, React.ComponentProps<'textarea'>>(
  ({ className, ...props }, ref) => {
    return (
      <textarea
        ref={ref}
        className={cn(
          'flex min-h-24 w-full rounded-lg border border-stone-200 bg-white px-3 py-2 text-sm text-stone-900 transition placeholder:text-stone-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-olive-700/20 focus-visible:border-olive-300',
          className,
        )}
        {...props}
      />
    )
  },
)
Textarea.displayName = 'Textarea'

export { Textarea }
