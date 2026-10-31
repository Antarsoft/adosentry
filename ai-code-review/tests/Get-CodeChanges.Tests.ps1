BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Get-CodeChanges.ps1')

    function Invoke-Git {
        & git -C $script:Repo @args | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git $args failed" }
    }

    function Write-RepoFile($Path, $Content) {
        $full = Join-Path $script:Repo $Path
        New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
        Set-Content -Path $full -Value $Content
    }

    # Builds a throwaway repo: `main` holds $Base, `feature` holds $Base plus $Change.
    # Both are exposed as refs/remotes/origin/* because the engine diffs origin/<target>...origin/<source>.
    function New-TestRepo([scriptblock]$Base, [scriptblock]$Change) {
        $script:Repo = Join-Path ([IO.Path]::GetTempPath()) ("cc-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        Invoke-Git init -q -b main
        Invoke-Git config user.email t@example.com
        Invoke-Git config user.name Test
        Invoke-Git config commit.gpgsign false
        & $Base
        Invoke-Git add -A
        Invoke-Git commit -q -m base
        Invoke-Git update-ref refs/remotes/origin/main HEAD
        Invoke-Git checkout -q -b feature
        & $Change
        Invoke-Git add -A
        Invoke-Git commit -q -m change
        Invoke-Git update-ref refs/remotes/origin/feature HEAD
    }

    function Get-Review([bool]$Deleted = $false, [string[]]$PathSpec = @(), [string[]]$Exclude = @()) {
        Push-Location $script:Repo
        try {
            Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature' `
                -PathSpec $PathSpec -ExcludePathSpec $Exclude -ReviewDeletedFiles $Deleted 6>$null
        } finally { Pop-Location }
    }

    $script:Lines = (1..30 | ForEach-Object { "line $_ of the original file" })
}

Describe 'Get-CodeChanges' {
AfterEach {
    if ($script:Repo -and (Test-Path $script:Repo)) { Remove-Item -Recurse -Force $script:Repo }
}

Describe 'renamed and moved files' {
    It 'pure rename is included, shows the old path and no content changes' {
        New-TestRepo { Write-RepoFile 'src/a.txt' $script:Lines } { Invoke-Git mv src/a.txt src/b.txt }
        $r = Get-Review
        $r.FilesReviewed | Should -Be 1
        $r.FilesRenamed | Should -Be 1
        $text = $r.Batches[0].Changes
        $text | Should -Match '## File: /src/b.txt'
        $text | Should -Match 'Renamed from: /src/a.txt'
        $text | Should -Match 'renamed, no content changes'
        $text | Should -Not -Match '\d+\+ line 1 of'
    }

    It 'rename with an edit shows only the real change, not the whole file as added' {
        New-TestRepo { Write-RepoFile 'a.txt' $script:Lines } {
            Invoke-Git mv a.txt b.txt
            Write-RepoFile 'b.txt' ($script:Lines -replace 'line 15 of the original file', 'line 15 CHANGED')
        }
        $r = Get-Review
        $r.FilesRenamed | Should -Be 1
        $text = $r.Batches[0].Changes
        $text | Should -Match 'Renamed from: /a.txt'
        $text | Should -Match '15\+ line 15 CHANGED'
        $r.LinesAdded | Should -Be 1
        $r.LinesRemoved | Should -Be 1
    }

    It 'moving a file to another directory counts as a rename' {
        New-TestRepo { Write-RepoFile 'old/dir/a.txt' $script:Lines } {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Repo 'new') | Out-Null
            Invoke-Git mv old/dir/a.txt new/a.txt
        }
        $r = Get-Review
        $r.FilesReviewed | Should -Be 1
        $r.Batches[0].Changes | Should -Match 'Renamed from: /old/dir/a.txt'
    }

    It 'a rename out of the pathspec into it is still reviewed with the old path' {
        New-TestRepo { Write-RepoFile 'other/a.txt' $script:Lines } {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Repo 'src') | Out-Null
            Invoke-Git mv other/a.txt src/a.txt
        }
        $r = Get-Review -PathSpec @('src')
        $r.FilesReviewed | Should -Be 1
    }
}

