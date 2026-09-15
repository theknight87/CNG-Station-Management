# UI Foundation

The design and interaction foundation established in Prompt 7, which Prompts 8-20 build on.

Authority: **CLAUDE.md §11 governs everything here.** Where a design-skill recommendation
conflicted with it, the rule won and the recommendation was rejected — §2 below lists each one.

---

## 1. Design direction

**Professional industrial engineering software**, not a SaaS dashboard. The working assumption is
an engineer who lives in this tool for a shift, comparing calibration dates across a station's
worth of valves — so density is a feature, colour carries meaning, and nothing moves without a
reason.

| Decision | Value | Why |
| --- | --- | --- |
| Palette | Industrial slate (`#334155` primary, `#F8FAFC` ground, `#0F172A` text) | Sober and utilitarian. No brand blue, no gradients |
| Radius | `0.25rem` | Restrained. Not every surface is a pill (§11.4) |
| Base font size | 14px | Dense working default; headings scale up, never down |
| Body font | system UI stack | No webfont dependency — see §5 |
| Technical font | system monospace + `tabular-nums` | A transposed digit in a serial is visible; columns align |
| Sidebar | 16rem, collapsing to 3.25rem | Browser-measured: see §8 |
| Header | 3rem | Chrome that earns its height |
| Table row | 34px | Scannable without scrolling; still mouse-friendly |

Colour is used for **status only**, never decoration. Both themes were contrast-checked
programmatically: **every foreground/background pair in light and dark mode meets WCAG AA
(≥ 4.5:1)**, the lowest being 4.90:1 (`due-soon` on its background).

---

## 2. ui-ux-pro-max: what was accepted and what was rejected

The skill was queried with `--design-system --variance 2 --motion 1 --density 9`, plus targeted
searches on the shadcn stack, navigation/accessibility UX rules, and icons.

### Accepted

| Recommendation | How it was applied |
| --- | --- |
| Palette "Industrial slate + stock green" | Adopted as the base, with the green demoted from a CTA accent to the `ok` status colour — colour must carry meaning, not sell |
| Density dial 9 (8-32px spacing scale) | Adopted wholesale: 14px base, 34px rows, 16px page padding |
| Fira Sans / Fira Code **mood** (dashboard, data, technical, precise) | Adopted as a PRINCIPLE — a UI sans for prose, a mono for identifiers — without the webfont (§5) |
| "Avoid: no filtering" | `DataToolbar` is a first-class primitive, not an afterthought |
| Pre-delivery checklist (no emoji icons, visible focus, 4.5:1 contrast, reduced motion, responsive at 4 widths) | All applied and browser-verified |
| UX rules: skip link, visible focus rings, aria-label on icon-only buttons, tab order matching visual order, sequential headings | All applied; each is asserted by a test or a browser check |
| shadcn: use a real `<table>`, not a div grid; semantic `thead`/`tbody` | Applied |

### Rejected

| Recommendation | Why it was rejected |
| --- | --- |
| **Pattern: "Real-Time / Operations Landing"** — hero, key-metrics section, "Start trial / Contact" CTA in nav | It is a MARKETING LANDING PAGE pattern. This is an authenticated internal tool with no hero and nothing to sell (§11.4) |
| **Style: "Exaggerated Minimalism"** — `font-size: clamp(3rem, 10vw, 12rem)`, `font-weight: 900`, "massive whitespace"; best for "fashion, architecture, luxury brands" | Directly contradicts §11.4's ban on huge typography and whitespace that costs data density. Only its high-contrast/WCAG-AA property was kept |
| **Motion: GSAP ScrollTrigger scroll-reveal** | §11.4 rules out unnecessary animation, and Prompt 7 forbids installing Framer Motion / 21st.dev; GSAP is the same category. An operations console does not animate its rows into view |
| **Google Fonts (Fira Sans / Fira Code)** | §17: no font dependency without justification. The system stack performs well, costs no network request, and cannot shift layout on a slow connection. The mood was kept without the dependency |
| **Phosphor icon library** | `lucide-react` is already a dependency and is equally professional. Adding a second icon library has no demonstrated need |
| **shadcn `Sidebar` component** (severity: Medium — "Don't: custom sidebar implementation") | It requires four Radix packages and ships roomier, pill-shaped defaults than §11.3's density allows. The accessibility behaviour it provides is implemented explicitly instead (focus trap, Escape, focus return, `aria-modal`, scroll lock) and is asserted by six tests plus three browser checks. This is the one rejection that trades a library's defaults for tested code, and it is recorded here so the trade is reviewable |

