# Accessibility Checklist (WCAG-grounded)

Always run this pass, even for purely visual review requests — accessibility issues are functional bugs, not style nitpicks.

## Semantics
- Use native elements (`button`, `a`, `input`, `nav`, `header`, `main`) instead of `div`/`span` with click handlers wherever possible.
- Headings should form a logical, non-skipping hierarchy (`h1` → `h2` → `h3`), one `h1` per page.
- Lists of items should be marked up as `ul`/`ol`, not stacks of `div`s.
- Form inputs need an associated `label` (via `htmlFor`/`for` or wrapping) — placeholder text is not a substitute for a label.

## Images & Media
- Every meaningful `img` needs descriptive `alt` text; purely decorative images should have `alt=""`.
- Icon-only buttons need an accessible name (`aria-label`, visually-hidden text, or `title` as a weaker fallback).
- Video/audio with meaningful content should have captions/transcripts if the project's scope allows it.

## Keyboard & Focus
- Everything a mouse user can do, a keyboard user must be able to do too — check tab order follows visual/logical order.
- Focus must be visibly indicated (`:focus-visible` styling) — never `outline: none` without a replacement.
- Modals/dialogs should trap focus while open and return focus to the trigger element on close.
- Custom interactive components (dropdowns, tabs, custom checkboxes) need correct `role`, `aria-*` state attributes, and keyboard handlers (Enter/Space to activate, arrow keys for composite widgets).

## Color & Contrast
- Text contrast ≥ 4.5:1 (normal), ≥ 3:1 (large/bold text ≥18px or 14px bold).
- UI component contrast (borders, icons conveying meaning) ≥ 3:1 against adjacent colors.
- Never rely on color alone to convey state — pair with text/icon/pattern.

## Screen Reader Considerations
- Decorative elements (dividers, background shapes) should be `aria-hidden="true"` if they'd otherwise be announced.
- Dynamic content updates (toasts, live validation errors) should use an `aria-live` region so screen reader users are notified.
- Avoid `aria-label` overriding visible text with different wording — keep them consistent to avoid confusing voice-control users.

## Quick flags to always call out if present
- Missing `alt` attributes
- `outline: none` with no visible focus replacement
- Color-only error/success indication
- Non-button/link elements with `onClick` and no keyboard handler or role
- Text under the 4.5:1 contrast threshold
