# Offline behavioral tests, requiring only Windows PowerShell 5.1 or PowerShell 7.
# Git is replaced by a function: no network, credentials or real remote are used.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/publish-results.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('publish-results-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($null -ne $message -and $message -match $Pattern) ('Expected failure matching: ' + $Pattern + '; actual: ' + $message)
}
function New-Fixture {
    $folder = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $results = Join-Path $folder 'prepared'
    $null = New-Item -ItemType Directory -Path $results -Force
    Set-Content -LiteralPath (Join-Path $results 'result.json') -Value '{"ok":true}' -Encoding ASCII
    $global:GitCalls = New-Object 'System.Collections.Generic.List[object]'
    $global:MockRemoteExists = $false
    $global:MockNoChanges = $false
    $global:MockMissingIdentity = $false
    $global:MockPushRace = $false
    $global:MockFailure = $null
    $global:MockDestinationLink = $null
    @{
        RepositoryUrl = 'https://github.com/example/results.git'
        Branch = 'results/job-123'
        ResultsDirectory = $results
        WorkDirectory = (Join-Path $folder 'publisher')
        CommitMessage = 'Result with spaces, $literal and `backtick'
    }
}

function global:git {
    $arguments = @($args | ForEach-Object { [string]$_ })
    $global:GitCalls.Add([pscustomobject]@{
        Arguments = $arguments
        Prompt = $env:GIT_TERMINAL_PROMPT; Interactive = $env:GCM_INTERACTIVE
        GitDir = $env:GIT_DIR; Index = $env:GIT_INDEX_FILE
    })
    $position = 0
    $clone = $null
    while ($position -lt $arguments.Count -and $arguments[$position] -in @('-c', '-C')) {
        if ($arguments[$position] -eq '-C') { $clone = $arguments[$position + 1] }
        $position += 2
    }
    $command = $arguments[$position]
    $global:LASTEXITCODE = 0
    if ($global:MockFailure -eq $command) {
        $global:LASTEXITCODE = 128
        Write-Output 'SECRET-TOKEN-MUST-NOT-ESCAPE'
        return
    }
    switch ($command) {
        'check-ref-format' { return }
        'ls-remote' {
            if ($global:MockRemoteExists) { Write-Output 'deadbeef refs/heads/results/job-123' }
            else { $global:LASTEXITCODE = 2 }
            return
        }
        'clone' {
            $destination = $arguments[-1]
            $null = New-Item -ItemType Directory -Path (Join-Path $destination '.git') -Force
            if ($global:MockDestinationLink) {
                $published = Join-Path $destination 'published-results'
                $null = New-Item -ItemType Directory -Path $published
                $null = New-Item -ItemType Junction -Path (Join-Path $published 'prepared') -Target $global:MockDestinationLink
            }
            return
        }
        'checkout' { Assert-True ([bool]$clone) 'checkout must address isolated clone'; return }
        'rev-parse' { Write-Output '0123456789abcdef'; return }
        'add' { return }
        'diff' { if (-not $global:MockNoChanges) { $global:LASTEXITCODE = 1 }; return }
        'config' {
            if ($global:MockMissingIdentity) { $global:LASTEXITCODE = 1; return }
            if ($arguments[-1] -eq 'user.name') { Write-Output 'Existing User' }
            elseif ($arguments[-1] -eq 'user.email') { Write-Output 'user@example.invalid' }
            else { throw 'Unexpected config operation' }
            return
        }
        'commit' { return }
        'push' {
            if ($global:MockPushRace) { $global:LASTEXITCODE = 1 }
            return
        }
        default { throw ('Unexpected mock Git command: ' + ($arguments -join ' | ')) }
    }
}