Describe 'ordinary changes still work' {
    It 'modified and added files are reviewed' {
        New-TestRepo { Write-RepoFile 'm.txt' $script:Lines } {
            Write-RepoFile 'm.txt' ($script:Lines + 'extra')
            Write-RepoFile 'n.txt' @('new')
        }
        $r = Get-Review
        $r.FilesReviewed | Should -Be 2
        $r.TotalFilesChanged | Should -Be 2
        $r.FilesRenamed | Should -Be 0
        $r.FilesDeleted | Should -Be 0
    }

    It 'exclude spec removes files and counts them' {
        New-TestRepo { Write-RepoFile 'm.txt' @('x') } {
            Write-RepoFile 'm.txt' @('y')
            Write-RepoFile 'skip/z.txt' @('z')
        }
        $r = Get-Review -Exclude @('skip/*')
        $r.FilesReviewed | Should -Be 1
        $r.FilesExcluded.Count | Should -Be 1
    }
}

Describe 'deleted files' {
    BeforeEach {
        New-TestRepo { Write-RepoFile 'gone.txt' $script:Lines; Write-RepoFile 'keep.txt' @('k') } {
            Invoke-Git rm -q gone.txt
            Write-RepoFile 'keep.txt' @('k2')
        }
    }

    It 'is ignored by default' {
        $r = Get-Review
        $r.FilesDeleted | Should -Be 0
        $r.FilesReviewed | Should -Be 1
        $r.Batches[0].Changes | Should -Not -Match 'Deleted files'
    }

    It 'lists names only, not content, when enabled' {
        $r = Get-Review -Deleted $true
        $r.FilesDeleted | Should -Be 1
        $r.FilesReviewed | Should -Be 1
        $r.Batches[0].DeletedFileCount | Should -Be 1
        $r.Batches[0].Changes | Should -Match 'Deleted files'
        $r.Batches[0].Changes | Should -Match '/?gone.txt'
        $r.Batches[0].Changes | Should -Not -Match 'line 1 of the original'
        $r.Batches[0].Changes | Should -Match 'lineNumber.{0,4}0'
    }

    It 'respects the exclude spec' {
        $r = Get-Review -Deleted $true -Exclude @('gone.*')
        $r.FilesDeleted | Should -Be 0
    }
}

Describe 'deletion-only pull request' {
    It 'still produces a batch carrying the deleted list' {
        New-TestRepo { Write-RepoFile 'gone.txt' $script:Lines } { Invoke-Git rm -q gone.txt }
        $r = Get-Review -Deleted $true
        $r.FilesReviewed | Should -Be 0
        $r.FilesDeleted | Should -Be 1
        $r.Batches.Count | Should -BeGreaterThan 0
        ($r.Batches | Where-Object { $_.DeletedFileCount -gt 0 }).Count | Should -Be 1
    }

    It 'with the option off there is nothing to review' {
        New-TestRepo { Write-RepoFile 'gone.txt' $script:Lines } { Invoke-Git rm -q gone.txt }
        $r = Get-Review
        $r.FilesReviewed | Should -Be 0
        $r.FilesDeleted | Should -Be 0
    }
}

Describe 'batching' {
    It 'puts the deleted list in the first batch only' {
        New-TestRepo { 1..3 | ForEach-Object { Write-RepoFile "f$_.txt" @('a') }; Write-RepoFile 'gone.txt' @('g') } {
            1..3 | ForEach-Object { Write-RepoFile "f$_.txt" @('b') }
            Invoke-Git rm -q gone.txt
        }
        Push-Location $script:Repo
        try {
            $r = Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature' -MaxFilesPerBatch 2 -ReviewDeletedFiles $true 6>$null
        } finally { Pop-Location }
        $r.BatchCount | Should -Be 2
        $r.Batches[0].DeletedFileCount | Should -Be 1
        $r.Batches[1].DeletedFileCount | Should -Be 0
    }
}

