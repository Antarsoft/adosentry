BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Resolve-AdoCollectionUrl.ps1')
    . (Join-Path $PSScriptRoot '..' 'Set-PullRequestComments.ps1')
    function Get-AzAccessToken { param($ResourceUrl, [switch]$AsSecureString) [PSCustomObject]@{ token = (ConvertTo-SecureString 'x' -AsPlainText -Force) } }
    $script:Posted = @()
    Mock Invoke-RestMethod {
        if ($Method -eq 'Post') { $script:Posted += $Body; return [PSCustomObject]@{ id = 1 } }
        return [PSCustomObject]@{ authenticatedUser = [PSCustomObject]@{ id = 'u' } }
    }
    function Invoke-Post($Reviews, $Existing = @()) {
        $script:Posted = @()
        Set-PullRequestComments -Organization o -PullRequestId 1 -RepositoryName r -Project p -Reviews ($Reviews | ConvertTo-Json -Depth 5 -Compress) -ExistingThreads $Existing 6>$null 3>$null
    }
}

Describe 'Set-PullRequestComments pull-request-level comments' {
    It 'posts lineNumber 0 without a threadContext and names the file in the text' {
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'infra/db.tf'; lineNumber = 0; comment = '⚠️ WARNING: removes the database module' }) }
        $r.CommentsPosted | Should -Be 1
        $r.FilesWithComments.Count | Should -Be 0
        $body = $script:Posted[0] | ConvertFrom-Json
        $body.PSObject.Properties.Name | Should -Not -Contain 'threadContext'
        $body.comments[0].content | Should -Match 'infra/db.tf'
    }

    It 'skips a repeat of an existing pull-request-level thread' {
        $existing = @([PSCustomObject]@{ FileName = '(pull request)'; LineNumber = 0; CommentText = "⚠️ WARNING: removes the database module`n`nFile: ``/infra/db.tf``" })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'infra/db.tf'; lineNumber = 0; comment = '⚠️ WARNING: removes the database module' }) } $existing
        $r.CommentsPosted | Should -Be 0
        $r.CommentsSkippedDuplicate | Should -Be 1
    }

    It 'still anchors ordinary comments to the file and line' {
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'a.ts'; lineNumber = 7; comment = '💡 SUGGESTION: rename this' }) }
        $body = $script:Posted[0] | ConvertFrom-Json
        $body.threadContext.filePath | Should -Be '/a.ts'
        $body.threadContext.rightFileStart.line | Should -Be 7
        $r.FilesWithComments | Should -Contain '/a.ts'
    }

    It 'does not let a deletion comment about one file suppress a similar one about another file' {
        $existing = @([PSCustomObject]@{ FileName = '(pull request)'; LineNumber = 0; CommentText = "⚠️ WARNING: removes the database module`n`nFile: ``/infra/db.tf``" })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'infra/cache.tf'; lineNumber = 0; comment = '⚠️ WARNING: removes the database module' }) } $existing
        $r.CommentsPosted | Should -Be 1
    }
}

