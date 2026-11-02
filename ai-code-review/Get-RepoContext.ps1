# Repository context for a review (opt-in, reviewRepoContext). Everything here is read-only and
# comes from the checkout the pipeline already made, through git: no clone, no Azure DevOps API
# call and no new permission. The pull request author can change any of it, so the caller sends
# it to the model as untrusted data, like the diff.

function Get-TrackedFilePaths {
    param(
        [string]$Ref,
        [string[]]$ExcludePathSpec = @()
    )

    # Every file tracked on the ref, repo-relative with forward slashes, minus the excludes
    # (generated, vendored and binary files carry no context worth paying for).
    $lines = @(git -c core.quotepath=off ls-tree -r --name-only $Ref 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Repository context: could not list the files on $Ref; continuing without a repository map."
        return @()
    }

    return @($lines | Where-Object {
            $_ -and -not (Test-ReviewPathExcluded -Path $_ -ExcludePathSpec $ExcludePathSpec)
        })
}

function Get-RepoMap {
    param(
        [string[]]$Paths = @(),
        [int]$MaxTokens = 3000
    )

    # A compact map of the repository: one line per folder with its file names. When that is over
    # the budget, folders are shown with a file count instead of names, and past that the deepest
    # folders are dropped. It tells the model where things live (is there a shared helpers folder,
    # a tests folder next to this one) for a few thousand tokens at most.
    if ($Paths.Count -eq 0 -or $MaxTokens -le 0) {
        return ''
    }

    $folders = [ordered]@{}
    foreach ($path in ($Paths | Sort-Object)) {
        $slash = $path.LastIndexOf('/')
        $folder = if ($slash -lt 0) { '/' } else { '/' + $path.Substring(0, $slash) + '/' }
        $name = if ($slash -lt 0) { $path } else { $path.Substring($slash + 1) }
        if (-not $folders.Contains($folder)) {
            $folders[$folder] = [System.Collections.Generic.List[string]]::new()
        }
        $folders[$folder].Add($name)
    }

    $header = "## Repository map ($($Paths.Count) files, $($folders.Count) folders)`n`n"
    $maxChars = [int]($MaxTokens * 3.5)

    $named = foreach ($folder in $folders.Keys) { "$folder  $($folders[$folder] -join ', ')" }
    $text = $header + ($named -join "`n") + "`n"
    if ($text.Length -le $maxChars) {
        return $text
    }

    # Too big with names: counts only, shallow folders first, then cut at the budget.
    $counted = @($folders.Keys |
            Sort-Object @{ Expression = { ($_ -split '/').Count } }, @{ Expression = { $_ } } |
            ForEach-Object { "$_  ($($folders[$_].Count) files)" })
    $builder = [System.Text.StringBuilder]::new($header)
    $shown = 0
    foreach ($line in $counted) {
        if ($builder.Length + $line.Length + 60 -gt $maxChars) { break }
        [void]$builder.Append($line).Append("`n")
        $shown++
    }
    if ($shown -lt $counted.Count) {
        [void]$builder.Append("... and $($counted.Count - $shown) deeper folder(s) not shown`n")
    }
    return $builder.ToString()
}
