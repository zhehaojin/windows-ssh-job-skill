# Offline native-process mocks. No remote server or real credential is accessed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('windows-ssh-skill-transport-' + [guid]::NewGuid().ToString('N'))
$sourceScripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$oldPath = $env:PATH
$oldMockExit = [Environment]::GetEnvironmentVariable('WINDOWS_SSH_MOCK_EXIT')
$oldMockSleep = [Environment]::GetEnvironmentVariable('WINDOWS_SSH_MOCK_SLEEP')
$passed = 0

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function Invoke-Helper([hashtable]$Values, [int]$ExpectedExit) {
    $output = & (Join-Path $fixtureRoot 'scripts\remote.ps1') @Values
    Assert-True ($LASTEXITCODE -eq $ExpectedExit) "Expected remote exit $ExpectedExit, got $LASTEXITCODE."
    $script:passed += 1
    return $output
}

try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'scripts') -Force | Out-Null
    foreach ($name in @('remote.ps1', 'setup.ps1', 'ssh_askpass.cs')) {
        Copy-Item -LiteralPath (Join-Path $sourceScripts $name) -Destination (Join-Path $fixtureRoot ('scripts\' + $name))
    }
    # This must stop before looking for askpass or starting any SSH process.
    [void](Invoke-Helper @{ Action = 'Info' } 2)
    $setupOutput = & (Join-Path $fixtureRoot 'scripts\setup.ps1')
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $fixtureRoot 'scripts\ssh_askpass.exe'))) 'Offline askpass compilation failed.'
    $compiler = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $mockSource = @'
using System;
using System.Text;
using System.Threading;
internal static class OfflineSshMock {
    static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        foreach (string arg in args)
            Console.WriteLine("ARG:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        Console.WriteLine("STDIN:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(Console.In.ReadToEnd())));
        int delay = 0; Int32.TryParse(Environment.GetEnvironmentVariable("WINDOWS_SSH_MOCK_SLEEP"), out delay);
        if (delay > 0) Thread.Sleep(delay);
        int code = 0; Int32.TryParse(Environment.GetEnvironmentVariable("WINDOWS_SSH_MOCK_EXIT"), out code);
        return code;
    }
}
'@
    $mockPath = Join-Path $fixtureRoot 'mock.cs'
    [IO.File]::WriteAllText($mockPath, $mockSource)
    & $compiler /nologo /target:exe ('/out:' + (Join-Path $fixtureRoot 'ssh.exe')) $mockPath
    Assert-True ($LASTEXITCODE -eq 0) 'The native SSH fixture did not compile.'
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'ssh.exe') -Destination (Join-Path $fixtureRoot 'scp.exe')
    $env:PATH = $fixtureRoot + ';' + $oldPath
    $credentialPath = Join-Path $fixtureRoot 'dummy-password.txt'
    [IO.File]::WriteAllText($credentialPath, 'offline dummy only')
    $profile = @{ host = 'example.invalid'; user = 'researcher'; repo = "D:\example's project"; credential_file = $credentialPath }
    $profilePath = Join-Path $fixtureRoot 'server.local.json'
    foreach ($missing in @('host', 'user', 'repo', 'credential_file')) {
        $incomplete = $profile.Clone()
        $incomplete.Remove($missing)
        [IO.File]::WriteAllText($profilePath, ($incomplete | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        [void](Invoke-Helper @{ Action = 'Info' } 2)
    }
    [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'scripts\remote_worker.py'), 'print("offline fixture")')

    $info = Invoke-Helper @{ Action = 'Info' } 0
    Assert-True (-not [string]::IsNullOrEmpty($info)) 'PowerShell assignment did not capture stdout.'
    $lines = @($info -split '\r?\n')
    $nativeArgs = @($lines | Where-Object { $_.StartsWith('ARG:') } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(4))) })
    $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($nativeArgs[-1]))
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($bootstrap, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0 -and $bootstrap.Contains("example''s project")) 'Remote literals were not escaped correctly.'
    & (Join-Path $fixtureRoot 'scripts\remote.ps1') -Action Info > (Join-Path $fixtureRoot 'redirect.txt')
    Assert-True ((Get-Item -LiteralPath (Join-Path $fixtureRoot 'redirect.txt')).Length -gt 0) 'PowerShell redirection did not capture stdout.'
    [void](Invoke-Helper @{ Action = 'Status'; LaunchRecord = 'D:\jobs\record.json' } 0)
    [void](Invoke-Helper @{ Action = 'Status' } 2)
    [void](Invoke-Helper @{ Action = 'Launch' } 2)
    $argumentPath = Join-Path $fixtureRoot 'arguments.json'
    # Keep user argv as JSON data, including quotes, empty values and slashes.
    $argv = @('scripts/run.py', '--label', 'a "quoted" value', '', 'D:\trailing slash\')
    [IO.File]::WriteAllText($argumentPath, (ConvertTo-Json -InputObject $argv))
    $launch = Invoke-Helper @{ Action = 'Launch'; ArgumentsFile = $argumentPath } 0
    $lines = @($launch -split '\r?\n')
    $nativeArgs = @($lines | Where-Object { $_.StartsWith('ARG:') } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(4))) })
    $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($nativeArgs[-1]))
    $requestB64 = [regex]::Match($bootstrap, "KING_REMOTE_REQUEST_B64 = '([^']+)'").Groups[1].Value
    $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($requestB64)) | ConvertFrom-Json
    Assert-True (($request.arguments | ConvertTo-Json -Compress) -eq ($argv | ConvertTo-Json -Compress)) 'Launch argv changed in transit.'
    [IO.File]::WriteAllText($argumentPath, '[["nested"]]')
    [void](Invoke-Helper @{ Action = 'Launch'; ArgumentsFile = $argumentPath } 2)
    [void](Invoke-Helper @{ Action = 'Pull'; RemotePath = 'D:\results;whoami'; LocalPath = (Join-Path $fixtureRoot 'out.json') } 2)
    $env:WINDOWS_SSH_MOCK_EXIT = '255'
    [void](Invoke-Helper @{ Action = 'Info' } 255)
    $env:WINDOWS_SSH_MOCK_EXIT = '0'; $env:WINDOWS_SSH_MOCK_SLEEP = '10000'
    [void](Invoke-Helper @{ Action = 'Info'; TimeoutSeconds = 1 } 124)
    Write-Output "transport: $passed offline cases and stdout redirection passed on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    $env:PATH = $oldPath
    [Environment]::SetEnvironmentVariable('WINDOWS_SSH_MOCK_EXIT', $oldMockExit)
    [Environment]::SetEnvironmentVariable('WINDOWS_SSH_MOCK_SLEEP', $oldMockSleep)
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
        $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\windows-ssh-skill-transport-'
        if ($resolved.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
