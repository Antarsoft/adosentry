# Functions behind tools/Invoke-RulesEval.ps1: build the exact review prompt the engine sends
# for a sample change, call a model, and score the answer against the sample's expectations.
# Kept in their own file so the Pester tests can load them without calling a model.

$script:SeverityRank = @{ 'SUGGESTION' = 1; 'WARNING' = 2; 'CRITICAL' = 3 }

# The engine's own functions build the diff format, the fenced user message and the system
# prompt, and check comment anchors, so a rules file is tested with exactly what the pipeline sends.
$engineRoot = Join-Path $PSScriptRoot '..' 'ai-code-review'
. (Join-Path $engineRoot 'Get-CodeChanges.ps1')
. (Join-Path $engineRoot 'Invoke-LLMCodeReview.ps1')

function Get-EvalCase {
    param([string]$CasePath)

    $expectPath = Join-Path $CasePath 'expect.json'
    if (-not (Test-Path $expectPath)) { throw "Sample $CasePath has no expect.json." }
    $expect = Get-Content -Raw -Path $expectPath | ConvertFrom-Json
    $findings = if ($expect.PSObject.Properties['findings']) { @($expect.findings) } else { @() }
    foreach ($finding in $findings) {
        foreach ($field in @('id', 'file', 'anchor', 'minSeverity')) {
            if (-not $finding.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$finding.$field)) {
                throw "Sample $CasePath has a finding without '$field'."
            }
        }
        if (-not $script:SeverityRank.ContainsKey(([string]$finding.minSeverity).ToUpperInvariant())) {
            throw "Sample $CasePath finding '$($finding.id)' has an unknown minSeverity '$($finding.minSeverity)'."
        }
    }

    return [PSCustomObject]@{
        Name        = Split-Path -Leaf $CasePath
        Path        = $CasePath
        Description = if ($expect.PSObject.Properties['description']) { [string]$expect.description } else { '' }
        Findings    = $findings
    }
}

