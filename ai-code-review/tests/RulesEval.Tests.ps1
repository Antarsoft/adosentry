BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'tools' 'RulesEval.ps1')
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'

    function New-Sample([string]$Before, [string]$After, [array]$Findings) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("eval-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'before' 'src'), (Join-Path $dir 'after' 'src') | Out-Null
        Set-Content -Path (Join-Path $dir 'before' 'src' 'app.ts') -Value $Before
        Set-Content -Path (Join-Path $dir 'after' 'src' 'app.ts') -Value $After
        @{ description = 'test'; findings = $Findings } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dir 'expect.json')
        return $dir
    }
}

Describe 'Rules eval samples' {
    It 'every stack with samples has a rules file, and every expected finding sits on exactly one added line' {
        $evalRoot = Join-Path $script:RepoRoot 'evals'
        $stacks = @(Get-ChildItem -Directory -Path $evalRoot | Where-Object { -not $_.Name.StartsWith('.') })
        $stacks.Count | Should -BeGreaterThan 0
        foreach ($stack in $stacks) {
            Join-Path $script:RepoRoot 'examples' 'rules' "$($stack.Name).rules.md" | Should -Exist
            $cases = @(Get-ChildItem -Directory -Path $stack.FullName)
            @($cases | Where-Object { (Get-EvalCase -CasePath $_.FullName).Findings.Count -eq 0 }).Count | Should -BeGreaterThan 0 -Because "$($stack.Name) needs at least one clean sample"
            @($cases | Where-Object { (Get-EvalCase -CasePath $_.FullName).Findings.Count -gt 0 }).Count | Should -BeGreaterThan 0 -Because "$($stack.Name) needs at least one sample with planted bugs"
            foreach ($caseDir in $cases) {
                $case = Get-EvalCase -CasePath $caseDir.FullName
                $diff = Get-EvalCaseDiff -CasePath $case.Path
                $diff.Changes | Should -Match '## File: /'
                foreach ($finding in $case.Findings) {
                    { Resolve-FindingLine -Finding $finding -Diff $diff } | Should -Not -Throw -Because "$($stack.Name)/$($case.Name) $($finding.id)"
                }
            }
        }
    }
}

Describe 'Get-EvalCaseDiff' {
    It 'numbers lines the way the engine does and maps paths under after/ to repo paths' {
        $dir = New-Sample -Before "a`nb`nc" -After "a`nb2`nc`nd" -Findings @()
        $diff = Get-EvalCaseDiff -CasePath $dir
        $diff.Changes | Should -Match '## File: /src/app.ts'
        $diff.Changes | Should -Match '   2\+ b2'
        $diff.Anchors['/src/app.ts'][4] | Should -Be 'added'
        $diff.LineText['/src/app.ts'][2] | Should -Be 'b2'
    }

    It 'treats a sample without before/ as new files' {
        $dir = New-Sample -Before 'x' -After "one`ntwo" -Findings @()
        Remove-Item -Recurse -Force (Join-Path $dir 'before')
        $diff = Get-EvalCaseDiff -CasePath $dir
        $diff.Anchors['/src/app.ts'][1] | Should -Be 'added'
        $diff.Anchors['/src/app.ts'][2] | Should -Be 'added'
    }
}

Describe 'Measure-EvalCase and Get-StackVerdict' {
    BeforeAll {
        $finding = [PSCustomObject]@{ id = 'bug'; file = '/src/app.ts'; anchor = 'eval(input)'; minSeverity = 'CRITICAL' }
        $script:BugDir = New-Sample -Before "const a = 1;`nconst b = 2;" -After "const a = 1;`nconst b = 2;`nrun(eval(input));`nconst c = 3;" -Findings @($finding)
        $script:Case = Get-EvalCase -CasePath $script:BugDir
        $script:Diff = Get-EvalCaseDiff -CasePath $script:BugDir
    }

    It 'counts a comment near the anchor at the right severity as caught' {
        $r = Measure-EvalCase -Case $script:Case -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = '/src/app.ts'; lineNumber = 4; severity = 'CRITICAL'; comment = 'x' })
        $r.Findings[0].Status | Should -Be 'caught'
        $r.Extras.Count | Should -Be 0
    }

    It 'counts a lower severity as underrated and a missing comment as missed' {
        (Measure-EvalCase -Case $script:Case -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = 'src/app.ts'; lineNumber = 3; severity = 'WARNING'; comment = 'x' })).Findings[0].Status | Should -Be 'underrated'
        (Measure-EvalCase -Case $script:Case -Diff $script:Diff -Reviews @()).Findings[0].Status | Should -Be 'missed'
    }

    It 'accepts a comment on an alsoAt line' {
        $finding = [PSCustomObject]@{ id = 'bug'; file = '/src/app.ts'; anchor = 'eval(input)'; minSeverity = 'CRITICAL'; tolerance = 0; alsoAt = @([PSCustomObject]@{ anchor = 'const c = 3;' }) }
        $case = [PSCustomObject]@{ Name = 'alt'; Findings = @($finding) }
        (Measure-EvalCase -Case $case -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = '/src/app.ts'; lineNumber = 4; severity = 'CRITICAL'; comment = 'x' })).Findings[0].Status | Should -Be 'caught'
        (Measure-EvalCase -Case $case -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = '/src/app.ts'; lineNumber = 2; severity = 'CRITICAL'; comment = 'x' })).Findings[0].Status | Should -Be 'missed'
    }

    It 'fails a stack that misses a CRITICAL or comments on a clean sample' {
        $missed = Measure-EvalCase -Case $script:Case -Diff $script:Diff -Reviews @()
        (Get-StackVerdict -CaseResults @($missed)).Pass | Should -BeFalse

        $cleanCase = [PSCustomObject]@{ Name = 'clean'; Findings = @() }
        $noisy = Measure-EvalCase -Case $cleanCase -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = '/src/app.ts'; lineNumber = 4; severity = 'WARNING'; comment = 'x' })
        $caught = Measure-EvalCase -Case $script:Case -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = '/src/app.ts'; lineNumber = 3; severity = 'CRITICAL'; comment = 'x' })
        $verdict = Get-StackVerdict -CaseResults @($caught, $noisy)
        $verdict.Pass | Should -BeFalse
        $verdict.CleanNoise | Should -Be 1

        $quiet = Measure-EvalCase -Case $cleanCase -Diff $script:Diff -Reviews @([PSCustomObject]@{ fileName = '/src/app.ts'; lineNumber = 4; severity = 'SUGGESTION'; comment = 'x' })
        (Get-StackVerdict -CaseResults @($caught, $quiet)).Pass | Should -BeTrue
    }
}

Describe 'ConvertFrom-ModelReviewJson' {
    It 'reads plain, fenced and wrapped JSON' {
        @(ConvertFrom-ModelReviewJson -Content '{"reviews":[]}').Count | Should -Be 0
        @(ConvertFrom-ModelReviewJson -Content "``````json`n{""reviews"":[{""fileName"":""/a"",""lineNumber"":1,""severity"":""WARNING"",""comment"":""c""}]}`n``````").Count | Should -Be 1
        @(ConvertFrom-ModelReviewJson -Content '{"reviews":["[{\"fileName\":\"/a\",\"lineNumber\":1,\"severity\":\"WARNING\",\"comment\":\"c\"}]"]}').Count | Should -Be 1
        @(ConvertFrom-ModelReviewJson -Content 'Here you go: {"reviews":[{"fileName":"/a","lineNumber":1,"severity":"WARNING","comment":"c"}]}').Count | Should -Be 1
    }
}
