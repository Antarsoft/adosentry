BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Resolve-AdoCollectionUrl.ps1')
    . (Join-Path $PSScriptRoot '..' 'Get-ExistingReviewThreads.ps1')
    . (Join-Path $PSScriptRoot '..' 'Set-PullRequestComments.ps1')
    function Get-AzAccessToken { param($ResourceUrl, [switch]$AsSecureString) [PSCustomObject]@{ token = (ConvertTo-SecureString 'x' -AsPlainText -Force) } }
}

BeforeDiscovery {
    # The three host shapes $(System.CollectionUri) takes, with the URL the scripts must build.
    $script:Hosts = @(
        @{ Name = 'dev.azure.com'; CollectionUri = 'https://dev.azure.com/contoso/'; Expected = 'https://dev.azure.com/contoso' }
        @{ Name = 'visualstudio.com'; CollectionUri = 'https://contoso.visualstudio.com/'; Expected = 'https://contoso.visualstudio.com' }
        @{ Name = 'Azure DevOps Server'; CollectionUri = 'https://server/tfs/Collection/'; Expected = 'https://server/tfs/Collection' }
    )
}

Describe 'Resolve-AdoCollectionUrl (E2, E3)' {
    It 'keeps the <Name> collection URL and drops the trailing slash' -ForEach ($script:Hosts + @(
        @{ Name = 'server without a trailing slash'; CollectionUri = 'https://server:8080/tfs/Collection'; Expected = 'https://server:8080/tfs/Collection' }
    )) {
        Resolve-AdoCollectionUrl -CollectionUri $CollectionUri | Should -Be $Expected
    }

    It 'prefers CollectionUri over Organization' {
        Resolve-AdoCollectionUrl -CollectionUri 'https://server/tfs/Collection/' -Organization 'contoso' | Should -Be 'https://server/tfs/Collection'
    }

    It 'falls back to dev.azure.com for an organization name' {
        Resolve-AdoCollectionUrl -Organization 'contoso' | Should -Be 'https://dev.azure.com/contoso'
    }

    It 'treats an unexpanded pipeline macro as empty' {
        Resolve-AdoCollectionUrl -CollectionUri '$(System.CollectionUri)' -Organization 'contoso' | Should -Be 'https://dev.azure.com/contoso'
    }

    It 'rejects a value that is not an absolute http(s) URL' -ForEach @(
        @{ Value = 'contoso' }, @{ Value = '/tfs/Collection' }, @{ Value = 'ftp://server/tfs/Collection' }
    ) {
        { Resolve-AdoCollectionUrl -CollectionUri $Value } | Should -Throw '*not an absolute http(s) URL*'
    }

    It 'fails when neither CollectionUri nor Organization is given' {
        { Resolve-AdoCollectionUrl } | Should -Throw '*CollectionUri*Organization*'
    }
}

Describe 'Azure DevOps REST URLs for every host shape (E3)' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $script:Calls.Add($Uri)
            if ($Uri -like '*connectionData*') { return [PSCustomObject]@{ authenticatedUser = [PSCustomObject]@{ id = 'bot-id'; providerDisplayName = 'AI Reviewer' } } }
            if ($Method -eq 'Post') { return [PSCustomObject]@{ id = 1 } }
            return [PSCustomObject]@{ value = @() }
        }
    }

    It 'Get-ExistingReviewThreads calls <Name>' -ForEach $script:Hosts {
        Get-ExistingReviewThreads -CollectionUri $CollectionUri -PullRequestId 7 -RepositoryName repo -Project proj 3>$null | Out-Null
        $script:Calls | Should -Contain "$Expected/_apis/connectionData"
        $script:Calls | Should -Contain "$Expected/proj/_apis/git/repositories/repo/pullRequests/7/threads?api-version=7.1"
    }

    It 'Set-PullRequestComments posts to <Name>' -ForEach $script:Hosts {
        $reviews = @{ reviews = @(@{ fileName = 'a.ts'; lineNumber = 3; comment = '💡 SUGGESTION: rename this' }) } | ConvertTo-Json -Depth 5 -Compress
        $result = Set-PullRequestComments -CollectionUri $CollectionUri -PullRequestId 7 -RepositoryName repo -Project proj -Reviews $reviews 6>$null 3>$null
        $result.CommentsPosted | Should -Be 1
        $script:Calls | Should -Contain "$Expected/proj/_apis/git/repositories/repo/pullRequests/7/threads?api-version=7.1"
        $script:Calls | Where-Object { $_ -like 'https://dev.azure.com/*' -and $Expected -notlike 'https://dev.azure.com/*' } | Should -BeNullOrEmpty
    }

    It 'still works with only an organization name' {
        Get-ExistingReviewThreads -Organization contoso -PullRequestId 7 -RepositoryName repo -Project proj 3>$null | Out-Null
        $script:Calls | Should -Contain 'https://dev.azure.com/contoso/proj/_apis/git/repositories/repo/pullRequests/7/threads?api-version=7.1'
    }
}