function Get-EvalCaseDiff {
    param([string]$CasePath)

    # A sample is two trees, before/ and after/. git diff --no-index gives the same unified diff
    # the pipeline gets from git, with the before/ and after/ prefixes in place of a/ and b/.
    $before = Join-Path $CasePath 'before'
    $after = Join-Path $CasePath 'after'
    $emptyDir = $null
    if (-not (Test-Path $before)) {
        $emptyDir = Join-Path ([IO.Path]::GetTempPath()) ("rules-eval-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $emptyDir | Out-Null
        $before = $emptyDir
    }

    try {
        $output = & git -c core.quotepath=off diff --no-index --no-color --no-renames -U3 -- $before $after 2>&1
        # Exit code 1 means "differences found", which is the normal case here.
        if ($LASTEXITCODE -gt 1) { throw "git diff failed for $CasePath`: $output" }
    }
    finally {
        if ($emptyDir) { Remove-Item -Recurse -Force $emptyDir }
    }

    $afterPrefix = ($after -replace '\\', '/').TrimStart('/')
    $sections = [ordered]@{}
    $current = $null
    foreach ($line in @($output)) {
        $text = [string]$line
        if ($text.StartsWith('diff --git ')) {
            $current = [System.Collections.Generic.List[string]]::new()
            $sections["pending-$($sections.Count)"] = $current
            continue
        }
        if ($null -eq $current) { continue }
        if ($text -match '^\+\+\+ b/(.+)$') {
            $path = $matches[1] -replace '\\', '/'
            $index = $path.IndexOf($afterPrefix)
            $relative = if ($index -ge 0) { $path.Substring($index + $afterPrefix.Length) } else { $path }
            $key = @($sections.Keys)[-1]
            $sections.Remove($key)
            $sections['/' + $relative.TrimStart('/')] = $current
        }
        $current.Add($text)
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append((Get-DiffLegend -RenamedSourceBranch 'origin/feature/sample' -RenamedTargetBranch 'origin/main'))
    $anchors = @{}
    $lineText = @{}
    $added = 0
    $removed = 0
    foreach ($file in $sections.Keys) {
        if ($file -like 'pending-*') { continue }
        $fileAnchors = @{}
        $fileText = @{}
        Add-ParsedDiffToBuilder -Builder $builder -FullPath $file -DiffLines @($sections[$file]) -TotalAdded ([ref]$added) -TotalRemoved ([ref]$removed) -Anchors $fileAnchors -LineText $fileText
        $anchors[$file] = $fileAnchors
        $lineText[$file] = $fileText
    }

    return [PSCustomObject]@{
        Changes  = $builder.ToString()
        Anchors  = $anchors
        LineText = $lineText
    }
}

function Resolve-FindingLine {
    param($Finding, $Diff)

    # Expectations name a line by a piece of its text, not its number, so a sample can be edited
    # without renumbering. The anchor must sit on exactly one added line of the file, or the
    # finding names which match it means with "occurrence" (1 = first, counted top to bottom).
    $file = [string]$Finding.file
    if (-not $Diff.LineText.ContainsKey($file)) { throw "Finding '$($Finding.id)' names $file, which is not in the sample's diff." }
    $hits = @(@(foreach ($entry in $Diff.LineText[$file].GetEnumerator()) {
                if ($Diff.Anchors[$file][$entry.Key] -eq 'added' -and $entry.Value.Contains([string]$Finding.anchor)) { [int]$entry.Key }
            }) | Sort-Object)
    $occurrence = if ($Finding.PSObject.Properties['occurrence']) { [int]$Finding.occurrence } else { 0 }
    if ($occurrence -gt 0) {
        if ($occurrence -gt $hits.Count) { throw "Finding '$($Finding.id)' asks for occurrence $occurrence of anchor '$($Finding.anchor)', but it matches $($hits.Count) added lines in $file." }
        return $hits[$occurrence - 1]
    }
    if ($hits.Count -ne 1) { throw "Finding '$($Finding.id)' anchor '$($Finding.anchor)' matches $($hits.Count) added lines in $file; it must match exactly one (or set occurrence)." }
    return $hits[0]
}

function Resolve-FindingLocations {
    param($Finding, $Diff)

    # A bug can often be reported fairly on more than one line (a field and the line that writes
    # it, a binding and the role it names). "alsoAt" lists those other lines, each with an
    # anchor and optionally its own file, occurrence and tolerance.
    $tol = if ($Finding.PSObject.Properties['tolerance']) { [int]$Finding.tolerance } else { 2 }
    $locations = [System.Collections.Generic.List[object]]::new()
    $locations.Add([PSCustomObject]@{ File = [string]$Finding.file; Line = (Resolve-FindingLine -Finding $Finding -Diff $Diff); Tolerance = $tol })
    if ($Finding.PSObject.Properties['alsoAt']) {
        foreach ($alt in @($Finding.alsoAt)) {
            $altFile = if ($alt.PSObject.Properties['file']) { [string]$alt.file } else { [string]$Finding.file }
            $altFinding = [PSCustomObject]@{ id = "$($Finding.id) (alsoAt)"; file = $altFile; anchor = [string]$alt.anchor }
            if ($alt.PSObject.Properties['occurrence']) { $altFinding | Add-Member -NotePropertyName occurrence -NotePropertyValue $alt.occurrence }
            $altTol = if ($alt.PSObject.Properties['tolerance']) { [int]$alt.tolerance } else { $tol }
            $locations.Add([PSCustomObject]@{ File = $altFile; Line = (Resolve-FindingLine -Finding $altFinding -Diff $Diff); Tolerance = $altTol })
        }
    }
    return $locations.ToArray()
}

function ConvertFrom-ModelReviewJson {
    param([string]$Content)

    # Models without structured output sometimes wrap the JSON in a fence or add a sentence.
    $text = $Content.Trim()
    if ($text -match '(?s)```(?:json)?\s*(\{.*\})\s*```') { $text = $matches[1] }
    elseif ($text -notmatch '^\{') {
        $start = $text.IndexOf('{')
        $end = $text.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) { $text = $text.Substring($start, $end - $start + 1) }
    }
    $parsed = $text | ConvertFrom-Json -ErrorAction Stop
    if (-not $parsed.PSObject.Properties['reviews']) { throw 'The model answer has no "reviews" field.' }
    $items = @($parsed.reviews)
    if ($items.Count -eq 1 -and $items[0] -is [string]) { $items = @($items[0] | ConvertFrom-Json -ErrorAction Stop) }
    return @($items | ForEach-Object { if ($_.PSObject.Properties['reviews'] -and -not $_.PSObject.Properties['fileName']) { $_.reviews } else { $_ } })
}

function Measure-EvalCase {
    param($Case, $Diff, [array]$Reviews, [int]$Tolerance = 2)

    $checked = Test-ReviewAnchors -Reviews $Reviews -Anchors $Diff.Anchors -SnapDistance 2
    $kept = @($checked.Reviews)
    $used = @{}
    $results = foreach ($finding in $Case.Findings) {
        $line = Resolve-FindingLine -Finding $finding -Diff $Diff
        $locations = @(Resolve-FindingLocations -Finding $finding -Diff $Diff)
        if (-not $finding.PSObject.Properties['tolerance']) { $locations[0].Tolerance = $Tolerance }
        $minRank = $script:SeverityRank[([string]$finding.minSeverity).ToUpperInvariant()]
        $best = $null
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $review = $kept[$i]
            $reviewFile = ([string]$review.fileName)
            if (-not $reviewFile.StartsWith('/')) { $reviewFile = "/$reviewFile" }
            $near = @($locations | Where-Object { $_.File -eq $reviewFile -and [math]::Abs([int]$review.lineNumber - $_.Line) -le $_.Tolerance })
            if ($near.Count -eq 0) { continue }
            $rank = $script:SeverityRank[([string]$review.severity).ToUpperInvariant()]
            if (-not $rank) { $rank = 0 }
            if ($null -eq $best -or $rank -gt $best.Rank) { $best = [PSCustomObject]@{ Index = $i; Rank = $rank } }
        }
        $status = if ($null -eq $best) { 'missed' } elseif ($best.Rank -ge $minRank) { 'caught' } else { 'underrated' }
        if ($null -ne $best) { $used[$best.Index] = $true }
        [PSCustomObject]@{ Id = [string]$finding.id; Line = $line; MinSeverity = ([string]$finding.minSeverity).ToUpperInvariant(); Status = $status }
    }

    $extras = @(for ($i = 0; $i -lt $kept.Count; $i++) { if (-not $used.ContainsKey($i)) { $kept[$i] } })
    $noise = @($extras | Where-Object { $script:SeverityRank[([string]$_.severity).ToUpperInvariant()] -ge 2 })

    return [PSCustomObject]@{
        Case        = $Case.Name
        Clean       = ($Case.Findings.Count -eq 0)
        Findings    = @($results)
        Extras      = $extras
        Noise       = $noise
        Dropped     = @($checked.Dropped)
    }
}

