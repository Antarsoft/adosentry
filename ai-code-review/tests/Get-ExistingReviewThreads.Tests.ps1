BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Resolve-AdoCollectionUrl.ps1')
    . (Join-Path $PSScriptRoot '..' 'Get-ExistingReviewThreads.ps1')
    function Get-AzAccessToken { param($ResourceUrl, [switch]$AsSecureString) [PSCustomObject]@{ token = (ConvertTo-SecureString 'x' -AsPlainText -Force) } }

    function New-Thread($Status, $Author = 'AI Reviewer', $Context = $true, $Deleted = $false, $Text = '⚠️ WARNING: something') {
        $thread = [ordered]@{
            status    = $Status
            isDeleted = $Deleted
            comments  = @([PSCustomObject]@{ author = [PSCustomObject]@{ displayName = $Author }; content = $Text; isDeleted = $false })
        }
        if ($Context) {
            $thread.threadContext = [PSCustomObject]@{ filePath = '/Src/A.ts'; rightFileStart = [PSCustomObject]@{ line = 5 } }
        }
        [PSCustomObject]$thread
    }

    function Get-Threads($Threads) {
        $script:ApiThreads = $Threads
        Mock Invoke-RestMethod {
            if ($Uri -like '*connectionData*') { return [PSCustomObject]@{ authenticatedUser = [PSCustomObject]@{ providerDisplayName = 'AI Reviewer' } } }
            return [PSCustomObject]@{ value = $script:ApiThreads }
        }
        (Get-ExistingReviewThreads -Organization o -PullRequestId 1 -RepositoryName r -Project p 3>$null).Threads
    }
}

Describe 'Get-ExistingReviewThreads' {
    It 'includes threads in every status, byDesign included (F-17)' -ForEach @(
        @{ Status = 'active' }, @{ Status = 'pending' }, @{ Status = 'fixed' }, @{ Status = 'wontFix' }, @{ Status = 'closed' }, @{ Status = 'byDesign' }
    ) {
        @(Get-Threads @(New-Thread $Status)).Count | Should -Be 1
    }

    It 'ignores unknown statuses, deleted threads and other authors' {
        $threads = Get-Threads @((New-Thread 'unknown'), (New-Thread 'active' -Deleted $true), (New-Thread 'active' -Author 'Some Person'))
        @($threads).Count | Should -Be 0
    }

    It 'keeps file threads lower-cased with their line' {
        $thread = @(Get-Threads @(New-Thread 'active'))[0]
        $thread.FileName | Should -Be '/src/a.ts'
        $thread.LineNumber | Should -Be 5
        $thread.Severity | Should -Be 'WARNING'
    }

    It 'keeps pull-request-level threads as (pull request)' {
        $thread = @(Get-Threads @(New-Thread 'active' -Context $false))[0]
        $thread.FileName | Should -Be '(pull request)'
        $thread.LineNumber | Should -Be 0
    }
}

Describe 'bot identity and fingerprints (F-22, F-18)' {
    BeforeAll {
        function New-RichThread($Comments, $Status = 'active') {
            [PSCustomObject]@{
                status        = $Status
                isDeleted     = $false
                threadContext = [PSCustomObject]@{ filePath = '/src/a.ts'; rightFileStart = [PSCustomObject]@{ line = 5 } }
                comments      = @($Comments)
            }
        }
        function New-Comment($Id, $AuthorId, $AuthorName, $Text, $Type = 'text') {
            [PSCustomObject]@{ id = $Id; author = [PSCustomObject]@{ id = $AuthorId; displayName = $AuthorName }; content = $Text; isDeleted = $false; commentType = $Type }
        }
        function Get-RichThreads($Threads) {
            $script:ApiThreads = $Threads
            Mock Invoke-RestMethod {
                if ($Uri -like '*connectionData*') { return [PSCustomObject]@{ authenticatedUser = [PSCustomObject]@{ providerDisplayName = 'AI Reviewer'; id = 'bot-id' } } }
                return [PSCustomObject]@{ value = $script:ApiThreads }
            }
            @((Get-ExistingReviewThreads -Organization o -PullRequestId 1 -RepositoryName r -Project p 3>$null).Threads)
        }
    }

    It 'recognises the bot by user id even when its display name changed' {
        $t = Get-RichThreads @(New-RichThread @(New-Comment 1 'bot-id' 'Renamed Bot' '⚠️ WARNING: x'))
        $t.Count | Should -Be 1
    }

    It 'still recognises older comments by display name' {
        $t = Get-RichThreads @(New-RichThread @(New-Comment 1 'old-id' 'AI Reviewer' '⚠️ WARNING: x'))
        $t.Count | Should -Be 1
    }

    It 'recognises a comment from another identity by its hidden marker' {
        $t = Get-RichThreads @(New-RichThread @(New-Comment 1 'other-id' 'Previous Bot' "⚠️ WARNING: x`n`n<!-- aicr:v1 fp=0123456789abcdef -->"))
        $t.Count | Should -Be 1
        $t[0].Fingerprint | Should -Be '0123456789abcdef'
    }

    It 'does not treat a human reply that quotes the marker as the bot' {
        $thread = New-RichThread @((New-Comment 1 'person-id' 'Some Person' 'my own comment'), (New-Comment 2 'person-id2' 'Another' '<!-- aicr:v1 fp=aaaa -->'))
        @(Get-RichThreads @($thread)).Count | Should -Be 0
    }

    It 'keeps the marker out of the comment text and reads the fingerprint' {
        $t = Get-RichThreads @(New-RichThread @(New-Comment 1 'bot-id' 'AI Reviewer' "⚠️ WARNING: pin the template`n`n<!-- aicr:v1 fp=deadbeef01234567 -->"))
        $t[0].CommentText | Should -Be '⚠️ WARNING: pin the template'
        $t[0].Fingerprint | Should -Be 'deadbeef01234567'
    }

    It 'leaves the fingerprint empty for a comment without a marker' {
        $t = Get-RichThreads @(New-RichThread @(New-Comment 1 'bot-id' 'AI Reviewer' '⚠️ WARNING: x'))
        $t[0].Fingerprint | Should -BeNullOrEmpty
    }
}
