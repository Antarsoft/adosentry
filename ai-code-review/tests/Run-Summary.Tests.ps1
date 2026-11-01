BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Get-CodeChanges.ps1')
    . (Join-Path $PSScriptRoot '..' 'Invoke-LLMCodeReview.ps1')
}

Describe 'Format-ReviewSummary (F-28)' {
    BeforeAll {
        $script:Review = [PSCustomObject]@{
            FilesReviewed = 4; TotalFilesChanged = 6; FilesExcluded = 1; FilesRenamed = 2; FilesDeleted = 1
            BatchCount = 2; FailedBatches = @(); TotalTokens = 12345; LatencyMs = 41200
        }
        $script:Post = [PSCustomObject]@{
            CommentsPosted = 2; CommentsProposed = 3; CommentsSkippedDuplicate = 1
            SeverityBreakdown = @{ critical = 1; warning = 1; suggestion = 0; unknown = 0 }
        }
    }

    It 'puts the whole run on one line' {
        $line = Format-ReviewSummary -ReviewResult $script:Review -PostResult $script:Post -Outcome 'commented'
        $line | Should -Not -Match "`n"
        $line | Should -Match 'outcome=commented'
        $line | Should -Match 'files 4 reviewed of 6 changed \(1 excluded, 2 renamed, 1 deleted listed\)'
        $line | Should -Match 'batches 2 \(0 failed\)'
        $line | Should -Match 'comments 2 posted of 3 proposed \(1 duplicate; critical 1, warning 1, suggestion 0\)'
        $line | Should -Match 'tokens 12345'
        $line | Should -Match 'model time 41.2s'
    }

    It 'shows the error type and the failed batches for a partial run' {
        $review = $script:Review.PSObject.Copy()
        $review.FailedBatches = @([PSCustomObject]@{ Batch = 2 })
        $line = Format-ReviewSummary -ReviewResult $review -PostResult $script:Post -Outcome 'partial' -ErrorType 'llm-api-error'
        $line | Should -Match 'outcome=partial \| error=llm-api-error'
        $line | Should -Match 'batches 2 \(1 failed\)'
    }

    It 'shows truncated files and split batches (F-02)' {
        $review = $script:Review.PSObject.Copy()
        $review | Add-Member -NotePropertyName FilesTruncated -NotePropertyValue 1
        $review | Add-Member -NotePropertyName BatchesSplit -NotePropertyValue 2
        $line = Format-ReviewSummary -ReviewResult $review -PostResult $script:Post -Outcome 'commented'
        $line | Should -Match '1 truncated as too large'
        $line | Should -Match 'batches 2 \(0 failed, 2 split\)'
    }

    It 'shows moved and dropped comments (F-19)' {
        $review = $script:Review.PSObject.Copy()
        $review | Add-Member -NotePropertyName CommentsSnapped -NotePropertyValue 2
        $review | Add-Member -NotePropertyName CommentsInvalid -NotePropertyValue 1
        (Format-ReviewSummary -ReviewResult $review -PostResult $script:Post -Outcome 'commented') | Should -Match 'anchors 2 moved, 1 dropped'
    }

    It 'stays quiet about anchors when nothing was moved or dropped' {
        (Format-ReviewSummary -ReviewResult $script:Review -PostResult $script:Post -Outcome 'commented') | Should -Not -Match 'anchors'
    }

    It 'still produces a line when the review never produced a result' {
        Format-ReviewSummary -ReviewResult $null -PostResult $null -Outcome 'error' -ErrorType 'llm-api-error' |
            Should -Be 'AI Code Review summary: outcome=error | error=llm-api-error'
    }
}

