# Offline fixtures only. Run with Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('windows-ssh-skill-configure-' + [guid]::NewGuid().ToString('N'))
$sourceScripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$passed = 0

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function Invoke-Configure([hashtable]$Values, [int]$ExpectedExit) {
    $output = & (Join-Path $fixtureRoot 'scripts\configure.ps1') @Values
    Assert-True ($LASTEXITCODE -eq $ExpectedExit) "Expected configure exit $ExpectedExit, got $LASTEXITCODE."
    if ($ExpectedExit -eq 0) {
        $record = $output | ConvertFrom-Json
        Assert-True ($record.configuration_path -eq (Join-Path $fixtureRoot 'server.local.json')) 'Wrong configuration output path.'
    }
    $script:passed += 1
}

try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'private') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceScripts 'configure.ps1') -Destination (Join-Path $fixtureRoot 'scripts\configure.ps1')
    $file = Join-Path $fixtureRoot 'private\ssh-password.txt'
    $otherFile = Join-Path $fixtureRoot 'private\custom.txt'
    [IO.File]::WriteAllText($file, 'offline dummy fixture')
    [IO.File]::WriteAllText($otherFile, 'another offline dummy fixture')
    $profilePath = Join-Path $fixtureRoot 'server.local.json'

    Invoke-Configure @{ CredentialFile = $file } 2
    Assert-True (-not (Test-Path -LiteralPath $profilePath)) 'An incomplete first configuration created a profile.'
    Invoke-Configure @{ CredentialFile = $file; ServerHost = 'example.invalid'; ServerUser = 'researcher'; Repo = 'D:\projects\example' } 0
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    Assert-True ($profile.host -eq 'example.invalid' -and $profile.user -eq 'researcher' -and $profile.repo -eq 'D:\projects\example') 'Initial connection fields differ.'

    $profile | Add-Member -MemberType NoteProperty -Name 'custom' -Value @{ enabled = $true; nested = @('value', @{ count = 3 }) }
    [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    Invoke-Configure @{ CredentialFile = $otherFile } 0
    $updated = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    Assert-True ($updated.credential_file -eq $otherFile -and $updated.host -eq $profile.host -and $updated.user -eq $profile.user -and $updated.repo -eq $profile.repo) 'Credential update changed connection fields.'
    Assert-True ($updated.custom.enabled -and $updated.custom.nested[1].count -eq 3) 'An unknown profile field was lost.'
    Invoke-Configure @{ CredentialDirectory = (Split-Path -Parent $file) } 0
    Invoke-Configure @{ CredentialDirectory = (Split-Path -Parent $file); CredentialFileName = 'custom.txt' } 0

    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($profilePath))
    Invoke-Configure @{ CredentialFile = (Join-Path $fixtureRoot 'missing.txt') } 2
    Invoke-Configure @{ CredentialFile = 'relative-password.txt' } 2
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($profilePath)) -ceq $before) 'A rejected update changed the existing profile.'
    Invoke-Configure @{ CredentialFile = $file; ServerHost = 'updated.invalid' } 0
    $updated = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    Assert-True ($updated.host -eq 'updated.invalid' -and $updated.repo -eq $profile.repo) 'An explicit host update lost other fields.'
    Assert-True ([IO.File]::ReadAllText($file) -ceq 'offline dummy fixture') 'The fixture credential file changed.'
    Assert-True (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '.server.local.*.tmp').Count -eq 0) 'A temporary profile was left behind.'
    Write-Output "configure: $passed offline cases passed on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
        $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\windows-ssh-skill-configure-'
        if ($resolved.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
