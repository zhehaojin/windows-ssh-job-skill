<#
.SYNOPSIS
Publishes an explicitly prepared results directory on a new GitHub branch.
.DESCRIPTION
Requires an existing HTTPS GitHub repository and Git on PATH. Uses a dedicated
work root and an isolated clone of origin's default branch. Never stages the
caller's checkout. Prepare ResultsDirectory yourself; do not pass a whole run,
environment, credential directory, or raw input tree.

Sensitive/environment/cache paths are excluded and counted. Symlinks/junctions
and individual files >= 50 MiB stop publication; use a GitHub Release for large
files. The existing Git user.name/email is used unless both AuthorName and
AuthorEmail are supplied. No Git configuration is written.

The exact empty-expectation lease --force-with-lease=refs/heads/<branch>:
is a create-only guard: Git refuses an already existing remote branch, including
a branch created after the initial check. No existing ref is overwritten.
DryRun can clone, copy and commit locally, but only runs git push --dry-run.
Successful calls return an object with Status, DryRun and PushMode=create-only.
Local clones are retained under WorkDirectory for inspection.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$RepositoryUrl,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Branch,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ResultsDirectory,
    [string]$PublishPath,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$WorkDirectory,
    [string]$CommitMessage = 'Publish Windows SSH job results',
    [string]$AuthorName,
    [string]$AuthorEmail,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($RepositoryUrl -cnotmatch '^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\.git$') {
    throw 'RepositoryUrl must be https://github.com/OWNER/REPO.git without userinfo, tokens, query strings or fragments.'
}
if ($Branch -in @('main', 'master', 'HEAD') -or $Branch -match '^refs/' -or
    $Branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
    $Branch.Contains('..') -or $Branch -match '(^|/)\.|//|/$|\.$|\.lock($|/)') {
    throw 'Branch must be a new non-main/master branch with safe Git ref components.'
}
if ([string]::IsNullOrWhiteSpace($CommitMessage)) { throw 'CommitMessage must not be empty.' }
if ([bool]$AuthorName -ne [bool]$AuthorEmail) { throw 'Supply both AuthorName and AuthorEmail, or neither.' }
if ($AuthorName -match '[\r\n]' -or $AuthorEmail -match '[\r\n]') { throw 'Author fields must be single-line values.' }

$source = Get-Item -LiteralPath $ResultsDirectory -Force
if ($source.PSProvider.Name -ne 'FileSystem' -or -not $source.PSIsContainer -or -not $source.Parent -or
    ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'ResultsDirectory must be a real filesystem directory, not a link or junction.'
}
$sourcePath = $source.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not $PublishPath) { $PublishPath = 'published-results/' + $source.Name }
if ($PublishPath -match '\\|^/|/$|//' -or $PublishPath -match '[\x00-\x1f]') {
    throw 'PublishPath must be a safe repository-relative path using forward slashes.'
}
foreach ($segment in $PublishPath.Split('/')) {
    if ($segment -notmatch '^[A-Za-z0-9_-][A-Za-z0-9._ -]*$' -or
        $segment -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)' -or
        $segment -in @('.', '..', '.git')) {
        throw 'PublishPath contains an unsafe or reserved path component.'
    }
}

$workPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDirectory)
$workPath = [IO.Path]::GetFullPath($workPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
$separator = [string][IO.Path]::DirectorySeparatorChar
if ($workPath.Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
    $workPath.StartsWith($sourcePath + $separator, [StringComparison]::OrdinalIgnoreCase) -or
    $sourcePath.StartsWith($workPath + $separator, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkDirectory and ResultsDirectory must be separate, non-overlapping trees.'
}
for ($ancestor = [IO.DirectoryInfo]$workPath; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
    if (Test-Path -LiteralPath (Join-Path $ancestor.FullName '.git')) {
        throw 'WorkDirectory must be outside existing Git checkouts.'
    }
}
$markerPath = Join-Path $workPath '.windows-ssh-job-results'
if (Test-Path -LiteralPath $workPath) {
    $workItem = Get-Item -LiteralPath $workPath -Force
    if (-not $workItem.PSIsContainer -or ($workItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'WorkDirectory must be a real dedicated directory.'
    }
    $contents = @(Get-ChildItem -LiteralPath $workPath -Force)
    if ($contents.Count -gt 0) {
        $marker = Get-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        if (-not $marker -or $marker.PSIsContainer -or
            ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-Content -LiteralPath $markerPath -Raw).Trim() -ne 'windows-ssh-job-results-v1') {
            throw 'Non-empty WorkDirectory is not a dedicated results publishing root. Choose a new empty directory.'
        }
    }
}

# Enumerate without following links or descending into excluded directories.
$files = New-Object 'System.Collections.Generic.List[object]'
$pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
$pending.Push($source)
$excludedCount = 0
$excludedDirectories = @('.git', '.ssh', '.aws', 'venv', '.venv', '.venvs', '.deployment', '.remote', '.local', 'env', 'inputs', 'input', 'cache', '.cache', '__pycache__', 'node_modules')
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'ResultsDirectory contains a symlink or junction. Prepare a directory of ordinary files before publishing.'
        }
        if ($item.Name -in $excludedDirectories) { $excludedCount++; continue }
        if ($item.PSIsContainer) {
            $pending.Push($item)
            continue
        }
        if ($item.Name -like 'credential*.env' -or $item.Name -like '*.local.json' -or
            $item.Name -like '*password*.txt' -or $item.Name -like '*credential*.txt' -or
            $item.Name -eq '.env' -or $item.Name -like '.env.*' -or
            $item.Extension -in @('.pem', '.key', '.pfx', '.p12', '.ppk') -or
            $item.Name -match '^id_(rsa|dsa|ecdsa|ed25519)(_|$)') {
            $excludedCount++; continue
        }
        if ($item.Length -ge 50MB) {
            throw 'A result file is at least 50 MiB. Publish large artifacts through a GitHub Release, then retry with a prepared smaller results directory.'
        }
        $stream = [IO.File]::OpenRead($item.FullName)
        try {
            $headerBytes = New-Object byte[] 256
            $read = $stream.Read($headerBytes, 0, $headerBytes.Length)
            $header = [Text.Encoding]::ASCII.GetString($headerBytes, 0, $read)
        } finally { $stream.Dispose() }
        if ($header -match '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|^PuTTY-User-Key-File-') {
            $excludedCount++; continue
        }
        $files.Add($item)
    }
}
if ($files.Count -eq 0) { throw 'No publishable result files remain after exclusions.' }

$gitCommand = Get-Command git -ErrorAction Stop
$clonePath = $null
$emptyHooks = $null
function Invoke-ResultsGit {
    param([string[]]$Arguments, [int[]]$AllowedExitCodes = @(0))
    $prefix = @('-c', ('core.hooksPath=' + $emptyHooks), '-c', 'protocol.file.allow=never')
    if ($clonePath) { $prefix += @('-C', $clonePath) }
    # Native Git writes normal progress to stderr on Windows PowerShell 5.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = 0
        $output = @(& $gitCommand @prefix @Arguments 2>$null)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($code -notin $AllowedExitCodes) {
        throw ('Git operation failed (exit {0}); inspect authentication, permissions and the retained local clone. Git output was suppressed to avoid exposing credentials.' -f $code)
    }
    [pscustomobject]@{ ExitCode = $code; Output = $output }
}
function New-PublishResult {
    param([string]$Status)
    [pscustomobject][ordered]@{
        Status = $Status; DryRun = [bool]$DryRun; PushMode = 'create-only'
        RepositoryUrl = $RepositoryUrl; Branch = $Branch; PublishPath = $PublishPath
        ClonePath = $clonePath; PublishedFileCount = $files.Count; ExcludedEntryCount = $excludedCount
    }
}

