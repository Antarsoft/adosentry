function ConvertTo-BashSingleQuoted {
    param([string]$Value)
    # Standard POSIX single-quote escaping: close the quote, emit an escaped
    # literal quote, reopen the quote.
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-DefaultExcludePathSpec {
    # Generated, vendored or binary files carry no reviewable intent and burn the review
    # budget. Matched with -like against the repo-relative path (case-insensitive).
    return @(
        # lockfiles
        '*package-lock.json', '*npm-shrinkwrap.json', '*yarn.lock', '*pnpm-lock.yaml',
        '*.terraform.lock.hcl', '*poetry.lock', '*Pipfile.lock', '*composer.lock',
        '*Gemfile.lock', '*Cargo.lock', '*go.sum',
        # generated and minified output
        '*.min.js', '*.min.css', '*.map',
        # images, fonts, documents and archives
        '*.svg', '*.png', '*.jpg', '*.jpeg', '*.gif', '*.ico', '*.webp', '*.bmp',
        '*.pdf', '*.woff', '*.woff2', '*.ttf', '*.eot', '*.otf',
        '*.zip', '*.gz', '*.tgz', '*.tar', '*.7z',
        # compiled binaries and media
        '*.exe', '*.dll', '*.so', '*.dylib', '*.class', '*.jar', '*.mp4', '*.mov', '*.mp3'
    )
}

function Test-ReviewPathExcluded {
    param(
        [string]$Path,
        [string[]]$ExcludePathSpec
    )

    if ($ExcludePathSpec.Count -eq 0) {
        return $false
    }

    $normalizedPath = ($Path -replace '\\', '/').TrimStart('/')
    foreach ($pattern in $ExcludePathSpec) {
        $likePattern = ($pattern -replace '\\', '/').TrimStart('/')
        if ($normalizedPath -like $likePattern) {
            return $true
        }
    }

    return $false
}

function Get-DiffLegend {
    param(
        [string]$RenamedSourceBranch,
        [string]$RenamedTargetBranch
    )

    return @"
# Code Review - Changes from $RenamedSourceBranch to $RenamedTargetBranch

## Legend:
- `+` = Added lines (new code)
- `-` = Removed lines (deleted code)
- `  ` = Unchanged lines (context)
- `Renamed from:` = the file was renamed or moved; only its content changes are shown

---

"@
}

function Add-ParsedDiffToBuilder {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$FullPath,
        [string[]]$DiffLines,
        [ref]$TotalAdded,
        [ref]$TotalRemoved,
        [string]$Notice = '',
        [hashtable]$Anchors = $null,
        [hashtable]$LineText = $null
    )

    [void]$Builder.Append("## File: $FullPath`n`n")

    $renamedFrom = $null
    $similarity = $null
    foreach ($headerLine in $DiffLines) {
        if ($headerLine -match '^@@ ') { break }
        if ($headerLine -match '^rename from (.+)$') { $renamedFrom = $matches[1] }
        elseif ($headerLine -match '^similarity index (\d+)%') { $similarity = $matches[1] }
    }

    if ($renamedFrom) {
        $oldFullPath = if ($renamedFrom.StartsWith('/')) { $renamedFrom } else { "/$renamedFrom" }
        $similarityText = if ($similarity) { " (similarity $similarity%)" } else { '' }
        [void]$Builder.Append("Renamed from: $oldFullPath$similarityText`n`n")
    }

    $inHunk = $false
    $oldLineNum = 0
    $newLineNum = 0
    $hunkContent = [System.Collections.Generic.List[string]]::new()
    $addedLines = 0
    $removedLines = 0
    $hunksSeen = 0

    foreach ($line in $DiffLines) {
        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            if ($hunkContent.Count -gt 0) {
                [void]$Builder.Append("### Changes: +$addedLines lines, -$removedLines lines`n")
                [void]$Builder.Append(($hunkContent -join "`n"))
                [void]$Builder.Append("`n`n")
                $TotalAdded.Value += $addedLines
                $TotalRemoved.Value += $removedLines
            }

            $hunkContent.Clear()
            $addedLines = 0
            $removedLines = 0
            $hunksSeen++
            $inHunk = $true
            $oldLineNum = [int]$matches[1]
            $newLineNum = [int]$matches[3]
            continue
        }

        # Git's own markers are only skipped outside a hunk. Inside a hunk every line starts
        # with ' ', '+' or '-', so a removed line whose text starts with "--" (a SQL comment,
        # a YAML "---" separator, a markdown rule) looks like a "---" header and must be kept.
        if ($line.StartsWith('\ No newline')) {
            continue
        }
        if (-not $inHunk -and ($line -match '^(diff --git|index|\+\+\+|---)' -or $line.StartsWith('Binary file'))) {
            continue
        }

        if ($inHunk) {
            if ($line.StartsWith('+')) {
                $hunkContent.Add($newLineNum.ToString().PadLeft(4) + '+ ' + $line.Substring(1))
                if ($null -ne $Anchors) { $Anchors[$newLineNum] = 'added' }
                if ($null -ne $LineText) { $LineText[$newLineNum] = $line.Substring(1) }
                $newLineNum++
                $addedLines++
            }
            elseif ($line.StartsWith('-')) {
                $hunkContent.Add($oldLineNum.ToString().PadLeft(4) + '- ' + $line.Substring(1))
                $oldLineNum++
                $removedLines++
            }
            elseif ($line.StartsWith(' ')) {
                $hunkContent.Add($newLineNum.ToString().PadLeft(4) + '  ' + $line.Substring(1))
                if ($null -ne $Anchors) { $Anchors[$newLineNum] = 'context' }
                if ($null -ne $LineText) { $LineText[$newLineNum] = $line.Substring(1) }
                $oldLineNum++
                $newLineNum++
            }
            else {
                $inHunk = $false
            }
        }
    }

    if ($hunkContent.Count -gt 0) {
        [void]$Builder.Append("### Changes: +$addedLines lines, -$removedLines lines`n")
        [void]$Builder.Append(($hunkContent -join "`n"))
        [void]$Builder.Append("`n")
        $TotalAdded.Value += $addedLines
        $TotalRemoved.Value += $removedLines
    }
    elseif ($renamedFrom -and $hunksSeen -eq 0) {
        # A pure rename has no hunks, so there is no line to anchor a comment on. Tell the
        # model to anchor any comment about the rename at line 1 of the (unchanged) file.
        [void]$Builder.Append("### Changes: renamed, no content changes`n")
        [void]$Builder.Append("   1  (file content unchanged; anchor any comment about this rename at lineNumber 1)`n")
        if ($null -ne $Anchors) { $Anchors[1] = 'context' }
    }

    if ($Notice) {
        [void]$Builder.Append($Notice)
    }

    [void]$Builder.Append("`n---`n")
}