---

## 3. Navigation architecture

```
Dashboard
Stations          Regions · Stations
Asset Management  SRV Management · Vessels · Gas Detectors · Hoses
                  Alerts · Reports
System            Admin · Settings
```

Straight from Prompt 7 §5. **SRV Management sits under Asset Management, never under Stations** —
SRVs are children of equipment, never a top-level physical asset (CLAUDE.md §4). A test asserts
that specifically.

Icons are `lucide-react` SVGs. **No emoji**, asserted by a test that rejects any pictographic
character in a label.

The temporary Prompt-5 routes `/sign-in`, `/sign-up` and `/auth-test` are **absent from
navigation**, asserted by a test.

### Authorization-aware navigation

`navigation.ts` carries a `roles` list per item. **This is visibility only.** Hiding a link is UX;
the database refuses unauthorized reads regardless (CLAUDE.md §10), and a user who types the URL
reaches a permission state rather than data — `/admin` renders `PermissionDenied` for non-admins
rather than redirecting them somewhere that explains nothing.

| Role | Sees |
| --- | --- |
| admin | everything, including Admin |
| manager | everything except Admin |
| engineer | everything except Admin |
| viewer | everything except Admin |
| unresolved | **nothing** — closed by default |

**Manager deliberately does not see Admin.** Prompt 5 gives it no authorization-management
privilege, and inventing one for the sake of a nav item would be inventing a business rule.

---

## 4. Responsive strategy

Desktop is the primary target.

| Width | Behaviour |
| --- | --- |
| ≥ 1024px | Persistent sidebar; collapsible to icons; preference in `localStorage` |
| < 1024px | Sidebar becomes a modal drawer behind a labelled trigger |
| any | The PAGE never scrolls horizontally; a wide TABLE scrolls inside its own region |

**Engineering tables do not become cards on mobile.** A table read by comparing columns loses its
meaning as a stack of cards, so it keeps its natural width and scrolls — verified at 390px.

The drawer implements focus movement on open, a Tab trap, Escape-to-close, focus return to the
trigger, backdrop close, scroll lock, and close-on-navigate. Its rows are roomier than the desktop
sidebar's because it IS a touch surface: browser-measured at 40px minimum across 11 links.

---

## 5. Typography

System stacks, with `'Noto Sans Arabic'` and `'Segoe UI Arabic'` named before the generic fallback
so Arabic renders in a real Arabic face where one exists.

`.font-technical` (system monospace + `tabular-nums`) is used for every serial, part number, job
number and warehouse code. `.tabular` is used for any column of figures that must line up.

**Tradeoff, stated because §17 asks for it:** a webfont (Fira Sans/Fira Code) would give identical
rendering on every machine. It would also add a network dependency, a layout-shift risk, and a
third-party request from an internal tool — for a gain that is aesthetic. If the owner later wants
brand-exact typography, this is the decision to revisit.

---

## 6. NULL and unknown presentation

CLAUDE.md §11.5, implemented in `NullValue` / `ValueOrNull`:

- a NULL renders as a quiet em dash, `aria-hidden`, with **"not recorded"** as real words for
  assistive technology — an unannounced dash is silence
