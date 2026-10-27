<#
.SYNOPSIS
Run a configured Windows server's SSH workflow without a GUI or a persistent session.
.DESCRIPTION
Info and Status only read remote state. Launch requires an explicit JSON array of
arguments after Python; RunPython sends the named local Python script on stdin.
Pull and Push transfer an explicit path; directories require -Recursive.
Authentication uses ssh_askpass.exe and the password-file path in server.local.json.
The password is never loaded by this script or placed in a command line.
.EXAMPLE
./remote.ps1 -Action Info
.EXAMPLE
./remote.ps1 -Action Status -RunDirectory 'D:\projects\example\runs\run_id'
.EXAMPLE
./remote.ps1 -Action Launch -ArgumentsFile './arguments.json' -Repo 'D:\projects\example'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Info', 'Status', 'Launch', 'RunPython', 'Pull', 'Push')]
    [string]$Action,
    [string]$Repo,
    [string]$RemotePython,
    [string]$RunDirectory,
    [string]$LaunchRecord,
    [string]$ScriptPath,
    [string]$ArgumentsFile,
    [string]$RemotePath,
    [string]$LocalPath,
    [switch]$Recursive,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 45,
    [ValidateRange(1, 20)]
    [int]$TailLines = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProfileValue($Profile, [string]$Name) {
    if ($null -ne $Profile) {
        $property = $Profile.PSObject.Properties[$Name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    throw "server.local.json requires a nonempty '$Name' field. Run scripts/configure.ps1 first."
}

function Assert-SingleLine([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOfAny([char[]]"`0`r`n") -ge 0) {
        throw "$Name must be a nonempty, single-line value."
    }
}

function Quote-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Quote-NativeArgument([string]$Value) {
    # CommandLineToArgvW / CRT quoting; also works on Windows PowerShell 5.1.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}

function Stop-OwnedTransport([Diagnostics.Process]$OwnedProcess) {
    if ($OwnedProcess.HasExited) { return }
    # This Process object was started by this invocation. Never search for or
    # terminate other SSH sessions, and never issue a remote kill command.
    $killTree = $OwnedProcess.GetType().GetMethod('Kill', [type[]]@([bool]))
    if ($null -ne $killTree) {
        if (-not $OwnedProcess.HasExited) { $OwnedProcess.Kill($true) }
        return
    }
    # Windows PowerShell 5.1 lacks Process.Kill(entireProcessTree). SCP can own
    # an SSH child, so kill precisely this still-live local process tree.
    $cleanupStart = New-Object Diagnostics.ProcessStartInfo
    $cleanupStart.FileName = Join-Path $env:WINDIR 'System32\taskkill.exe'
    $cleanupStart.Arguments = '/PID ' + $OwnedProcess.Id + ' /T /F'
    $cleanupStart.UseShellExecute = $false
    $cleanupStart.CreateNoWindow = $true
    $cleanupStart.RedirectStandardOutput = $true
    $cleanupStart.RedirectStandardError = $true
    $cleanup = New-Object Diagnostics.Process
    $cleanup.StartInfo = $cleanupStart
    try {
        if (-not $OwnedProcess.HasExited -and $cleanup.Start()) {
            [void]$cleanup.StandardOutput.ReadToEndAsync()
            [void]$cleanup.StandardError.ReadToEndAsync()
            if (-not $cleanup.WaitForExit(5000)) { $cleanup.Kill() }
        }
    }
    finally {
        $cleanup.Dispose()
        if (-not $OwnedProcess.HasExited) { $OwnedProcess.Kill() }
    }
}

function Invoke-OpenSsh([string]$Program, [string[]]$ArgumentValues, [string]$InputText, [int]$LimitSeconds) {
    $command = Get-Command -Name $Program -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $command.Source
    $start.Arguments = (($ArgumentValues | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $start.EnvironmentVariables['SSH_ASKPASS'] = $askpass
    $start.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
    $start.EnvironmentVariables['DISPLAY'] = 'local'
    $start.EnvironmentVariables['KING_SSH_PASSWORD_FILE'] = $credentialFile
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $started = $false
    $inputFailed = $false
    try {
        if (-not $process.Start()) { throw 'OpenSSH could not start.' }
        $started = $true
        # Drain both streams concurrently, including while writing a large script.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            try {
                $inputBytes = $utf8.GetBytes($InputText)
                $writeTask = $process.StandardInput.BaseStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
                $remaining = [Math]::Max(1, [int]($LimitSeconds * 1000 - $timer.ElapsedMilliseconds))
                if (-not $writeTask.Wait($remaining)) { $timedOut = $true }
                if (-not $timedOut) { [void]$writeTask.GetAwaiter().GetResult() }
            }
            catch { $inputFailed = $true }
        }
        try { $process.StandardInput.BaseStream.Close() } catch { $inputFailed = $true }
        $remaining = [Math]::Max(1, [int]($LimitSeconds * 1000 - $timer.ElapsedMilliseconds))
        if ($timedOut -or -not $process.WaitForExit($remaining)) {
            $timedOut = $true
            # Only the SSH/SCP process created here is terminated. Detached remote
            # jobs are not stopped, and unrelated local sessions are untouched.
            Stop-OwnedTransport $process
            [void]$process.WaitForExit(5000)
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($timedOut) {
            $stderr += "`nOpenSSH timed out after $LimitSeconds seconds. A remote launch may already have happened; check its launch record before retrying.`n"
            return [pscustomobject]@{ ExitCode = 124; Stdout = $stdout; Stderr = $stderr }
        }
        if ($inputFailed -and $process.ExitCode -eq 0) {
            return [pscustomobject]@{ ExitCode = 2; Stdout = $stdout; Stderr = ($stderr + "`nOpenSSH did not receive the complete input script.`n") }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }
    finally {
        if ($started -and -not $process.HasExited) { Stop-OwnedTransport $process }
        $process.Dispose()
    }
}

try {
    if ($PSBoundParameters.ContainsKey('LaunchRecord') -and $Action -ne 'Status') { throw '-LaunchRecord is a Status locator; Launch returns its new record path.' }
    if ($PSBoundParameters.ContainsKey('RunDirectory') -and $Action -ne 'Status') { throw '-RunDirectory is used only with Status; Launch arguments select the runner output.' }
    if ($PSBoundParameters.ContainsKey('ArgumentsFile') -and $Action -ne 'Launch') { throw '-ArgumentsFile is used only with Launch.' }
    if ($PSBoundParameters.ContainsKey('ScriptPath') -and $Action -ne 'RunPython') { throw '-ScriptPath is used only with RunPython.' }
    if (($PSBoundParameters.ContainsKey('RemotePath') -or $PSBoundParameters.ContainsKey('LocalPath') -or $Recursive) -and $Action -notin @('Pull', 'Push')) {
        throw '-RemotePath, -LocalPath and -Recursive are used only with Pull or Push.'
    }
    $profilePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'server.local.json'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw 'server.local.json is missing. Run scripts/configure.ps1 with the server details and credential-file location first.'
    }
    $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $serverUser = Get-ProfileValue $profile 'user'
    $serverHost = Get-ProfileValue $profile 'host'
    $profileRepo = Get-ProfileValue $profile 'repo'
    if (-not $PSBoundParameters.ContainsKey('Repo')) {
        $Repo = $profileRepo
    }
    $credentialFile = Get-ProfileValue $profile 'credential_file'
    if ($serverUser -notmatch '^[A-Za-z0-9_.\\-]+$' -or $serverHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
        throw 'Invalid user or host in server.local.json.'
    }
    Assert-SingleLine $Repo 'Repo'
    Assert-SingleLine $credentialFile 'credential_file'
    if (-not (Test-Path -LiteralPath $credentialFile -PathType Leaf)) { throw 'The configured SSH credential file does not exist.' }
    $askpass = Join-Path $PSScriptRoot 'ssh_askpass.exe'
    if (-not (Test-Path -LiteralPath $askpass -PathType Leaf)) {
        throw 'ssh_askpass.exe is missing. Compile scripts/ssh_askpass.cs during skill installation; no software is installed by this helper.'
    }
    if ($Action -eq 'Launch' -and -not $PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds = 60 }
    $sshOptions = @(
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=2',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'LogLevel=ERROR'
    )
    $target = $serverUser + '@' + $serverHost
    if ($Action -eq 'Pull' -or $Action -eq 'Push') {
        Assert-SingleLine $RemotePath 'RemotePath'
        Assert-SingleLine $LocalPath 'LocalPath'
        # SFTP-backed SCP on this Windows server accepts drive paths. Refuse
        # shell metacharacters and globs so a transfer always names one target.
        if ($RemotePath -notmatch '^[A-Za-z]:[\\/]' -or $RemotePath -match '[\x00-\x1f"''`$;&|<>*?\[\]{}!%()^]') {
            throw 'RemotePath must be an absolute Windows drive path without shell metacharacters or wildcards.'
        }
        $localFullPath = [IO.Path]::GetFullPath($LocalPath)
        $remoteSpec = $target + ':' + $RemotePath.Replace('\', '/')
        $transferOptions = @($sshOptions)
        if ($Recursive) { $transferOptions += '-r' }
        if ($Action -eq 'Push') {
            if (-not (Test-Path -LiteralPath $localFullPath)) { throw 'The local source does not exist.' }
            if ((Test-Path -LiteralPath $localFullPath -PathType Container) -and -not $Recursive) { throw 'A directory transfer requires -Recursive.' }
            $transferOptions += @($localFullPath, $remoteSpec)
        }
        else { $transferOptions += @($remoteSpec, $localFullPath) }
        $result = Invoke-OpenSsh 'scp.exe' $transferOptions $null $TimeoutSeconds
    }
    else {
        $request = [ordered]@{ action = $Action.ToLowerInvariant(); repo = $Repo }
        if ($Action -eq 'Status') {
            if ([string]::IsNullOrWhiteSpace($RunDirectory) -and [string]::IsNullOrWhiteSpace($LaunchRecord)) {
                throw 'Status requires -RunDirectory or -LaunchRecord.'
            }
            if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
                Assert-SingleLine $RunDirectory 'RunDirectory'
                $request.run_directory = $RunDirectory
            }
            $request.tail_lines = $TailLines
        }
        if (-not [string]::IsNullOrWhiteSpace($LaunchRecord)) {
            Assert-SingleLine $LaunchRecord 'LaunchRecord'
            $request.launch_record = $LaunchRecord
        }
        if ($Action -eq 'Launch') {
            Assert-SingleLine $ArgumentsFile 'ArgumentsFile'
            $argumentText = Get-Content -LiteralPath $ArgumentsFile -Raw -Encoding UTF8
            if ($argumentText.Trim() -notmatch '^\[') { throw 'ArgumentsFile must contain a JSON string array.' }
            # Keep the top-level JSON array intact on both PS5 and PS7, so a
            # nested array cannot accidentally become a flat string argv.
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) {
                [object[]]$launchArguments = ConvertFrom-Json -InputObject $argumentText -NoEnumerate
            }
            else { [object[]]$launchArguments = ConvertFrom-Json -InputObject $argumentText }
            if ($null -eq $launchArguments -or $launchArguments.Count -eq 0) { throw 'ArgumentsFile must contain at least one Python argument.' }
            foreach ($value in $launchArguments) {
                if ($null -eq $value -or $value -isnot [string] -or $value.Contains([string][char]0)) {
                    throw 'ArgumentsFile must contain only strings, without NUL characters.'
                }
            }
            $request.arguments = @($launchArguments)
        }
        if ($Action -eq 'RunPython') {
            Assert-SingleLine $ScriptPath 'ScriptPath'
            $scriptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath).Path)
            $request.action = 'run_python'
        }
        else {
            $scriptText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'remote_worker.py'))
        }
        $utf8 = New-Object Text.UTF8Encoding($false)
        $requestJson = ConvertTo-Json -InputObject $request -Compress -Depth 20
        $requestB64 = [Convert]::ToBase64String($utf8.GetBytes($requestJson))
        $repoLiteral = Quote-PowerShellLiteral $Repo
        $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object Text.UTF8Encoding(`$false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding(`$false)
`$env:PYTHONIOENCODING = 'utf-8'
`$env:KING_REMOTE_REQUEST_B64 = '$requestB64'
`$repo = $repoLiteral
try {
    Set-Location -LiteralPath `$repo
"@
        if (-not [string]::IsNullOrWhiteSpace($RemotePython)) {
            Assert-SingleLine $RemotePython 'RemotePython'
            $bootstrap += "`n    `$python = " + (Quote-PowerShellLiteral $RemotePython)
        }
        else {
            $bootstrap += @'

    $environmentFile = Join-Path $repo '.deployment\environment.json'
    $environmentRecord = Get-Content -LiteralPath $environmentFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $python = [string]$environmentRecord.python
'@
        }
        $bootstrap += @'

    if ([string]::IsNullOrWhiteSpace($python) -or -not [IO.Path]::IsPathRooted($python) -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw 'The locked Python executable is missing; specify -RemotePython or repair the deployment record.'
    }
    & $python -
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
'@
        $encodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $sshArguments = @($sshOptions) + @('-T', $target, 'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedBootstrap)
        $result = Invoke-OpenSsh 'ssh.exe' $sshArguments ($scriptText + "`n") $TimeoutSeconds
    }
    if ($result.Stdout.Length -gt 0) { Write-Output -NoEnumerate $result.Stdout }
    if ($result.Stderr.Length -gt 0) { [Console]::Error.Write($result.Stderr) }
    exit $result.ExitCode
}
catch {
    [Console]::Error.WriteLine('remote.ps1: ' + $_.Exception.Message)
    exit 2
}
