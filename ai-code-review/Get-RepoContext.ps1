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

    $ordered = @($folders.Keys | Sort-Object @{ Expression = { $_ -ne '/' } }, @{ Expression = { $_ } })
    $named = foreach ($folder in $ordered) { "$folder  $($folders[$folder] -join ', ')" }
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

function Get-RefFileLines {
    param(
        [string]$Ref,
        [string]$Path,
        [hashtable]$Cache = $null
    )

    # One file's lines on the ref, read once per run.
    if ($null -ne $Cache -and $Cache.ContainsKey($Path)) {
        return , $Cache[$Path]
    }
    $lines = @(git -c core.quotepath=off show "${Ref}:$Path" 2>$null)
    if ($LASTEXITCODE -ne 0) { $lines = @() }
    if ($null -ne $Cache) { $Cache[$Path] = $lines }
    return , $lines
}

function Resolve-RelativeRepoPath {
    param(
        [string]$FromFile,
        [string]$Reference
    )

    # Joins a reference such as '../lib/http' to the folder of the file that makes it, and
    # removes '.' and '..' segments. Returns $null when it climbs above the repository root.
    $reference = ($Reference -replace '\\', '/')
    $slash = $FromFile.LastIndexOf('/')
    $folder = if ($slash -lt 0) { '' } else { $FromFile.Substring(0, $slash) }
    $joined = if ($reference.StartsWith('/')) { $reference.TrimStart('/') } elseif ($folder) { "$folder/$reference" } else { $reference }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in ($joined -split '/')) {
        if ($segment -eq '' -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($parts.Count -eq 0) { return $null }
            $parts.RemoveAt($parts.Count - 1)
            continue
        }
        $parts.Add($segment)
    }
    return ($parts -join '/')
}

