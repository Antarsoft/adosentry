#Requires -Version 7.0
<#
.SYNOPSIS
    Estimates what reviewRepoContext adds to a review, without calling a model.

.DESCRIPTION
    Builds the review input for the changes between two commits the way the review stage does,
    with and without repository context, and prints the estimated prompt tokens per batch (about
    3.5 characters per token, the engine's own estimate). Run it in a clone of the repository you
    want to review, to see the extra cost before you turn the setting on.

    With -OutputPath, each batch's repository context is also written to a text file, so you can
    read exactly what the model would get.

.EXAMPLE
    pwsh tools/Measure-RepoContext.ps1 -TargetRef origin/main -SourceRef origin/feature/login

.EXAMPLE
    pwsh tools/Measure-RepoContext.ps1 -TargetRef 1a2b3c4 -SourceRef 5d6e7f8 -MaxTokens 8000 -OutputPath ./context
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRef,
    [Parameter(Mandatory)][string]$SourceRef,
    [int]$MaxTokens = 12000,
    [int]$MaxBatchTokens = 300000,
    [string]$PromptFile = '',
    [string]$OutputPath = ''
)

# No strict mode: the engine scripts are written for the pipeline's default mode.
$ErrorActionPreference = 'Stop'

$engine = Join-Path $PSScriptRoot '..' 'ai-code-review'
. (Join-Path $engine 'Get-CodeChanges.ps1')
. (Join-Path $engine 'Get-RepoContext.ps1')

$basePrompt = Join-Path $engine 'prompts' 'base.codereviewprompt.md'
$systemText = (Get-Content -Raw $basePrompt)
if ($PromptFile) { $systemText += "`n`n" + (Get-Content -Raw $PromptFile) }
$systemTokens = Get-EstimatedTokenCount -Text $systemText

$changes = Get-CodeChanges -TargetBranch $TargetRef -SourceBranch $SourceRef -MaxBatchTokens $MaxBatchTokens 6>$null
$options = New-RepoContextOptions -SourceBranch $SourceRef -MaxTokens $MaxTokens 6>$null
if ($OutputPath) { New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null }

$rows = [System.Collections.Generic.List[object]]::new()
$number = 0
foreach ($batch in @($changes.Batches)) {
    $number++
    if (-not $batch.FilesReviewed) { continue }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $context = New-BatchRepoContext -Batch $batch -Options $options
    $timer.Stop()
    $diffTokens = Get-EstimatedTokenCount -Text $batch.Changes
    $rows.Add([PSCustomObject]@{
            Batch          = $number
            Files          = $batch.FilesReviewed
            PromptTokens   = $systemTokens + $diffTokens
            ContextTokens  = $context.Tokens
            ContextFiles   = $context.Files
            IncreasePct    = [Math]::Round(100 * $context.Tokens / ($systemTokens + $diffTokens), 0)
            BuildMs        = $timer.ElapsedMilliseconds
        })
    if ($OutputPath) {
        Set-Content -Path (Join-Path $OutputPath "batch-$number-context.txt") -Value $context.Text
    }
}

Write-Output ($rows | Format-Table -AutoSize | Out-String -Width 160)
$prompt = [int](@($rows | ForEach-Object { $_.PromptTokens }) | Measure-Object -Sum).Sum
$extra = [int](@($rows | ForEach-Object { $_.ContextTokens }) | Measure-Object -Sum).Sum
if ($prompt -gt 0) {
    Write-Output ("Prompt tokens without context: about {0:N0}. Repository context adds about {1:N0} ({2:N0}%)." -f $prompt, $extra, (100 * $extra / $prompt))
}
