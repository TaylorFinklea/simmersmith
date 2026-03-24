import { Component, type ErrorInfo, type PropsWithChildren } from 'react'

import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'

interface State {
  error: Error | null
}

export class ErrorBoundary extends Component<PropsWithChildren, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[ErrorBoundary]', error, info.componentStack)
  }

  render() {
    if (this.state.error) {
      return (
        <Card className="mx-auto mt-12 max-w-md">
          <CardContent className="space-y-4 p-6 text-center">
            <p className="text-lg font-medium text-stone-900 dark:text-stone-100">Something went wrong</p>
            <p className="text-sm text-stone-500">{this.state.error.message}</p>
            <Button onClick={() => this.setState({ error: null })}>Try again</Button>
          </CardContent>
        </Card>
      )
    }
    return this.props.children
  }
}
