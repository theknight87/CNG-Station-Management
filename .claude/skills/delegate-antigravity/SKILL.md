---
name: delegate-antigravity
description: Delegate coding implementation to Google Antigravity CLI as a separate executor, then review its work yourself. Use when the user explicitly asks to delegate implementation to Antigravity, Gemini via Antigravity, agy, or asks for Antigravity to implement/fix/refactor/test code. Supports explicit Antigravity model and effort selection. The current Codex or Claude session remains the planner, controller, and reviewer and must not silently take over implementation if delegation fails.
---

# Delegate Antigravity

Use Google Antigravity CLI (`agy`) as a separate implementation executor.

## Roles

The current Codex or Claude session is:

- PLANNER
- CONTROLLER
- REVIEWER

Antigravity is:

- IMPLEMENTER
- TEST RUNNER

The current agent MUST NOT silently implement delegated work itself.

## Core rule

Once implementation has been delegated to Antigravity:

1. Antigravity performs the implementation.
2. The current agent reviews the actual workspace changes.
3. If the review fails, send precise review feedback back to Antigravity.
4. Allow a maximum of 3 Antigravity implementation attempts.
5. After the third failed attempt, STOP.
6. Explain what remains incomplete or incorrect to the user.
7. Ask the user whether they want:
   - another Antigravity attempt,
   - the current Codex/Claude agent to take over implementation,
   - or to stop/change approach.
8. NEVER take over implementation without explicit user approval.

This restriction applies even when the missing fix appears trivial.

## When to delegate

Delegate when the user explicitly asks to:

- delegate to Antigravity
- use agy
- use Gemini through Antigravity
- have Antigravity implement/fix/refactor/test something
- execute an approved implementation plan through Antigravity

Do not delegate merely because Antigravity is available.

## Before delegation

Make sure the task is sufficiently defined.

For non-trivial work, create or update:

`IMPLEMENTATION_PLAN.md`

It should include:

- objective
- implementation requirements
- relevant files/areas
- constraints
- things that must NOT change
- tests/checks
- acceptance criteria

Resolve architectural, product, and security decisions before delegation.

Antigravity should execute decisions, not invent unresolved architecture.

## Model selection

The user may specify any model supported by their installed Antigravity CLI.

Known models at the time this skill was configured include:

- gemini-3.8-flash-high
- gemini-3.8-flash-medium
- gemini-3.8-flash-low
- gemini-3.7-flash-high
- gemini-3.7-flash-medium
- gemini-3.7-flash-low
- gemini-3.6-flash-high
- gemini-3.6-flash-medium
- gemini-3.6-flash-low
- gemini-3.1-pro-high
- gemini-3.1-pro-low
- claude-sonnet-4-6
- claude-opus-4-6-thinking
- gpt-oss-120b-medium

If the user specifies a model, pass it exactly.

If the user does not specify a model, omit the model argument and allow Antigravity to use its current/default model.

Do not silently substitute a different explicitly requested model.

If a requested model is rejected by Antigravity, report that failure rather than guessing a replacement.

## Effort selection

Supported effort values are:

- low
- medium
- high

If the user explicitly specifies effort, pass it.

If the user does not specify effort, omit the effort argument and allow Antigravity/default model behavior.

Model variant names such as `gemini-3.8-flash-high` and the Antigravity `--effort` option are separate controls. Preserve both when the user explicitly supplies both.

## Delegation command

Use the shared wrapper:

PowerShell:

`powershell.exe -ExecutionPolicy Bypass -File "$HOME\.shared-agent-skills\delegate-antigravity\scripts\delegate-antigravity.ps1" ...`

Always pass the actual current project/workspace root using `-ProjectDir`.

For example:

`powershell.exe -ExecutionPolicy Bypass -File "$HOME\.shared-agent-skills\delegate-antigravity\scripts\delegate-antigravity.ps1" -ProjectDir "C:\path\to\project" -PromptFile "C:\path\to\prompt.txt" -Model "gemini-3.8-flash-high" -Effort "high"`

The wrapper intentionally runs Antigravity with automatic tool approval.

## Workspace requirement

Antigravity normally has its own scratch workspace.

Therefore the wrapper MUST pass the actual project directory through Antigravity `--add-dir`.

Never review Antigravity's scratch directory as if it were the project.

After delegation, inspect the ACTUAL project workspace.

## Review

Do not trust the executor's textual success report by itself.

After every attempt:

1. Inspect actual changed files in the project.
2. Inspect git diff/status when Git is available.
3. Run or independently verify relevant tests/checks.
4. Compare the implementation against every acceptance criterion.
5. Identify incomplete, incorrect, unsafe, or unrelated changes.

The reviewer may run read-only inspection and verification commands.

The reviewer must not edit/fix delegated implementation during review.

## Retry loop

### Attempt 1

Send the complete implementation task to Antigravity.

Review the actual result.

If correct:
- report success.

If incorrect:
- write precise implementation feedback for Antigravity.

### Attempt 2

Delegate only the required corrections plus relevant original requirements.

Tell Antigravity to inspect the existing implementation and fix the review findings.

Review again.

### Attempt 3

Delegate the remaining concrete failures.

Review again.

If still incorrect:
- STOP.
- Do not edit the implementation.
- Tell the user exactly what remains wrong.
- Ask whether the user wants the current agent to take over, retry Antigravity, or stop/change approach.

## Safety / scope

Antigravity is launched with automatic permission approval.

Therefore give it explicit scope constraints:

- operate only on the supplied project
- do not modify unrelated files
- do not use web search unless the user explicitly requested it
- do not access secrets unnecessarily
- do not change external systems unless explicitly required and approved
- do not delegate to another agent

Automatic approval does NOT mean unlimited task scope.

## Result handling

The wrapper writes Antigravity's textual output to:

`ANTIGRAVITY_EXECUTOR_RESULT.md`

Treat this as an executor report only.

It is NOT proof that implementation succeeded.

Actual workspace inspection and reviewer verification are authoritative.

## Final principle

Antigravity implements.

Codex/Claude reviews.

If Antigravity fails, Codex/Claude sends it back for correction.

After 3 failed attempts, the human decides who implements next.