function Get-ImportedFilePaths {
    param(
        [string]$File,
        [string[]]$Lines = @(),
        [hashtable]$Tracked = @{},
        [hashtable]$GoModules = @{}
    )

    # Files in this repository that $File imports, from the import syntax of the common languages.
    # Each is returned with the import line, so the caller can rank imports that the changed lines
    # use. Only files that exist on the branch are returned; packages and anything outside the
    # repository are ignored.
    $found = [ordered]@{}
    $extension = [IO.Path]::GetExtension($File).ToLowerInvariant()
    $addFirst = {
        param([string[]]$Candidates, [string]$ImportLine)
        foreach ($candidate in $Candidates) {
            if ($candidate -and $candidate -ne $File -and $Tracked.ContainsKey($candidate)) {
                if (-not $found.Contains($candidate)) { $found[$candidate] = $ImportLine }
                return
            }
        }
    }

    foreach ($line in $Lines) {
        switch -Regex ($extension) {
            '^\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte)$' {
                foreach ($match in [regex]::Matches($line, '(?:\bfrom\s+|\brequire\(\s*|\bimport\(\s*|^\s*import\s+)[''"]([^''"]+)[''"]')) {
                    $spec = $match.Groups[1].Value
                    $base = if ($spec.StartsWith('.')) { Resolve-RelativeRepoPath -FromFile $File -Reference $spec }
                    elseif ($spec.StartsWith('@/')) { 'src/' + $spec.Substring(2) }
                    else { $null }
                    if (-not $base) { continue }
                    $candidates = @($base) + @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.d.ts', '.vue' | ForEach-Object { "$base$_" }) +
                        @('/index.ts', '/index.tsx', '/index.js', '/index.jsx' | ForEach-Object { "$base$_" })
                    & $addFirst $candidates $line
                }
            }
            '^\.py$' {
                $modules = @()
                if ($line -match '^\s*from\s+(\.*)([\w.]*)\s+import\s+(.+)$') {
                    $dots = $matches[1]; $module = $matches[2]; $names = $matches[3]
                    if ($dots) {
                        $up = '../' * ($dots.Length - 1)
                        $relative = if ($module) { $up + ($module -replace '\.', '/') } else { $null }
                        if ($relative) { $modules += , @(Resolve-RelativeRepoPath -FromFile $File -Reference "./$relative") }
                        else {
                            foreach ($name in ($names -replace '[()]', '' -split ',')) {
                                $name = ($name.Trim() -split '\s+')[0]
                                if ($name -match '^\w+$') { $modules += , @(Resolve-RelativeRepoPath -FromFile $File -Reference "./$up$name") }
                            }
                        }
                    }
                    elseif ($module) {
                        $path = $module -replace '\.', '/'
                        $modules += , @($path, "src/$path")
                    }
                }
                elseif ($line -match '^\s*import\s+([\w.]+)') {
                    $path = $matches[1] -replace '\.', '/'
                    $modules += , @($path, "src/$path")
                }
                foreach ($group in $modules) {
                    $candidates = foreach ($base in @($group)) { if ($base) { "$base.py"; "$base/__init__.py" } }
                    & $addFirst @($candidates) $line
                }
            }
            '^\.go$' {
                if ($line -match '^\s*(?:import\s+)?(?:[\w.]+\s+)?"([^"]+)"\s*$') {
                    $importPath = $matches[1]
                    foreach ($module in $GoModules.Keys) {
                        if ($importPath -eq $module -or $importPath.StartsWith("$module/")) {
                            $folder = (($GoModules[$module] + $importPath.Substring($module.Length)) -replace '^/', '').TrimEnd('/')
                            $prefix = if ($folder) { "$folder/" } else { '' }
                            # A Go package is a folder; take its first few non-test files.
                            $files = @($Tracked.Keys | Where-Object {
                                    $_.StartsWith($prefix) -and $_.EndsWith('.go') -and -not $_.EndsWith('_test.go') -and
                                    $_.Substring($prefix.Length) -notmatch '/'
                                } | Sort-Object | Select-Object -First 3)
                            foreach ($goFile in $files) { & $addFirst @($goFile) $line }
                        }
                    }
                }
            }
            '^\.(ps1|psm1|psd1)$' {
                foreach ($match in [regex]::Matches($line, '[''"]([^''"]+\.ps[md]?1)[''"]')) {
                    $spec = $match.Groups[1].Value -replace '^\$PSScriptRoot[\\/]', ''
                    if ($line -match 'Join-Path') {
                        # (Join-Path $PSScriptRoot '..' 'x.ps1'): join every quoted argument.
                        $spec = (@([regex]::Matches($line, '[''"]([^''"]+)[''"]') | ForEach-Object { $_.Groups[1].Value }) -join '/')
                    }
                    if ($spec -match '\$') { continue }
                    & $addFirst @(Resolve-RelativeRepoPath -FromFile $File -Reference $spec) $line
                }
            }
            '^\.bicep$' {
                if ($line -match '^\s*module\s+\w+\s+''([^'']+\.bicep)''') {
                    & $addFirst @(Resolve-RelativeRepoPath -FromFile $File -Reference $matches[1]) $line
                }
            }
        }
    }

    return @($found.Keys | ForEach-Object { [PSCustomObject]@{ Path = $_; ImportLine = $found[$_] } })
}

