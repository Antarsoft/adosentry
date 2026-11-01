# AI code review engine as a PowerShell module.
# The functions live in the script files next to this one; the module loads them and
# exports only what stage-template.yml calls. Everything else (batching, fencing, retries,
# fingerprints, log redaction) stays private to the module.

foreach ($file in @(
        'Resolve-AdoCollectionUrl.ps1',
        'Get-CodeChanges.ps1',
        'Get-ExistingReviewThreads.ps1',
        'Invoke-LLMCodeReview.ps1',
        'Set-PullRequestComments.ps1'
    )) {
    . (Join-Path $PSScriptRoot $file)
}

Export-ModuleMember -Function @(
    'Get-CodeChanges',
    'Get-ExistingReviewThreads',
    'Invoke-LLMCodeReview',
    'Set-PullRequestComments',
    'Format-ReviewSummary',
    'Get-ReviewErrorInfo',
    'Get-MetricsRequestHeaders',
    'Get-EngineVersion'
)
