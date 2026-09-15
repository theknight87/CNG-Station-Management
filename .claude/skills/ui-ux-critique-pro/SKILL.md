---
name: ui-ux-critique-pro
description: Reviews and critiques UI/UX code — React, HTML/Tailwind, Vue, or other frontend frameworks — against professional design and accessibility standards. Produces a structured critique covering visual hierarchy, spacing, color/contrast, typography, responsiveness, interaction states, and accessibility, with concrete before/after fixes. Use this whenever the user shares frontend code (components, pages, snippets) and asks for a review, critique, feedback, "does this look good", "is this accessible", "clean this up", or any request to improve, polish, or audit an existing UI — even if they don't use the words "UI/UX review" explicitly. Also use when the user pastes a screenshot or description of an interface and wants design feedback.
---

# UI/UX Critique Pro

A structured, opinionated design-review workflow for critiquing existing frontend UI code (React, Vue, HTML/Tailwind, or similar) against professional visual-design and accessibility standards. This skill is for **reviewing and improving what exists**, not generating a full design system from scratch.

## When this triggers

Use this skill whenever the user:
- Shares a component, page, or snippet of frontend code and asks for feedback, a review, or a critique
- Asks "does this look good", "how can I improve this UI", "is this accessible", "clean this up", "make this look more professional"
- Pastes a screenshot of an interface and wants design commentary
- Asks you to audit a page/app for UI or UX issues before shipping

Do NOT use this for generating a brand-new design system, picking colors/fonts for a blank project, or writing large amounts of new UI from scratch — that's a different task; just build the UI directly using good judgment and `frontend-design` skill guidance where relevant.

## Workflow

1. **Get the code in view.** If the user attached a file, `view` it. If it's inline, read it directly. If they only gave a screenshot or description with no code, work from that — note in your critique that a code-level pass would catch more (e.g. missing `alt` text, non-semantic markup).

2. **Identify the stack.** Detect React/JSX, Vue SFC, plain HTML+CSS/Tailwind, Svelte, etc. from file extensions and syntax. Load `references/stack-notes.md` and read only the section for the detected stack(s) — this has framework-specific pitfalls (e.g. Vue reactivity misuse showing up as UI bugs, React inline-style overuse, unstyled semantic HTML in plain pages).

3. **Run the critique in five passes.** For each pass, read the relevant reference file the first time you need it in a session, then apply it:
   - **Visual hierarchy & layout** — `references/visual-design.md`
   - **Color, contrast & typography** — `references/visual-design.md`
   - **Spacing & responsiveness** — `references/visual-design.md`
   - **Interaction states & motion** — `references/visual-design.md`
   - **Accessibility** — `references/accessibility.md` (always run this pass, even if the user only asked about "looks")

4. **Structure the output** as:
   - A one-paragraph overall impression (what's working, what's not)
   - Issues grouped by category (Hierarchy, Color/Typography, Spacing/Responsive, Interaction, Accessibility) — each issue gets: what's wrong, why it matters, and a concrete fix (code snippet or exact CSS/Tailwind class change)
   - A short prioritized "fix these first" list (3–5 items) at the end, ranked by user impact

   Use `step_card_display_v0` or plain prose depending on how many issues there are — a handful of issues reads fine as prose; more than ~6 issues benefits from the step/options card so it's scannable. Don't use a card just for the sake of it if prose is cleaner.

5. **Offer to apply fixes.** After the critique, ask if the user wants you to actually implement the changes in the code (don't do this unprompted — critique first, edit second).

## Principles to apply during critique

- **Specificity over vibes.** Never say "improve the spacing" — say "the gap between the card title and body is 4px but should be at least 8–12px to visually group them; use `mb-2` or `mb-3` instead of `mb-1`."
- **Contrast is non-negotiable.** Flag any text/background pair under a 4.5:1 ratio (3:1 for large text) as a hard issue, not a suggestion.
- **No fake affordances.** Flag non-interactive elements styled to look clickable, and clickable elements missing `cursor-pointer`/hover/focus states.
- **Respect existing constraints.** If the user has an existing design system, brand colors, or component library, work within it — don't suggest replacing their whole visual language unless asked.
- **Motion and accessibility.** Flag missing `prefers-reduced-motion` handling on any nontrivial animation.
- **Don't invent problems.** If a section is genuinely fine, say so briefly instead of padding the critique with minor nitpicks.

## Reference files

- `references/visual-design.md` — hierarchy, color/contrast, typography, spacing, responsive breakpoints, interaction/motion checklist
- `references/accessibility.md` — WCAG-grounded checklist (semantics, keyboard nav, ARIA, focus, contrast, screen-reader considerations)
- `references/stack-notes.md` — pitfalls specific to React, Vue, and plain HTML/Tailwind