function Get-CodeLanguage {
    param([string]$Path)

    # The language family of a source file and the git pathspecs that match its family. Symbols
    # are only searched for in the same family: a Go function named Parse says nothing about a
    # PowerShell file that calls [int]::Parse. Markdown, YAML, JSON and other non-code files have
    # no family, so their text is never mistaken for declarations.
    $families = [ordered]@{
        js     = @('ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'mts', 'cts', 'vue', 'svelte')
        py     = @('py')
        go     = @('go')
        ps     = @('ps1', 'psm1')
        dotnet = @('cs', 'fs', 'vb')
        jvm    = @('java', 'kt', 'kts', 'scala', 'groovy')
        rb     = @('rb')
        php    = @('php')
        rs     = @('rs')
        swift  = @('swift')
        c      = @('c', 'h', 'cc', 'cpp', 'cxx', 'hpp', 'hh', 'm', 'mm')
    }
    $extension = [IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    foreach ($name in $families.Keys) {
        if ($families[$name] -contains $extension) {
            return [PSCustomObject]@{ Name = $name; PathSpec = @($families[$name] | ForEach-Object { "*.$_" }) }
        }
    }
    return $null
}

function Get-ChangedSymbolNames {
    param(
        [string[]]$ChangedLines = @(),
        [string[]]$HunkFunctions = @()
    )

    # Names of functions, methods, classes and types that the diff defines, changes or removes
    # (from the + and - lines), then the functions whose bodies changed (from git's hunk headers).
    # Callers of these are the code most likely to break. Short and generic names are skipped:
    # searching for them would only find noise.
    $patterns = @(
        '\bfunction\s+([A-Za-z_$][\w$]*(?:-[A-Za-z]\w*)*)',
        '\b(?:class|interface|type|enum|struct|trait|record|protocol)\s+([A-Za-z_]\w*)',
        '\bdef\s+([A-Za-z_]\w*)',
        '\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)',
        '\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[A-Za-z_$][\w$]*\s*=>)',
        '\b(?:public|internal|protected|private)\s+(?:(?:static|async|virtual|override|abstract|sealed|final|readonly)\s+)*[\w<>\[\],.?]+\s+([A-Z]\w*)\s*[(<]',
        '^\s*(?:export\s+)?(?:async\s+)?([a-zA-Z_]\w*)\s*\([^)]*\)\s*(?::\s*[\w<>\[\]|, ]+)?\s*\{\s*$'
    )
    $stop = @{}
    foreach ($word in @('main', 'init', 'test', 'tests', 'setup', 'render', 'constructor', 'handler', 'handle', 'index',
            'value', 'data', 'item', 'items', 'result', 'error', 'props', 'state', 'config', 'options', 'params', 'args',
            'string', 'number', 'object', 'boolean', 'function', 'return', 'export', 'import', 'default', 'async', 'await',
            'catch', 'while', 'switch', 'begin', 'process', 'end', 'param', 'Main', 'Test', 'Setup', 'String', 'Object')) {
        $stop[$word] = $true
    }

    $names = [ordered]@{}
    $add = {
        param([string]$Name, [int]$Priority)
        if ($Name.Length -lt 4 -or $stop.ContainsKey($Name) -or $names.Contains($Name)) { return }
        $names[$Name] = $Priority
    }

    foreach ($rawLine in $ChangedLines) {
        # Comments name things in prose ("the function call below"); only code declares them.
        if ($rawLine -match '^\s*(//|#|\*|/\*|<#|--|\{-)') { continue }
        $line = $rawLine -replace '\s//.*$', ''
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($line, $pattern)) { & $add $match.Groups[1].Value 2 }
        }
    }
    foreach ($header in $HunkFunctions) {
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($header, $pattern)) { & $add $match.Groups[1].Value 1 }
        }
    }

    return @($names.Keys | ForEach-Object { [PSCustomObject]@{ Name = $_; Priority = $names[$_] } })
}

function Find-SymbolUsage {
    param(
        [string]$Ref,
        [object[]]$Symbols = @(),
        [string[]]$SkipFiles = @(),
        [string[]]$ExcludePathSpec = @(),
        [string[]]$PathSpec = @(),
        [int]$MaxSymbols = 20,
        [int]$MaxFilesPerSymbol = 40
    )

    # Files on the branch that use the symbols, found with one `git grep -w` on the ref (whole
    # words, fixed strings, text files only). A symbol used in more than MaxFilesPerSymbol files
    # is too common to tell us anything and is dropped. Returns one entry per file, the files
    # that use the most (and most important) symbols first.
    $symbolList = @($Symbols | Sort-Object @{ Expression = 'Priority'; Descending = $true } | Select-Object -First $MaxSymbols)
    if ($symbolList.Count -eq 0) {
        return @()
    }

    $grepArgs = @('-c', 'core.quotepath=off', 'grep', '-n', '-I', '-w', '-F')
    foreach ($symbol in $symbolList) { $grepArgs += @('-e', $symbol.Name) }
    $grepArgs += @($Ref, '--') + @($PathSpec)
    $output = @(git @grepArgs 2>$null)

    $skip = @{}
    foreach ($file in $SkipFiles) { $skip[$file.TrimStart('/')] = $true }
    $prefix = "${Ref}:"
    $byFile = [ordered]@{}
    foreach ($line in $output) {
        if (-not $line.StartsWith($prefix)) { continue }
        $rest = $line.Substring($prefix.Length)
        if ($rest -notmatch '^(.+?):(\d+):(.*)$') { continue }
        $path = $matches[1]; $number = [int]$matches[2]; $text = $matches[3]
        if ($skip.ContainsKey($path) -or (Test-ReviewPathExcluded -Path $path -ExcludePathSpec $ExcludePathSpec)) { continue }
        if ($text -match '^\s*(//|#|\*|/\*|<#|--)') { continue }
        if (-not $byFile.Contains($path)) { $byFile[$path] = [System.Collections.Generic.List[object]]::new() }
        $byFile[$path].Add([PSCustomObject]@{ Line = $number; Text = $text })
    }

    $filesPerSymbol = @{}
    $usage = foreach ($path in $byFile.Keys) {
        $used = @($symbolList | Where-Object {
                $name = [regex]::Escape($_.Name)
                @($byFile[$path] | Where-Object { $_.Text -match "(?<![\w$-])$name(?![\w$-])" }).Count -gt 0
            })
        foreach ($symbol in $used) { $filesPerSymbol[$symbol.Name] = 1 + [int]$filesPerSymbol[$symbol.Name] }
        [PSCustomObject]@{ Path = $path; Symbols = $used; Hits = $byFile[$path] }
    }

    $common = @{}
    foreach ($name in $filesPerSymbol.Keys) { if ($filesPerSymbol[$name] -gt $MaxFilesPerSymbol) { $common[$name] = $true } }
    $result = foreach ($entry in @($usage)) {
        $kept = @($entry.Symbols | Where-Object { -not $common.ContainsKey($_.Name) })
        if ($kept.Count -eq 0) { continue }
        $names = @($kept | ForEach-Object { [regex]::Escape($_.Name) }) -join '|'
        $hits = @($entry.Hits | Where-Object { $_.Text -match "(?<![\w$-])(?:$names)(?![\w$-])" })
        [PSCustomObject]@{
            Path    = $entry.Path
            Symbols = @($kept | ForEach-Object { $_.Name })
            Score   = [int](@($kept | ForEach-Object { $_.Priority }) | Measure-Object -Sum).Sum
            Lines   = @($hits | ForEach-Object { $_.Line })
        }
    }

    return @($result | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { $_.Lines.Count }; Descending = $true }, Path)
}

