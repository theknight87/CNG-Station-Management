param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDir,

    [Parameter(Mandatory = $false)]
    [string]$Prompt,

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [string]$Model,

    [Parameter(Mandatory = $false)]
    [ValidateSet("low", "medium", "high")]
    [string]$Effort,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 0
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Validate project
# ------------------------------------------------------------

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)

if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
    throw "Project directory does not exist: $ProjectDir"
}

# ------------------------------------------------------------
# Locate Antigravity
# ------------------------------------------------------------

$AgyCommand = Get-Command agy -ErrorAction SilentlyContinue

if ($AgyCommand) {
    $AgyExe = $AgyCommand.Source
}
else {
    $FallbackAgy = Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"

    if (Test-Path -LiteralPath $FallbackAgy) {
        $AgyExe = $FallbackAgy
    }
    else {
        throw "Antigravity CLI (agy) was not found."
    }
}

# ------------------------------------------------------------
# Resolve executor prompt
# ------------------------------------------------------------

if ($PromptFile) {

    $PromptFile = [System.IO.Path]::GetFullPath($PromptFile)

    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        throw "Prompt file does not exist: $PromptFile"
    }

    $TaskPrompt = Get-Content -LiteralPath $PromptFile -Raw
}
elseif ($Prompt) {
    $TaskPrompt = $Prompt
}
else {
    throw "Provide either -Prompt or -PromptFile."
}

if ([string]::IsNullOrWhiteSpace($TaskPrompt)) {
    throw "Executor prompt is empty."
}

# ------------------------------------------------------------
# Build executor prompt
# ------------------------------------------------------------

$ExecutorPrompt = @"
You are the ANTIGRAVITY IMPLEMENTATION EXECUTOR.

The target project workspace is:

$ProjectDir

IMPORTANT ROLE BOUNDARY:

You are the implementation executor.
The parent Codex or Claude agent is the planner and reviewer.

Execute the requested implementation completely.

MANDATORY RULES:

1. Work on the supplied target project.
2. Inspect relevant project files before editing.
3. Complete every requested implementation step.
4. Continue automatically through the entire task.
5. Do not stop after one file edit or one successful command.
6. Use your file and terminal tools to perform the actual work.
7. Run all required tests/checks.
8. Fix mechanical implementation errors you encounter.
9. Verify the requested acceptance criteria before finishing.
10. Do not make unrelated changes.
11. Do not redesign architecture unless explicitly instructed.
12. Do not change requirements.
13. Do not use web search unless the task explicitly requires it.
14. Do not delegate this work to another agent.
15. Do not modify files outside the supplied project unless the task explicitly requires it.
16. Do not claim success merely because a command was attempted.
17. Report failures honestly.

TASK:

$TaskPrompt

FINAL RESPONSE:

Report:

STATUS: COMPLETE or BLOCKED

SUMMARY:
What you implemented.

FILES CHANGED:
Files you actually changed.

TESTS:
Commands/checks actually executed and their results.

ACCEPTANCE CRITERIA:
What passed or failed.

ISSUES:
Anything unresolved.

Remember: your textual report is not the final authority.
The parent reviewer will independently inspect the actual workspace.
"@

# ------------------------------------------------------------
# Build agy arguments
# ------------------------------------------------------------

$Arguments = @(
    "--print", $ExecutorPrompt,
    "--add-dir", $ProjectDir,
    "--mode", "accept-edits",
    "--dangerously-skip-permissions"
)

if ($Model) {
    $Arguments += @("--model", $Model)
}

if ($Effort) {
    $Arguments += @("--effort", $Effort)
}

if ($TimeoutSeconds -le 0) {
    $Arguments += @("--print-timeout", "0s")
}
else {
    $Arguments += @("--print-timeout", "$($TimeoutSeconds)s")
}

# ------------------------------------------------------------
# Execute
# ------------------------------------------------------------

$ResultFile = Join-Path $ProjectDir "ANTIGRAVITY_EXECUTOR_RESULT.md"

Write-Host ""
Write-Host "=============================================="
Write-Host " ANTIGRAVITY EXECUTOR"
Write-Host "=============================================="
Write-Host "Project : $ProjectDir"

if ($Model) {
    Write-Host "Model   : $Model"
}
else {
    Write-Host "Model   : Antigravity default"
}

if ($Effort) {
    Write-Host "Effort  : $Effort"
}
else {
    Write-Host "Effort  : Antigravity default"
}

Write-Host "Auto approval: ENABLED"
Write-Host ""

Push-Location $ProjectDir

try {

    $Output = & $AgyExe @Arguments 2>&1
    $ExitCode = $LASTEXITCODE

    $OutputText = ($Output | Out-String).TrimEnd()

    $Report = @"
# Antigravity Executor Result

Exit code: $ExitCode
Model: $(if ($Model) { $Model } else { "default" })
Effort: $(if ($Effort) { $Effort } else { "default" })
Project: $ProjectDir

## Executor Output

$OutputText
"@

    Set-Content `
        -LiteralPath $ResultFile `
        -Value $Report `
        -Encoding UTF8

    if ($OutputText) {
        Write-Host $OutputText
    }

    Write-Host ""
    Write-Host "Executor report:"
    Write-Host $ResultFile
    Write-Host ""
    Write-Host "Exit code: $ExitCode"

    exit $ExitCode
}
finally {
    Pop-Location
}