function New-ReviewSchema {
    return @{
        type                 = 'object'
        properties           = @{
            reviews = @{
                type  = 'array'
                items = @{
                    type                 = 'object'
                    properties           = [ordered]@{
                        fileName   = @{ type = 'string'; description = 'The file path being reviewed' }
                        lineNumber = @{ type = 'integer'; description = 'The line number where the issue occurs' }
                        severity   = @{ type = 'string'; enum = @('CRITICAL', 'WARNING', 'SUGGESTION'); description = 'How serious the issue is' }
                        comment    = @{ type = 'string'; description = 'The review comment: the problem, its consequence and an optional suggested fix. No emoji and no severity word' }
                    }
                    required             = @('fileName', 'lineNumber', 'severity', 'comment')
                    additionalProperties = $false
                }
            }
        }
        required             = @('reviews')
        additionalProperties = $false
    }
}

function Invoke-EvalRequest {
    param([string]$Uri, [hashtable]$Headers, [string]$Body, [int]$MaxAttempts = 5)

    # Rate limits and overloads are normal during a long eval run; retry them with backoff.
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Body))
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $retryable = $status -in @(408, 409, 429, 500, 502, 503, 504, 529) -or $status -eq 0
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, $attempt)))
        }
    }
}

function Invoke-EvalModel {
    param(
        [ValidateSet('anthropic', 'openai', 'azure')]
        [string]$Provider,
        [string]$Model,
        [string]$ApiKey,
        [string]$Endpoint,
        [string]$SystemPrompt,
        [string]$UserMessage,
        [string]$ReasoningEffort = ''
    )

    $schema = New-ReviewSchema
    if ($Provider -eq 'anthropic') {
        # A forced tool call is Anthropic's structured-output route: the tool input is the review
        # JSON. Models that reason before answering refuse a forced tool, so those get
        # tool_choice auto and the JSON is read from a tool call or from the text.
        $uri = if ($Endpoint) { $Endpoint } else { 'https://api.anthropic.com/v1/messages' }
        $headers = @{ 'x-api-key' = $ApiKey; 'anthropic-version' = '2023-06-01' }
        $request = [ordered]@{
            model       = $Model
            max_tokens  = 16000
            system      = $SystemPrompt
            messages    = @(@{ role = 'user'; content = $UserMessage })
            tools       = @(@{ name = 'submit_review'; description = 'Submit the code review result. Always call this exactly once with the full review.'; input_schema = $schema })
            tool_choice = @{ type = 'tool'; name = 'submit_review' }
        }
        try {
            $response = Invoke-EvalRequest -Uri $uri -Headers $headers -Body ($request | ConvertTo-Json -Depth 50)
        }
        catch {
            if ("$($_.ErrorDetails.Message) $($_.Exception.Message)" -notmatch 'tool_choice') { throw }
            $request.tool_choice = @{ type = 'auto' }
            $response = Invoke-EvalRequest -Uri $uri -Headers $headers -Body ($request | ConvertTo-Json -Depth 50)
        }
        $tool = @($response.content | Where-Object { $_.type -eq 'tool_use' })[0]
        $reviews = if ($tool -and $tool.input.reviews -is [string]) {
            # Some models put the array in the tool input as a JSON string.
            ConvertFrom-ModelReviewJson -Content ('{"reviews":' + $tool.input.reviews + '}')
        }
        elseif ($tool) {
            # Some models nest the whole answer one level down: { reviews: [ { reviews: [...] } ] }.
            @($tool.input.reviews | ForEach-Object { if ($_.PSObject.Properties['reviews'] -and -not $_.PSObject.Properties['fileName']) { $_.reviews } else { $_ } })
        }
        else {
            $text = (@($response.content | Where-Object { $_.type -eq 'text' }) | ForEach-Object { $_.text }) -join "`n"
            if ([string]::IsNullOrWhiteSpace($text)) { throw "The model returned no review (stop_reason: $($response.stop_reason))." }
            ConvertFrom-ModelReviewJson -Content $text
        }
        return [PSCustomObject]@{
            Reviews      = $reviews
            InputTokens  = [int]$response.usage.input_tokens
            OutputTokens = [int]$response.usage.output_tokens
        }
    }

    # OpenAI and Azure OpenAI / AI Foundry: the same chat completions call the engine makes.
    $uri = if ($Endpoint) { $Endpoint } else { 'https://api.openai.com/v1/chat/completions' }
    $bodyTable = [ordered]@{
        model           = $Model
        messages        = @(@{ role = 'system'; content = $SystemPrompt }, @{ role = 'user'; content = $UserMessage })
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'CodeReviewResponse'; strict = $true; schema = $schema } }
    }
    if ($ReasoningEffort) { $bodyTable['reasoning_effort'] = $ReasoningEffort }
    $headers = if ($Provider -eq 'azure') { @{ 'api-key' = $ApiKey } } else { @{ 'Authorization' = "Bearer $ApiKey" } }
    $body = $bodyTable | ConvertTo-Json -Depth 50
    $response = Invoke-EvalRequest -Uri $uri -Headers $headers -Body $body
    $content = [string]@($response.choices)[0].message.content
    return [PSCustomObject]@{
        Reviews      = ConvertFrom-ModelReviewJson -Content $content
        InputTokens  = [int]$response.usage.prompt_tokens
        OutputTokens = [int]$response.usage.completion_tokens
    }
}