function Format-ContextExcerpt {
    param(
        [string[]]$Lines = @(),
        [int[]]$Focus = @(),
        [int]$Radius = 2,
        [int]$MaxTokens = 1500,
        [switch]$Outline
    )

    # Numbered lines of a context file: the whole file when it fits, otherwise the lines around
    # $Focus (or, with -Outline, its declaration lines). The 'NN | ' numbering is deliberately
    # unlike the diff's 'NN+ ' so the model cannot mistake a context line for a changed one.
    $maxChars = [int]($MaxTokens * 3.5)
    $render = {
        param([int[]]$Numbers)
        $builder = [System.Text.StringBuilder]::new()
        $previous = 0
        foreach ($number in $Numbers) {
            if ($previous -and $number -gt $previous + 1) { [void]$builder.Append("     ...`n") }
            $text = $Lines[$number - 1]
            if ($text.Length -gt 240) { $text = $text.Substring(0, 240) + ' ...' }
            [void]$builder.Append($number.ToString().PadLeft(5)).Append(' | ').Append($text).Append("`n")
            $previous = $number
        }
        if ($previous -and $previous -lt $Lines.Count) { [void]$builder.Append("     ...`n") }
        return $builder.ToString()
    }

    if ($Lines.Count -eq 0) {
        return ''
    }

    $all = & $render @(1..$Lines.Count)
    if ($all.Length -le $maxChars) {
        return $all
    }

    $wanted = [System.Collections.Generic.SortedSet[int]]::new()
    if ($Outline) {
        $declaration = '^\s*(export\s+|public\s+|internal\s+|protected\s+|private\s+|static\s+|async\s+|abstract\s+)*(function|class|interface|type|enum|struct|def|func|const\s+\w+\s*=\s*(async\s*)?\(|module|resource|param|output|var\s+\w+\s*=\s*(async\s*)?function)\b'
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match $declaration) { [void]$wanted.Add($i + 1) }
        }
    }
    foreach ($line in $Focus) {
        for ($n = [Math]::Max(1, $line - $Radius); $n -le [Math]::Min($Lines.Count, $line + $Radius); $n++) { [void]$wanted.Add($n) }
    }
    if ($wanted.Count -eq 0) {
        foreach ($n in 1..([Math]::Min($Lines.Count, 30))) { [void]$wanted.Add($n) }
    }

    # Drop lines from the end until it fits.
    $numbers = [System.Collections.Generic.List[int]]::new([int[]]@($wanted))
    $text = & $render @($numbers)
    while ($text.Length -gt $maxChars -and $numbers.Count -gt 1) {
        $remove = [Math]::Max(1, [int]($numbers.Count / 5))
        $numbers.RemoveRange($numbers.Count - $remove, $remove)
        $text = & $render @($numbers)
    }
    return $text
}

