<#
.SYNOPSIS
    Tests the example rules files against sample pull requests and scores the reviews.

.DESCRIPTION
    Each stack under evals/ has sample changes: some with planted bugs, some clean. For every
    sample this script builds the exact prompt the pipeline sends (shared base prompt, the
    stack's rules file from examples/rules/, the line-numbered diff in its untrusted fence),
    asks a model for a review, and checks the answer against the sample's expect.json:

      caught      a comment within a couple of lines of the planted bug, at or above its severity
      underrated  a comment in the right place at a lower severity
      missed      no comment there
      noise       a CRITICAL or WARNING comment on a clean sample

    A stack passes when every planted CRITICAL is caught, at least -MinWarningRecall of planted
    WARNINGs are caught, and no clean sample gets a CRITICAL or WARNING comment. Results vary
    between runs, so use -Runs 3 before calling a rules file done.

    -Provider manual makes no model call: it writes each sample's prompt to -WorkDir, and scores
    any answer JSON found there as <stack>/<sample>.answer.json. That is how a rules file is
    checked by hand or with a model reached some other way.

.EXAMPLE
    $env:ANTHROPIC_API_KEY = '...'
    ./tools/Invoke-RulesEval.ps1 -Provider anthropic -Model claude-haiku-5-5 -Stack nextjs

.EXAMPLE
    ./tools/Invoke-RulesEval.ps1 -Provider azure -Model gpt-5-mini `
        -Endpoint 'https://<resource>.openai.azure.com/openai/v1/chat/completions' -ApiKey $env:AZURE_OPENAI_KEY
#>
[CmdletBinding()]
param(
    [ValidateSet('anthropic', 'openai', 'azure', 'manual')]
    [string]$Provider = 'manual',
    [string]$Model = '',
    [string]$ApiKey = '',
    [string]$Endpoint = '',
    [string]$ReasoningEffort = '',
    [string[]]$Stack = @(),
    [ValidateRange(1, 10)]
    [int]$Runs = 1,
    [double]$MinWarningRecall = 0.8,
    [string]$WorkDir = '',
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RulesEval.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$evalRoot = Join-Path $repoRoot 'evals'
$rulesRoot = Join-Path $repoRoot 'examples' 'rules'
$basePrompt = Join-Path $repoRoot 'ai-code-review' 'prompts' 'base.codereviewprompt.md'

if ($Provider -ne 'manual') {
    if (-not $Model) { throw '-Model is required unless -Provider is manual.' }
    if (-not $ApiKey) {
        $ApiKey = switch ($Provider) {
            'anthropic' { $env:ANTHROPIC_API_KEY }
            'openai' { $env:OPENAI_API_KEY }
            'azure' { $env:AZURE_OPENAI_API_KEY }
        }
    }
    if (-not $ApiKey) { throw "No API key: pass -ApiKey or set the provider's environment variable." }
    if ($Provider -eq 'azure' -and -not $Endpoint) { throw '-Endpoint is required for -Provider azure.' }
}
if (-not $WorkDir) { $WorkDir = Join-Path $repoRoot 'evals' '.work' }

$stacks = @(Get-ChildItem -Directory -Path $evalRoot | Where-Object { -not $_.Name.StartsWith('.') } | ForEach-Object Name)
if ($Stack.Count -gt 0) {
    $unknown = @($Stack | Where-Object { $_ -notin $stacks })
    if ($unknown) { throw "No samples for: $($unknown -join ', ')" }
    $stacks = $Stack
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("# Rules eval: $Provider $Model")
$report.Add('')
$report.Add('| Stack | Run | CRITICAL caught | WARNING caught | Noise on clean | Other comments | Result |')
$report.Add('| --- | --- | --- | --- | --- | --- | --- |')
$details = [System.Collections.Generic.List[string]]::new()
$allPass = $true
$inputTokens = 0
$outputTokens = 0

foreach ($stackName in $stacks) {
    $rulesFile = Join-Path $rulesRoot "$stackName.rules.md"
    if (-not (Test-Path $rulesFile)) { throw "Samples exist for '$stackName' but $rulesFile does not." }
    $systemPrompt = Get-SystemPromptText -PathToReviewFile $rulesFile -PromptMode 'rules' -BasePromptFile $basePrompt
    $cases = @(Get-ChildItem -Directory -Path (Join-Path $evalRoot $stackName) | Sort-Object Name | ForEach-Object { Get-EvalCase -CasePath $_.FullName })

    for ($run = 1; $run -le $Runs; $run++) {
        $caseResults = [System.Collections.Generic.List[object]]::new()
        foreach ($case in $cases) {
            $diff = Get-EvalCaseDiff -CasePath $case.Path
            # Validate every anchor before spending tokens on the sample.
            foreach ($finding in $case.Findings) { [void](Resolve-FindingLine -Finding $finding -Diff $diff) }
            $userMessage = New-UntrustedDiffText -Changes $diff.Changes

            if ($Provider -eq 'manual') {
                $caseDir = Join-Path $WorkDir $stackName
                New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
                Set-Content -Path (Join-Path $caseDir "$($case.Name).prompt.md") -Encoding utf8NoBOM -Value ("<system>`n$systemPrompt`n</system>`n`n<user>`n$userMessage`n</user>")
                $answerPath = Join-Path $caseDir "$($case.Name).answer.json"
                if (-not (Test-Path $answerPath)) { continue }
                $reviews = ConvertFrom-ModelReviewJson -Content (Get-Content -Raw -Path $answerPath)
            }
            else {
                $answer = Invoke-EvalModel -Provider $Provider -Model $Model -ApiKey $ApiKey -Endpoint $Endpoint -SystemPrompt $systemPrompt -UserMessage $userMessage -ReasoningEffort $ReasoningEffort
                $reviews = $answer.Reviews
                $inputTokens += $answer.InputTokens
                $outputTokens += $answer.OutputTokens
            }

            $result = Measure-EvalCase -Case $case -Diff $diff -Reviews $reviews
            $caseResults.Add($result)
            foreach ($f in $result.Findings) {
                if ($f.Status -ne 'caught') { $details.Add("- ${stackName}/$($case.Name) run ${run}: $($f.Id) (line $($f.Line), $($f.MinSeverity)) $($f.Status)") }
            }
            foreach ($n in $result.Noise) {
                if ($result.Clean) { $details.Add("- ${stackName}/$($case.Name) run ${run}: noise $($n.severity) on line $($n.lineNumber): $(([string]$n.comment -split "`n")[0])") }
            }
        }

        if ($caseResults.Count -eq 0) {
            $report.Add("| $stackName | $run | - | - | - | - | prompts written |")
            continue
        }
        $verdict = Get-StackVerdict -CaseResults $caseResults -MinWarningRecall $MinWarningRecall
        if (-not $verdict.Pass) { $allPass = $false }
        $resultText = if ($verdict.Pass) { 'pass' } else { 'FAIL: ' + ($verdict.Reasons -join '; ') }
        $report.Add("| $stackName | $run | $($verdict.CriticalCaught)/$($verdict.CriticalTotal) | $($verdict.WarningCaught)/$($verdict.WarningTotal) | $($verdict.CleanNoise) | $($verdict.Extras) | $resultText |")
    }
}

if ($details.Count -gt 0) {
    $report.Add('')
    $report.Add('## Misses and noise')
    $report.Add('')
    foreach ($line in $details) { $report.Add($line) }
}
if ($Provider -ne 'manual') {
    $report.Add('')
    $report.Add("Tokens: $inputTokens in, $outputTokens out.")
}

$text = $report -join "`n"
Write-Output $text
if ($ReportPath) { Set-Content -Path $ReportPath -Value $text -Encoding utf8NoBOM }
if (-not $allPass) { exit 1 }