Describe 'token-aware batching (F-02)' {
    BeforeAll {
        function Get-SizedReview([int]$MaxBatchTokens, [int]$MaxFileTokens = 0, [int]$MaxFiles = 25) {
            Push-Location $script:Repo
            try {
                Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature' `
                    -MaxFilesPerBatch $MaxFiles -MaxBatchTokens $MaxBatchTokens -MaxFileTokens $MaxFileTokens 6>$null
            } finally { Pop-Location }
        }
        $script:WideLines = { param($Tag) (1..40 | ForEach-Object { "$Tag line $_ " + ('x' * 90) }) }
    }

    It 'starts a new batch when the next file would pass the token budget' {
        New-TestRepo { 1..4 | ForEach-Object { Write-RepoFile "f$_.txt" @('base') } } {
            1..4 | ForEach-Object { Write-RepoFile "f$_.txt" (& $script:WideLines "f$_") }
        }
        $r = Get-SizedReview -MaxBatchTokens 3500
        $r.BatchCount | Should -BeGreaterThan 1
        $r.FilesReviewed | Should -Be 4
        foreach ($batch in $r.Batches) {
            $batch.EstimatedTokens | Should -BeLessOrEqual 3500
        }
    }

    It 'keeps everything in one batch when it fits the budget' {
        New-TestRepo { 1..4 | ForEach-Object { Write-RepoFile "f$_.txt" @('base') } } {
            1..4 | ForEach-Object { Write-RepoFile "f$_.txt" (& $script:WideLines "f$_") }
        }
        $r = Get-SizedReview -MaxBatchTokens 300000
        $r.BatchCount | Should -Be 1
        $r.Batches[0].FilesReviewed | Should -Be 4
    }

    It 'still applies the file-count limit when the token budget is not reached' {
        New-TestRepo { 1..4 | ForEach-Object { Write-RepoFile "f$_.txt" @('base') } } {
            1..4 | ForEach-Object { Write-RepoFile "f$_.txt" @('small change') }
        }
        $r = Get-SizedReview -MaxBatchTokens 300000 -MaxFiles 2
        $r.BatchCount | Should -Be 2
    }

    It 'gives an oversized file a batch of its own when file truncation is off' {
        New-TestRepo { Write-RepoFile 'a.txt' @('base'); Write-RepoFile 'big.txt' @('base'); Write-RepoFile 'c.txt' @('base') } {
            Write-RepoFile 'a.txt' @('small')
            Write-RepoFile 'big.txt' (1..300 | ForEach-Object { "big line $_ " + ('y' * 90) })
            Write-RepoFile 'c.txt' @('small')
        }
        $r = Get-SizedReview -MaxBatchTokens 3000 -MaxFileTokens 0
        $bigBatch = $r.Batches | Where-Object { $_.FileNames -contains 'big.txt' }
        @($bigBatch.FileNames).Count | Should -Be 1
        @($r.FilesTruncated).Count | Should -Be 0
    }

    It 'truncates a file above the per-file cap, says so in the diff and reports it' {
        New-TestRepo { Write-RepoFile 'big.txt' @('base'); Write-RepoFile 'ok.txt' @('base') } {
            Write-RepoFile 'big.txt' (1..600 | ForEach-Object { "big line $_ " + ('y' * 90) })
            Write-RepoFile 'ok.txt' @('small')
        }
        $r = Get-SizedReview -MaxBatchTokens 300000 -MaxFileTokens 2000
        @($r.FilesTruncated) | Should -Be @('big.txt')
        $text = ($r.Batches | ForEach-Object { $_.Changes }) -join "`n"
        $text | Should -Match 'Diff truncated: the remaining \d+ line\(s\)'
        $text | Should -Match 'big line 1 '
        $text | Should -Not -Match 'big line 600 '
        $text | Should -Match '## File: /ok.txt'
        ($r.Batches | Measure-Object -Property EstimatedTokens -Maximum).Maximum | Should -BeLessThan 4500
    }

    It 'does not truncate files under the cap' {
        New-TestRepo { Write-RepoFile 'a.txt' @('base') } { Write-RepoFile 'a.txt' (& $script:WideLines 'a') }
        $r = Get-SizedReview -MaxBatchTokens 300000 -MaxFileTokens 80000
        @($r.FilesTruncated).Count | Should -Be 0
        $r.Batches[0].Changes | Should -Not -Match 'Diff truncated'
    }
}

