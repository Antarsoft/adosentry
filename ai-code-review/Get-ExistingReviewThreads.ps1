function Get-ExistingReviewThreads {
    param (
        # The pipeline's $(System.CollectionUri). Works for dev.azure.com, *.visualstudio.com and
        # Azure DevOps Server. Organization is the fallback when only the name is known.
        [parameter()]
        [string]
        $CollectionUri = '',

        [parameter()]
        [string]
        $Organization = '',

        [parameter(Mandatory)]
        [int]
        $PullRequestId,

        [Parameter(Mandatory)]
        [string]
        $RepositoryName,

        [parameter(Mandatory)]
        [string]
        $Project
    )

    $collectionUrl = Resolve-AdoCollectionUrl -CollectionUri $CollectionUri -Organization $Organization

    # A transient failure acquiring the token, or fetching either connectionData or the
    # thread list, should degrade this review round to "no history" rather than aborting
    # the whole review job -- prior-round history is a nice-to-have, not something worth
    # failing the pipeline over.
    try {
        # Do NOT simplify to (Get-AzAccessToken -ResourceUrl "...").Token -- on this environment's
        # Az.Accounts version, .Token returns a SecureString, not a plain string. Interpolating that
        # into "Bearer $token" silently stringifies to the literal text "System.Security.SecureString"
        # instead of the real token, breaking every REST call in this script with no thrown exception.
        # See Set-PullRequestComments.ps1 for the confirmed incident. The -AsSecureString + PSCredential
        # unwrap below is required.
        $token = (New-Object System.Management.Automation.PSCredential("token", (Get-AzAccessToken -ResourceUrl "499b84ac-1321-427f-aa17-267ca6975798" -AsSecureString).token)).GetNetworkCredential().Password
    }
    catch {
        Write-Warning "Failed to acquire access token, continuing without review history: $_"
        return [PSCustomObject]@{
            Threads         = @()
            CurrentUserName = $null
            ConnectionData  = $null
        }
    }
    $headers = @{
        Authorization  = "Bearer $token"
        "Content-Type" = "application/json"
    }

    try {
        $connectionData = Invoke-RestMethod -Uri "$collectionUrl/_apis/connectionData" -Headers $headers -Method Get
    }
    catch {
        Write-Warning "Failed to retrieve connection data, continuing without review history: $_"
        return [PSCustomObject]@{
            Threads         = @()
            CurrentUserName = $null
            ConnectionData  = $null
        }
    }
    $currentUserName = $connectionData.authenticatedUser.providerDisplayName
    $currentUserId = $connectionData.authenticatedUser.id

    $getThreadsUrl = "$collectionUrl/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/threads?api-version=7.1"

    try {
        $existingThreads = Invoke-RestMethod -Uri $getThreadsUrl -Headers $headers -Method Get
    }
    catch {
        Write-Warning "Failed to retrieve existing threads, continuing without review history: $_"
        return [PSCustomObject]@{
            Threads         = @()
            CurrentUserName = $currentUserName
            ConnectionData  = $connectionData
        }
    }

    # Only threads with a comment from this same bot account count as review history --
    # human review comments aren't something the LLM should be told it "already said".
    $threadList = @()
    foreach ($thread in $existingThreads.value) {
        if ($thread.isDeleted) {
            continue
        }

        # PR-level threads (no file anchor) are posted for findings that have no line to
        # comment on, such as a risky file deletion. Keep them as "(pull request)" : 0 so
        # they take part in duplicate detection and in the prior-round history.
        $isPullRequestLevel = -not $thread.threadContext -or -not $thread.threadContext.filePath

        if ($thread.status -notin @("active", "pending", "fixed", "wontFix", "closed", "byDesign")) {
            continue
        }

        # A comment is the bot's if it was written by this identity (matched by id, the display
        # name is only a fallback for older comments), or if it carries the hidden marker the bot
        # adds to every comment it posts, which survives a renamed or replaced service principal.
        $firstComment = $thread.comments | Where-Object { -not $_.isDeleted } | Select-Object -First 1
        $botComment = $thread.comments | Where-Object {
            -not $_.isDeleted -and (
                ($currentUserId -and $_.author.id -eq $currentUserId) -or
                $_.author.displayName -eq $currentUserName -or
                ($_.commentType -ne 'system' -and $firstComment -and $_.id -eq $firstComment.id -and $_.content -match '<!-- aicr:v\d+')
            )
        } | Select-Object -First 1

        if (-not $botComment) {
            continue
        }

        if ($isPullRequestLevel) {
            $normalizedPath = '(pull request)'
            $lineNum = 0
        } else {
            $normalizedPath = $thread.threadContext.filePath.ToLower()
            if (-not $normalizedPath.StartsWith('/')) {
                $normalizedPath = "/$normalizedPath"
            }

            $lineNum = $null
            if ($thread.threadContext.rightFileStart -and $thread.threadContext.rightFileStart.line) {
                $lineNum = $thread.threadContext.rightFileStart.line
            } elseif ($thread.threadContext.leftFileStart -and $thread.threadContext.leftFileStart.line) {
                $lineNum = $thread.threadContext.leftFileStart.line
            } else {
                # No usable line context for this thread; skip
                continue
            }
        }

        # Severity is the leading "<emoji> <LEVEL>" of the comment text, per the
        # severity prefix the engine adds to every comment (see prompts/base.codereviewprompt.md).
        $severity = 'UNKNOWN'
        if ($botComment.content -match '^(🚨|⚠️|💡)\s*(CRITICAL|WARNING|SUGGESTION)') {
            $severity = $matches[2]
        }

        # The hidden marker is for the engine only: keep its fingerprint, and keep it out of
        # the text shown to the model and compared word by word.
        $fingerprint = $null
        if ($botComment.content -match '<!-- aicr:v\d+(?: fp=([0-9a-f]+))? -->') {
            $fingerprint = $matches[1]
        }
        $commentText = ($botComment.content -replace '(?s)\s*<!-- aicr:v\d+[^>]*-->\s*', '').Trim()

        $threadList += [PSCustomObject]@{
            FileName    = $normalizedPath
            LineNumber  = $lineNum
            Severity    = $severity
            CommentText = $commentText
            Status      = $thread.status
            Fingerprint = $fingerprint
        }
    }

    return [PSCustomObject]@{
        Threads         = $threadList
        CurrentUserName = $currentUserName
        ConnectionData  = $connectionData
    }
}