try {
    $fixture = New-Fixture
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture.ResultsDirectory 'nested')
    Set-Content -LiteralPath (Join-Path $fixture.ResultsDirectory 'nested/table.csv') -Value 'a,b'
    foreach ($directory in @('.git', 'venv', 'inputs', 'cache', '.venvs', '.deployment', '.remote', '.local')) {
        $path = Join-Path $fixture.ResultsDirectory $directory
        $null = New-Item -ItemType Directory -Path $path
        Set-Content -LiteralPath (Join-Path $path 'private.txt') -Value 'SECRET'
    }
    foreach ($file in @('credentials.env', 'settings.local.json', 'id_rsa', 'private.pem', '.env', 'service-password.txt', 'service-credentials.txt')) {
        Set-Content -LiteralPath (Join-Path $fixture.ResultsDirectory $file) -Value 'SECRET'
    }
    Set-Content -LiteralPath (Join-Path $fixture.ResultsDirectory 'renamed-private.txt') -Value '-----BEGIN OPENSSH PRIVATE KEY-----'
    $oldLocation = (Get-Location).Path
    $priorPrompt = $env:GIT_TERMINAL_PROMPT
    $priorInteractive = $env:GCM_INTERACTIVE
    $priorGitDir = $env:GIT_DIR
    $priorIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_TERMINAL_PROMPT = 'original-prompt'
        $env:GCM_INTERACTIVE = 'original-interactive'
        $env:GIT_DIR = 'caller-checkout'
        $env:GIT_INDEX_FILE = 'caller-index'
        $result = & $scriptPath @fixture -DryRun
        Assert-True ($result.Status -eq 'DryRun' -and $result.DryRun -and $result.PushMode -eq 'create-only') 'explicit dry-run result'
        Assert-True ($env:GIT_TERMINAL_PROMPT -eq 'original-prompt' -and $env:GCM_INTERACTIVE -eq 'original-interactive') 'restore prompt environment'
        Assert-True ($env:GIT_DIR -eq 'caller-checkout' -and $env:GIT_INDEX_FILE -eq 'caller-index') 'restore caller repository environment'
    } finally {
        $env:GIT_TERMINAL_PROMPT = $priorPrompt; $env:GCM_INTERACTIVE = $priorInteractive
        $env:GIT_DIR = $priorGitDir; $env:GIT_INDEX_FILE = $priorIndex
    }
    Assert-True ((Get-Location).Path -eq $oldLocation) 'caller current directory preserved'
    Assert-True ($result.PublishedFileCount -eq 2 -and $result.ExcludedEntryCount -eq 16) 'copy only prepared safe files and count exclusions'
    $published = Join-Path $result.ClonePath 'published-results/prepared'
    Assert-True (Test-Path -LiteralPath (Join-Path $published 'nested/table.csv')) 'nested result copied'
    Assert-True (@(Get-ChildItem -LiteralPath $published -File -Recurse -Force).Count -eq 2) 'no sensitive files copied'
    $pushes = @($global:GitCalls | Where-Object { $_.Arguments -contains 'push' })
    Assert-True ($pushes.Count -eq 1) 'exactly one push invocation'
    $push = $pushes[0].Arguments
    Assert-True ($push -contains '--dry-run' -and $push -contains '--force-with-lease=refs/heads/results/job-123:') 'dry-run and exact empty-expectation creation lease'
    Assert-True ($push -contains '--no-follow-tags') 'global followTags cannot expand pushed refs'
    Assert-True ($push[-2] -eq 'origin' -and $push[-1] -eq 'HEAD:refs/heads/results/job-123') 'one explicit branch refspec'
    foreach ($call in $global:GitCalls) {
        Assert-True ($call.Prompt -eq '0' -and $call.Interactive -eq 'never') 'all Git calls noninteractive'
        Assert-True (-not $call.GitDir -and -not $call.Index) 'caller repository overrides cleared for all Git calls'
        Assert-True (-not ($call.Arguments -contains '--global') -and -not ($call.Arguments -contains '--force') -and -not ($call.Arguments -contains '--force-with-lease')) 'no global config or unrestricted force'
        foreach ($argument in $call.Arguments) { Assert-True (-not $argument.StartsWith('+')) 'no force refspec' }
    }
    $add = @($global:GitCalls | Where-Object { $_.Arguments -contains 'add' })[0].Arguments
    Assert-True ($add[-2] -eq '--' -and $add[-1] -eq ':(literal)published-results/prepared') 'stage only explicit literal PublishPath'
    $commit = @($global:GitCalls | Where-Object { $_.Arguments -contains 'commit' })[0].Arguments
    Assert-True ($commit[-1] -ceq $fixture.CommitMessage) 'commit message remains one literal argv item'
    $passed++

    # A dedicated publishing root can be reused; every run has a separate clone.
    $again = & $scriptPath @fixture -DryRun
    Assert-True ($again.ClonePath -ne $result.ClonePath) 'separate clone on dedicated root reuse'
    $passed++

    foreach ($badBranch in @('main', 'MASTER', 'HEAD', '-option', 'refs/heads/result', 'a..b', 'a@{b', 'x:y', 'a//b', 'a.lock', 'a/.hidden', 'a/', 'a?b')) {
        $fixture = New-Fixture
        $fixture.Branch = $badBranch
        Assert-Throws { & $scriptPath @fixture -DryRun } 'Branch must'
        Assert-True ($global:GitCalls.Count -eq 0) 'reject unsafe branch before Git'
    }
    $passed++
    foreach ($badUrl in @('https://token@github.com/o/r.git', 'http://github.com/o/r.git', 'https://github.com.evil/o/r.git', 'https://github.com/o/r.git?token=x', 'git@github.com:o/r.git')) {
        $fixture = New-Fixture; $fixture.RepositoryUrl = $badUrl
        Assert-Throws { & $scriptPath @fixture -DryRun } 'RepositoryUrl must'
        Assert-True ($global:GitCalls.Count -eq 0) 'reject unsafe repository before Git'
    }
    $passed++
    foreach ($badPath in @('../escape', '/absolute', 'C:/drive', 'safe/../escape', 'safe/.git', 'safe//bad', 'safe\bad', 'safe/NUL', 'safe/trailing.', ':(top)')) {
        $fixture = New-Fixture; $fixture.PublishPath = $badPath
        Assert-Throws { & $scriptPath @fixture -DryRun } 'PublishPath'
        Assert-True ($global:GitCalls.Count -eq 0) 'reject unsafe destination before Git'
    }
    $passed++

    $fixture = New-Fixture
    $global:MockRemoteExists = $true
    $existing = & $scriptPath @fixture
    Assert-True ($existing.Status -eq 'AlreadyExists') 'existing remote branch returns conservatively'
    Assert-True (@($global:GitCalls | Where-Object { $_.Arguments -contains 'clone' -or $_.Arguments -contains 'push' }).Count -eq 0) 'existing branch never cloned or pushed'
    $passed++

    $fixture = New-Fixture; $global:MockNoChanges = $true
    $unchanged = & $scriptPath @fixture
    Assert-True ($unchanged.Status -eq 'NoChanges') 'unchanged result status'
    Assert-True (@($global:GitCalls | Where-Object { $_.Arguments -contains 'commit' -or $_.Arguments -contains 'push' }).Count -eq 0) 'unchanged files never committed or pushed'
    $passed++

    $fixture = New-Fixture
    $normal = & $scriptPath @fixture -AuthorName 'Explicit User' -AuthorEmail 'explicit@example.invalid'
    Assert-True ($normal.Status -eq 'Published' -and -not $normal.DryRun) 'normal publish result'
    $push = @($global:GitCalls | Where-Object { $_.Arguments -contains 'push' })[0].Arguments
    Assert-True (-not ($push -contains '--dry-run')) 'real publish has no dry-run flag'
    $commit = @($global:GitCalls | Where-Object { $_.Arguments -contains 'commit' })[0].Arguments
    Assert-True ($commit -contains 'user.name=Explicit User' -and $commit -contains 'user.email=explicit@example.invalid') 'explicit identity set only in commit argv'
    $passed++

    $fixture = New-Fixture; $global:MockMissingIdentity = $true
    Assert-Throws { & $scriptPath @fixture } 'Configure Git user.name and user.email'
    Assert-True (@($global:GitCalls | Where-Object { $_.Arguments -contains 'push' -or $_.Arguments -contains 'commit' }).Count -eq 0) 'missing identity stops before commit/push'
    $passed++

    $fixture = New-Fixture; $global:MockPushRace = $true
    Assert-Throws { & $scriptPath @fixture } 'Git operation failed'
    Assert-True (@($global:GitCalls | Where-Object { $_.Arguments -contains 'push' }).Count -eq 1) 'lease rejection never retried with force'
    $passed++

    $fixture = New-Fixture; $global:MockFailure = 'clone'
    $message = $null
    try { & $scriptPath @fixture | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'Git operation failed' -and $message -notmatch 'SECRET-TOKEN') 'Git output never exposed on failure'
    Assert-True ($env:GIT_TERMINAL_PROMPT -eq $priorPrompt -and $env:GCM_INTERACTIVE -eq $priorInteractive) 'environment restored on failure'
    $passed++

    $fixture = New-Fixture
    $large = [IO.File]::Create((Join-Path $fixture.ResultsDirectory 'large.bin'))
    try { $large.SetLength(50MB) } finally { $large.Dispose() }
    Assert-Throws { & $scriptPath @fixture -DryRun } '50 MiB.*GitHub Release'
    Assert-True ($global:GitCalls.Count -eq 0) 'oversized artifact stops before Git'
    $passed++

    $fixture = New-Fixture
    $outside = Join-Path (Split-Path -Parent $fixture.ResultsDirectory) 'outside'
    $null = New-Item -ItemType Directory -Path $outside
    $null = New-Item -ItemType Junction -Path (Join-Path $fixture.ResultsDirectory 'link') -Target $outside
    Assert-Throws { & $scriptPath @fixture -DryRun } 'symlink or junction'
    Assert-True ($global:GitCalls.Count -eq 0) 'source junction rejected before Git'
    $passed++

    $fixture = New-Fixture
    $outside = Join-Path (Split-Path -Parent $fixture.ResultsDirectory) 'outside'
    $null = New-Item -ItemType Directory -Path $outside
    $global:MockDestinationLink = $outside
    Assert-Throws { & $scriptPath @fixture -DryRun } 'conflicts with a file, link or junction'
    Assert-True (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'repository junction cannot write outside clone'
    $passed++

    $fixture = New-Fixture
    $null = New-Item -ItemType Directory -Path $fixture.WorkDirectory
    Set-Content -LiteralPath (Join-Path $fixture.WorkDirectory 'user-data.txt') -Value 'keep'
    Assert-Throws { & $scriptPath @fixture -DryRun } 'Non-empty WorkDirectory'
    $fixture = New-Fixture
    $null = New-Item -ItemType Directory -Path (Join-Path (Split-Path -Parent $fixture.WorkDirectory) '.git')
    Assert-Throws { & $scriptPath @fixture -DryRun } 'outside existing Git checkouts'
    $passed++
    Write-Output ('PASS: {0} offline publishing scenarios; no real Git remote or credentials used.' -f $passed)
} finally {
    Remove-Item Function:\git -ErrorAction SilentlyContinue
    # Every path is generated below this verified unique test root. Remove links
    # themselves before recursive cleanup so neither PowerShell version follows them.
    if ($testRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testRoot) -like 'publish-results-tests-*') {
        Get-ChildItem -LiteralPath $testRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