Describe 'anchor map (F-19)' {
    It 'lists the new-side lines that were shown, flagged added or context' {
        New-TestRepo { Write-RepoFile 'src/a.txt' (1..20 | ForEach-Object { "line $_" }) } {
            $content = 1..20 | ForEach-Object { "line $_" }
            $content[9] = 'line 10 CHANGED'
            Write-RepoFile 'src/a.txt' $content
        }
        $r = Get-Review
        $anchors = $r.Anchors['/src/a.txt']
        $anchors[10] | Should -Be 'added'
        $anchors[8] | Should -Be 'context'
        $anchors[15] | Should -Be 'context'
        $anchors.ContainsKey(1) | Should -BeFalse
        $anchors.ContainsKey(20) | Should -BeFalse
    }

    It 'does not treat a removed line as an anchor' {
        New-TestRepo { Write-RepoFile 'a.txt' (1..20 | ForEach-Object { "line $_" }) } {
            Write-RepoFile 'a.txt' ((1..20 | ForEach-Object { "line $_" }) | Where-Object { $_ -ne 'line 10' })
        }
        $r = Get-Review
        $anchors = $r.Anchors['/a.txt']
        @($anchors.Values | Where-Object { $_ -eq 'added' }).Count | Should -Be 0
        $anchors.Count | Should -BeGreaterThan 0
    }

    It 'allows line 1 for a pure rename' {
        New-TestRepo { Write-RepoFile 'src/a.txt' $script:Lines } { Invoke-Git mv src/a.txt src/b.txt }
        $r = Get-Review
        $r.Anchors['/src/b.txt'][1] | Should -Be 'context'
    }

    It 'reports the deleted files it listed' {
        New-TestRepo { Write-RepoFile 'gone.txt' $script:Lines; Write-RepoFile 'keep.txt' @('a') } {
            Invoke-Git rm -q gone.txt
            Write-RepoFile 'keep.txt' @('b')
        }
        (Get-Review -Deleted $true).DeletedFilePaths | Should -Be @('/gone.txt')
    }
}

Describe 'Split-BlocksIntoBatches' {
    BeforeAll {
        function New-Block($Tokens) { [PSCustomObject]@{ File = "f$Tokens"; Tokens = $Tokens } }
    }

    It 'returns nothing for no blocks' {
        @(Split-BlocksIntoBatches -Blocks @() -MaxFiles 25 -MaxTokens 100).Count | Should -Be 0
    }

    It 'returns one batch holding every block when they fit' {
        $batches = @(Split-BlocksIntoBatches -Blocks @((New-Block 10), (New-Block 20)) -MaxFiles 25 -MaxTokens 100)
        $batches.Count | Should -Be 1
        $batches[0].Count | Should -Be 2
    }

    It 'splits on the token budget, counting the per-batch overhead' {
        $blocks = @((New-Block 40), (New-Block 40), (New-Block 40))
        $batches = @(Split-BlocksIntoBatches -Blocks $blocks -MaxFiles 25 -MaxTokens 100 -OverheadTokens 25)
        $batches.Count | Should -Be 3
    }

    It 'always puts at least one block in a batch, even if it is over budget' {
        $batches = @(Split-BlocksIntoBatches -Blocks @((New-Block 500), (New-Block 5)) -MaxFiles 25 -MaxTokens 100)
        $batches.Count | Should -Be 2
        $batches[0].Count | Should -Be 1
    }

    It 'treats a zero budget as unlimited' {
        $batches = @(Split-BlocksIntoBatches -Blocks @((New-Block 500), (New-Block 500)) -MaxFiles 0 -MaxTokens 0)
        $batches.Count | Should -Be 1
    }
}