Describe 'Get-EngineVersion (F-28)' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("ev-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        git -C $script:Dir init -q -b main
        git -C $script:Dir config user.email t@example.com
        git -C $script:Dir config user.name Test
        git -C $script:Dir config commit.gpgsign false
        Set-Content -Path (Join-Path $script:Dir 'a.txt') -Value 'a'
        git -C $script:Dir add -A
        git -C $script:Dir commit -q -m one
    }
    AfterEach { Remove-Item -Recurse -Force $script:Dir -ErrorAction SilentlyContinue }

    It 'returns the tag the checkout is on' {
        git -C $script:Dir tag v5
        Get-EngineVersion -TemplatesPath $script:Dir | Should -Be 'v5'
    }

    It 'returns the short commit when there is no tag' {
        $sha = git -C $script:Dir rev-parse --short HEAD
        Get-EngineVersion -TemplatesPath $script:Dir | Should -Be $sha
    }

    It 'returns unknown when the path is not a git checkout' {
        $plain = Join-Path ([IO.Path]::GetTempPath()) ("nogit-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $plain | Out-Null
        try { Get-EngineVersion -TemplatesPath $plain | Should -Be 'unknown' }
        finally { Remove-Item -Recurse -Force $plain }
    }
}

Describe 'stage-template.yml' {
    BeforeAll { $script:Yaml = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'stage-template.yml') }

    It 'does not leave git credentials on the agent (F-25)' {
        $script:Yaml | Should -Not -Match 'persistCredentials:\s*true'
    }

    It 'declares every parameter it uses' {
        $declared = [regex]::Matches($script:Yaml, '(?m)^  - name: (\w+)$') | ForEach-Object { $_.Groups[1].Value }
        $used = [regex]::Matches($script:Yaml, '\$\{\{[^}]*\bparameters\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        $used | Should -Contain 'promptFile'
        foreach ($name in $used) { $declared | Should -Contain $name }
    }

    It 'passes the new engine options through' {
        $script:Yaml | Should -Match 'reviewDeletedFiles'
        $script:Yaml | Should -Match 'reviewDefaultExcludes'
    }

    It 'passes the token limits and reports truncation and splits (F-02)' {
        $script:Yaml | Should -Match '-MaxBatchTokens \$\{\{ parameters.reviewMaxBatchTokens \}\}'
        $script:Yaml | Should -Match '-MaxFileTokens \$\{\{ parameters.reviewMaxFileTokens \}\}'
        $script:Yaml | Should -Match 'filesTruncated'
        $script:Yaml | Should -Match 'batchesSplit'
    }

    It 'defaults to the rules prompt mode and passes the mode and base prompt to the engine (F-34, E5)' {
        $script:Yaml | Should -Match '(?s)name: promptMode\s+type: string\s+default: "rules"'
        $script:Yaml | Should -Match "-PromptMode '\$\{\{ parameters.promptMode \}\}'"
        $script:Yaml | Should -Match 'templates/ai-code-review/prompts/base.codereviewprompt.md'
    }

    It 'passes the collection URL so every Azure DevOps host works (E2)' {
        $script:Yaml | Should -Not -Match 'dev\.azure\.com'
        $script:Yaml | Should -Not -Match '-Organization '
        ([regex]::Matches($script:Yaml, '-CollectionUri \$env:AICR_COLLECTION_URI')).Count | Should -Be 2
        $script:Yaml | Should -Match '(?m)^\s+AICR_COLLECTION_URI: \$\(System\.CollectionUri\)$'
    }

    It 'defaults to Entra auth for the model (E1)' {
        $script:Yaml | Should -Match '(?s)name: foundryAuth\s+type: string\s+default: "entra"'
        $script:Yaml | Should -Match "-AuthMode '\$\{\{ parameters.foundryAuth \}\}'"
    }

    It 'maps the model key into the step only for key auth (E1)' {
        $script:Yaml | Should -Match "(?m)^\s+\$\{\{ if eq\(parameters\.foundryAuth, 'key'\) \}\}:\r?\n\s+FOUNDRY_KEY: \$\(foundry-key\)"
        ([regex]::Matches($script:Yaml, 'FOUNDRY_KEY:')).Count | Should -Be 1
    }

    It 'sends no metrics key header when aiMetricsApiKey is unset (E4)' {
        $script:Yaml | Should -Match "\`$metricsKey -and -not \`$metricsKey\.StartsWith\('\`$\('\)"
        $script:Yaml | Should -Not -Match "'X-Api-Key' = \`$env:AI_METRICS_API_KEY"
    }

    It 'still offers the legacy prompt mode (E5)' {
        $script:Yaml | Should -Match '(?s)name: promptMode\s+type: string\s+default: "rules"\s+values:\s+- rules\s+- legacy'
    }

    It 'runs the stage only for pull request builds (E7)' {
        $script:Yaml | Should -Match "(?m)^  - stage: AICodeReview\r?\n(?:    .*\r?\n)*?    condition: and\(succeeded\(\), eq\(variables\['Build\.Reason'\], 'PullRequest'\)\)"
    }

    It 'fails the run on a review error by default' {
        $script:Yaml | Should -Match '(?s)name: continueOnError\s+type: boolean\s+default: false'
    }
}

