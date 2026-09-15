# Stack-Specific Notes

Read only the section(s) relevant to the code under review.

## React / Next.js
- Inline `style={{...}}` scattered through components instead of a consistent utility/CSS approach usually signals no real spacing/color scale — flag it and suggest consolidating.
- Conditional rendering that toggles entire chunks of markup for small state changes (e.g. different JSX trees for hover) often means missed CSS-only solutions — prefer CSS state (`:hover`, `:focus`) over JS-driven style toggling when no extra logic is needed.
- Check custom interactive components (built from `div`s) for missing keyboard handling — this is extremely common in React apps built quickly.
- Watch for `<img>` without `alt`, and Next.js `<Image>` usage without `alt` or with poor `sizes`/priority choices on above-the-fold images.
- Class-name concatenation logic that's hard to read (`className={a + ' ' + (b ? c : d)}`) — suggest a `clsx`/`classnames` utility if not already used.

## Vue
- `v-if`/`v-show` misuse: `v-show` (CSS `display: none`) is usually better for elements toggled frequently (e.g. tabs, tooltips); `v-if` is better for rarely-toggled or heavy content. Wrong choice can cause layout thrash or unnecessary re-mounts affecting perceived UI smoothness.
- Scoped styles are good for isolation but can lead to duplicated spacing/color values across components — check for a shared design-token source (CSS variables, a Tailwind config, or a shared SCSS file) rather than magic numbers repeated per component.
- Transition components (`<Transition>`) without `name`/CSS classes defined often mean animations silently don't run — verify the corresponding CSS exists.
- Custom form components should still emit native-feeling behavior — check `v-model` wrappers expose proper `id`/`label` association.

## Plain HTML + CSS / Tailwind
- Check for semantic HTML before reaching for ARIA — ARIA should patch gaps, not replace semantics that already exist natively.
- Tailwind: watch for arbitrary values (`mt-[13px]`, `text-[15px]`) scattered throughout — these usually indicate no consistent scale; prefer standard scale utilities (`mt-3`, `text-base`) unless there's a real reason for the odd value.
- Long utility-class strings with no organization are hard to review — suggest grouping by concern (layout → spacing → typography → color → state) for readability, or extracting repeated patterns into a component/class via `@apply` if the project supports it.
- Verify responsive prefixes (`sm:`, `md:`, `lg:`) are actually used somewhere — a fully unprefixed layout is a strong signal responsiveness wasn't considered.
- Check for missing `:focus-visible` styling — Tailwind's default browser outline is sometimes stripped (`focus:outline-none`) without a replacement `focus:ring` or similar.

## Svelte / Angular / Other
- Apply the general Visual Design and Accessibility checklists directly — framework-specific idioms matter less here than in React/Vue. Watch for the same core patterns: unstyled semantic elements, missing focus states, inconsistent spacing scales, and color-only state indication.
