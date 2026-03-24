import * as React from 'react'

import { cn } from '@/lib/utils'

const Input = React.forwardRef<HTMLInputElement, React.ComponentProps<'input'>>(({ className, ...props }, ref) => {
  return (
    <input
      ref={ref}
      className={cn(
        'flex h-9 w-full rounded-lg border border-stone-200 bg-white px-3 py-1.5 text-sm text-stone-900 transition placeholder:text-stone-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-olive-700/20 focus-visible:border-olive-300',
        className,
      )}
      {...props}
    />
  )
})
Input.displayName = 'Input'

export { Input }
