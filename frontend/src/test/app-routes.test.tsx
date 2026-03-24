import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import { type PropsWithChildren } from 'react'
import { createMemoryRouter, RouterProvider } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { ThemeProvider } from '@/app/theme-provider'
import { AppShell } from '@/components/shared/app-shell'
import { DashboardPage } from '@/features/dashboard/dashboard-page'
import { PricingPage } from '@/features/pricing/pricing-page'

function jsonResponse(payload: unknown) {
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
}

function renderRoute(initialPath: string, responses: Record<string, unknown>) {
  const fetchMock = vi.fn((input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input.toString()
    const payload = responses[url]
    if (payload === undefined) {
      return Promise.reject(new Error(`Unhandled request: ${url}`))
    }
    return Promise.resolve(jsonResponse(payload))
  })
  vi.stubGlobal('fetch', fetchMock)

  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
    },
  })

  const router = createMemoryRouter(
    [
      {
        path: '/',
        element: <AppShell />,
        children: [
          { index: true, element: <DashboardPage /> },
          { path: '/pricing/current', element: <PricingPage /> },
        ],
      },
    ],
    { initialEntries: [initialPath] },
  )

  function Wrapper({ children }: PropsWithChildren) {
    return (
      <ThemeProvider>
        <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
      </ThemeProvider>
    )
  }

  return {
    ...render(<RouterProvider router={router} />, { wrapper: Wrapper }),
    fetchMock,
  }
}

beforeEach(() => {
  vi.restoreAllMocks()
  window.localStorage.clear()
  document.documentElement.classList.remove('dark')
  vi.stubGlobal(
    'matchMedia',
    vi.fn().mockImplementation(() => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
    })),
  )
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('app routes', () => {
  it('renders the empty dashboard state when no current week exists', async () => {
    renderRoute('/', {
      '/api/weeks/current': null,
      '/api/weeks?limit=6': [],
    })

    expect(await screen.findByText('No planning week yet')).toBeInTheDocument()
    expect(screen.getByText('Plan this week')).toBeInTheDocument()
  })

  it('renders pricing split recommendations for the pricing route', async () => {
    window.localStorage.setItem('simmersmith-theme', 'dark')
    renderRoute('/pricing/current', {
      '/api/weeks/current': {
        week_id: 'week-1',
        week_start: '2026-03-16',
        week_end: '2026-03-22',
        status: 'priced',
        notes: '',
        approved_at: '2026-03-14T12:00:00Z',
        priced_at: '2026-03-15T10:00:00Z',
        meals: [],
        grocery_items: [],
      },
      '/api/weeks/week-1/pricing': {
        week_id: 'week-1',
        week_start: '2026-03-16',
        totals: { aldi: 10.5, walmart: 11.25 },
        items: [
          {
            grocery_item_id: 'item-1',
            ingredient_name: 'Milk',
            normalized_name: 'milk',
            total_quantity: 2,
            unit: 'gal',
            quantity_text: '',
            category: 'Dairy',
            source_meals: 'Weekly snack restock',
            notes: '',
            review_flag: '',
            retailer_prices: [
              {
                retailer: 'aldi',
                status: 'matched',
                store_name: 'Aldi 66109',
                product_name: 'Whole Milk',
                package_size: '1 gal',
                unit_price: 3.5,
                line_price: 7.0,
                product_url: '',
                availability: 'In stock',
                candidate_score: 0.9,
                review_note: '',
                raw_query: 'milk',
                scraped_at: '2026-03-15T10:00:00Z',
              },
              {
                retailer: 'walmart',
                status: 'matched',
                store_name: 'Walmart 66109',
                product_name: 'Whole Milk',
                package_size: '1 gal',
                unit_price: 3.9,
                line_price: 7.8,
                product_url: '',
                availability: 'In stock',
                candidate_score: 0.88,
                review_note: '',
                raw_query: 'milk',
                scraped_at: '2026-03-15T10:00:00Z',
              },
            ],
          },
        ],
      },
    })

    expect(await screen.findByText('Store split & shopping handoff')).toBeInTheDocument()
    expect(document.documentElement.classList.contains('dark')).toBe(true)
    await waitFor(() => expect(screen.getAllByText('Aldi').length).toBeGreaterThan(0))
    expect(screen.getAllByText('Whole Milk • 1 gal • In stock').length).toBeGreaterThan(0)
  })
})
