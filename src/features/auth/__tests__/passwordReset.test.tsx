import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({ session: null as object | null }))
const auth = vi.hoisted(() => ({
  resetPasswordForEmail: vi.fn(),
  updateUser: vi.fn(),
}))

vi.mock('@/features/auth/AuthProvider', () => ({
  useAuth: () => ({ session: state.session, user: null, loading: false, signOut: vi.fn() }),
}))
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => ({ auth }) }))

const { ForgotPasswordPage, ResetPasswordPage, RESET_REQUESTED } = await import('@/features/auth/PasswordResetPages')
const { SignInPage } = await import('@/features/auth/SignInPage')

beforeEach(() => {
  state.session = null
  auth.resetPasswordForEmail.mockReset().mockResolvedValue({ error: null })
  auth.updateUser.mockReset().mockResolvedValue({ error: null })
})

describe('password reset', () => {
  it('RESET-1 sign-in links to the reset request page', () => {
    render(<MemoryRouter><SignInPage /></MemoryRouter>)
    expect(screen.getByRole('link', { name: /forgot password/i }).getAttribute('href')).toBe('/forgot-password')
  })

  it('RESET-2 requests a link that returns to /reset-password', async () => {
    const user = userEvent.setup()
    render(<MemoryRouter><ForgotPasswordPage /></MemoryRouter>)
    await user.type(screen.getByLabelText(/email address/i), 'someone@example.com')
    await user.click(screen.getByRole('button', { name: /send reset link/i }))
    expect(auth.resetPasswordForEmail).toHaveBeenCalledWith('someone@example.com', { redirectTo: `${window.location.origin}/reset-password` })
    expect(await screen.findByText(RESET_REQUESTED)).toBeDefined()
  })

  it('RESET-3 shows the same message when the request fails, so accounts cannot be discovered', async () => {
    const user = userEvent.setup()
    auth.resetPasswordForEmail.mockResolvedValue({ error: { message: 'User not found' } })
    render(<MemoryRouter><ForgotPasswordPage /></MemoryRouter>)
    await user.type(screen.getByLabelText(/email address/i), 'nobody@example.com')
    await user.click(screen.getByRole('button', { name: /send reset link/i }))
    expect(await screen.findByText(RESET_REQUESTED)).toBeDefined()
    expect(screen.queryByText(/not found/i)).toBeNull()
  })

  it('RESET-4 without a recovery session the link is reported invalid and no form is offered', () => {
    const { container } = render(<MemoryRouter><ResetPasswordPage /></MemoryRouter>)
    expect(screen.getByText(/invalid or has expired/i)).toBeDefined()
    expect(container.querySelector('input')).toBeNull()
  })

  it('RESET-5 rejects short and mismatched passwords without calling the server', async () => {
    const user = userEvent.setup()
    state.session = { access_token: 'x' }
    render(<MemoryRouter><ResetPasswordPage /></MemoryRouter>)
    const pw = screen.getByLabelText(/^new password/i)
    pw.removeAttribute('minLength')
    await user.type(pw, 'short')
    await user.type(screen.getByLabelText(/confirm/i), 'short')
    await user.click(screen.getByRole('button', { name: /save new password/i }))
    expect(screen.getByRole('alert').textContent).toMatch(/at least 8/)
    await user.clear(pw); await user.type(pw, 'Longenough1!')
    await user.click(screen.getByRole('button', { name: /save new password/i }))
    expect(screen.getByRole('alert').textContent).toMatch(/do not match/)
    expect(auth.updateUser).not.toHaveBeenCalled()
  })

  it('RESET-6 saves the new password and continues into the app', async () => {
    const user = userEvent.setup()
    state.session = { access_token: 'x' }
    render(
      <MemoryRouter initialEntries={['/reset-password']}>
        <Routes>
          <Route path="/reset-password" element={<ResetPasswordPage />} />
          <Route path="/dashboard" element={<p>Dashboard</p>} />
        </Routes>
      </MemoryRouter>,
    )
    await user.type(screen.getByLabelText(/^new password/i), 'Longenough1!')
    await user.type(screen.getByLabelText(/confirm/i), 'Longenough1!')
    await user.click(screen.getByRole('button', { name: /save new password/i }))
    expect(auth.updateUser).toHaveBeenCalledWith({ password: 'Longenough1!' })
    expect(await screen.findByText('Dashboard')).toBeDefined()
  })
})