Describe 'stage-template.yml quoting (E8)' {
    BeforeAll {
        $script:Yaml = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'stage-template.yml')
        $script:Inline = [regex]::Match($script:Yaml, '(?s)Inline: \|\r?\n(.*?)\r?\n            env:').Groups[1].Value

        # Expands the template expressions the way Azure Pipelines would for the given parameter
        # values, so the result can be parsed as the PowerShell the agent runs.
        function Expand-Inline([hashtable]$Values) {
            $text = $script:Inline
            foreach ($name in $Values.Keys) {
                $text = $text.Replace("`${{ replace(parameters.$name, '''', '''''') }}", $Values[$name].Replace("'", "''"))
                $text = $text.Replace("`${{ parameters.$name }}", $Values[$name])
            }
            $text
        }
    }

    It 'finds the inline script' {
        $script:Inline | Should -Match 'Invoke-LLMCodeReview'
    }

    It 'doubles single quotes in every free-text string parameter' -ForEach @(
        @{ Name = 'promptFile' }, @{ Name = 'reviewPathSpec' }, @{ Name = 'reviewExcludePathSpec' }, @{ Name = 'foundryTokenResource' }
    ) {
        $script:Inline | Should -Not -Match "\$\{\{ parameters\.$Name \}\}"
        $script:Inline | Should -Match ([regex]::Escape("`${{ replace(parameters.$Name, '''', '''''') }}"))
    }

    It 'keeps a quote in a parameter inside its string' {
        $values = @{
            promptFile = "rules/it's.rules.md"; reviewPathSpec = "src/o'brien/**"; reviewExcludePathSpec = "docs/'x'"
            foundryTokenResource = 'https://ai.azure.com'; foundryAuth = 'entra'; promptMode = 'rules'
            reviewMaxFilesPerBatch = '25'; reviewMaxBatchTokens = '300000'; reviewMaxFileTokens = '80000'
            reviewDeletedFiles = 'False'; reviewDefaultExcludes = 'True'
        }
        $expanded = Expand-Inline $values
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($expanded, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-LLMCodeReview' }, $true)
        $elements = @($call.CommandElements)
        $argumentFor = {
            param($parameter)
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq $parameter) {
                    return $elements[$i + 1].SafeGetValue()
                }
            }
        }
        & $argumentFor 'PathToReviewFile' | Should -Be '$(Build.SourcesDirectory)/rules/it''s.rules.md'
        & $argumentFor 'PathSpec' | Should -Be "src/o'brien/**"
        & $argumentFor 'ExcludePathSpec' | Should -Be "docs/'x' rules/it's.rules.md"
    }

    It 'passes pull request and repository names through the environment, not the script text' -ForEach @(
        @{ Macro = 'System.PullRequest.SourceBranch' }, @{ Macro = 'System.PullRequest.TargetBranch' }
        @{ Macro = 'System.PullRequest.PullRequestId' }, @{ Macro = 'System.TeamProject' }
        @{ Macro = 'Build.Repository.Name' }, @{ Macro = 'System.CollectionUri' }
    ) {
        $script:Inline | Should -Not -Match ([regex]::Escape("`$($Macro)"))
        $script:Yaml | Should -Match "(?m)^              AICR_\w+: $([regex]::Escape("`$($Macro)"))\r?$"
    }

    It 'does not expand a secret macro anywhere in the inline script' {
        $script:Inline | Should -Not -Match '\$\((foundry-key|aiMetricsApiKey)\)'
    }
}