function Get-ChangedFileEntries {
    param(
        [string]$DiffRange,
        [string[]]$PathSpec = @()
    )

    # --name-status reports how git classifies each change: A(dded), M(odified), D(eleted) and
    # R(enamed, which includes a move to another directory). A rename is NOT a modification, so
    # --diff-filter=AM used to drop renamed files entirely, including any edits made to them.
    # core.quotepath=off keeps non-ASCII file names literal instead of octal-escaped.
    if ($PathSpec.Count -gt 0) {
        $quotedRange = ConvertTo-BashSingleQuoted $DiffRange
        $quotedPathSpec = ($PathSpec | ForEach-Object { ConvertTo-BashSingleQuoted $_ }) -join ' '
        $lines = @(bash -c "git -c core.quotepath=off diff --name-status --diff-filter=AMRD $quotedRange -- $quotedPathSpec")
    }
    else {
        $lines = @(git -c core.quotepath=off diff --name-status --diff-filter=AMRD $DiffRange)
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split "`t"
        $status = $parts[0].Substring(0, 1)
        if ($status -eq 'R' -and $parts.Count -ge 3) {
            $entries.Add([PSCustomObject]@{ Status = 'R'; Path = $parts[2]; OldPath = $parts[1] })
        }
        elseif ($parts.Count -ge 2) {
            $entries.Add([PSCustomObject]@{ Status = $status; Path = $parts[1]; OldPath = $null })
        }
    }

    return @($entries)
}

