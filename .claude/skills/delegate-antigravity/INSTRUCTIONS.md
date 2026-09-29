# Antigravity Delegation Protocol

## Roles

The parent Codex or Claude session is the PLANNER, CONTROLLER, and REVIEWER.

Antigravity is the IMPLEMENTATION EXECUTOR and TEST RUNNER.

## Planning

Before delegation, make sure requirements, constraints, and acceptance criteria are clear.

For substantial tasks, create or update IMPLEMENTATION_PLAN.md.

Resolve architectural, product, security, and requirement decisions before delegation.

## Execution

Run:

C:\Users\Eslam\.shared-agent-skills\delegate-antigravity\scripts\delegate-antigravity.ps1

Always pass the actual current project root using -ProjectDir.

Provide implementation instructions using -Prompt or -PromptFile.

Antigravity must modify the actual project workspace, not its scratch workspace.

## Model

If the user specifies a model, pass it exactly using -Model.

Examples:

gemini-3.8-flash-high
gemini-3.8-flash-medium
gemini-3.8-flash-low
gemini-3.7-flash-high
gemini-3.1-pro-high
claude-sonnet-4-6
claude-opus-4-6-thinking
gpt-oss-120b-medium

If no model is specified, omit -Model.

Never silently substitute a different explicitly requested model.

## Effort

Supported values:

low
medium
high

If specified by the user, pass it using -Effort.

If not specified, omit -Effort.

Model variant and --effort are separate controls. Preserve both when both are requested.

## Permissions

The executor intentionally uses Antigravity automatic tool approval.

The implementation prompt must clearly restrict work to the requested project and task.

## Review

After every Antigravity attempt, independently inspect the ACTUAL project.

Check:

- changed files
- git status and diff when available
- required tests
- acceptance criteria
- unrelated changes
- implementation correctness

Do not trust ANTIGRAVITY_EXECUTOR_RESULT.md alone.

The actual workspace is authoritative.

## Failed Review

If review fails:

DO NOT FIX THE IMPLEMENTATION YOURSELF.

Send precise review findings back to Antigravity.

Antigravity then performs the correction.

Review again.

Maximum total Antigravity implementation attempts: 3.

## Attempt Limit

Attempt 1:
Initial implementation.

Attempt 2:
Correction based on reviewer findings.

Attempt 3:
Final correction based on remaining reviewer findings.

If attempt 3 still fails:

STOP.

Do not implement the remaining work yourself.

Explain exactly what remains incomplete or incorrect.

Ask the user to choose:

1. another Antigravity attempt
2. Codex or Claude takes over implementation
3. stop or change approach

The parent agent may take over implementation ONLY after explicit user approval.

This rule applies even when the remaining fix appears trivial.

## Core Principle

Antigravity implements.

Codex or Claude reviews.

Failed work goes back to Antigravity.

After three failed attempts, the human decides what happens next.