Describe 'Split-CodeChangesBatch' {
    It 'rebuilds a batch as two halves and keeps the deleted list with the first' {
        $blocks = 1..5 | ForEach-Object { [PSCustomObject]@{ File = "f$_.ts"; Text = "## File: /f$_.ts`n"; Added = 1; Removed = 0; Truncated = $false } }
        $batch = New-CodeChangesBatchObject -Legend "legend`n" -BatchNumber 2 -BatchCount 3 -DeletedNotice "deleted`n" -DeletedFileCount 2 -Blocks $blocks
        $halves = @(Split-CodeChangesBatch -Batch $batch)
        $halves.Count | Should -Be 2
        @($halves[0].FileNames).Count | Should -Be 3
        @($halves[1].FileNames).Count | Should -Be 2
        $halves[0].DeletedFileCount | Should -Be 2
        $halves[1].DeletedFileCount | Should -Be 0
        $halves[0].Changes | Should -Match 'deleted'
        $halves[1].Changes | Should -Not -Match 'deleted'
        $halves[1].Changes | Should -Match 'Review batch 2 of 3'
    }

    It 'returns a single-file batch unchanged' {
        $block = [PSCustomObject]@{ File = 'a.ts'; Text = "x`n"; Added = 1; Removed = 0; Truncated = $false }
        $batch = New-CodeChangesBatchObject -Legend "l`n" -BatchNumber 1 -BatchCount 1 -Blocks @($block)
        @(Split-CodeChangesBatch -Batch $batch).Count | Should -Be 1
    }
}
}

Describe 'Split-IntoBatches' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'Get-CodeChanges.ps1')
    }

    It 'returns no batches for no items' {
        @(Split-IntoBatches -Items @() -BatchSize 25).Count | Should -Be 0
    }

    It 'returns one batch holding every item when under the limit' -ForEach @(
        @{ Count = 1 }, @{ Count = 4 }, @{ Count = 25 }
    ) {
        $items = 1..$Count | ForEach-Object { "f$_" }
        $batches = @(Split-IntoBatches -Items $items -BatchSize 25)
        $batches.Count | Should -Be 1
        @($batches[0]).Count | Should -Be $Count
    }

    It 'splits into batches of at most the limit' -ForEach @(
        @{ Count = 26; Sizes = @(25, 1) }, @{ Count = 50; Sizes = @(25, 25) }, @{ Count = 51; Sizes = @(25, 25, 1) }
    ) {
        $items = 1..$Count | ForEach-Object { "f$_" }
        $batches = @(Split-IntoBatches -Items $items -BatchSize 25)
        $batches.Count | Should -Be $Sizes.Count
        for ($i = 0; $i -lt $Sizes.Count; $i++) { @($batches[$i]).Count | Should -Be $Sizes[$i] }
    }

    It 'keeps everything in one batch when the batch size is zero or negative' {
        @(Split-IntoBatches -Items @('a', 'b', 'c') -BatchSize 0).Count | Should -Be 1
    }
}

Describe 'Get-CodeChanges batching' {
    It 'puts a small pull request into a single batch' {
        New-TestRepo { 1..4 | ForEach-Object { Write-RepoFile "f$_.txt" @('a') } } {
            1..4 | ForEach-Object { Write-RepoFile "f$_.txt" @('b') }
        }
        $r = Get-Review
        $r.BatchCount | Should -Be 1
        $r.Batches.Count | Should -Be 1
        $r.Batches[0].FilesReviewed | Should -Be 4
    }

    It 'puts a single changed file into a single batch' {
        New-TestRepo { Write-RepoFile 'only.txt' @('a') } { Write-RepoFile 'only.txt' @('b') }
        $r = Get-Review
        $r.BatchCount | Should -Be 1
        $r.Batches[0].FilesReviewed | Should -Be 1
    }
}

