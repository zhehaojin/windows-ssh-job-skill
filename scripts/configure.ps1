<#
.SYNOPSIS
Remember the local SSH password-file location without reading its contents.
.DESCRIPTION
Accept an existing absolute local file path, or a directory containing the file.
The initial profile requires ServerHost, ServerUser and Repo. On later calls,
only explicitly supplied connection fields and credential_file are updated.
The password file is never read, copied, moved, created or modified.
.EXAMPLE
./configure.ps1 -ServerHost '100.64.0.10' -ServerUser 'researcher' -Repo 'D:\projects\example' -CredentialFile 'C:\private\ssh-password.txt'
.EXAMPLE
./configure.ps1 -CredentialDirectory 'D:\private'
.EXAMPLE
./configure.ps1 -CredentialDirectory 'D:\private' -CredentialFileName 'server-password.txt'
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialFile,
    [Parameter(Mandatory = $true, ParameterSetName = 'Directory')]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory,
    [Parameter(ParameterSetName = 'Directory')]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialFileName = 'ssh-password.txt',
    [ValidateNotNullOrEmpty()]
    [string]$ServerHost,
    [ValidateNotNullOrEmpty()]
    [string]$ServerUser,
    [ValidateNotNullOrEmpty()]
    [string]$Repo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temporaryPath = $null

function Get-LocalAbsolutePath([string]$Value, [string]$Name) {
    if ($Value -notmatch '^[A-Za-z]:[\\/]' -or $Value.IndexOfAny([char[]]"`0`r`n") -ge 0) {
        throw "$Name must be an absolute local Windows drive path."
    }
    return [IO.Path]::GetFullPath($Value)
}

try {
    if ($PSBoundParameters.ContainsKey('ServerHost') -and $ServerHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
        throw 'ServerHost must be a host name or IPv4 address.'
    }
    if ($PSBoundParameters.ContainsKey('ServerUser') -and $ServerUser -notmatch '^[A-Za-z0-9_.\\-]+$') {
        throw 'ServerUser contains unsupported characters.'
    }
    if ($PSBoundParameters.ContainsKey('Repo')) {
        [void](Get-LocalAbsolutePath $Repo 'Repo')
    }
    if ($PSCmdlet.ParameterSetName -eq 'Directory') {
        $directory = Get-LocalAbsolutePath $CredentialDirectory 'CredentialDirectory'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw 'CredentialDirectory does not exist.'
        }
        if ($CredentialFileName -match '[\\/:\x00-\x1f]' -or $CredentialFileName -in @('.', '..')) {
            throw 'CredentialFileName must be a file name without a directory.'
        }
        $credentialPath = [IO.Path]::Combine($directory, $CredentialFileName)
    }
    else {
        $credentialPath = Get-LocalAbsolutePath $CredentialFile 'CredentialFile'
    }
    # Existence checks only: never open the credential file.
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        throw 'The specified credential file does not exist.'
    }

    $skillRoot = Split-Path -Parent $PSScriptRoot
    $configurationPath = Join-Path $skillRoot 'server.local.json'
    $configurationExists = Test-Path -LiteralPath $configurationPath -PathType Leaf
    if ($configurationExists) {
        $json = [IO.File]::ReadAllText($configurationPath, [Text.Encoding]::UTF8)
        # Newer PowerShell can preserve JSON date strings explicitly. PS5's
        # converter already keeps them as strings.
        $converter = Get-Command ConvertFrom-Json
        if ($converter.Parameters.ContainsKey('DateKind')) {
            $configuration = ConvertFrom-Json -InputObject $json -DateKind String
        }
        else { $configuration = ConvertFrom-Json -InputObject $json }
        if ($null -eq $configuration -or $configuration -isnot [pscustomobject]) {
            throw 'server.local.json must contain a JSON object.'
        }
    }
    else {
        if (-not $PSBoundParameters.ContainsKey('ServerHost') -or -not $PSBoundParameters.ContainsKey('ServerUser') -or -not $PSBoundParameters.ContainsKey('Repo')) {
            throw 'The first configuration requires -ServerHost, -ServerUser and -Repo.'
        }
        $configuration = [pscustomobject][ordered]@{}
    }
    if ($PSBoundParameters.ContainsKey('ServerHost')) { $configuration | Add-Member -MemberType NoteProperty -Name 'host' -Value $ServerHost -Force }
    if ($PSBoundParameters.ContainsKey('ServerUser')) { $configuration | Add-Member -MemberType NoteProperty -Name 'user' -Value $ServerUser -Force }
    if ($PSBoundParameters.ContainsKey('Repo')) { $configuration | Add-Member -MemberType NoteProperty -Name 'repo' -Value $Repo -Force }
    $configuration | Add-Member -MemberType NoteProperty -Name 'credential_file' -Value $credentialPath -Force
    foreach ($required in @('host', 'user', 'repo')) {
        $property = $configuration.PSObject.Properties[$required]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "server.local.json requires '$required'; supply the corresponding connection parameter."
        }
    }

    $updatedJson = ConvertTo-Json -InputObject $configuration -Depth 100
    $temporaryPath = Join-Path $skillRoot ('.server.local.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporaryPath, ($updatedJson + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    if ($configurationExists) {
        # PS5 otherwise converts $null to an empty backup-path string.
        [IO.File]::Replace($temporaryPath, $configurationPath, [NullString]::Value)
    }
    else {
        # Move does not overwrite a profile created concurrently by another call.
        [IO.File]::Move($temporaryPath, $configurationPath)
    }
    $temporaryPath = $null
    [pscustomobject]@{
        configuration_path = $configurationPath
        credential_file = $credentialPath
    } | ConvertTo-Json -Compress | Write-Output
    exit 0
}
catch {
    [Console]::Error.WriteLine('configure.ps1: ' + $_.Exception.Message)
    exit 2
}
finally {
    if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}