# Clear inherited repository overrides only for this process, restoring them even
# when a command fails. Git credential helpers may still use existing credentials.
$environmentValues = @{
    GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'never'
    GIT_DIR = $null; GIT_WORK_TREE = $null; GIT_INDEX_FILE = $null
    GIT_COMMON_DIR = $null; GIT_OBJECT_DIRECTORY = $null
    GIT_ALTERNATE_OBJECT_DIRECTORIES = $null; GIT_CONFIG_COUNT = $null
    GIT_CONFIG_PARAMETERS = $null; GIT_CONFIG = $null; GIT_NAMESPACE = $null
}
$savedEnvironment = @{}
try {
    foreach ($name in $environmentValues.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -eq $environmentValues[$name]) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        } else { [Environment]::SetEnvironmentVariable($name, $environmentValues[$name], 'Process') }
    }
    if (-not (Test-Path -LiteralPath $workPath)) { $null = New-Item -ItemType Directory -Path $workPath }
    if (-not (Test-Path -LiteralPath $markerPath)) { Set-Content -LiteralPath $markerPath -Value 'windows-ssh-job-results-v1' -Encoding ASCII }
    $emptyHooks = Join-Path $workPath ('hooks-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $emptyHooks
    $null = Invoke-ResultsGit @('check-ref-format', '--branch', $Branch)
    $remote = Invoke-ResultsGit @('ls-remote', '--exit-code', '--heads', $RepositoryUrl, ('refs/heads/' + $Branch)) @(0, 2)
    if ($remote.ExitCode -eq 0) { New-PublishResult 'AlreadyExists'; return }

    $newClone = Join-Path $workPath ('clone-' + [guid]::NewGuid().ToString('N'))
    $null = Invoke-ResultsGit @('clone', '--depth', '1', '--single-branch', '--no-tags', '--', $RepositoryUrl, $newClone)
    $clonePath = $newClone
    $null = Invoke-ResultsGit @('rev-parse', '--verify', 'HEAD')
    $null = Invoke-ResultsGit @('checkout', '-b', $Branch)
    $target = $clonePath
    foreach ($segment in $PublishPath.Split('/')) {
        $target = Join-Path $target $segment
        $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($targetItem) {
            if (-not $targetItem.PSIsContainer -or ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'PublishPath conflicts with a file, link or junction in the repository.'
            }
        }
    }
    $null = New-Item -ItemType Directory -Path $target -Force
    foreach ($file in $files) {
        # Recheck each file before reading in case the prepared tree was changed.
        $current = Get-Item -LiteralPath $file.FullName -Force
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $current.Length -ge 50MB) {
            throw 'A prepared file changed to a link or oversized artifact; prepare results again.'
        }
        $relative = $file.FullName.Substring($sourcePath.Length + 1)
        $destination = Join-Path $target $relative
        $parent = Split-Path -Parent $destination
        # Copying over repository symlinks could write outside the isolated clone.
        for ($part = $destination; $part.Length -gt $clonePath.Length; $part = Split-Path -Parent $part) {
            $partItem = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            if ($partItem) {
                if ($partItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw 'A destination path contains a link or junction; choose another PublishPath.'
                }
            }
        }
        $null = New-Item -ItemType Directory -Path $parent -Force
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
    $null = Invoke-ResultsGit @('add', '--', (':(literal)' + $PublishPath))
    $difference = Invoke-ResultsGit @('diff', '--cached', '--quiet', '--', (':(literal)' + $PublishPath)) @(0, 1)
    if ($difference.ExitCode -eq 0) { New-PublishResult 'NoChanges'; return }

    $authorOptions = @()
    if ($AuthorName) {
        $authorOptions = @('-c', ('user.name=' + $AuthorName), '-c', ('user.email=' + $AuthorEmail))
    } else {
        $name = Invoke-ResultsGit @('config', 'user.name') @(0, 1)
        $email = Invoke-ResultsGit @('config', 'user.email') @(0, 1)
        if ($name.ExitCode -ne 0 -or $email.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace(($name.Output -join '')) -or [string]::IsNullOrWhiteSpace(($email.Output -join ''))) {
            throw 'Configure Git user.name and user.email, or provide both AuthorName and AuthorEmail. No commit or push was made.'
        }
    }
    $null = Invoke-ResultsGit ($authorOptions + @('commit', '--no-gpg-sign', '-m', $CommitMessage))
    # Empty expected value means this exact remote ref MUST NOT already exist.
    # https://git-scm.com/docs/git-push#Documentation/git-push.txt---force-with-leaseltrefnamegtltexpectgt
    $pushArguments = @('push', '--porcelain', '--no-follow-tags', '--signed=false', ('--force-with-lease=refs/heads/' + $Branch + ':'))
    if ($DryRun) { $pushArguments += '--dry-run' }
    $pushArguments += @('origin', ('HEAD:refs/heads/' + $Branch))
    $null = Invoke-ResultsGit $pushArguments
    if ($DryRun) { New-PublishResult 'DryRun'; return }
    New-PublishResult 'Published'
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        } else { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    }
}
