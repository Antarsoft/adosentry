function Set-PullRequestComments {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingThreads', Justification = 'Used inside nested helper script blocks, which the rule does not follow.')]
    param (
        [parameter(Mandatory)]
        [string]
        $Organization,

        [parameter(Mandatory)]
        [int]
        $PullRequestId,

        [Parameter(Mandatory)]
        [string]
        $RepositoryName,

        [parameter(Mandatory)]
        [string]
        $Project,

        [parameter(Mandatory)]
        [string]
        $Reviews,

        [parameter()]
        [array]
        $ExistingThreads = @(),

        [parameter()]
        [switch]
        $AutoApprove
    )

    # Do NOT simplify to (Get-AzAccessToken -ResourceUrl "...").Token -- on this environment's
    # Az.Accounts version, .Token returns a SecureString, not a plain string. Interpolating that
    # into "Bearer $token" silently stringifies to the literal text "System.Security.SecureString"
    # instead of the real token, breaking every REST call in this script with no thrown exception
    # (Azure DevOps returns its HTML sign-in page instead of a clean 401). Confirmed by direct
    # incident on 2026-07-09. The -AsSecureString + PSCredential unwrap below is required.
    $token = (New-Object System.Management.Automation.PSCredential("token", (Get-AzAccessToken -ResourceUrl "499b84ac-1321-427f-aa17-267ca6975798" -AsSecureString).token)).GetNetworkCredential().Password
    $headers = @{
        Authorization  = "Bearer $token"
        "Content-Type" = "application/json"
    }

    # Get current authenticated user from Azure DevOps (needed for AutoApprove's reviewerId)
    $connectionData = Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/connectionData" -Headers $headers -Method Get

    # Existing threads now come from Get-ExistingReviewThreads.ps1 (called once, upstream,
    # and also handed to the LLM as prior-round history) instead of being re-fetched here.
    #
    # Proximity alone (fileName + line tolerance) isn't a safe duplicate signal on its own --
    # two unrelated issues can legitimately sit within a few lines of each other in the same
    # file, and matching on proximity alone would silently drop a genuinely new finding with
    # no trace of it happening. So a candidate within the line window is only treated as a
    # duplicate if its text is also substantially similar to the existing comment -- proximity
    # narrows the candidates, content similarity confirms it's actually the same underlying
    # issue re-surfacing (e.g. after a nearby line shift) rather than a different one.
    $lineTolerance = 3

    # Word-overlap (Jaccard) similarity on the normalized explanation text, ignoring the
    # severity prefix and any suggested-fix code block. This is a cheap heuristic, not
    # semantic understanding -- 0.4 was chosen so that a reworded restatement of the same
    # complaint still matches (most of the key nouns/verbs survive rewording) while two
    # genuinely different complaints that merely share a few common words don't.
    $similarityThreshold = 0.4

    # A second, looser bar used only when file, line window AND severity all agree. The model
    # rewords a finding between rounds: the same "don't track the moving main branch" comment
    # scored 0.29 against its earlier wording, while distinct same-severity comments on
    # unrelated problems scored 0.02-0.14. 0.25 sits between the two.
    $sameSeveritySimilarityThreshold = 0.25

    # Pull-request-level comments (risky deletions) are matched on the file named in the text
    # as well, and the reviewer is asked for at most one finding per deleted file, so the
    # same file plus the same severity is already a strong repeat signal.
    $sameFileSimilarityThreshold = 0.15

    function Get-CommentGistWords($commentText) {
        $gist = ($commentText -replace '(?s)<!--.*?-->', ' ')
        $gist = ($gist -split 'Suggested fix:')[0]
        $gist = $gist -replace '^(🚨|⚠️|💡)\s*(CRITICAL|WARNING|SUGGESTION):?\s*', ''
        $gist = $gist -replace '[^\w\s]', ' '
        $gist = $gist.ToLower()
        return @($gist -split '\s+' | Where-Object { $_.Length -gt 2 } | Select-Object -Unique)
    }

    function Get-CommentSeverity($commentText) {
        if ($commentText -match '^(🚨|⚠️|💡)\s*(CRITICAL|WARNING|SUGGESTION)') {
            return $matches[2]
        }
        return 'UNKNOWN'
    }

    function Test-SimilarComment($textA, $textB, $threshold = $similarityThreshold) {
        $wordsA = Get-CommentGistWords $textA
        $wordsB = Get-CommentGistWords $textB
        if ($wordsA.Count -eq 0 -or $wordsB.Count -eq 0) {
            return $false
        }
        $intersection = @($wordsA | Where-Object { $wordsB -contains $_ })
        $union = @($wordsA + $wordsB | Select-Object -Unique)
        return ($intersection.Count / $union.Count) -ge $threshold
    }

    # Looser bar for a fingerprint match: the line of code is the same one, so only a clearly
    # different complaint (different severity AND almost no shared words) is let through.
    $sameAnchorSimilarityThreshold = 0.15

    function Test-DuplicateComment($fileName, $lineNumber, $commentText, $fingerprint = $null) {
        # lineNumber 0 (or less) means a pull-request-level finding with no file anchor.
        if ($lineNumber -le 0) {
            $normalizedPath = $fileName.ToLower()
            if (-not $normalizedPath.StartsWith('/')) {
                $normalizedPath = "/$normalizedPath"
            }
            foreach ($thread in $ExistingThreads) {
                # The file is named in the comment text ("File: `path`"), so only a thread about
                # the same file can be a repeat. Two deletions must never suppress each other.
                if ($thread.FileName -ne '(pull request)' -or -not $thread.CommentText.ToLower().Contains($normalizedPath)) {
                    continue
                }
                # Drop the trailing "File: `path`" line we add to PR-level comments; the new
                # comment does not carry it, so it would only dilute the word overlap.
                $existingText = $thread.CommentText -replace '(?s)\s*File: `[^`]*`\s*$', ''
                if (Test-SimilarComment $commentText $existingText) {
                    return $true
                }
                $severity = Get-CommentSeverity $commentText
                if ($severity -ne 'UNKNOWN' -and $severity -eq (Get-CommentSeverity $existingText) -and
                    (Test-SimilarComment $commentText $existingText $sameFileSimilarityThreshold)) {
                    return $true
                }
            }
            return $false
        }

        $normalizedPath = $fileName.ToLower()
        if (-not $normalizedPath.StartsWith('/')) {
            $normalizedPath = "/$normalizedPath"
        }

        # Same file and same code line, wherever the line is now: a thread the bot started on this
        # exact line of code is the same finding, however the comment is worded.
        if ($fingerprint) {
            foreach ($thread in $ExistingThreads) {
                if ($thread.Fingerprint -and $thread.Fingerprint -eq $fingerprint) {
                    $severity = Get-CommentSeverity $commentText
                    if (($severity -ne 'UNKNOWN' -and $severity -eq (Get-CommentSeverity $thread.CommentText)) -or
                        (Test-SimilarComment $commentText $thread.CommentText $sameAnchorSimilarityThreshold)) {
                        return $true
                    }
                }
            }
        }

        foreach ($thread in $ExistingThreads) {
            if ($thread.FileName -eq $normalizedPath -and [Math]::Abs($thread.LineNumber - $lineNumber) -le $lineTolerance) {
                if (Test-SimilarComment $commentText $thread.CommentText) {
                    return $true
                }
                $severity = Get-CommentSeverity $commentText
                if ($severity -ne 'UNKNOWN' -and $severity -eq (Get-CommentSeverity $thread.CommentText) -and
                    (Test-SimilarComment $commentText $thread.CommentText $sameSeveritySimilarityThreshold)) {
                    return $true
                }
            }
        }
        return $false
    }

    # Parse and validate reviews
    try {
        $reviewsObject = $Reviews | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $rawPreview = if ($Reviews.Length -gt 800) { $Reviews.Substring(0, 800) + '... (truncated)' } else { $Reviews }
        Write-Host "LLM output was not valid JSON. Raw output (truncated in logs for security):`n$rawPreview"
        throw "Failed to parse LLM review output as JSON: $_"
    }

    if ($null -eq $reviewsObject.reviews -or $reviewsObject.reviews.Count -eq 0) {
        Write-Host "No reviews to post."

        $autoApproved = $false
        if ($AutoApprove) {
            Write-Host "AutoApprove enabled: Approving pull request..." -ForegroundColor Cyan
            $reviewerId = $connectionData.authenticatedUser.id
            $approveUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/reviewers/$($reviewerId)?api-version=7.1"

            $approveBody = @{
                vote = 10
            }

            try {
                $null = Invoke-RestMethod -Uri $approveUrl -Headers $headers -Method Put -Body ($approveBody | ConvertTo-Json -Depth 10)
                Write-Host "Pull request approved successfully." -ForegroundColor Green
                $autoApproved = $true
            }
            catch {
                Write-Warning "Failed to approve pull request: $_"
            }
        }

        return [PSCustomObject]@{
            CommentsProposed         = 0
            CommentsPosted           = 0
            CommentsSkippedDuplicate = 0
            Outcome                  = if ($autoApproved) { 'auto-approved' } else { 'no-comments' }
            AutoApproved             = $autoApproved
            SeverityBreakdown        = @{ critical = 0; warning = 0; suggestion = 0; unknown = 0 }
            FilesWithComments        = @()
        }
    }

    # Filter out duplicate reviews
    $newReviews = @($reviewsObject.reviews | Where-Object {
        -not (Test-DuplicateComment $_.fileName $_.lineNumber $_.comment $_.fingerprint)
    })

    # The same finding can also arrive twice in one run (two batches, or two items in one
    # answer). Keep the first of each.
    $uniqueReviews = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $newReviews) {
        $isRepeat = $false
        foreach ($kept in $uniqueReviews) {
            if ($kept.fileName -ne $candidate.fileName) { continue }
            $sameFingerprint = $candidate.fingerprint -and $kept.fingerprint -eq $candidate.fingerprint
            $sameLine = $kept.lineNumber -eq $candidate.lineNumber -and $candidate.lineNumber -gt 0
            if (($sameFingerprint -and (Test-SimilarComment $candidate.comment $kept.comment $sameAnchorSimilarityThreshold)) -or
                ($sameLine -and (Test-SimilarComment $candidate.comment $kept.comment))) {
                $isRepeat = $true
                break
            }
        }
        if ($isRepeat) {
            Write-Host "Dropping a repeat of a comment already proposed in this run on '$($candidate.fileName)' line $($candidate.lineNumber)."
        }
        else {
            $uniqueReviews.Add($candidate)
        }
    }
    $newReviews = @($uniqueReviews)

    if ($newReviews.Count -eq 0) {
        Write-Host "All comments already exist. No new comments to post." -ForegroundColor Yellow
        return [PSCustomObject]@{
            CommentsProposed         = $reviewsObject.reviews.Count
            CommentsPosted           = 0
            CommentsSkippedDuplicate = $reviewsObject.reviews.Count
            Outcome                  = 'no-comments'
            AutoApproved             = $false
            SeverityBreakdown        = @{ critical = 0; warning = 0; suggestion = 0; unknown = 0 }
            FilesWithComments        = @()
        }
    }

    $skipped = $reviewsObject.reviews.Count - $newReviews.Count
    if ($skipped -gt 0) {
        Write-Host "Skipping $skipped duplicate comment(s)" -ForegroundColor Yellow
    }

    # Post new reviews
    $createThreadUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/threads?api-version=7.1"

    $postedCount = 0
    $severityBreakdown = @{ critical = 0; warning = 0; suggestion = 0; unknown = 0 }
    $filesWithComments = @()
    foreach ($review in $newReviews) {
        # Determine line range for suggestions
        $startLine = $review.lineNumber
        $endLine = $review.lineNumber
        $endOffset = 1000

        # Ensure a leading slash (Get-CodeChanges.ps1 always sends paths this way), but
        # preserve original casing -- Azure DevOps file paths are case-sensitive, so
        # normalizing case here (unlike the lowercase-only comparison keys above) would
        # break thread anchoring for any file with uppercase characters in its name.
        $postPath = $review.fileName
        if (-not $postPath.StartsWith('/')) {
            $postPath = "/$postPath"
        }

        $isPullRequestLevel = $review.lineNumber -le 0
        $commentContent = $review.comment
        if ($isPullRequestLevel) {
            # No file anchor: name the file in the text so the comment stands on its own.
            $commentContent = "$($review.comment)`n`nFile: ``$postPath``"
        }

        # Hidden marker (an HTML comment, not rendered): identifies the comment as the bot's and
        # carries the fingerprint of the code line it is about, for the next round.
        $marker = if ($review.fingerprint) { "<!-- aicr:v1 fp=$($review.fingerprint) -->" } else { '<!-- aicr:v1 -->' }
        $commentContent = "$commentContent`n`n$marker"

        $threadBody = @{
            comments = @(
                @{
                    parentCommentId = 0
                    content         = $commentContent
                    commentType     = 1
                }
            )
            status   = 1
        }
        if (-not $isPullRequestLevel) {
            $threadBody['threadContext'] = @{
                filePath       = $postPath
                rightFileStart = @{ line = $startLine; offset = 1 }
                rightFileEnd   = @{ line = $endLine; offset = $endOffset }
            }
        }

        try {
            $response = Invoke-RestMethod -Uri $createThreadUrl -Headers $headers -Method Post -Body ($threadBody | ConvertTo-Json -Depth 10)
            Write-Host "Comment posted on '$($review.fileName)' line $($review.lineNumber) (Thread ID: $($response.id))" -ForegroundColor Green
            $postedCount++
            if (-not $isPullRequestLevel) {
                $filesWithComments += $postPath
            }

            # Severity is the leading "<emoji> <LEVEL>" of the comment text, per the
            # "Severity Levels" convention
            # Anything that doesn't match one of the three defined tiers (or a comment
            # the model didn't format as instructed) counts as "unknown" rather than
            # being silently dropped from the breakdown.
            if ($review.comment -match '^(🚨|⚠️|💡)\s*(CRITICAL|WARNING|SUGGESTION)') {
                switch ($matches[2]) {
                    'CRITICAL'   { $severityBreakdown.critical++ }
                    'WARNING'    { $severityBreakdown.warning++ }
                    'SUGGESTION' { $severityBreakdown.suggestion++ }
                }
            } else {
                $severityBreakdown.unknown++
            }
        }
        catch {
            Write-Warning "Failed to post comment on '$($review.fileName)' line $($review.lineNumber): $_"
        }
    }

    return [PSCustomObject]@{
        CommentsProposed         = $reviewsObject.reviews.Count
        CommentsPosted           = $postedCount
        CommentsSkippedDuplicate = $skipped
        Outcome                  = if ($postedCount -gt 0) { 'commented' } else { 'no-comments' }
        AutoApproved             = $false
        SeverityBreakdown        = $severityBreakdown
        FilesWithComments        = @($filesWithComments | Select-Object -Unique)
    }
}
