import { afterEach } from 'vitest'
import { cleanup } from '@testing-library/react'

/**
 * Testing Library's automatic cleanup only registers when Vitest globals are
 * enabled. Globals are off here (explicit imports are clearer), so unmounting
 * between tests is wired up explicitly — without it every render accumulates in
 * the same jsdom document and queries start matching earlier tests' output.
 */
afterEach(cleanup)