function Get-GoModuleMap {
    param(
        [string]$Ref,
        [string[]]$Paths = @()
    )

    # module path -> folder of its go.mod, so a Go import can be mapped to a folder in the repo.
    $modules = @{}
    foreach ($goMod in @($Paths | Where-Object { $_ -eq 'go.mod' -or $_.EndsWith('/go.mod') })) {
        $content = Get-RefFileLines -Ref $Ref -Path $goMod
        $line = @($content | Where-Object { $_ -match '^\s*module\s+(\S+)' } | Select-Object -First 1)
        if ($line.Count -gt 0 -and $line[0] -match '^\s*module\s+(\S+)') {
            $modules[$matches[1].Trim('"')] = if ($goMod -eq 'go.mod') { '' } else { $goMod.Substring(0, $goMod.Length - '/go.mod'.Length) }
        }
    }
    return $modules
}

function New-RepoContextOptions {
    param(
        [string]$SourceBranch,
        [string[]]$ExcludePathSpec = @(),
        [bool]$UseDefaultExcludes = $true,
        [int]$MaxTokens = 12000
    )

    # Everything that is the same for every batch of a run: the branch, its file list and map.
    $ref = $SourceBranch -replace 'refs/heads/', 'origin/'
    $excludes = @($ExcludePathSpec)
    if ($UseDefaultExcludes) { $excludes += @(Get-DefaultExcludePathSpec) }

    $paths = @(Get-TrackedFilePaths -Ref $ref -ExcludePathSpec $excludes)
    $tracked = @{}
    foreach ($path in $paths) { $tracked[$path] = $true }
    $mapBudget = [Math]::Min(3000, [int]($MaxTokens / 4))

    return [PSCustomObject]@{
        Ref             = $ref
        ExcludePathSpec = $excludes
        MaxTokens       = $MaxTokens
        Tracked         = $tracked
        GoModules       = Get-GoModuleMap -Ref $ref -Paths $paths
        RepoMap         = Get-RepoMap -Paths $paths -MaxTokens $mapBudget
        FileCache       = @{}
    }
}

