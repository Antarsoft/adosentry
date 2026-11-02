BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Get-CodeChanges.ps1')
    . (Join-Path $PSScriptRoot '..' 'Get-RepoContext.ps1')

    function Invoke-Git {
        & git -C $script:Repo @args | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git $args failed" }
    }

    function Write-RepoFile($Path, $Content) {
        $full = Join-Path $script:Repo $Path
        New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
        Set-Content -Path $full -Value $Content
    }

    # A throwaway repo: `main` holds $Base, `feature` holds $Base plus $Change, both exposed as
    # refs/remotes/origin/* like the pipeline's checkout.
    function New-TestRepo([scriptblock]$Base, [scriptblock]$Change = {}) {
        $script:Repo = Join-Path ([IO.Path]::GetTempPath()) ("rc-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        Invoke-Git init -q -b main
        Invoke-Git config user.email t@example.com
        Invoke-Git config user.name Test
        Invoke-Git config commit.gpgsign false
        & $Base
        Invoke-Git add -A
        Invoke-Git commit -q -m base
        Invoke-Git update-ref refs/remotes/origin/main HEAD
        Invoke-Git checkout -q -b feature
        & $Change
        Invoke-Git add -A
        Invoke-Git commit -q --allow-empty -m change
        Invoke-Git update-ref refs/remotes/origin/feature HEAD
    }

    function Invoke-InRepo([scriptblock]$Script) {
        Push-Location $script:Repo
        try { & $Script 6>$null } finally { Pop-Location }
    }
}

Describe 'Repository context' {
AfterEach {
    if ($script:Repo -and (Test-Path $script:Repo)) { Remove-Item -Recurse -Force $script:Repo }
    $script:Repo = $null
}

Describe 'Get-TrackedFilePaths' {
    It 'lists the files on the ref and leaves out excluded ones' {
        New-TestRepo {
            Write-RepoFile 'src/a.ts' 'a'
            Write-RepoFile 'package-lock.json' '{}'
            Write-RepoFile 'docs/x.md' 'x'
        }
        $paths = Invoke-InRepo { Get-TrackedFilePaths -Ref 'origin/feature' -ExcludePathSpec @('*package-lock.json', 'docs/*') }
        $paths | Should -Be @('src/a.ts')
    }

    It 'returns nothing for a ref that does not exist' {
        New-TestRepo { Write-RepoFile 'a.txt' 'a' }
        $paths = Invoke-InRepo { Get-TrackedFilePaths -Ref 'origin/missing' }
        @($paths).Count | Should -Be 0
    }
}

Describe 'Get-RepoMap' {
    It 'lists one line per folder with its file names' {
        $map = Get-RepoMap -Paths @('README.md', 'src/api/users.ts', 'src/api/routes.ts', 'src/lib/http.ts') -MaxTokens 3000
        $map | Should -Match '## Repository map \(4 files, 3 folders\)'
        $map | Should -Match '(?m)^/  README\.md$'
        $map | Should -Match '(?m)^/src/api/  routes\.ts, users\.ts$'
        $map | Should -Match '(?m)^/src/lib/  http\.ts$'
    }

    It 'falls back to file counts when the names do not fit' {
        $paths = 1..400 | ForEach-Object { "src/area$($_ % 4)/file-with-a-long-name-$_.ts" }
        $map = Get-RepoMap -Paths $paths -MaxTokens 300
        $map | Should -Match '(?m)^/src/area0/  \(100 files\)$'
        $map | Should -Not -Match 'file-with-a-long-name'
    }

    It 'stays within the budget and says how many folders it left out' {
        $paths = 1..2000 | ForEach-Object { "pkg/m$_/sub/deep/f.go" }
        $map = Get-RepoMap -Paths $paths -MaxTokens 200
        $map.Length | Should -BeLessOrEqual (200 * 3.5)
        $map | Should -Match 'deeper folder\(s\) not shown'
    }

    It 'returns nothing without files or budget' {
        Get-RepoMap -Paths @() | Should -Be ''
        Get-RepoMap -Paths @('a.txt') -MaxTokens 0 | Should -Be ''
    }
}
}