Describe 'Set-PullRequestComments reworded duplicates (F-40)' {
    BeforeAll {
        $script:First = '⚠️ WARNING: This pipeline now consumes the moving `main` branch of the shared templates repository, so a future template change can alter builds or reviews without any change to this repository. Prefer pinning to a versioned tag or commit SHA for reproducible and controlled pipeline behavior.'
        $script:Reworded = '⚠️ WARNING: Referencing the shared pipeline templates from the mutable `main` branch makes builds non-reproducible and allows unreviewed template changes to affect this pipeline. Pin this dependency to a reviewed immutable tag or commit instead.'
        $script:Unrelated = '⚠️ WARNING: This query interpolates user input directly into the SQL string, which allows injection. Use parameterized queries instead.'
        function New-Existing($Text, $File = '/pipelines/pr-pipelines.yml', $Line = 20) {
            @([PSCustomObject]@{ FileName = $File; LineNumber = $Line; Severity = 'WARNING'; CommentText = $Text; Status = 'active' })
        }
    }

    It 'skips a reworded repeat of the same finding on the same line and severity' {
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'pipelines/pr-pipelines.yml'; lineNumber = 20; comment = $script:Reworded }) } (New-Existing $script:First)
        $r.CommentsPosted | Should -Be 0
        $r.CommentsSkippedDuplicate | Should -Be 1
    }

    It 'still posts an unrelated comment of the same severity on the same line' {
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'pipelines/pr-pipelines.yml'; lineNumber = 20; comment = $script:Unrelated }) } (New-Existing $script:First)
        $r.CommentsPosted | Should -Be 1
    }

    It 'posts the reworded finding when the severity differs' {
        $suggestion = $script:Reworded -replace '^⚠️ WARNING', '💡 SUGGESTION'
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'pipelines/pr-pipelines.yml'; lineNumber = 20; comment = $suggestion }) } (New-Existing $script:First)
        $r.CommentsPosted | Should -Be 1
    }

    It 'posts the reworded finding when it is more than three lines away' {
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'pipelines/pr-pipelines.yml'; lineNumber = 40; comment = $script:Reworded }) } (New-Existing $script:First)
        $r.CommentsPosted | Should -Be 1
    }

    It 'posts the reworded finding in a different file' {
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'other.yml'; lineNumber = 20; comment = $script:Reworded }) } (New-Existing $script:First)
        $r.CommentsPosted | Should -Be 1
    }

    It 'skips a reworded pull-request-level repeat about the same file' {
        $existing = @([PSCustomObject]@{ FileName = '(pull request)'; LineNumber = 0; Severity = 'WARNING'; Status = 'active'
            CommentText = "⚠️ WARNING: Deleting the health-check endpoint may break load-balancer probes that rely on /api/health.`n`nFile: ``/src/app/api/health/route.ts``" })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'src/app/api/health/route.ts'; lineNumber = 0; comment = '⚠️ WARNING: Removing the /api/health route can break platform health probes and mark healthy deployments unavailable.' }) } $existing
        $r.CommentsPosted | Should -Be 0
    }
}

