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

Describe 'Resolve-RelativeRepoPath' {
    It 'joins a relative reference to the folder of the importing file' {
        Resolve-RelativeRepoPath -FromFile 'src/api/users.ts' -Reference '../lib/http' | Should -Be 'src/lib/http'
        Resolve-RelativeRepoPath -FromFile 'src/api/users.ts' -Reference './db' | Should -Be 'src/api/db'
        Resolve-RelativeRepoPath -FromFile 'main.bicep' -Reference 'modules/cosmos.bicep' | Should -Be 'modules/cosmos.bicep'
    }

    It 'returns nothing for a reference above the repository root' {
        Resolve-RelativeRepoPath -FromFile 'a.ts' -Reference '../../x' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ImportedFilePaths' {
    BeforeAll {
        $script:Tracked = @{}
        foreach ($path in @('src/api/users.ts', 'src/lib/http.ts', 'src/lib/index.ts', 'src/db/index.js', 'app/models/user.py',
                'app/services/__init__.py', 'app/util.py', 'svc/internal/auth/auth.go', 'svc/internal/auth/auth_test.go',
                'svc/internal/auth/sub/x.go', 'engine/Helpers.ps1', 'engine/lib/Shared.ps1', 'infra/modules/cosmos.bicep')) {
            $script:Tracked[$path] = $true
        }
        function Get-Imports($File, [string[]]$Lines, $GoModules = @{}) {
            @(Get-ImportedFilePaths -File $File -Lines $Lines -Tracked $script:Tracked -GoModules $GoModules | ForEach-Object { $_.Path })
        }
    }

    It 'resolves TypeScript and JavaScript imports, adding extensions and index files' {
        $imports = Get-Imports 'src/api/users.ts' @(
            "import { get } from '../lib/http';",
            "import lib from '../lib';",
            "const db = require('../db');",
            "import React from 'react';"
        )
        $imports | Should -Be @('src/lib/http.ts', 'src/lib/index.ts', 'src/db/index.js')
    }

    It 'resolves Python relative and absolute imports' {
        Get-Imports 'app/models/user.py' @('from ..util import slugify', 'from app.services import billing', 'import os') |
            Should -Be @('app/util.py', 'app/services/__init__.py')
    }

    It 'maps a Go import to the package folder through go.mod, without test files or subfolders' {
        Get-Imports 'svc/main.go' @('import (', '    "fmt"', '    "example.com/svc/internal/auth"', ')') @{ 'example.com/svc' = 'svc' } |
            Should -Be @('svc/internal/auth/auth.go')
    }

    It 'resolves PowerShell dot-sourcing and Join-Path references' {
        Get-Imports 'engine/Main.ps1' @('. "$PSScriptRoot/Helpers.ps1"', '. (Join-Path $PSScriptRoot ''lib'' ''Shared.ps1'')') |
            Should -Be @('engine/Helpers.ps1', 'engine/lib/Shared.ps1')
    }

    It 'resolves Bicep modules' {
        Get-Imports 'infra/main.bicep' @("module cosmos 'modules/cosmos.bicep' = {") | Should -Be @('infra/modules/cosmos.bicep')
    }

    It 'ignores files that are not on the branch' {
        Get-Imports 'src/api/users.ts' @("import x from './missing';") | Should -BeNullOrEmpty
    }
}

Describe 'Get-CodeLanguage' {
    It 'groups extensions into families and has none for non-code files' {
        (Get-CodeLanguage 'src/a.tsx').Name | Should -Be 'js'
        (Get-CodeLanguage 'tools/x.psm1').Name | Should -Be 'ps'
        (Get-CodeLanguage 'tools/x.psm1').PathSpec | Should -Contain '*.ps1'
        Get-CodeLanguage 'README.md' | Should -BeNullOrEmpty
        Get-CodeLanguage 'pipeline.yml' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ChangedSymbolNames' {
    It 'finds declarations in several languages' {
        $names = @(Get-ChangedSymbolNames -ChangedLines @(
                'export function createUser(name: string, email: string) {',
                'export const deleteUser = async (id) => {',
                'class UserService {',
                'def send_invoice(order):',
                'func (s *Store) SaveEvent(ctx context.Context) error {',
                'function Get-ReviewFingerprint {',
                'public async Task<User> LoadUser(int id)'
            ) | ForEach-Object { $_.Name })
        foreach ($name in @('createUser', 'deleteUser', 'UserService', 'send_invoice', 'SaveEvent', 'Get-ReviewFingerprint', 'LoadUser')) {
            $names | Should -Contain $name
        }
    }

    It 'ranks changed declarations above functions whose bodies changed' {
        $symbols = @(Get-ChangedSymbolNames -ChangedLines @('function renameUser(id) {') -HunkFunctions @('function loadUsers(filter) {'))
        ($symbols | Where-Object Name -eq 'renameUser').Priority | Should -Be 2
        ($symbols | Where-Object Name -eq 'loadUsers').Priority | Should -Be 1
    }

    It 'skips comments, short names and generic names' {
        $names = @(Get-ChangedSymbolNames -ChangedLines @(
                '// the function call below retries', '# def helper_in_a_comment():', 'function run() {', 'function render() {'
            ) | ForEach-Object { $_.Name })
        $names | Should -BeNullOrEmpty
    }
}

Describe 'Format-ContextExcerpt' {
    It 'shows a small file whole, numbered unlike the diff' {
        $text = Format-ContextExcerpt -Lines @('a', 'b') -MaxTokens 500
        $text | Should -Match '(?m)^    1 \| a$'
        $text | Should -Match '(?m)^    2 \| b$'
    }

    It 'shows the lines around the focus of a large file, within the budget' {
        $lines = 1..500 | ForEach-Object { "line number $_ of a long file with some padding text" }
        $text = Format-ContextExcerpt -Lines $lines -Focus @(100, 300) -Radius 2 -MaxTokens 300
        $text.Length | Should -BeLessOrEqual (300 * 3.5)
        $text | Should -Match '(?m)^   98 \| '
        $text | Should -Match '(?m)^  302 \| '
        $text | Should -Not -Match '(?m)^   97 \| '
        $text | Should -Match '\.\.\.'
    }

    It 'shows the declarations of a large file as an outline' {
        $lines = @('function first() {') + (1..400 | ForEach-Object { "  body line $_ with enough text to be long" }) + @('export class Second {', '}')
        $text = Format-ContextExcerpt -Lines $lines -Outline -MaxTokens 200
        $text | Should -Match '(?m)^    1 \| function first'
        $text | Should -Match 'export class Second'
        $text | Should -Not -Match 'body line 200'
    }
}

Describe 'Find-SymbolUsage' {
    It 'finds the files that use a symbol, skipping the batch and other languages' {
        New-TestRepo {
            Write-RepoFile 'src/users.ts' 'export function createUser(name) { return name; }'
            Write-RepoFile 'src/routes.ts' @('import { createUser } from "./users";', 'app.post("/u", (r) => createUser(r.body));')
            Write-RepoFile 'src/other.ts' 'export const unrelated = 1;'
            Write-RepoFile 'scripts/x.py' 'createUser = None'
        }
        $usage = Invoke-InRepo {
            Find-SymbolUsage -Ref 'origin/feature' -Symbols @([PSCustomObject]@{ Name = 'createUser'; Priority = 2 }) `
                -SkipFiles @('src/users.ts') -PathSpec @('*.ts', '*.tsx')
        }
        @($usage).Count | Should -Be 1
        $usage[0].Path | Should -Be 'src/routes.ts'
        $usage[0].Symbols | Should -Be @('createUser')
        $usage[0].Lines | Should -Be @(1, 2)
    }

    It 'drops a symbol that too many files use' {
        New-TestRepo {
            1..5 | ForEach-Object { Write-RepoFile "src/f$_.ts" 'logEvent("x");' }
            Write-RepoFile 'src/g.ts' 'saveOrder(1);'
        }
        $usage = Invoke-InRepo {
            Find-SymbolUsage -Ref 'origin/feature' -MaxFilesPerSymbol 3 -Symbols @(
                [PSCustomObject]@{ Name = 'logEvent'; Priority = 2 }, [PSCustomObject]@{ Name = 'saveOrder'; Priority = 2 })
        }
        @($usage | ForEach-Object { $_.Path }) | Should -Be @('src/g.ts')
    }

    It 'does not count a word inside a longer hyphenated or comment text' {
        New-TestRepo { Write-RepoFile 'a.go' @('// sign in first', 'x := sign-in', 'y := signer(1)') }
        $usage = Invoke-InRepo { Find-SymbolUsage -Ref 'origin/feature' -Symbols @([PSCustomObject]@{ Name = 'sign'; Priority = 2 }) }
        @($usage).Count | Should -Be 0
    }
}

Describe 'New-BatchRepoContext' {
    It 'adds the map, the callers of a changed function and the files the change imports' {
        New-TestRepo {
            Write-RepoFile 'src/users.ts' @('import { query } from "./db";', '', 'export function createUser(name: string) {', '  return query(name);', '}')
            Write-RepoFile 'src/db.ts' @('export function query(sql: string) {', '  return sql;', '}')
            Write-RepoFile 'src/routes.ts' @('import { createUser } from "./users";', '', 'export const post = (r) => createUser(r.name);')
            Write-RepoFile 'README.md' 'createUser is documented here'
        } {
            Write-RepoFile 'src/users.ts' @('import { query } from "./db";', '', 'export function createUser(name: string, email: string) {', '  return query(name + email);', '}')
        }
        $context = Invoke-InRepo {
            $changes = Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature'
            $options = New-RepoContextOptions -SourceBranch 'refs/heads/feature' -MaxTokens 4000
            New-BatchRepoContext -Batch $changes.Batches[0] -Options $options
        }
        $context.Files | Should -Be 2
        $context.Tokens | Should -BeGreaterThan 0
        $context.Text | Should -Match '## Repository map \(4 files'
        $context.Text | Should -Match '(?s)## Related file: /src/routes.ts\nWhy: uses `createUser`, which this batch changes'
        $context.Text | Should -Match '(?m)^    3 \| export const post = \(r\) => createUser\(r.name\);$'
        $context.Text | Should -Match '(?s)## Related file: /src/db.ts\nWhy: imported by /src/users.ts'
        $context.Text | Should -Not -Match 'Related file: /src/users.ts'
        $context.Text | Should -Not -Match 'Related file: /README.md'
    }

    It 'stays within the token budget' {
        New-TestRepo {
            Write-RepoFile 'src/core.ts' 'export function computeTotals(x) { return x; }'
            1..30 | ForEach-Object { Write-RepoFile "src/use$_.ts" ((1..80 | ForEach-Object { "const v$_ = computeTotals($_); // padding padding padding" }) -join "`n") }
        } {
            Write-RepoFile 'src/core.ts' 'export function computeTotals(x, y) { return x + y; }'
        }
        $context = Invoke-InRepo {
            $changes = Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature'
            $options = New-RepoContextOptions -SourceBranch 'refs/heads/feature' -MaxTokens 2000
            New-BatchRepoContext -Batch $changes.Batches[0] -Options $options
        }
        $context.Text.Length | Should -BeLessOrEqual (2000 * 3.5)
        $context.Files | Should -BeGreaterThan 0
        $context.Files | Should -BeLessOrEqual 12
    }

    It 'returns nothing when the budget is zero' {
        (New-BatchRepoContext -Batch ([PSCustomObject]@{ Blocks = @() }) -Options ([PSCustomObject]@{ MaxTokens = 0 })).Text | Should -Be ''
    }
}

Describe 'Get-CodeChanges hunk functions' {
    It 'keeps the enclosing function git names in each hunk header' {
        $before = @('function loadUsers(filter) {') + (1..12 | ForEach-Object { "  const step$_ = $_;" }) + @('  return filter;', '}')
        $after = @('function loadUsers(filter) {') + (1..12 | ForEach-Object { "  const step$_ = $_;" }) + @('  return filter.trim();', '}')
        New-TestRepo { Write-RepoFile 'src/a.js' $before } { Write-RepoFile 'src/a.js' $after }
        $changes = Invoke-InRepo { Get-CodeChanges -TargetBranch 'refs/heads/main' -SourceBranch 'refs/heads/feature' }
        $changes.Batches[0].Blocks[0].HunkFunctions | Should -Contain 'function loadUsers(filter) {'
    }
}
}