- **never** `N/A`, `Unknown`, `-`, `0`, or any invented stand-in
- an empty or whitespace-only string is absence; a real `0` is a **value** and is rendered
- a NULL is never styled as an error and never marks a record "incomplete" (principle #19)

`DateValue` enforces date precision: a `year_only` value shows its year labelled "(year only)" and
**has no `value` field to render as a date at all**, so no component can expand it to 1 January
even by accident. An `invalid` date shows the preserved source text (`منتهية`) beside an explicitly
absent date, and never converts it into a date or a computed status (decision D6).

---

## 7. Status semantics

Eight meanings, named by MEANING rather than hue: `ok`, `due_soon`, `due`, `overdue`, `unmapped`,
`conflict`, `inactive`, `info`.

Every badge carries **an icon, a word, and a visually-hidden description**. Colour is never the only
signal — it survives greyscale printing, colour blindness, and a screenshot pasted into a report.
There is no rainbow: one visual weight, muted tones.

`unmapped` is deliberately NOT styled as an error. An unresolved mapping is missing evidence, not a
faulty asset.

---

## 8. Arabic and mixed direction

The application chrome stays LTR. **Individual values decide their own direction.**

- `EntityName` renders with `dir="auto"` plus `unicode-bidi: isolate`, so `الماظة 1` lays out
  right-to-left inside a left-to-right table cell without reordering the text around it
- `Identifier` is forced `dir="ltr"`, so a serial never reorders beside an Arabic name
- names are never truncated into ambiguity

Verified in a real browser: `الماظة` renders at 39px with `direction: rtl` at all three viewports.

---

## 9. Reusable primitives

| Primitive | File |
| --- | --- |
| `AppShell`, `AppLayout` | `layout/AppShell.tsx`, `layout/AppLayout.tsx` |
| `SidebarNav`, `MobileNav` | `layout/` |
| `AppHeader`, `AccountControl` | `layout/` |
| `Breadcrumbs`, `crumbsFromPath` | `layout/Breadcrumbs.tsx`, `layout/breadcrumbPaths.ts` |
| `PageContainer`, `PageHeader`, `PageActions`, `SectionHeader`, `DataToolbar` | `layout/PageContainer.tsx` |
| `TableScroll`, `DataTable`, `TableHead/Body/Row/Cell`, `SortableHeader`, `RowHeaderCell` | `data/DataTable.tsx` |
| `StatusBadge` + `statusSemantics` | `data/` |
| `NullValue`, `ValueOrNull`, `EntityName`, `Identifier`, `DateValue` | `data/` |
| `LoadingState`, `EmptyState`, `NoResultsState`, `ErrorState`, `PermissionDenied`, `NotImplemented` | `states/AppStates.tsx` |

`AppShell` is pure presentation; `AppLayout` supplies Clerk identity and the Supabase role. That
split is what makes the shell renderable in a browser without an authentication round-trip — which
is the only reason visual verification was possible here at all.

---

## 10. Application states

Five states, deliberately distinguishable. The failure this guards against is the common one: an
unbuilt feature, a permission refusal and a genuinely empty table all rendering as the same blank
panel.

- **Empty** ("No records") is distinct from **No results** ("no results match these filters")
- **Error** offers a retry ONLY when a real retry exists
- **Permission denied** is visually and semantically unlike empty data
- **Not implemented** names the Prompt that will build the feature and invents no figures

---

## 11. Accessibility

Applied and verified: skip link as the first tab stop · `aria-current="page"` on the active nav
item, plus a left marker so active state is not colour alone · accessible names on every icon-only
control, including collapsed sidebar links · labelled `nav` landmarks · named scroll regions
(`label` is a REQUIRED prop — two unnamed regions are no better than none) · named `search`
landmark on `DataToolbar` · `aria-sort` on sortable headers · `aria-selected` on selectable rows ·
`role="status"` + `aria-live` on loading · focus trap, Escape, and focus return in the drawer ·
`prefers-reduced-motion` honoured globally · WCAG AA contrast in both themes.

---

## 12. ui-ux-critique-pro findings, and what was fixed

| Finding | Action |
| --- | --- |
| Sticky table header used `backdrop-blur` | **Fixed.** That is glassmorphism (§11.4), and a blurred sticky header leaves column names unreadable over scrolling rows. Now an opaque surface with an inset border |
| `TableScroll` had a hard-coded generic region label | **Fixed.** `label` is now required |
| `DataToolbar` exposed an unnamed `search` landmark | **Fixed.** `label` is now required |
| Section labels and the role line were 11px, under the 12px readable floor | **Fixed.** Raised to 12px; density cost nil |
| Backdrop `div` has `onClick` without a keyboard handler | **Not changed, deliberately.** It is `aria-hidden`, does not look clickable, and every keyboard user has both Escape and a labelled Close button. Adding a focusable backdrop would add a tab stop that announces nothing |

---

## 13. Browser verification

Real Chromium via the vendored `playwright-cli` skill's tooling, driving the dev-only preview
harness (`dev/preview.tsx`, excluded from the production bundle — verified).

**Why a harness:** this environment's egress policy blocks Clerk, so the authenticated shell cannot
be reached in a browser here. The harness mounts the REAL shell, REAL navigation and REAL
primitives with a stubbed account, so what the browser rendered is the actual component tree.

`npm run verify:ui` → **32/32 checks pass** at 1440px, 1024px and 390px. Screenshots in
`artifacts/ui/` (git-ignored).

### Defects the browser found that source review had not

1. **Table rows ballooned to 137px below 1024px.** The table was being squeezed into the viewport,
   so cells wrapped to four lines. Fixed with `w-max min-w-full` on the table and `whitespace-nowrap`
   on cells: the table now keeps its natural width and scrolls, as designed. Re-measured at **34px**.
2. **"Gas Detector Management" was ellipsed** in the sidebar — 189px of text in 183px of space.
   Fixed by widening the sidebar from 15rem to 16rem. A truncated navigation label is a worse trade
   than 16px of chrome.

A third failure was a flaw in the check itself, not the app: it pressed Tab without resetting focus
after an earlier click, so it measured the second tab stop rather than the first.

---

## 14. Deferred

| Item | Phase |
| --- | --- |
| Dashboard rollups, KPIs, charts | Prompt 8 |
| Hierarchy browser and real asset tables | Prompt 9+ |
| Admin: users, region access, data quality, import | Prompts 10-14, 21 |
| Notification bell and delivery | Prompt 18 |
| Global search / command palette | not scheduled — deliberately absent rather than faked |
| Dark-mode toggle | tokens are complete and contrast-checked; no control is wired yet |
| Removing `/sign-in`, `/sign-up`, `/auth-test` | before production (`docs/authentication.md` §11) |
| End-to-end verification of the authenticated shell | blocked by the egress policy; the harness covers the shell itself |


---

## 13. Cargas Brand System (added during Prompt 9)

*Status: implemented and browser-verified at 1440 / 1024 / 390. Authoritative for
every future UI prompt.*

### 13.1 Official reference source

| Source | Used? | Why |
| --- | --- | --- |
| `public/brand/logo.png` (official Cargas / NGV lockup, 300×300 RGBA) | **yes — primary** | The only official artwork available to this environment. Colours were sampled from its pixels. |
| `https://cargas.com.eg/English/Default.aspx` | **no — unreachable** | The network egress proxy refuses CONNECT with HTTP 403. Verified three ways (WebFetch, curl to the apex and the `www` host). |
| Memory of the Cargas website | **never** | Recalling a corporate palette is fabrication, not extraction (principle #1). |

Because the site could not be inspected, **the logo is the single source of brand
truth** for this system. Nothing in the palette below was invented.

### 13.2 Supplied assets

| File | Role | Note |
| --- | --- | --- |
| `logo.png` | official source asset, kept unchanged | never edited |
| `logo-trimmed.png` | expanded sidebar, mobile drawer | transparent margin removed only — **no artwork altered**; 204×232 |
| `mark.png` | collapsed sidebar rail | the leaf device, cut from the lockup at its own **fully transparent seam** (row y=192, the blank row the artwork itself puts between the device and the NGV wordmark) |
| `favicon.ico` (16/32/48), `favicon-96.png`, `apple-touch-icon.png` | browser and platform icons | resampled from `mark.png` |
| `favicon.svg` | **deliberately NOT wired up** | a blue gear placeholder (`#1d4ed8`) — scaffold content, not Cargas artwork. Flagged to the owner; the derived favicon is used instead. |

### 13.3 Extracted brand colours

The mark is exactly **two inks**. Of its 22,269 fully opaque pixels, 80.04% are
green and 19.96% are yellow:

| Token | Value | Source |
| --- | --- | --- |
| Cargas green | `#089B4B` — `hsl(147 90% 32%)` | modal green pixel |
| NGV yellow | `#FFEB00` — `hsl(55 100% 50%)` | modal yellow pixel |
| Deep green | `#004221` — `hsl(156 100% 13%)` | the darkest green **already present in the logo** |

### 13.4 Accessible UI derivatives, and why each was required

Two official colours cannot legally carry text. Every figure below is measured,
and re-measured on every run by `scripts/verify-brand.mjs`.

| Source colour | Measured | Derivative | Why required |
| --- | --- | --- | --- |
| `#089B4B` | 3.62:1 with white; 3.46:1 as text on the working ground | **`#07833F`** (`--brand-strong`, same hue and saturation, lightness 32%→27%) → 4.85:1 and 4.64:1 | Both source figures are under the 4.5:1 AA floor for normal text. The official green is therefore used for **identity fills only**; anything involving text uses the derivative. |
| `#FFEB00` | **1.17:1** on the working ground | none for light grounds — the colour is **confined** to dark grounds and the logo | At 1.17:1 it is invisible. It reaches 14.49:1 with near-black on top and 9.40:1 as a mark on `--brand-deep`. Confinement is also what stops the product reading as a yellow marketing site. |
| `#FFEB00` (rare text use) | — | `#7A7000` (`--brand-yellow-ink`) → 4.84:1 | For the rare case where a yellow-derived *text* accent is needed on light. |
| `#089B4B` on a dark ground | 2.4:1 | **`#22C36B`** (`hsl(147 70% 45%)`) → 8.10:1 | The dark theme lightens the **same hue** rather than substituting another colour. |

### 13.5 Brand vs semantic colour — the separation rule

**Brand colour marks identity, navigation and selection. Semantic colour states
compliance. They are separate token namespaces and must never collapse.**

Cargas green must never come to mean "healthy", and NGV yellow must never come to
mean "warning" — otherwise reading a screen becomes a brand decision.

Enforcing that required moving a semantic token: `--status-ok` was green at hue
**158°**, only **11° from the brand green**, and the two read as one colour. It is
now **174° (teal)**, 27° away. `scripts/verify-brand.mjs` fails if that distance
ever drops below 20°.

`AttentionBadge` deliberately renders "Nothing overdue" in the **teal** `ok`
status, never in Cargas green.

### 13.6 Logo usage

- Never recoloured, stretched, distorted, redrawn or regenerated.
- Aspect ratio preserved by sizing from height with `w-auto`, and by declaring
  intrinsic `width`/`height` so the browser reserves the correct box. Measured in
  the browser: **0.0004 drift** from intrinsic ratio.
- **Never a decorative watermark.** It appears once per surface, as
  identification: the expanded sidebar, the mobile drawer, and the browser icon.
- The collapsed rail uses the leaf device because the wordmarks turn to mud
  between 16px and 52px — an official crop, never a new mark.

### 13.7 Typography

Unchanged by the branding work. The system sans stack (with `Noto Sans Arabic` /
`Segoe UI Arabic` for Arabic) and the monospace technical stack stay as decided in
§4. No webfont was added: the brand character is carried by the logo and the
colour system, and a webfont would cost a network request and layout shift for a
tool engineers keep open all day.

### 13.8 Sidebar and header treatment

- The logo sits on the **card ground, not on a green panel** — the mark's own ink
  is green, and on a green field the leaf would disappear into it.
- The brand's green/yellow relationship enters the UI as a **2px keyline** beneath
  the brand block: `--brand` for two thirds, `--brand-yellow` for one third. The
  same keyline appears in the mobile drawer so it reads as one product.
- The active navigation row uses `--brand-strong` text on a 10% tint, plus the
  selection rail. The focus ring is `--brand-strong` throughout.
- **That is the whole of it.** Brand colour touches the chrome in exactly three
  places: the logo, the keyline, and the active/focus state. Everything else stays
  neutral slate so the data leads.

### 13.9 What was taken from the official identity — and what was not

**Taken:** the two inks and their proportion (green dominant, yellow as the
accent), the deep green already inside the mark, the green-above-yellow
relationship expressed in the keyline, and the lockup itself.

**Deliberately NOT copied from the public website:** its page layout, its
navigation pattern, its hero and marketing sections, any slogan or tagline, large
flat areas of corporate green, and decorative use of the logo. This is an
operations console, not a corporate site — §11.3 and §11.4 still govern, and the
brand serves the data rather than competing with it.
