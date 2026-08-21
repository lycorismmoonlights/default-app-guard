[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,
    [Parameter(Mandatory)]
    [string]$WorkRoot,
    [Parameter(Mandatory)]
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "RegistryTestIsolation.psm1") -Force

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
}

function Get-PackageAgentProcesses {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $normalized = Get-NormalizedPath $ExecutablePath
    return @(
        Get-CimInstance Win32_Process -Filter `
            "Name='DefaultAppGuard.Agent.exe'" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                (Get-NormalizedPath $_.ExecutablePath) -eq $normalized
            })
}

function Invoke-Watchdog {
    param(
        [Parameter(Mandatory)][string]$SetupPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$AgentUrl,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $arguments = @(
        "--watchdog"
        "--url `"$AgentUrl`""
        "--state `"$StatePath`""
        "--config `"$ConfigurationPath`""
    ) -join " "
    $process = Start-Process `
        -FilePath $SetupPath `
        -ArgumentList $arguments `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    return $process.ExitCode
}

function Get-WatchdogStatusText {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        "Software\DefaultAppGuard\Watchdog")
    if ($null -eq $key) {
        return $null
    }

    try {
        return [string]$key.GetValue(
            "StatusJson",
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Dispose()
    }
}

$packagePath = Get-NormalizedPath $PackageDirectory
$workPath = [IO.Path]::GetFullPath($WorkRoot)
$evidenceFile = [IO.Path]::GetFullPath($EvidencePath)
$setupPath = Join-Path $packagePath "DefaultAppGuard.Setup.exe"
$agentPath = Join-Path $packagePath "DefaultAppGuard.Agent.exe"
if (Test-Path -LiteralPath $workPath) {
    throw "Watchdog backoff work root already exists: $workPath"
}
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $agentPath -PathType Leaf)) {
    throw "The release package lacks the watchdog executables."
}
if (@(Get-PackageAgentProcesses -ExecutablePath $agentPath).Count -ne 0) {
    throw "The release package Agent is already running."
}

$listener = [Net.Sockets.TcpListener]::new(
    [Net.IPAddress]::Loopback,
    0)
$watchdogRegistryPath = "Software\DefaultAppGuard\Watchdog"
$watchdogRegistrySnapshot = Get-DagRegistryTreeSnapshot `
    -SubKeyPath $watchdogRegistryPath
$passed = $false
try {
    New-Item -ItemType Directory -Path $workPath | Out-Null
    $runtimePath = Join-Path $workPath "runtime"
    New-Item -ItemType Directory -Path $runtimePath | Out-Null
    $statePath = Join-Path $runtimePath "agent-status.json"
    $configurationPath = Join-Path $runtimePath "guard-configuration.json"
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $watchdogRegistryPath,
        $false)

    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $agentUrl = "http://127.0.0.1:$port"

    $firstExitCode = Invoke-Watchdog `
        -SetupPath $setupPath `
        -WorkingDirectory $packagePath `
        -AgentUrl $agentUrl `
        -StatePath $statePath `
        -ConfigurationPath $configurationPath
    Assert-True ($firstExitCode -eq 24) `
        "The watchdog did not report the forced health-check failure."
    $firstStatusText = Get-WatchdogStatusText
    Assert-True (-not [string]::IsNullOrWhiteSpace($firstStatusText)) `
        "The failed recovery did not create watchdog telemetry."
    $firstStatus = $firstStatusText | ConvertFrom-Json
    Assert-True ([string]$firstStatus.outcome -eq "failed") `
        "The watchdog did not record a failed outcome."
    Assert-True ([int]$firstStatus.exitCode -eq 24) `
        "The watchdog telemetry exit code is unexpected."
    Assert-True ([bool]$firstStatus.recoveryAttempted) `
        "The watchdog did not record the failed recovery attempt."
    Assert-True ([int]$firstStatus.consecutiveRecoveryFailures -eq 1) `
        "The watchdog failure counter did not start at one."
    Assert-True ([string]$firstStatus.failureStage -eq
        "recovery-health-check") `
        "The watchdog did not identify the failed health-check stage."
    $firstNextAllowed = [DateTimeOffset]::Parse(
        [string]$firstStatus.nextRecoveryAllowedAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    $firstCompleted = [DateTimeOffset]::Parse(
        [string]$firstStatus.completedAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    Assert-True ($firstNextAllowed -eq $firstCompleted.AddMinutes(5)) `
        "The first watchdog backoff is not exactly five minutes."
    Start-Sleep -Milliseconds 500
    Assert-True (@(Get-PackageAgentProcesses `
        -ExecutablePath $agentPath).Count -eq 0) `
        "The watchdog left the failed Agent process running."

    $secondExitCode = Invoke-Watchdog `
        -SetupPath $setupPath `
        -WorkingDirectory $packagePath `
        -AgentUrl $agentUrl `
        -StatePath $statePath `
        -ConfigurationPath $configurationPath
    Assert-True ($secondExitCode -eq 0) `
        "The intentional watchdog backoff returned an error."
    $secondStatusText = Get-WatchdogStatusText
    Assert-True (-not [string]::IsNullOrWhiteSpace($secondStatusText)) `
        "The deferred recovery did not update watchdog telemetry."
    $secondStatus = $secondStatusText | ConvertFrom-Json
    Assert-True ([string]$secondStatus.outcome -eq "recovery-deferred") `
        "The immediate retry did not enter recovery backoff."
    Assert-True ([int]$secondStatus.consecutiveRecoveryFailures -eq 1) `
        "The deferred retry incorrectly increased the failure counter."
    Assert-True ([string]$secondStatus.nextRecoveryAllowedAtUtc -eq
        [string]$firstStatus.nextRecoveryAllowedAtUtc) `
        "The deferred retry changed the original backoff deadline."
    Assert-True ([string]$secondStatus.failureStage -eq "recovery-backoff") `
        "The deferred retry did not record the backoff stage."
    Assert-True (@(Get-PackageAgentProcesses `
        -ExecutablePath $agentPath).Count -eq 0) `
        "The deferred retry launched another Agent process."
    Assert-True ($secondStatusText.IndexOf(
        $packagePath,
        [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "Watchdog backoff telemetry exposed the package path."
    Assert-True ($secondStatusText.IndexOf(
        $workPath,
        [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "Watchdog backoff telemetry exposed the work path."

    $evidence = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        firstAttempt = [ordered]@{
            exitCode = $firstExitCode
            outcome = [string]$firstStatus.outcome
            failureStage = [string]$firstStatus.failureStage
            consecutiveRecoveryFailures =
                [int]$firstStatus.consecutiveRecoveryFailures
            backoffMinutes = 5
            failedProcessCleaned = $true
        }
        immediateRetry = [ordered]@{
            exitCode = $secondExitCode
            outcome = [string]$secondStatus.outcome
            consecutiveRecoveryFailures =
                [int]$secondStatus.consecutiveRecoveryFailures
            deadlinePreserved = $true
            agentLaunchSuppressed = $true
        }
        telemetryRedacted = $true
        passed = $true
    }
    $evidenceDirectory = Split-Path -Parent $evidenceFile
    New-Item `
        -ItemType Directory `
        -Path $evidenceDirectory `
        -Force | Out-Null
    $evidence |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $evidenceFile -Encoding UTF8
    $passed = $true

    [pscustomobject]@{
        Passed = $true
        EvidencePath = $evidenceFile
        FirstExitCode = $firstExitCode
        ImmediateRetryExitCode = $secondExitCode
        BackoffMinutes = 5
        FailedProcessCleaned = $true
        RetryLaunchSuppressed = $true
    }
}
finally {
    $listener.Stop()
    foreach ($process in @(Get-PackageAgentProcesses `
        -ExecutablePath $agentPath)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Restore-DagRegistryTreeSnapshot `
        -SubKeyPath $watchdogRegistryPath `
        -Snapshot $watchdogRegistrySnapshot
    if (Test-Path -LiteralPath $workPath) {
        Remove-Item -LiteralPath $workPath -Recurse -Force
    }
    if (-not $passed -and (Test-Path -LiteralPath $evidenceFile)) {
        Remove-Item -LiteralPath $evidenceFile -Force
    }
}