function Get-FileDiffSections {
    param(
        [string]$RenamedTargetBranch,
        [string]$RenamedSourceBranch,
        [string[]]$Files,
        [hashtable]$RenamedFrom = @{}
    )

    if ($Files.Count -eq 0) {
        return @{}
    }

    # For a renamed file the old path must be in the pathspec too. With only the new path git
    # cannot pair the rename and would show the whole file as newly added; with both paths it
    # reports just the real content changes (or no hunks at all for a pure rename).
    $pathSpec = @($Files)
    foreach ($file in $Files) {
        if ($RenamedFrom.ContainsKey($file) -and $RenamedFrom[$file]) {
            $pathSpec += $RenamedFrom[$file]
        }
    }

    $diffLines = git -c core.quotepath=off diff "$RenamedTargetBranch...$RenamedSourceBranch" --unified=5 -- @pathSpec
    $sections = [ordered]@{}
    $currentFile = $null
    $currentLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $diffLines) {
        if ($line -match '^diff --git a/(.+?) b/(.+)$') {
            if ($currentFile) {
                $sections[$currentFile] = @($currentLines.ToArray())
            }

            $currentFile = $matches[2]
            $currentLines = [System.Collections.Generic.List[string]]::new()
            continue
        }

        if ($currentFile) {
            $currentLines.Add($line)
        }
    }

    if ($currentFile) {
        $sections[$currentFile] = @($currentLines.ToArray())
    }

    return $sections
}

function Get-DeletedFilesNotice {
    param(
        [string[]]$DeletedFiles,
        [int]$MaxListed = 50
    )

    if ($DeletedFiles.Count -eq 0) {
        return ''
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append("## Deleted files (content not shown)`n`n")
    foreach ($deleted in ($DeletedFiles | Select-Object -First $MaxListed)) {
        $fullPath = if ($deleted.StartsWith('/')) { $deleted } else { "/$deleted" }
        [void]$builder.Append("- $fullPath`n")
    }
    if ($DeletedFiles.Count -gt $MaxListed) {
        [void]$builder.Append("- ... and $($DeletedFiles.Count - $MaxListed) more`n")
    }
    [void]$builder.Append("`nThis pull request deletes the files above. A deleted file has no lines to comment on. ")
    [void]$builder.Append("If a deletion looks risky (for example it removes infrastructure, an export that consumers import, ")
    [void]$builder.Append("or code that is still referenced elsewhere), report it with ``fileName`` set to the deleted path and ")
    [void]$builder.Append("``lineNumber`` 0; a comment with lineNumber 0 is posted on the pull request as a whole. Otherwise ")
    [void]$builder.Append("say nothing about deleted files.`n`n---`n`n")

    return $builder.ToString()
}

function Get-EstimatedTokenCount {
    param([string]$Text)

    # No tokenizer is available in the pipeline, so estimate from the character count. Code
    # tokenizes at roughly 3 to 4 characters per token; 3.5 errs on the side of too many tokens.
    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }

    return [int][Math]::Ceiling($Text.Length / 3.5)
}

function New-FileDiffBlock {
    param(
        [string]$File,
        [string[]]$DiffLines,
        [int]$MaxFileTokens = 0
    )

    # Renders one file's diff and measures it. A diff above MaxFileTokens is cut at a line
    # boundary and carries a notice, so one huge file cannot crowd everything else out of a batch.
    $lines = @($DiffLines)
    $omittedLines = 0
    if ($MaxFileTokens -gt 0) {
        $maxChars = [int]($MaxFileTokens * 3.5)
        $total = 0
        $keep = 0
        foreach ($line in $lines) {
            $total += $line.Length + 1
            if ($total -gt $maxChars -and $keep -gt 0) { break }
            $keep++
        }
        if ($keep -lt $lines.Count) {
            $omittedLines = $lines.Count - $keep
            $lines = @($lines[0..($keep - 1)])
        }
    }

    $notice = ''
    if ($omittedLines -gt 0) {
        $notice = "### Diff truncated: the remaining $omittedLines line(s) of this file's diff are not shown because the file is too large for one review request. Only comment on the code shown above, and do not infer anything about the part you cannot see.`n"
    }

    $fullPath = if ($File.StartsWith('/')) { $File } else { "/$File" }
    $builder = [System.Text.StringBuilder]::new()
    $added = 0
    $removed = 0
    $addedRef = [ref]$added
    $removedRef = [ref]$removed
    # Anchor map: the new-side line numbers shown to the model, flagged added or context.
    # It is what a comment's lineNumber is checked against before posting.
    $anchors = @{}
    $lineText = @{}
    Add-ParsedDiffToBuilder -Builder $builder -FullPath $fullPath -DiffLines $lines -TotalAdded $addedRef -TotalRemoved $removedRef -Notice $notice -Anchors $anchors -LineText $lineText
    $text = $builder.ToString()

    return [PSCustomObject]@{
        File         = $File
        FullPath     = $fullPath
        Anchors      = $anchors
        LineText     = $lineText
        Text         = $text
        Added        = $added
        Removed      = $removed
        Tokens       = Get-EstimatedTokenCount -Text $text
        Truncated    = ($omittedLines -gt 0)
        OmittedLines = $omittedLines
    }
}