Describe 'diff lines that look like git headers (F-04)' {
    It 'keeps removed and added lines whose text starts with dashes or pluses' {
        New-TestRepo {
            Write-RepoFile 'doc.md' @('title', '---', 'text', '-- sql comment', 'end')
        } {
            Write-RepoFile 'doc.md' @('title', 'text', '++ plus text', 'end')
        }
        $r = Get-Review
        $text = $r.Batches[0].Changes
        $text | Should -Match '2- ---'
        $text | Should -Match '4- -- sql comment'
        $text | Should -Match '\+ \+\+ plus text'
        $r.LinesRemoved | Should -Be 2
        $r.LinesAdded | Should -Be 1
    }

    It 'still drops git file headers' {
        New-TestRepo { Write-RepoFile 'a.txt' @('one') } { Write-RepoFile 'a.txt' @('two') }
        $text = (Get-Review).Batches[0].Changes
        $text | Should -Not -Match 'diff --git'
        $text | Should -Not -Match '(?m)^index '
        $text | Should -Not -Match '(?m)^\+\+\+ b/'
    }
}

Describe 'prompt file exclusion (F-23)' {
    It 'excludes the prompt file even when it follows an empty exclude spec' {
        $spec = ' pipelines/ai-code-review/prompts/App.codereviewprompt.md' -split '\s+'
        Test-ReviewPathExcluded -Path 'pipelines/ai-code-review/prompts/App.codereviewprompt.md' -ExcludePathSpec $spec | Should -BeTrue
    }

    It 'does not exclude other files because of the empty spec entry' {
        $spec = ' pipelines/ai-code-review/prompts/App.codereviewprompt.md' -split '\s+'
        Test-ReviewPathExcluded -Path 'src/app.ts' -ExcludePathSpec $spec | Should -BeFalse
    }
}

Describe 'default excludes (F-03)' {
    BeforeEach {
        New-TestRepo {
            Write-RepoFile 'src/a.ts' @('a')
            Write-RepoFile 'package-lock.json' @('{}')
            Write-RepoFile 'web/yarn.lock' @('x')
            Write-RepoFile 'img/logo.svg' @('<svg/>')
            Write-RepoFile 'dist/app.js.map' @('{}')
        } {
            Write-RepoFile 'src/a.ts' @('b')
            Write-RepoFile 'package-lock.json' @('{"a":1}')
            Write-RepoFile 'web/yarn.lock' @('y')
            Write-RepoFile 'img/logo.svg' @('<svg x/>')
            Write-RepoFile 'dist/app.js.map' @('{"v":3}')
        }
    }

    It 'excludes lockfiles, svg and source maps by default and still counts them' {
        $r = Get-Review
        $r.FilesReviewed | Should -Be 1
        $r.FilesExcluded.Count | Should -Be 4
        $r.TotalFilesChanged | Should -Be 5
        $r.Batches[0].Changes | Should -Match '/src/a.ts'
        $r.Batches[0].Changes | Should -Not -Match 'package-lock'
    }

    It 'reviews them when default excludes are switched off' {
        Push-Location $script:Repo
        try {
            $r = Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature' -UseDefaultExcludes $false 6>$null
        } finally { Pop-Location }
        $r.FilesReviewed | Should -Be 5
        $r.FilesExcluded.Count | Should -Be 0
    }

    It 'adds the repo exclude spec on top of the defaults' {
        $r = Get-Review -Exclude @('src/*')
        $r.FilesReviewed | Should -Be 0
        $r.FilesExcluded.Count | Should -Be 5
    }
}