Describe 'Set-PullRequestComments fingerprints and in-run repeats (F-18)' {
    BeforeAll {
        $script:Pin = '⚠️ WARNING: This pipeline now consumes the moving `main` branch of the shared templates repository, so a future template change can alter builds without any change to this repository. Prefer pinning to a versioned tag.'
        $script:PinReworded = '⚠️ WARNING: Referencing the mutable `main` branch of the shared templates makes builds non-reproducible. Pin it to an immutable tag or commit.'
        $script:Sql = '🚨 CRITICAL: User input is interpolated into the SQL string, which allows injection. Use parameterized queries.'
        # Exactly on the same-severity bar (3 shared words of 12 = 0.25): any extra word from the
        # marker would push it under, so this only matches while the marker is ignored.
        $script:BorderFirst = '⚠️ WARNING: alpha bravo charlie delta echo foxtrot golf hotel'
        $script:BorderReworded = '⚠️ WARNING: alpha bravo charlie india juliet kilo lima'
    }

    It 'adds a hidden marker with the fingerprint to the posted comment' {
        Invoke-Post @{ reviews = @(@{ fileName = 'a.ts'; lineNumber = 7; comment = '💡 SUGGESTION: rename this'; fingerprint = 'abcdef0123456789' }) } | Out-Null
        ($script:Posted[0] | ConvertFrom-Json).comments[0].content | Should -Match '<!-- aicr:v1 fp=abcdef0123456789 -->$'
    }

    It 'adds a marker without a fingerprint when there is none' {
        Invoke-Post @{ reviews = @(@{ fileName = 'a.ts'; lineNumber = 0; comment = '⚠️ WARNING: removes it' }) } | Out-Null
        ($script:Posted[0] | ConvertFrom-Json).comments[0].content | Should -Match '<!-- aicr:v1 -->$'
    }

    It 'recognises the same code line after it moved far away, even with a reworded comment' {
        $existing = @([PSCustomObject]@{ FileName = '/p.yml'; LineNumber = 20; Severity = 'WARNING'; CommentText = $script:Pin; Status = 'active'; Fingerprint = 'aaaabbbbccccdddd' })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'p.yml'; lineNumber = 85; comment = $script:PinReworded; fingerprint = 'aaaabbbbccccdddd' }) } $existing
        $r.CommentsPosted | Should -Be 0
        $r.CommentsSkippedDuplicate | Should -Be 1
    }

    It 'still posts a clearly different finding on the same code line' {
        $existing = @([PSCustomObject]@{ FileName = '/p.yml'; LineNumber = 20; Severity = 'WARNING'; CommentText = $script:Pin; Status = 'active'; Fingerprint = 'aaaabbbbccccdddd' })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'p.yml'; lineNumber = 85; comment = $script:Sql; fingerprint = 'aaaabbbbccccdddd' }) } $existing
        $r.CommentsPosted | Should -Be 1
    }

    It 'does not match a different code line that has a different fingerprint' {
        $existing = @([PSCustomObject]@{ FileName = '/p.yml'; LineNumber = 20; Severity = 'WARNING'; CommentText = $script:Pin; Status = 'active'; Fingerprint = 'aaaabbbbccccdddd' })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'p.yml'; lineNumber = 85; comment = $script:PinReworded; fingerprint = '1111222233334444' }) } $existing
        $r.CommentsPosted | Should -Be 1
    }

    It 'ignores the hidden marker when comparing wording' {
        $existing = @([PSCustomObject]@{ FileName = '/p.yml'; LineNumber = 20; Severity = 'WARNING'; CommentText = "$($script:BorderFirst)`n`n<!-- aicr:v1 fp=aaaabbbbccccdddd -->"; Status = 'active' })
        $r = Invoke-Post @{ reviews = @(@{ fileName = 'p.yml'; lineNumber = 20; comment = $script:BorderReworded }) } $existing
        $r.CommentsPosted | Should -Be 0
    }

    It 'posts a finding proposed twice in one run only once' {
        $r = Invoke-Post @{ reviews = @(
                @{ fileName = 'p.yml'; lineNumber = 20; comment = $script:Pin; fingerprint = 'aaaabbbbccccdddd' },
                @{ fileName = 'p.yml'; lineNumber = 20; comment = $script:PinReworded; fingerprint = 'aaaabbbbccccdddd' }) }
        $r.CommentsPosted | Should -Be 1
        $r.CommentsSkippedDuplicate | Should -Be 1
    }

    It 'posts two different findings on the same line' {
        $r = Invoke-Post @{ reviews = @(
                @{ fileName = 'p.yml'; lineNumber = 20; comment = $script:Pin; fingerprint = 'aaaabbbbccccdddd' },
                @{ fileName = 'p.yml'; lineNumber = 20; comment = $script:Sql; fingerprint = 'aaaabbbbccccdddd' }) }
        $r.CommentsPosted | Should -Be 2
    }
}

Describe 'Set-PullRequestComments never approves (E6)' {
    It 'has no AutoApprove parameter' {
        (Get-Command Set-PullRequestComments).Parameters.Keys | Should -Not -Contain 'AutoApprove'
    }

    It 'reports no-comments and calls no reviewer API when there is nothing to post' {
        $script:Methods = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod { $script:Methods.Add("$Method $Uri"); [PSCustomObject]@{ id = 1 } }
        $r = Invoke-Post @{ reviews = @() }
        $r.Outcome | Should -Be 'no-comments'
        $r.PSObject.Properties.Name | Should -Not -Contain 'AutoApproved'
        $script:Methods | Where-Object { $_ -match '^Put |/reviewers/' } | Should -BeNullOrEmpty
    }
}
