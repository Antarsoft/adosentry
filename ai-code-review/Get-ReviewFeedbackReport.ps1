<#
.SYNOPSIS
    Aggregates outcomes of AI code review comments across completed PRs.

.DESCRIPTION
    Scans completed pull requests in the given repositories for comment threads
    posted by the AI code reviewer, and summarizes what happened to each one
    (fixed, wontFix, or left active) grouped by severity. Use this to spot
    which review rules are noisy or well-calibrated before hand-editing the
    review prompt (pipelines/ai-code-review/prompts/*.codereviewprompt.md).

    This is an ad hoc reporting tool, not part of the PR pipeline -- run it
    manually, on your own machine or any box with pwsh + the Az module. It
    only makes REST API calls, so it doesn't need a repo checkout.

.PARAMETER RepositoryNames
    One or more Azure DevOps repository names to scan.

.PARAMETER Organization
    Azure DevOps organization name.

.PARAMETER Project
    Azure DevOps project name.

.PARAMETER Since
    Only include PRs completed on or after this date. Defaults to 30 days ago.

.PARAMETER OutputPath
    Where to write the full per-comment CSV. Defaults to a timestamped file
    in the current directory.

.PARAMETER BotDisplayName
    The AI reviewer's Azure DevOps display name, used to identify which PR
    comments were posted by it. The display name of the service principal the
    pipeline runs as (shown as the comment author in Azure DevOps). When run locally under your own login (rather than
    the pipeline's service connection), the authenticated identity is you,
    not the bot -- so this must be matched against a fixed, known name
    rather than "whoever is currently logged in".

.EXAMPLE
    Connect-AzAccount
    ./Get-ReviewFeedbackReport.ps1 `
        -RepositoryNames @('my-repo', 'other-repo') `
        -Organization 'my-org' `
        -Project 'my-project' `
        -BotDisplayName 'my-org-my-project-<service-connection-guid>' `
        -Since (Get-Date).AddDays(-30)

.NOTES
    Requires an authenticated Az context (run Connect-AzAccount first) with
    read access to the target Azure DevOps org/project -- the pipeline scripts
    get this for free from the service connection, this one doesn't.
#>
param(
    [parameter(Mandatory)]
    [string[]]
    $RepositoryNames,

    [parameter(Mandatory)]
    [string]
    $Organization,

    [parameter(Mandatory)]
    [string]
    $Project,

    [datetime]
    $Since = (Get-Date).AddDays(-30),

    [string]
    $OutputPath = "./ai-review-feedback-$(Get-Date -Format 'yyyyMMdd').csv",

    [parameter(Mandatory)]
    [string]
    $BotDisplayName
)

$token = (New-Object System.Management.Automation.PSCredential(
    "token", (Get-AzAccessToken -ResourceUrl "499b84ac-1321-427f-aa17-267ca6975798" -AsSecureString).token
)).GetNetworkCredential().Password
$headers = @{ Authorization = "Bearer $token" }

Write-Host "Looking for review comments from: $BotDisplayName"

$results = foreach ($repo in $RepositoryNames) {
    Write-Host "Scanning $repo since $($Since.ToString('yyyy-MM-dd'))..."

    $prsUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repo/pullrequests" +
              "?searchCriteria.status=completed&searchCriteria.minTime=$($Since.ToString('o'))&api-version=7.1"
    $prs = (Invoke-RestMethod -Uri $prsUrl -Headers $headers).value

    foreach ($pr in $prs) {
        $threadsUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repo/pullRequests/$($pr.pullRequestId)/threads?api-version=7.1"
        $threads = (Invoke-RestMethod -Uri $threadsUrl -Headers $headers).value

        foreach ($thread in $threads) {
            if ($thread.isDeleted -or -not $thread.threadContext) { continue }

            $botComment = $thread.comments | Where-Object { $_.author.displayName -eq $BotDisplayName } | Select-Object -First 1
            if (-not $botComment) { continue }

            $severity = if ($botComment.content -match '^(🚨|⚠️|💡)\s*(CRITICAL|WARNING|SUGGESTION)') { $matches[2] } else { 'UNKNOWN' }

            [PSCustomObject]@{
                Repo       = $repo
                PR         = $pr.pullRequestId
                File       = $thread.threadContext.filePath
                Severity   = $severity
                Status     = $thread.status
                ClosedDate = $thread.comments[-1].publishedDate
            }
        }
    }
}

if (-not $results) {
    Write-Host "No AI review threads found in the given window."
    return
}

Write-Host "`nSummary (by severity and outcome):"
$results | Group-Object Severity, Status |
    Select-Object @{n = 'Severity'; e = { $_.Values[0] } }, @{n = 'Status'; e = { $_.Values[1] } }, Count |
    Sort-Object Severity, Status |
    Format-Table -AutoSize

$results | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "`nFull detail written to $OutputPath"
