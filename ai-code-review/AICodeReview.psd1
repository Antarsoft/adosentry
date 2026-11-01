@{
    RootModule           = 'AICodeReview.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'd08a2541-4c52-43a2-99d8-f68743e2d39f'
    Author               = 'PullPicket contributors'
    Description          = 'AI pull request review for Azure DevOps pipelines (used by stage-template.yml).'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Get-CodeChanges',
        'Get-ExistingReviewThreads',
        'Invoke-LLMCodeReview',
        'Set-PullRequestComments',
        'Format-ReviewSummary',
        'Get-ReviewErrorInfo',
        'Get-MetricsRequestHeaders',
        'Get-EngineVersion'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
