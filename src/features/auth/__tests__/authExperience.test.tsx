import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'

import { AuthGate } from '@/features/auth/AuthGate'
import { SignInPage } from '@/features/auth/SignInPage'

vi.mock('@/features/auth/AuthProvider', () => ({
  useAuth: () => ({ session: null, user: null, loading: false, signOut: vi.fn() }),
}))

vi.mock('@/hooks/useAppUser', () => ({
  useAppUser: () => ({ status: 'unauthenticated' }),
}))

const auth = vi.hoisted(() => ({
  signInWithPassword: vi.fn(),
  signInWithOAuth: vi.fn(),
}))

vi.mock('@/lib/supabase/client', () => ({
  useSupabaseClient: () => ({ auth }),
}))

function SignInWithLocation() {
  const location = useLocation()
  return <><SignInPage /><output data-testid="requested-route">{(location.state as { from?: string } | null)?.from}</output></>
}

describe('authentication experience', () => {
  it('sends a signed-out protected visit straight to the full sign-in form and remembers the destination', async () => {
    render(
      <MemoryRouter initialEntries={['/reports/due?window=30']}>
        <Routes>
          <Route path="/sign-in" element={<SignInWithLocation />} />
          <Route path="*" element={<AuthGate><p>Private application</p></AuthGate>} />
        </Routes>
      </MemoryRouter>,
    )

    expect(await screen.findByRole('heading', { name: 'Welcome back' })).toBeDefined()
    expect(screen.getByLabelText('Email address')).toBeDefined()
    expect(screen.getByLabelText('Password')).toBeDefined()
    expect(screen.getByTestId('requested-route').textContent).toBe('/reports/due?window=30')
    expect(screen.queryByText('Sign in to continue. Access is granted by an administrator.')).toBeNull()
  })

  it('shows the company identity and direct access form together', () => {
    render(<MemoryRouter><SignInPage /></MemoryRouter>)

    expect(screen.getAllByAltText('Cargas NGV').length).toBeGreaterThan(0)
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeDefined()
    expect(screen.getByText('Role and Region controlled access')).toBeDefined()
  })

  it('maps provider failures to a safe sign-in message', async () => {
    auth.signInWithPassword.mockResolvedValueOnce({
      error: { message: 'provider diagnostic: upstream token failure' },
    })
    const user = userEvent.setup()
    render(<MemoryRouter><SignInPage /></MemoryRouter>)

    await user.type(screen.getByLabelText('Email address'), 'test@example.invalid')
    await user.type(screen.getByLabelText('Password'), 'not-a-real-password')
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect((await screen.findByRole('alert')).textContent).toContain('Email or password is incorrect. Please try again.')
    expect(screen.queryByText(/provider diagnostic/i)).toBeNull()
  })
})
