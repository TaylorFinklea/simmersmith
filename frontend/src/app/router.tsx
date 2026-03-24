/* eslint-disable react-refresh/only-export-components -- lazy-loaded route definitions are not HMR components */
import { lazy, Suspense } from 'react'
import { createBrowserRouter } from 'react-router-dom'

import { AppShell } from '@/components/shared/app-shell'
import { PageSkeleton } from '@/components/shared/skeleton'

const DashboardPage = lazy(() => import('@/features/dashboard/dashboard-page').then(m => ({ default: m.DashboardPage })))
const WeekPage = lazy(() => import('@/features/week/week-page').then(m => ({ default: m.WeekPage })))
const GroceryPage = lazy(() => import('@/features/grocery/grocery-page').then(m => ({ default: m.GroceryPage })))
const PricingPage = lazy(() => import('@/features/pricing/pricing-page').then(m => ({ default: m.PricingPage })))
const RecipesPage = lazy(() => import('@/features/recipes/recipes-page').then(m => ({ default: m.RecipesPage })))
const ProfilePage = lazy(() => import('@/features/profile/profile-page').then(m => ({ default: m.ProfilePage })))

function Lazy({ children }: { children: React.ReactNode }) {
  return <Suspense fallback={<PageSkeleton />}>{children}</Suspense>
}

export const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    children: [
      { index: true, element: <Lazy><DashboardPage /></Lazy> },
      { path: '/profile', element: <Lazy><ProfilePage /></Lazy> },
      { path: '/recipes', element: <Lazy><RecipesPage /></Lazy> },
      { path: '/weeks/current', element: <Lazy><WeekPage /></Lazy> },
      { path: '/grocery/current', element: <Lazy><GroceryPage /></Lazy> },
      { path: '/pricing/current', element: <Lazy><PricingPage /></Lazy> },
    ],
  },
])
