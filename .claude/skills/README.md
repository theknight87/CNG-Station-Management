# Project skills

Skills vendored into this repository so they travel with the project and are available in every
future session, on any machine, without depending on a particular account's synced skill set.

Claude Code loads skills from `.claude/skills/<name>/SKILL.md`.

| Skill | Why it is here |
| --- | --- |
| `ui-ux-critique-pro` | **The skill CLAUDE.md §11 requires.** From Prompt 7 onward it is invoked for every user-facing interface task. Reviews frontend code against professional visual-design and accessibility standards and returns concrete before/after fixes |
| `security-audit` | Authorization, RLS and secret-exposure auditing — the methodology behind the Prompt 5 security work, kept available for future phases |
| `website-builder-setup` | Vendored for reference **only**, because CLAUDE.md §11.1 names it. It installs a Framer-Motion/21st.dev website-builder stack whose animation-heavy output conflicts with §11.3/§11.4. **Do not run it without the owner's explicit approval** |

## On "UI/UX Pro Max"

The owner refers to the design skill as "UI/UX Pro Max". No skill with that literal name exists on
this account — `website-builder-setup` merely offers to *install* a stack by that name.
`ui-ux-critique-pro` is the enabled design/review skill and is what CLAUDE.md §11 means.

If a skill genuinely named "UI/UX Pro Max" is installed later, vendor it here beside these and
update CLAUDE.md §11.1.

## What is deliberately NOT here

The account also syncs `docx`, `pptx`, `xlsx`, `pdf`, `canvas-design`, `theme-factory`,
`skill-creator`, `mcp-builder`, `web-artifacts-builder`, `brand-guidelines`, `morning`,
`import-memory`, `antigravity-protocol` and `ultimate-protocol-simulator` — about 11 MB, almost all
of it unrelated to this product. They are left out to keep the repository about the CNG Station
Management System. Ask if you want any of them added.

## Updating

These are copies. To refresh one, replace its directory from the account's synced skills and commit
the diff, so the change is reviewable like any other repository content.