function Split-BlocksIntoBatches {
    param(
        [array]$Blocks,
        [int]$MaxFiles = 0,
        [int]$MaxTokens = 0,
        [int]$OverheadTokens = 0
    )

    # Packs files into batches in order, starting a new batch when adding the next file would
    # pass the file limit or the token budget. A batch always holds at least one file. Emits one
    # array per batch; callers must collect the result with @(...) (see Split-IntoBatches).
    if ($Blocks.Count -eq 0) {
        return
    }

    $current = [System.Collections.Generic.List[object]]::new()
    $currentTokens = $OverheadTokens
    foreach ($block in $Blocks) {
        $overFiles = $MaxFiles -gt 0 -and $current.Count -ge $MaxFiles
        $overTokens = $MaxTokens -gt 0 -and $current.Count -gt 0 -and ($currentTokens + $block.Tokens) -gt $MaxTokens
        if ($overFiles -or $overTokens) {
            , @($current.ToArray())
            $current = [System.Collections.Generic.List[object]]::new()
            $currentTokens = $OverheadTokens
        }
        $current.Add($block)
        $currentTokens += $block.Tokens
    }

    if ($current.Count -gt 0) {
        , @($current.ToArray())
    }
}

function New-CodeChangesBatchObject {
    param(
        [string]$Legend,
        [int]$BatchNumber,
        [int]$BatchCount,
        [string]$DeletedNotice = '',
        [int]$DeletedFileCount = 0,
        [object[]]$Blocks = @()
    )

    $prefix = $Legend
    if ($BatchCount -gt 1) {
        $prefix += "## Review batch $BatchNumber of $BatchCount`n`n---`n`n"
    }
    $prefix += $DeletedNotice

    $blockList = @($Blocks | Where-Object { $_ })
    $batchAnchors = @{}
    $batchLineText = @{}
    foreach ($block in $blockList) {
        if ($block.FullPath) {
            $batchAnchors[$block.FullPath] = $block.Anchors
            $batchLineText[$block.FullPath] = $block.LineText
        }
    }
    $text = $prefix + (($blockList | ForEach-Object { $_.Text }) -join '')

    return [PSCustomObject]@{
        Changes          = $text
        FilesReviewed    = $blockList.Count
        LinesAdded       = [int](@($blockList | ForEach-Object { $_.Added }) | Measure-Object -Sum).Sum
        LinesRemoved     = [int](@($blockList | ForEach-Object { $_.Removed }) | Measure-Object -Sum).Sum
        FileNames        = @($blockList | ForEach-Object { $_.File })
        DeletedFileCount = $DeletedFileCount
        EstimatedTokens  = Get-EstimatedTokenCount -Text $text
        Blocks           = $blockList
        Legend           = $Legend
        BatchNumber      = $BatchNumber
        BatchCount       = $BatchCount
        DeletedNotice    = $DeletedNotice
        TruncatedFiles   = @($blockList | Where-Object { $_.Truncated } | ForEach-Object { $_.File })
        Anchors          = $batchAnchors
        LineText         = $batchLineText
    }
}