function Get-StackVerdict {
    param([array]$CaseResults, [double]$MinWarningRecall = 0.8)

    # The bar a rules file must clear: every planted CRITICAL caught at CRITICAL, at least
    # MinWarningRecall of planted WARNINGs caught at WARNING or above, and no CRITICAL or
    # WARNING comment on a clean sample.
    $findings = @($CaseResults | ForEach-Object { $_.Findings })
    $critical = @($findings | Where-Object { $_.MinSeverity -eq 'CRITICAL' })
    $warning = @($findings | Where-Object { $_.MinSeverity -eq 'WARNING' })
    $criticalCaught = @($critical | Where-Object { $_.Status -eq 'caught' }).Count
    $warningCaught = @($warning | Where-Object { $_.Status -eq 'caught' }).Count
    $cleanNoise = @($CaseResults | Where-Object { $_.Clean } | ForEach-Object { $_.Noise }).Count
    $warningRecall = if ($warning.Count -gt 0) { $warningCaught / $warning.Count } else { 1.0 }

    $reasons = @()
    if ($criticalCaught -lt $critical.Count) { $reasons += "$($critical.Count - $criticalCaught) CRITICAL not caught" }
    if ($warningRecall -lt $MinWarningRecall) { $reasons += "WARNING recall $([math]::Round($warningRecall * 100))%" }
    if ($cleanNoise -gt 0) { $reasons += "$cleanNoise noisy comment(s) on clean samples" }

    return [PSCustomObject]@{
        Pass           = ($reasons.Count -eq 0)
        CriticalCaught = $criticalCaught
        CriticalTotal  = $critical.Count
        WarningCaught  = $warningCaught
        WarningTotal   = $warning.Count
        CleanNoise     = $cleanNoise
        Extras         = @($CaseResults | ForEach-Object { $_.Extras }).Count
        Reasons        = $reasons
    }
}
