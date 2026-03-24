import { fireEvent, render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { THEME_STORAGE_KEY, ThemeProvider, useTheme } from '@/app/theme-provider'

function ThemeProbe() {
  const { resolvedTheme, theme, toggleTheme } = useTheme()

  return (
    <div>
      <p>theme:{theme}</p>
      <p>resolved:{resolvedTheme}</p>
      <button type="button" onClick={toggleTheme}>
        toggle
      </button>
    </div>
  )
}

function renderWithTheme() {
  return render(
    <ThemeProvider>
      <ThemeProbe />
    </ThemeProvider>,
  )
}

function mockMatchMedia(matches: boolean) {
  vi.stubGlobal(
    'matchMedia',
    vi.fn().mockImplementation(() => ({
      matches,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
    })),
  )
}

beforeEach(() => {
  vi.restoreAllMocks()
  window.localStorage.clear()
  document.documentElement.classList.remove('dark')
  document.documentElement.removeAttribute('data-theme')
})

describe('theme provider', () => {
  it('defaults to system theme when no saved preference exists', () => {
    mockMatchMedia(true)

    renderWithTheme()

    expect(screen.getByText('theme:system')).toBeInTheDocument()
    expect(screen.getByText('resolved:dark')).toBeInTheDocument()
    expect(document.documentElement.classList.contains('dark')).toBe(true)
  })

  it('applies a saved dark preference on mount', () => {
    mockMatchMedia(false)
    window.localStorage.setItem(THEME_STORAGE_KEY, 'dark')

    renderWithTheme()

    expect(screen.getByText('theme:dark')).toBeInTheDocument()
    expect(screen.getByText('resolved:dark')).toBeInTheDocument()
    expect(document.documentElement.classList.contains('dark')).toBe(true)
  })

  it('toggles theme and updates localStorage', () => {
    mockMatchMedia(false)

    renderWithTheme()
    fireEvent.click(screen.getByRole('button', { name: 'toggle' }))

    expect(screen.getByText('theme:dark')).toBeInTheDocument()
    expect(screen.getByText('resolved:dark')).toBeInTheDocument()
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark')
    expect(document.documentElement.classList.contains('dark')).toBe(true)
  })
})