function New-BatchRepoContext {
    param(
        $Batch,
        $Options
    )

    # The repository context for one review batch: the repository map, then excerpts of the files
    # that call what the batch changes and of the files the batch's files import, taken in turn
    # (callers first) until the token budget or 12 files is reached. Files in the batch are never
    # repeated; they are in the diff already.
    $empty = [PSCustomObject]@{ Text = ''; Files = 0; Tokens = 0 }
    if (-not $Options -or $Options.MaxTokens -le 0) {
        return $empty
    }

    $blocks = @($Batch.Blocks | Where-Object { $_ })
    $batchFiles = @($blocks | ForEach-Object { $_.File })
    $inBatch = @{}
    foreach ($file in $batchFiles) { $inBatch[$file] = $true }

    # Changed symbols per language family, from the batch's + and - lines and hunk headers.
    $addedWords = @{}
    $families = [ordered]@{}
    foreach ($block in $blocks) {
        $language = Get-CodeLanguage -Path $block.File
        if (-not $language) { continue }
        # Helpers a test file declares are only called by tests; their callers add nothing.
        if ($block.File -match '(_test\.go|\.Tests\.ps1|\.(test|spec)\.[jt]sx?|(^|/)test_[^/]+\.py|_test\.py|Tests?\.cs)$') { continue }
        if (-not $families.Contains($language.Name)) {
            $families[$language.Name] = [PSCustomObject]@{
                PathSpec = $language.PathSpec
                Lines    = [System.Collections.Generic.List[string]]::new()
                Headers  = [System.Collections.Generic.List[string]]::new()
            }
        }
        $family = $families[$language.Name]
        foreach ($line in ($block.Text -split "`n")) {
            if ($line -match '^\s*\d+([+-]) (.*)$') {
                $family.Lines.Add($matches[2])
                if ($matches[1] -eq '+') { foreach ($word in [regex]::Matches($matches[2], '[A-Za-z_$][\w$]{2,}')) { $addedWords[$word.Value] = $true } }
            }
        }
        foreach ($header in @($block.HunkFunctions)) { if ($header) { $family.Headers.Add($header) } }
    }

    $callerList = foreach ($name in $families.Keys) {
        $family = $families[$name]
        $symbols = @(Get-ChangedSymbolNames -ChangedLines @($family.Lines) -HunkFunctions @($family.Headers))
        Find-SymbolUsage -Ref $Options.Ref -Symbols $symbols -SkipFiles $batchFiles -ExcludePathSpec $Options.ExcludePathSpec -PathSpec $family.PathSpec
    }
    $callers = @($callerList | Where-Object { $_ } | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { $_.Lines.Count }; Descending = $true }, Path)

    $imports = [System.Collections.Generic.List[object]]::new()
    $seenImports = @{}
    foreach ($file in $batchFiles) {
        $lines = Get-RefFileLines -Ref $Options.Ref -Path $file -Cache $Options.FileCache
        foreach ($import in @(Get-ImportedFilePaths -File $file -Lines $lines -Tracked $Options.Tracked -GoModules $Options.GoModules)) {
            if ($inBatch.ContainsKey($import.Path) -or $seenImports.ContainsKey($import.Path)) { continue }
            $seenImports[$import.Path] = $true
            $usedNames = @([regex]::Matches($import.ImportLine, '[A-Za-z_$][\w$]{2,}') | Where-Object { $addedWords.ContainsKey($_.Value) }).Count
            $imports.Add([PSCustomObject]@{ Path = $import.Path; By = $file; Score = $(if ($usedNames -gt 0) { 2 } else { 1 }) })
        }
    }
    $importList = @($imports | Sort-Object @{ Expression = 'Score'; Descending = $true })

    $candidates = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt [Math]::Max($callers.Count, $importList.Count); $i++) {
        if ($i -lt $callers.Count) { $candidates.Add([PSCustomObject]@{ Kind = 'caller'; Item = $callers[$i] }) }
        if ($i -lt $importList.Count) { $candidates.Add([PSCustomObject]@{ Kind = 'import'; Item = $importList[$i] }) }
    }

    $header = "# Repository context (read-only)`n`nFiles from the pull request branch that are related to the changes in this batch, for reference only. They are not part of the diff: never comment on them or their line numbers. Excerpts are partial; a caller missing here may still exist.`n`n"
    $builder = [System.Text.StringBuilder]::new($header)
    if ($Options.RepoMap) { [void]$builder.Append($Options.RepoMap).Append("`n") }

    $budgetChars = [int]($Options.MaxTokens * 3.5)
    $files = 0
    $taken = @{}
    foreach ($candidate in $candidates) {
        if ($files -ge 12) { break }
        $path = $candidate.Item.Path
        if ($taken.ContainsKey($path)) { continue }
        $remaining = [int](($budgetChars - $builder.Length) / 3.5)
        if ($remaining -lt 200) { break }
        $perFile = [Math]::Min(2500, [Math]::Max(200, [int]($remaining / 3)))

        $lines = Get-RefFileLines -Ref $Options.Ref -Path $path -Cache $Options.FileCache
        if ($lines.Count -eq 0) { continue }
        if ($candidate.Kind -eq 'caller') {
            $names = ($candidate.Item.Symbols | Select-Object -First 5 | ForEach-Object { "``$_``" }) -join ', '
            $why = "uses $names, which this batch changes"
            $excerpt = Format-ContextExcerpt -Lines $lines -Focus @($candidate.Item.Lines | Select-Object -First 8) -MaxTokens $perFile
        }
        else {
            $why = "imported by /$($candidate.Item.By)"
            $excerpt = Format-ContextExcerpt -Lines $lines -Outline -MaxTokens $perFile
        }
        $section = "## Related file: /$path`nWhy: $why`n`n$excerpt`n"
        if ($builder.Length + $section.Length -gt $budgetChars) { continue }
        [void]$builder.Append($section)
        $taken[$path] = $true
        $files++
    }

    if ($files -eq 0 -and -not $Options.RepoMap) {
        return $empty
    }

    $text = $builder.ToString()
    return [PSCustomObject]@{
        Text   = $text
        Files  = $files
        Tokens = Get-EstimatedTokenCount -Text $text
    }
}
