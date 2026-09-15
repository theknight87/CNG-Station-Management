# Project skills

Skills vendored into this repository so they travel with the project and are available in every
future session, on any machine, without depending on a particular account's synced skill set.

Claude Code loads skills from `.claude/skills/<name>/SKILL.md`.

Installed from the owner-supplied archive `claude-skills-security-audit.tar.gz`
(sha256 `498f34deaf58b5db2b8bbf37b3b8d51b14ed952eeeef6131c06d18f01b0b2624`), verified
byte-identical to it. The archive and its one-shot extraction workflow were removed afterwards:
the extracted files ARE the deliverable, and keeping a 3.3 MB tarball of the same content beside
them would leave two copies to drift apart.

Two symlinks in the archive (`security-audit`, `playwright-cli`, both pointing at duplicate
top-level copies) were materialised into real directories, so a Windows or archive-export checkout
gets the files rather than broken links.

## The design skills

| Skill | Role |
| --- | --- |
| **`ui-ux-pro-max`** | **The skill CLAUDE.md §11 requires.** Searchable design-intelligence database — styles, colour palettes, font pairings, product types, UX guidelines, icons, motion presets and chart types across 22 stacks, with priority-ordered rules. Invoked for every user-facing interface task from Prompt 7 onward |
| `ui-styling` | Styling reference that accompanies it |
| `design-system` | Design tokens, generation and validation scripts |
| `design`, `brand` | Visual identity and asset tooling |
| `slides`, `banner-design` | Presentation and banner output — not used by the application UI |
| `ui-ux-critique-pro` | A second, narrower review pass: critiques existing frontend code against visual-design and accessibility standards. **Secondary.** `ui-ux-pro-max` is the primary skill named by §11 |

## The engineering skills

| Skill | Role |
| --- | --- |
| `security-audit` | Authorization, RLS and secret-exposure auditing — the methodology behind the Prompt 5 security work |
| `playwright-cli` | Browser automation: tracing, request mocking, storage state, video. Useful for the real end-to-end checks this environment's egress policy blocks |
| `speckit-*` (11 skills) | Spec-driven development workflow: constitution, specify, clarify, plan, tasks, analyze, checklist, implement, converge, tasks-to-issues |

## These skills do not override the project's rules

CLAUDE.md §11.2 governs. A design skill critiques and improves **presentation**. It has no
authority over the equipment hierarchy, authorization and RLS, the data principles, database
constraints, the mapping lifecycle, or the import pipeline. Where a suggestion from any skill here
conflicts with a project rule, **the project rule wins and the suggestion is discarded**.

In particular, nothing in these skills authorizes rendering `N/A`, `Unknown`, `-` or `0` where a
value is NULL (§11.5), and nothing authorizes the animation-heavy, marketing-site aesthetic §11.4
rules out — `ui-ux-pro-max` carries motion presets and decorative styles that are simply not used
here.

## Updating

These are copies. To refresh one, replace its directory and commit the diff, so the change is
reviewable like any other repository content.
