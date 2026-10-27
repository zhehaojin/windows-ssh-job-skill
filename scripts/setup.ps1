<#
.SYNOPSIS
Build the SSH askpass helper using an existing .NET Framework C# compiler.
.DESCRIPTION
Compiles ssh_askpass.cs beside this script. No packages, network access, SSH
configuration or credential reads are involved. The generated executable is local.
.EXAMPLE
./setup.ps1
.EXAMPLE
./setup.ps1 -CompilerPath 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
#>
[CmdletBinding()]
param([string]$CompilerPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
        $candidates = @(
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
        )
        $CompilerPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if ([string]::IsNullOrWhiteSpace($CompilerPath) -or -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
        throw 'An existing .NET Framework csc.exe was not found. Supply -CompilerPath; this script does not install software.'
    }
    $sourcePath = Join-Path $PSScriptRoot 'ssh_askpass.cs'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'ssh_askpass.cs is missing.' }
    $outputPath = Join-Path $PSScriptRoot 'ssh_askpass.exe'
    & $CompilerPath /nologo /target:exe ('/out:' + $outputPath) $sourcePath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    [pscustomobject]@{ helper_path = $outputPath } | ConvertTo-Json -Compress | Write-Output
    exit 0
}
catch {
    [Console]::Error.WriteLine('setup.ps1: ' + $_.Exception.Message)
    exit 2
}
