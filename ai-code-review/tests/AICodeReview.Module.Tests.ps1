BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'AICodeReview.psd1'
    $script:Public = @(
        'Format-ReviewSummary', 'Get-CodeChanges', 'Get-EngineVersion', 'Get-ExistingReviewThreads',
        'Get-ReviewErrorInfo', 'Invoke-LLMCodeReview', 'Set-PullRequestComments'
    )
    Remove-Module AICodeReview -ErrorAction SilentlyContinue
    Import-Module $script:ManifestPath -Force
}

AfterAll {
    Remove-Module AICodeReview -ErrorAction SilentlyContinue
}

Describe 'AICodeReview module (F-32)' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports exactly the functions the pipeline template calls' {
        $exported = @((Get-Module AICodeReview).ExportedFunctions.Keys | Sort-Object)
        $exported | Should -Be ($script:Public | Sort-Object)
    }

    It 'keeps the internal helpers private' {
        foreach ($name in @('Protect-LogText', 'New-UntrustedDiffText', 'Invoke-LLMRequestWithRetry', 'Get-FoundryAccessToken', 'ConvertTo-PrefixedReviewComment')) {
            Get-Command -Module AICodeReview -Name $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'lists the same functions in the manifest and in Export-ModuleMember' {
        $manifest = Import-PowerShellDataFile $script:ManifestPath
        @($manifest.FunctionsToExport | Sort-Object) | Should -Be ($script:Public | Sort-Object)
    }

    It 'resolves calls across the script files from inside the module' {
        Mock -ModuleName AICodeReview Get-CodeChanges {
            [PSCustomObject]@{ FilesReviewed = 0; FilesDeleted = 0; TotalFilesChanged = 2; FilesExcluded = @('a', 'b') }
        }
        $result = Invoke-LLMCodeReview -SourceBranch s -TargetBranch t -PathToReviewFile 'unused.md' -ModelName m `
            -ModelDeploymentUrl u -Key k 6>$null
        $result.Content | Should -Be '{"reviews":[]}'
        Should -Invoke -ModuleName AICodeReview Get-CodeChanges -Times 1
    }

    It 'finds the shipped base prompt from inside the module' {
        InModuleScope AICodeReview {
            $base = Join-Path (Split-Path (Get-Command Invoke-LLMCodeReview).ScriptBlock.File) 'prompts/base.codereviewprompt.md'
            Test-Path $base | Should -BeTrue
        }
    }
}

Describe 'stage-template.yml loads the module' {
    BeforeAll { $script:Yaml = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'stage-template.yml') }

    It 'imports the module manifest' {
        $script:Yaml | Should -Match 'Import-Module "\$\(Pipeline\.Workspace\)/templates/ai-code-review/AICodeReview\.psd1"'
    }

    It 'no longer dot-sources the script files' {
        $script:Yaml | Should -Not -Match '\.\s+"\$\(Pipeline\.Workspace\)/templates/ai-code-review/[A-Za-z-]+\.ps1"'
    }

    It 'only calls engine functions the module exports' {
        $engineFunctions = InModuleScope AICodeReview { @(Get-ChildItem function: | Where-Object { $_.ScriptBlock.Module.Name -eq 'AICodeReview' } | ForEach-Object Name) }
        foreach ($name in $engineFunctions) {
            if ($script:Yaml -match "\b$([regex]::Escape($name))\b") { $script:Public | Should -Contain $name }
        }
    }
}