function Split-CodeChangesBatch {
    param($Batch)

    # Used when the model rejects a batch as too large: rebuild it as two halves. The deleted-file
    # list stays with the first half.
    $blocks = @($Batch.Blocks)
    if ($blocks.Count -lt 2) {
        return @($Batch)
    }

    $mid = [int][Math]::Ceiling($blocks.Count / 2)
    $first = New-CodeChangesBatchObject -Legend $Batch.Legend -BatchNumber $Batch.BatchNumber -BatchCount $Batch.BatchCount `
        -DeletedNotice $Batch.DeletedNotice -DeletedFileCount $Batch.DeletedFileCount -Blocks @($blocks[0..($mid - 1)])
    $second = New-CodeChangesBatchObject -Legend $Batch.Legend -BatchNumber $Batch.BatchNumber -BatchCount $Batch.BatchCount `
        -Blocks @($blocks[$mid..($blocks.Count - 1)])

    return @($first, $second)
}

function Split-IntoBatches {
    param(
        [array]$Items,
        [int]$BatchSize
    )

    # Always emits one array object per batch. Callers must collect the result with @(...),
    # otherwise PowerShell unrolls a single batch into its items and every file ends up in
    # a batch of its own.
    if ($Items.Count -eq 0) {
        return
    }

    if ($BatchSize -le 0 -or $Items.Count -le $BatchSize) {
        return , @($Items)
    }

    for ($index = 0; $index -lt $Items.Count; $index += $BatchSize) {
        $end = [Math]::Min($index + $BatchSize - 1, $Items.Count - 1)
        , @($Items[$index..$end])
    }
}

