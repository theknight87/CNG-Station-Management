import { createContext, useContext } from 'react'

/** Opens the Station hierarchy popup from anywhere in the app (owner request 2026-09-28). */
export type OpenStation = (station: { id: string; name: string }) => void

export const StationPopupContext = createContext<OpenStation | null>(null)

/** null outside the provider (tests, isolated renders): callers then fall back to plain text. */
export function useOpenStation(): OpenStation | null {
  return useContext(StationPopupContext)
}

/** Fired after a Station is added or removed, so any open Station list reloads. */
export const STATIONS_CHANGED = 'cng:stations-changed'
