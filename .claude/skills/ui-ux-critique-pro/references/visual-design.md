# Visual Design Checklist

Use this during the Hierarchy, Color/Typography, Spacing/Responsive, and Interaction passes.

## Visual Hierarchy & Layout
- Is there one clear primary action per screen/section? Multiple competing CTAs of equal visual weight is a common issue.
- Does size/weight/color correlate with importance? Headings should visually dominate body text; primary buttons should outweigh secondary/tertiary ones.
- Is whitespace used to group related elements and separate unrelated ones (proximity principle)? Cramped unrelated elements or excessive gaps between related ones both read as broken hierarchy.
- Check alignment — items should sit on a consistent grid/baseline, not "eyeballed."
- Flag more than ~3 levels of visual emphasis competing on one screen.

## Color & Typography
- Contrast: body text ≥ 4.5:1 against background; large text (18px+/bold 14px+) ≥ 3:1. Flag anything under this as a hard issue.
- Color should not be the only signal for state (error/success/required) — pair with icon, text, or pattern.
- Limit to 1–2 typefaces; check that a clear type scale exists (not five near-identical font sizes).
- Line length: body text should be roughly 45–75 characters per line; flag full-width paragraphs on wide screens.
- Line height: body text generally 1.4–1.6x font size.
- Check for pure black (#000) on pure white — slightly softened values are usually easier to read and feel more polished (e.g. #1a1a1a on #fafafa).

## Spacing & Responsiveness
- Check for a consistent spacing scale (e.g. 4/8px increments) rather than arbitrary pixel values scattered through the code.
- Touch targets should be at least ~44x44px on mobile/touch contexts.
- Test/reason through common breakpoints: ~375px (mobile), ~768px (tablet), ~1024–1440px (desktop). Does content reflow sensibly, or does it just shrink/overflow?
- Flag fixed-width containers that will overflow on small screens, and text that will wrap awkwardly (e.g. orphaned single words).
- Horizontal scrolling on mobile (other than intentional carousels) is almost always a bug.

## Interaction States & Motion
- Every clickable element needs: default, hover, focus-visible, active, and (if applicable) disabled states. Missing focus states are both a UX and accessibility issue.
- Cursor should be `pointer` on anything clickable that isn't a native button/link.
- Transitions on hover/state changes should generally sit in the 150–300ms range — instant feels jarring, slow feels sluggish.
- Loading and empty states should exist for anything async — flag components that only render a "happy path."
- Check for `prefers-reduced-motion` handling on any animation beyond a subtle hover transition.
- Avoid animating properties that trigger layout thrash (`width`, `height`, `top`, `left`) — prefer `transform`/`opacity`.
