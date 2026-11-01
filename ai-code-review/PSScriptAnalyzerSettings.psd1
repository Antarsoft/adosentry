# PSScriptAnalyzer settings for the ai-code-review engine (used by .azuredevops/ai-code-review-ci.yml and .github/workflows/ci.yml).
# Every finding at Error or Warning fails CI, except the rules below, which the engine breaks on purpose.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts run inside a pipeline step; Write-Host is how they write to the job log.
        'PSAvoidUsingWriteHost',
        # Function names such as Get-CodeChanges and Set-PullRequestComments are the template's public surface.
        'PSUseSingularNouns',
        # Nothing runs interactively, so -WhatIf / -Confirm support adds nothing.
        'PSUseShouldProcessForStateChangingFunctions',
        # The files are UTF-8 without a BOM (they contain emoji); PowerShell 7 reads them correctly.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