function Get-CodeChanges {
    param (
        [string]$TargetBranch,
        [string]$SourceBranch,
        [string[]]$PathSpec = @(),
        [string[]]$ExcludePathSpec = @(),
        [int]$MaxFilesPerBatch = 25,
        [bool]$ReviewDeletedFiles = $false,
        [bool]$UseDefaultExcludes = $true,
        [int]$MaxBatchTokens = 300000,
        [int]$MaxFileTokens = 80000
    )

    $renamedSourceBranch = $SourceBranch -replace 'refs/heads/', 'origin/'
    $renamedTargetBranch = $TargetBranch -replace 'refs/heads/', 'origin/'
    $diffRange = "$renamedTargetBranch...$renamedSourceBranch"

    if ($UseDefaultExcludes) {
        $ExcludePathSpec = @($ExcludePathSpec) + @(Get-DefaultExcludePathSpec)
    }

    $changedEntries = @(Get-ChangedFileEntries -DiffRange $diffRange -PathSpec $PathSpec)
    $filesToReview = [System.Collections.Generic.List[string]]::new()
    $filesExcluded = [System.Collections.Generic.List[string]]::new()
    $deletedFiles = [System.Collections.Generic.List[string]]::new()
    $renamedFrom = @{}
    $totalFilesChanged = 0

    foreach ($entry in $changedEntries) {
        if ([string]::IsNullOrWhiteSpace($entry.Path)) {
            continue
        }

        if ($entry.Status -eq 'D') {
            if ($ReviewDeletedFiles -and -not (Test-ReviewPathExcluded -Path $entry.Path -ExcludePathSpec $ExcludePathSpec)) {
                $deletedFiles.Add($entry.Path)
            }
            continue
        }

        $totalFilesChanged++

        if (Test-ReviewPathExcluded -Path $entry.Path -ExcludePathSpec $ExcludePathSpec) {
            $filesExcluded.Add($entry.Path)
            continue
        }

        $filesToReview.Add($entry.Path)
        if ($entry.Status -eq 'R') {
            $renamedFrom[$entry.Path] = $entry.OldPath
        }
    }

    if ($filesExcluded.Count -gt 0) {
        Write-Host "Excluded $($filesExcluded.Count) changed file(s) (default excludes and reviewExcludePathSpec)."
    }

    if ($renamedFrom.Count -gt 0) {
        Write-Host "Including $($renamedFrom.Count) renamed or moved file(s) in the review."
    }

    if ($deletedFiles.Count -gt 0) {
        Write-Host "Listing $($deletedFiles.Count) deleted file(s) for the reviewer (reviewDeletedFiles is on)."
    }

    $diffSections = Get-FileDiffSections -RenamedTargetBranch $renamedTargetBranch -RenamedSourceBranch $renamedSourceBranch -Files @($filesToReview) -RenamedFrom $renamedFrom
    $blocks = @(foreach ($file in $filesToReview) {
            Write-Host "Processing: $file"
            if ($diffSections.Contains($file)) {
                New-FileDiffBlock -File $file -DiffLines $diffSections[$file] -MaxFileTokens $MaxFileTokens
            }
        })

    $truncatedFiles = @($blocks | Where-Object { $_.Truncated })
    foreach ($truncated in $truncatedFiles) {
        Write-Host "Diff of $($truncated.File) is larger than the per-file limit of about $MaxFileTokens tokens: $($truncated.OmittedLines) diff line(s) are not reviewed."
    }

    $legend = Get-DiffLegend -RenamedSourceBranch $renamedSourceBranch -RenamedTargetBranch $renamedTargetBranch
    $deletedNotice = Get-DeletedFilesNotice -DeletedFiles @($deletedFiles)
    $overheadTokens = (Get-EstimatedTokenCount -Text ($legend + $deletedNotice)) + 100

    $blockBatches = @(Split-BlocksIntoBatches -Blocks $blocks -MaxFiles $MaxFilesPerBatch -MaxTokens $MaxBatchTokens -OverheadTokens $overheadTokens)
    $batchCount = $blockBatches.Count
    if ($batchCount -gt 1) {
        Write-Host "Splitting $($blocks.Count) file(s) into $batchCount review batch(es) (max $MaxFilesPerBatch file(s) and about $MaxBatchTokens tokens per batch)."
    }

    $batches = @()
    $batchNumber = 1
    foreach ($batchBlocks in $blockBatches) {
        # The deleted-file list rides along with the first batch only, so the reviewer sees it once.
        $isFirst = ($batchNumber -eq 1)
        $batches += New-CodeChangesBatchObject `
            -Legend $legend `
            -BatchNumber $batchNumber `
            -BatchCount $batchCount `
            -DeletedNotice $(if ($isFirst) { $deletedNotice } else { '' }) `
            -DeletedFileCount $(if ($isFirst) { $deletedFiles.Count } else { 0 }) `
            -Blocks @($batchBlocks)
        $batchNumber++
    }

    if ($batches.Count -eq 0) {
        $batches = @([PSCustomObject]@{
            Changes          = (Get-DiffLegend -RenamedSourceBranch $renamedSourceBranch -RenamedTargetBranch $renamedTargetBranch) + (Get-DeletedFilesNotice -DeletedFiles @($deletedFiles))
            FilesReviewed    = 0
            LinesAdded       = 0
            LinesRemoved     = 0
            FileNames        = @()
            DeletedFileCount = $deletedFiles.Count
        })
    }

    $allAnchors = @{}
    $allLineText = @{}
    foreach ($batch in $batches) {
        if ($batch.Anchors) {
            foreach ($path in $batch.Anchors.Keys) {
                $allAnchors[$path] = $batch.Anchors[$path]
                $allLineText[$path] = $batch.LineText[$path]
            }
        }
    }

    $totalFilesReviewed = ($batches | ForEach-Object { $_.FilesReviewed } | Measure-Object -Sum).Sum
    $totalLinesAdded = ($batches | ForEach-Object { $_.LinesAdded } | Measure-Object -Sum).Sum
    $totalLinesRemoved = ($batches | ForEach-Object { $_.LinesRemoved } | Measure-Object -Sum).Sum

    return [PSCustomObject]@{
        Batches           = $batches
        FilesReviewed     = $totalFilesReviewed
        LinesAdded        = $totalLinesAdded
        LinesRemoved      = $totalLinesRemoved
        TotalFilesChanged = $totalFilesChanged
        FilesExcluded     = @($filesExcluded)
        FilesRenamed      = $renamedFrom.Count
        FilesDeleted      = $deletedFiles.Count
        FilesTruncated    = @($truncatedFiles | ForEach-Object { $_.File })
        Anchors           = $allAnchors
        LineText          = $allLineText
        DeletedFilePaths  = @($deletedFiles | ForEach-Object { if ($_.StartsWith('/')) { $_ } else { "/$_" } })
        BatchCount        = $batchCount
    }
}
