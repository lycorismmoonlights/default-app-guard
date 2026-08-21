[CmdletBinding()]
param(
    [string]$InstallDirectory = (
        Join-Path $env:LOCALAPPDATA "Programs\DefaultAppGuard"),
    [string]$DataDirectory = (
        Join-Path $env:LOCALAPPDATA "DefaultAppGuard"),
    [string]$TaskName = "DefaultAppGuard Agent",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._ -]{0,79}$')]
    [string]$UninstallRegistryKeyName = "DefaultAppGuard Community",
    [string]$OutputPath = (
        Join-Path (Get-Location) (
            "DefaultAppGuard-diagnostics-{0}.json" -f (
                Get-Date -Format "yyyyMMdd-HHmmss")))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$packageModulePath = Join-Path $PSScriptRoot "DefaultAppGuard.Package.psm1"
if (-not (Test-Path -LiteralPath $packageModulePath -PathType Leaf)) {
    throw "Package verification module is missing."
}
Import-Module -Name $packageModulePath -Force

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
}

$installPath = Get-NormalizedPath $InstallDirectory
$dataPath = Get-NormalizedPath $DataDirectory
$outputFile = [IO.Path]::GetFullPath($OutputPath)
$operationalLogDirectory = Join-Path $dataPath "runtime\logs"
$issues = [Collections.Generic.List[string]]::new()
$notices = [Collections.Generic.List[string]]::new()

$installState = $null
$installStatePath = Join-Path $dataPath "install-state.json"
if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
    try {
        $installState = Get-Content `
            -LiteralPath $installStatePath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        $issues.Add("install-state-unreadable")
    }
} else {
    $issues.Add("install-state-missing")
}

$manifestPath = Join-Path $installPath "package-manifest.json"
$packageCheck = Test-DagPackageIntegrity -PackageRoot $installPath
$manifest = $packageCheck.Manifest
$payloadCheck = [pscustomobject]@{
    DeclaredFileCount = $packageCheck.DeclaredFileCount
    ActualFileCount = $packageCheck.ActualFileCount
    Passed = $packageCheck.Passed
    IssueCodes = $packageCheck.IssueCodes
}
if (-not $packageCheck.Passed) {
    $issues.Add("package-integrity-failed")
    foreach ($issueCode in $packageCheck.IssueCodes) {
        $issues.Add([string]$issueCode)
    }
}

$manifestMatchesInstallState = $false
if ($null -ne $installState -and
    $null -ne $installState.packageManifestSha256 -and
    (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $manifestHash = (Get-FileHash `
        -LiteralPath $manifestPath `
        -Algorithm SHA256).Hash
    $manifestMatchesInstallState = $manifestHash.Equals(
        [string]$installState.packageManifestSha256,
        [StringComparison]::OrdinalIgnoreCase)
    if (-not $manifestMatchesInstallState) {
        $issues.Add("installed-manifest-hash-mismatch")
    }
}

$executableName = "DefaultAppGuard.Agent.exe"
if ($null -ne $manifest -and
    -not [string]::IsNullOrWhiteSpace($manifest.executable)) {
    $executableName = [string]$manifest.executable
}
$executablePath = Join-Path $installPath $executableName
$executableExists = Test-Path -LiteralPath $executablePath -PathType Leaf
$fileVersion = $null
$executableSha256 = $null
$peSubsystem = $null
$signatureStatus = "Missing"
$signerSubject = $null
$signatureTimestamped = $false
if ($executableExists) {
    $fileVersion = (Get-Item -LiteralPath $executablePath).VersionInfo.FileVersion
    $executableSha256 = (Get-FileHash `
        -LiteralPath $executablePath `
        -Algorithm SHA256).Hash
    $peSubsystem = Get-DagPeSubsystem -Path $executablePath
    $signature = Get-AuthenticodeSignature -LiteralPath $executablePath
    $signatureStatus = [string]$signature.Status
    if ($null -ne $signature.SignerCertificate) {
        $signerSubject = $signature.SignerCertificate.Subject
    }
    $signatureTimestamped = $null -ne $signature.TimeStamperCertificate
    if ($peSubsystem -ne 2) {
        $issues.Add("agent-console-subsystem")
    }
} else {
    $issues.Add("agent-executable-missing")
}

$setupPath = Join-Path $installPath "DefaultAppGuard.Setup.exe"
$setupExists = Test-Path -LiteralPath $setupPath -PathType Leaf
$setupFileVersion = $null
$setupSha256 = $null
$setupPeSubsystem = $null
$setupSignatureStatus = "Missing"
$setupSignerSubject = $null
$setupSignatureTimestamped = $false
if ($setupExists) {
    $setupFileVersion = (Get-Item -LiteralPath $setupPath).VersionInfo.FileVersion
    $setupSha256 = (Get-FileHash `
        -LiteralPath $setupPath `
        -Algorithm SHA256).Hash
    $setupPeSubsystem = Get-DagPeSubsystem -Path $setupPath
    $setupSignature = Get-AuthenticodeSignature -LiteralPath $setupPath
    $setupSignatureStatus = [string]$setupSignature.Status
    if ($null -ne $setupSignature.SignerCertificate) {
        $setupSignerSubject = $setupSignature.SignerCertificate.Subject
    }
    $setupSignatureTimestamped =
        $null -ne $setupSignature.TimeStamperCertificate
    if ($setupPeSubsystem -ne 2) {
        $issues.Add("setup-console-subsystem")
    }
} else {
    $issues.Add("setup-executable-missing")
}
if ($signatureStatus -ne $setupSignatureStatus) {
    $issues.Add("release-signature-state-mismatch")
}
if ($signatureStatus -eq "Valid" -and
    $signerSubject -ne $setupSignerSubject) {
    $issues.Add("release-signer-mismatch")
}

$recordedUninstallKeyProperty = if ($null -ne $installState) {
    $installState.PSObject.Properties["uninstallRegistryKeyName"]
} else {
    $null
}
$recordedUninstallKeyName = if (
    $null -ne $recordedUninstallKeyProperty -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$recordedUninstallKeyProperty.Value)) {
    [string]$recordedUninstallKeyProperty.Value
} else {
    $UninstallRegistryKeyName
}
$uninstallKeyNameMatches =
    $recordedUninstallKeyName -eq $UninstallRegistryKeyName
if (-not $uninstallKeyNameMatches) {
    $issues.Add("uninstall-registration-key-mismatch")
}
$uninstallSubKeyPath = (
    "Software\Microsoft\Windows\CurrentVersion\Uninstall\" +
    $UninstallRegistryKeyName)
$uninstallEntryPresent = $false
$uninstallMetadataMatches = $false
$uninstallCommandHidden = $false
$quietUninstallPresent = $false
$uninstallKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $uninstallSubKeyPath)
if ($null -eq $uninstallKey) {
    $issues.Add("uninstall-registration-missing")
} else {
    try {
        $uninstallEntryPresent = $true
        $registeredName = [string]$uninstallKey.GetValue("DisplayName")
        $registeredVersion = [string]$uninstallKey.GetValue("DisplayVersion")
        $registeredLocation = [string]$uninstallKey.GetValue("InstallLocation")
        $uninstallString = [string]$uninstallKey.GetValue("UninstallString")
        $quietUninstallString = [string]$uninstallKey.GetValue(
            "QuietUninstallString")
        $noModify = [int]$uninstallKey.GetValue("NoModify", 0)
        $noRepair = [int]$uninstallKey.GetValue("NoRepair", 0)
        $manifestVersion = if ($null -ne $manifest) {
            [string]$manifest.version
        } else {
            $null
        }
        $locationMatches =
            -not [string]::IsNullOrWhiteSpace($registeredLocation) -and
            (Get-NormalizedPath $registeredLocation) -eq $installPath
        $uninstallMetadataMatches =
            $registeredName -eq "DefaultAppGuard Community" -and
            $registeredVersion -eq $manifestVersion -and
            $locationMatches -and
            $noModify -eq 1 -and
            $noRepair -eq 1
        $expectedUninstaller = Join-Path $installPath `
            "Uninstall-DefaultAppGuard.ps1"
        $uninstallCommandHidden =
            $uninstallString.Contains($expectedUninstaller) -and
            $uninstallString.Contains("-ExecutionPolicy Bypass") -and
            $uninstallString.Contains("-WindowStyle Hidden") -and
            $uninstallString.Contains($UninstallRegistryKeyName)
        $quietUninstallPresent =
            -not [string]::IsNullOrWhiteSpace($quietUninstallString) -and
            $quietUninstallString -eq $uninstallString
        if (-not $uninstallMetadataMatches) {
            $issues.Add("uninstall-registration-metadata-mismatch")
        }
        if (-not $uninstallCommandHidden) {
            $issues.Add("uninstall-command-mismatch")
        }
        if (-not $quietUninstallPresent) {
            $issues.Add("quiet-uninstall-missing")
        }
    } finally {
        $uninstallKey.Dispose()
    }
}
$uninstallRegistrationHealthy =
    $uninstallEntryPresent -and
    $uninstallKeyNameMatches -and
    $uninstallMetadataMatches -and
    $uninstallCommandHidden -and
    $quietUninstallPresent

$agentUrl = "http://127.0.0.1:51873"
if ($null -ne $installState -and
    -not [string]::IsNullOrWhiteSpace($installState.agentUrl)) {
    $agentUrl = [string]$installState.agentUrl
}
$expectedWatchdogIntervalMinutes = 5
if ($null -ne $installState -and
    $null -ne $installState.watchdogIntervalMinutes) {
    try {
        $recordedWatchdogInterval = [int]$installState.watchdogIntervalMinutes
        if ($recordedWatchdogInterval -lt 1 -or
            $recordedWatchdogInterval -gt 60) {
            throw "Recorded watchdog interval is outside the supported range."
        }
        $expectedWatchdogIntervalMinutes = $recordedWatchdogInterval
    } catch {
        $issues.Add("install-state-watchdog-invalid")
    }
}
$runtimePath = Join-Path $dataPath "runtime"
$watchdogRegistrySubKeyPath = "Software\DefaultAppGuard\Watchdog"
$watchdogRegistryValueName = "StatusJson"
$watchdogTelemetryPresent = $false
$watchdogStatus = $null
$watchdogStatusReadable = $false
$watchdogSchemaValid = $false
$watchdogOutcome = $null
$watchdogExitCode = $null
$watchdogCompletedAtUtc = $null
$watchdogCompletedAgeSeconds = $null
$watchdogRecoveryAttempted = $false
$watchdogPreviousProcessId = $null
$watchdogActiveProcessId = $null
$watchdogConsecutiveFailures = $null
$watchdogNextRecoveryAllowedAtUtc = $null
$watchdogFailureStage = $null
$watchdogKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $watchdogRegistrySubKeyPath)
if ($null -ne $watchdogKey) {
    try {
        $watchdogStatusJson = $watchdogKey.GetValue(
            $watchdogRegistryValueName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($watchdogStatusJson -isnot [string] -or
            [string]::IsNullOrWhiteSpace($watchdogStatusJson)) {
            throw "Watchdog telemetry registry value is missing or invalid."
        }
        $watchdogTelemetryPresent = $true
        $watchdogStatus = $watchdogStatusJson | ConvertFrom-Json
        $watchdogStatusReadable = $true
        $watchdogSchemaValid = [int]$watchdogStatus.schemaVersion -eq 1
        $watchdogOutcome = [string]$watchdogStatus.outcome
        $watchdogExitCode = [int]$watchdogStatus.exitCode
        $watchdogCompletedAtUtc = [DateTimeOffset]::Parse(
            [string]$watchdogStatus.completedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $watchdogCompletedAgeSeconds = [Math]::Max(
            0,
            ([DateTimeOffset]::UtcNow - $watchdogCompletedAtUtc).TotalSeconds)
        $watchdogRecoveryAttempted =
            [bool]$watchdogStatus.recoveryAttempted
        if ($null -ne $watchdogStatus.previousProcessId) {
            $watchdogPreviousProcessId =
                [int]$watchdogStatus.previousProcessId
        }
        if ($null -ne $watchdogStatus.activeProcessId) {
            $watchdogActiveProcessId = [int]$watchdogStatus.activeProcessId
        }
        $watchdogConsecutiveFailures =
            [int]$watchdogStatus.consecutiveRecoveryFailures
        if ($null -ne $watchdogStatus.nextRecoveryAllowedAtUtc) {
            $watchdogNextRecoveryAllowedAtUtc = [DateTimeOffset]::Parse(
                [string]$watchdogStatus.nextRecoveryAllowedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        }
        if ($null -ne $watchdogStatus.failureStage) {
            $watchdogFailureStage = [string]$watchdogStatus.failureStage
        }
        if (-not $watchdogSchemaValid) {
            $issues.Add("watchdog-telemetry-schema")
        }
    } catch {
        $issues.Add("watchdog-telemetry-unreadable")
    } finally {
        $watchdogKey.Dispose()
    }
} else {
    $issues.Add("watchdog-telemetry-missing")
}
$expectedAgentArguments = @(
    "--url `"$agentUrl`""
    "--state `"$(Join-Path $runtimePath "agent-status.json")`""
    "--config `"$(Join-Path $runtimePath "guard-configuration.json")`""
) -join " "
$expectedTaskArguments = "--watchdog $expectedAgentArguments"
$expectedWatchdogInterval = [Xml.XmlConvert]::ToString(
    [TimeSpan]::FromMinutes($expectedWatchdogIntervalMinutes))

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = $null
$taskActionMatches = $false
$taskExecutableMatches = $false
$taskWorkingDirectoryMatches = $false
$taskArgumentsMatch = $false
$taskPrincipalMatches = $false
$taskSettingsMatch = $false
$taskTriggersMatch = $false
$taskConfigurationHealthy = $false
$taskEnabled = $false
$taskState = "Missing"
$taskStateHealthy = $false
$taskRunAgeSeconds = $null
$taskLastResult = $null
$taskLastResultDisposition = "unavailable"
$triggerSummaries = @()
if ($null -ne $task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    $taskActions = @($task.Actions)
    if ($taskActions.Count -eq 1) {
        $taskExecutableMatches =
            -not [string]::IsNullOrWhiteSpace($taskActions[0].Execute) -and
            (Get-NormalizedPath $taskActions[0].Execute) -eq $setupPath
        $taskWorkingDirectoryMatches =
            -not [string]::IsNullOrWhiteSpace(
                $taskActions[0].WorkingDirectory) -and
            (Get-NormalizedPath $taskActions[0].WorkingDirectory) -eq
                $installPath
        $taskArgumentsMatch =
            [string]$taskActions[0].Arguments -eq $expectedTaskArguments
    }
    $taskActionMatches =
        $taskExecutableMatches -and
        $taskWorkingDirectoryMatches -and
        $taskArgumentsMatch

    try {
        $principalUserId = [string]$task.Principal.UserId
        $principalSid = if ($principalUserId.StartsWith(
            "S-1-",
            [StringComparison]::OrdinalIgnoreCase)) {
            [Security.Principal.SecurityIdentifier]::new(
                $principalUserId).Value
        } else {
            [Security.Principal.NTAccount]::new($principalUserId).
                Translate([Security.Principal.SecurityIdentifier]).Value
        }
        $taskPrincipalMatches =
            $principalSid -eq (
                [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -and
            [string]$task.Principal.RunLevel -eq "Limited" -and
            [string]$task.Principal.LogonType -eq "Interactive"
    } catch {
        $taskPrincipalMatches = $false
    }

    $taskSettingsMatch =
        [string]$task.Settings.MultipleInstances -eq "IgnoreNew" -and
        [bool]$task.Settings.StartWhenAvailable -and
        [int]$task.Settings.RestartCount -eq 3 -and
        [string]$task.Settings.RestartInterval -eq "PT1M" -and
        [string]$task.Settings.ExecutionTimeLimit -eq "PT1M" -and
        -not [bool]$task.Settings.DisallowStartIfOnBatteries -and
        -not [bool]$task.Settings.StopIfGoingOnBatteries

    $taskTriggers = @($task.Triggers)
    $logonTriggers = @(
        $taskTriggers |
            Where-Object {
                $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger"
            })
    $watchdogTriggers = @(
        $taskTriggers |
            Where-Object {
                $_.CimClass.CimClassName -eq "MSFT_TaskTimeTrigger"
            })
    $taskTriggersMatch =
        $taskTriggers.Count -eq 2 -and
        $logonTriggers.Count -eq 1 -and
        [bool]$logonTriggers[0].Enabled -and
        $watchdogTriggers.Count -eq 1 -and
        [bool]$watchdogTriggers[0].Enabled -and
        [string]$watchdogTriggers[0].Repetition.Interval -eq
            $expectedWatchdogInterval

    $taskEnabled = [bool]$task.Settings.Enabled
    $taskState = [string]$task.State
    if ($taskState -eq "Ready") {
        $taskStateHealthy = $true
    } elseif ($taskState -eq "Running") {
        $taskRunAgeSeconds = [Math]::Max(
            0,
            ((Get-Date) - $taskInfo.LastRunTime).TotalSeconds)
        $taskStateHealthy = $taskRunAgeSeconds -le 90
    }
    $taskLastResult = $taskInfo.LastTaskResult
    $taskLastResultDisposition = if (
        $taskState -eq "Running" -and $taskStateHealthy) {
        "watchdog-running"
    } elseif ($taskState -eq "Ready" -and [int64]$taskLastResult -eq 0) {
        "success"
    } else {
        "nonzero"
    }
    $triggerSummaries = @(
        $taskTriggers |
            ForEach-Object {
                [ordered]@{
                    type = $_.CimClass.CimClassName
                    enabled = [bool]$_.Enabled
                    repetitionInterval = [string]$_.Repetition.Interval
                }
            })
    $taskConfigurationHealthy =
        $taskEnabled -and
        $taskStateHealthy -and
        $taskActionMatches -and
        $taskPrincipalMatches -and
        $taskSettingsMatch -and
        $taskTriggersMatch
    if (-not $taskActionMatches) {
        $issues.Add("task-action-mismatch")
    }
    if (-not $taskPrincipalMatches) {
        $issues.Add("task-principal-mismatch")
    }
    if (-not $taskSettingsMatch) {
        $issues.Add("task-settings-mismatch")
    }
    if (-not $taskTriggersMatch) {
        $issues.Add("task-triggers-mismatch")
    }
    if (-not $taskEnabled -or -not $taskStateHealthy) {
        $issues.Add("scheduled-task-state-unhealthy")
    }
} else {
    $issues.Add("scheduled-task-missing")
}

$watchdogOutcomeHealthy =
    $watchdogStatusReadable -and
    $watchdogSchemaValid -and
    $watchdogOutcome -in @("healthy", "recovered") -and
    $watchdogExitCode -eq 0 -and
    $watchdogConsecutiveFailures -eq 0 -and
    $null -eq $watchdogNextRecoveryAllowedAtUtc -and
    $null -eq $watchdogFailureStage
$watchdogTelemetryMatchesTaskRun = $false
if ($watchdogStatusReadable -and
    $null -ne $watchdogCompletedAtUtc -and
    $null -ne $taskInfo) {
    $taskLastRunUtc = ([DateTimeOffset]$taskInfo.LastRunTime).ToUniversalTime()
    $watchdogTelemetryMatchesTaskRun =
        $taskState -eq "Running" -or
        $taskLastRunUtc.Year -lt 2000 -or
        $watchdogCompletedAtUtc -ge $taskLastRunUtc.AddSeconds(-5)
    if ($watchdogCompletedAtUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) {
        $watchdogTelemetryMatchesTaskRun = $false
    }
}
if ($watchdogStatusReadable -and -not $watchdogOutcomeHealthy) {
    $issues.Add("watchdog-last-outcome-unhealthy")
}
if ($watchdogStatusReadable -and -not $watchdogTelemetryMatchesTaskRun) {
    $issues.Add("watchdog-telemetry-stale")
}

$agentProcesses = @()
$consoleChildCount = 0
if ($executableExists) {
    $agentProcesses = @(
        Get-CimInstance Win32_Process -Filter `
            "Name='DefaultAppGuard.Agent.exe'" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                (Get-NormalizedPath $_.ExecutablePath) -eq $executablePath
            })
    foreach ($agentProcess in $agentProcesses) {
        $consoleChildCount += @(
            Get-CimInstance Win32_Process |
                Where-Object {
                    $_.ParentProcessId -eq $agentProcess.ProcessId -and
                    $_.Name -in @(
                        "conhost.exe",
                        "OpenConsole.exe",
                        "WindowsTerminal.exe")
                }).Count
    }
}
if ($agentProcesses.Count -ne 1) {
    $issues.Add("agent-process-count")
}
if ($consoleChildCount -ne 0) {
    $issues.Add("agent-console-child")
}

$watchdogProcessMatches =
    $watchdogOutcomeHealthy -and
    $null -ne $watchdogActiveProcessId -and
    $agentProcesses.Count -eq 1 -and
    [int]$watchdogActiveProcessId -eq [int]$agentProcesses[0].ProcessId
if ($watchdogStatusReadable -and
    $watchdogOutcomeHealthy -and
    -not $watchdogProcessMatches) {
    $issues.Add("watchdog-process-mismatch")
}

$health = $null
$status = $null
$readiness = $null
$apiReachable = $false
$readinessReady = $false
$auditFreshnessAvailable = $false
$auditFresh = $false
$auditAgeSeconds = $null
$maximumAuditAgeSeconds = $null
$configurationPersistenceHealthy = $false
$configurationBackupAvailable = $false
$configurationRecovered = $false
$configurationRecoveryCode = $null
$configurationRecoveredAtUtc = $null
$notificationChannel = $null
$notificationsAvailable = $false
$notificationsEnabled = $false
$notificationLastQueuedKind = $null
$notificationLastQueuedAtUtc = $null
$configurationRecoveryLastQueuedKind = $null
$configurationRecoveryLastQueuedAtUtc = $null
$notificationTelemetryHealthy = $false
$configurationRecoveryNotificationExpected = $false
$configurationRecoveryNotificationVerified = $false
try {
    $agentUri = [Uri]$agentUrl
    if (-not $agentUri.IsLoopback -or
        $agentUri.Scheme -ne [Uri]::UriSchemeHttp) {
        throw "Stored Agent URL is not a loopback HTTP origin."
    }
    $health = Invoke-RestMethod `
        -Uri "$($agentUrl.TrimEnd('/'))/api/health" `
        -TimeoutSec 2
    $status = Invoke-RestMethod `
        -Uri "$($agentUrl.TrimEnd('/'))/api/status" `
        -TimeoutSec 2
    $apiReachable = $health.Service -eq "DefaultAppGuard.Agent"
} catch {
    $issues.Add("agent-api-unreachable")
}
if ($apiReachable) {
    $configurationBackupAvailable =
        [bool]$health.ConfigurationBackupAvailable
    $configurationRecovered = [bool]$health.ConfigurationRecovered
    $configurationRecoveryCode =
        [string]$health.ConfigurationRecoveryCode
    $configurationRecoveredAtUtc =
        [string]$health.ConfigurationRecoveredAtUtc
    $configurationPersistenceHealthy =
        $health.ConfigurationStorage -eq
            "runtime/guard-configuration.json" -and
        $health.ConfigurationBackupStorage -eq
            "runtime/guard-configuration.json.bak" -and
        $configurationBackupAvailable -and
        (($configurationRecoveryCode -eq "none" -and
            -not $configurationRecovered) -or
         ($configurationRecoveryCode -in @(
                "backup-restored",
                "defaults-restored") -and
            $configurationRecovered -and
            -not [string]::IsNullOrWhiteSpace(
                $configurationRecoveredAtUtc)))
    if (-not $configurationBackupAvailable) {
        $issues.Add("configuration-backup-unavailable")
    }
    if (-not $configurationPersistenceHealthy) {
        $issues.Add("configuration-persistence-unhealthy")
    } elseif ($configurationRecovered) {
        $notices.Add(
            "configuration-$configurationRecoveryCode")
    }

    $auditedAtUtc = [DateTimeOffset]::MinValue
    $auditedAtText = if ($null -ne $status.Audit) {
        [string]$status.Audit.AuditedAtUtc
    } else {
        ""
    }
    $maximumAuditAgeSeconds = [int64]$health.MaximumAuditAgeSeconds
    if ($maximumAuditAgeSeconds -gt 0 -and
        [DateTimeOffset]::TryParse(
            $auditedAtText,
            [ref]$auditedAtUtc)) {
        $auditAgeSeconds = [int64][Math]::Ceiling(
            ([DateTimeOffset]::UtcNow - $auditedAtUtc).TotalSeconds)
        if ($auditAgeSeconds -lt 0) {
            $auditAgeSeconds = 0
        }
        $auditFreshnessAvailable = $true
        $auditFresh = $auditAgeSeconds -le $maximumAuditAgeSeconds
        if (-not $auditFresh) {
            $issues.Add("association-audit-stale")
        }
    } else {
        $issues.Add("association-audit-freshness-unavailable")
    }

    try {
        $readiness = Invoke-RestMethod `
            -Uri "$($agentUrl.TrimEnd('/'))/api/readiness" `
            -TimeoutSec 2
        $readinessReady = [bool]$readiness.Ready -and
            $readiness.Code -eq "ready" -and
            [bool]$readiness.AuditFresh -and
            [int64]$readiness.AuditAgeSeconds -ge 0 -and
            [int64]$readiness.MaximumAuditAgeSeconds -eq
                $maximumAuditAgeSeconds -and
            [int64]$readiness.AuditAgeSeconds -le
                [int64]$readiness.MaximumAuditAgeSeconds -and
            [int]$readiness.ExpectedHandlerCount -gt 0 -and
            [int]$readiness.ResolvedHandlerCount -eq
                [int]$readiness.ExpectedHandlerCount -and
            [int]$readiness.DistinctTargetCount -gt 0 -and
            [int]$readiness.DistinctTargetCount -le
                [int]$readiness.ExpectedHandlerCount -and
            [int]$readiness.AuditedExtensionCount -eq
                [int]$readiness.ExpectedHandlerCount -and
            [int]$readiness.PrimarySnapshotCount -eq
                [int]$readiness.AuditedExtensionCount -and
            [int]$readiness.FailedReadCount -eq 0
        if (-not $readinessReady) {
            $issues.Add("agent-not-ready")
        }
    } catch {
        $issues.Add("agent-not-ready")
    }
}

$apiProcessMatches = $false
if ($apiReachable -and $agentProcesses.Count -eq 1) {
    $apiProcessMatches =
        [int]$health.ProcessId -eq [int]$agentProcesses[0].ProcessId
    if (-not $apiProcessMatches) {
        $issues.Add("agent-api-process-mismatch")
    }
}

$listenerAddresses = @()
if ($agentProcesses.Count -eq 1) {
    try {
        $listenerAddresses = @(
            Get-NetTCPConnection `
                -State Listen `
                -OwningProcess $agentProcesses[0].ProcessId `
                -ErrorAction Stop |
                ForEach-Object {
                    "{0}:{1}" -f $_.LocalAddress, $_.LocalPort
                })
    } catch {
        $issues.Add("listener-query-failed")
    }
}
$loopbackOnly = $listenerAddresses.Count -gt 0 -and
    @($listenerAddresses | Where-Object {
        -not $_.StartsWith("127.0.0.1:") -and
        -not $_.StartsWith("[::1]:") -and
        -not $_.StartsWith("::1:")
    }).Count -eq 0
if (-not $loopbackOnly) {
    $issues.Add("listener-not-loopback-only")
}

$auditHealthy = $false
$healthyCount = 0
$driftCount = $null
$extensionCount = 0
$queryAlgorithm = $null
$monitorAlgorithm = $null
$processMode = $null
$operationalLogChannel = $null
$operationalLogsAvailable = $false
$operationalLogFormat = $null
$operationalLogStorage = $null
$operationalLogFileSizeLimitBytes = 0L
$operationalLogRetainedFileCountLimit = 0
$operationalLogLastError = $null
$hasRuntimeError = $false
if ($apiReachable -and $null -ne $status -and
    $null -ne $status.audit) {
    $auditHealthy = [bool]$status.audit.healthy
    $healthyCount = [int]$status.audit.healthyCount
    $driftCount = [int]$status.audit.driftCount
    $extensionCount = @($status.audit.items).Count
    $queryAlgorithm = [string]$status.queryAlgorithm
    $monitorAlgorithm = [string]$status.monitorAlgorithm
    $processMode = [string]$health.ProcessMode
    $notificationChannel = [string]$health.NotificationChannel
    $notificationsAvailable = [bool]$health.NotificationsAvailable
    $notificationsEnabled = [bool]$health.NotificationsEnabled
    $notificationLastQueuedKind =
        [string]$health.NotificationLastQueuedKind
    $notificationLastQueuedAtUtc =
        [string]$health.NotificationLastQueuedAtUtc
    $configurationRecoveryLastQueuedKind =
        [string]$health.ConfigurationRecoveryNotificationLastQueuedKind
    $configurationRecoveryLastQueuedAtUtc =
        [string]$health.ConfigurationRecoveryNotificationLastQueuedAtUtc
    $hasQueuedKind = -not [string]::IsNullOrWhiteSpace(
        $notificationLastQueuedKind)
    $hasQueuedAtUtc = -not [string]::IsNullOrWhiteSpace(
        $notificationLastQueuedAtUtc)
    $queuedAtUtc = [DateTimeOffset]::MinValue
    $queuedAtUtcValid = $hasQueuedAtUtc -and
        [DateTimeOffset]::TryParse(
            $notificationLastQueuedAtUtc,
            [ref]$queuedAtUtc) -and
        $queuedAtUtc -le [DateTimeOffset]::UtcNow.AddMinutes(1)
    $allowedNotificationKinds = @(
        "association-drift",
        "configuration-backup-restored",
        "configuration-defaults-restored")
    $generalNotificationTelemetryHealthy =
        (-not $hasQueuedKind -and -not $hasQueuedAtUtc) -or
        ($hasQueuedKind -and
            $hasQueuedAtUtc -and
            $notificationLastQueuedKind -in $allowedNotificationKinds -and
            $queuedAtUtcValid)
    $hasRecoveryQueuedKind = -not [string]::IsNullOrWhiteSpace(
        $configurationRecoveryLastQueuedKind)
    $hasRecoveryQueuedAtUtc = -not [string]::IsNullOrWhiteSpace(
        $configurationRecoveryLastQueuedAtUtc)
    $recoveryQueuedAtUtc = [DateTimeOffset]::MinValue
    $recoveryQueuedAtUtcValid = $hasRecoveryQueuedAtUtc -and
        [DateTimeOffset]::TryParse(
            $configurationRecoveryLastQueuedAtUtc,
            [ref]$recoveryQueuedAtUtc) -and
        $recoveryQueuedAtUtc -le [DateTimeOffset]::UtcNow.AddMinutes(1)
    $recoveryNotificationTelemetryHealthy =
        (-not $hasRecoveryQueuedKind -and -not $hasRecoveryQueuedAtUtc) -or
        ($hasRecoveryQueuedKind -and
            $hasRecoveryQueuedAtUtc -and
            $configurationRecoveryLastQueuedKind -in @(
                "configuration-backup-restored",
                "configuration-defaults-restored") -and
            $recoveryQueuedAtUtcValid)
    $notificationTelemetryHealthy =
        $generalNotificationTelemetryHealthy -and
        $recoveryNotificationTelemetryHealthy
    if (-not $notificationTelemetryHealthy) {
        $issues.Add("notification-telemetry-invalid")
    }
    $configurationRecoveryNotificationExpected =
        $configurationRecovered -and
        $configurationPersistenceHealthy -and
        $notificationsEnabled -and
        $notificationsAvailable
    $configurationRecoveryNotificationVerified =
        -not $configurationRecoveryNotificationExpected
    if ($configurationRecoveryNotificationExpected) {
        $recoveredAtUtc = [DateTimeOffset]::MinValue
        $recoveredAtUtcValid = [DateTimeOffset]::TryParse(
            $configurationRecoveredAtUtc,
            [ref]$recoveredAtUtc)
        $expectedQueuedKind =
            "configuration-$configurationRecoveryCode"
        $configurationRecoveryNotificationVerified =
            $notificationTelemetryHealthy -and
            $configurationRecoveryLastQueuedKind -eq $expectedQueuedKind -and
            $recoveredAtUtcValid -and
            $recoveryQueuedAtUtcValid -and
            $recoveryQueuedAtUtc -ge $recoveredAtUtc
        if (-not $configurationRecoveryNotificationVerified) {
            $issues.Add(
                "configuration-recovery-notification-missing")
        }
    }
    $operationalLogChannel = [string]$health.OperationalLogChannel
    $operationalLogsAvailable =
        [bool]$health.OperationalLogsAvailable
    $operationalLogFormat = [string]$health.OperationalLogFormat
    $operationalLogStorage = [string]$health.OperationalLogStorage
    $operationalLogFileSizeLimitBytes =
        [int64]$health.OperationalLogFileSizeLimitBytes
    $operationalLogRetainedFileCountLimit =
        [int]$health.OperationalLogRetainedFileCountLimit
    $operationalLogLastError =
        $health.OperationalLogLastError
    $hasRuntimeError = $null -ne $status.lastError
    if ($queryAlgorithm -ne
        "IApplicationAssociationRegistration.QueryCurrentDefault" -or
        $monitorAlgorithm -ne "RegNotifyChangeKeyValue") {
        $issues.Add("non-primary-algorithm")
    }
    if (-not $auditHealthy -or $driftCount -ne 0) {
        $issues.Add("association-drift")
    }
    if ($processMode -ne "background-no-console") {
        $issues.Add("agent-process-mode")
    }
    if ($notificationChannel -ne "WindowsForms.NotifyIcon") {
        $issues.Add("notification-channel-unexpected")
    }
    if (-not $notificationsAvailable) {
        $issues.Add("notification-channel-unavailable")
    }
    if ($operationalLogChannel -ne "Serilog.Sinks.File" -or
        -not $operationalLogsAvailable) {
        $issues.Add("operational-log-channel-unavailable")
    }
    if ($operationalLogFormat -ne "CLEF" -or
        $operationalLogStorage -ne "runtime/logs" -or
        $operationalLogFileSizeLimitBytes -ne 2MB -or
        $operationalLogRetainedFileCountLimit -ne 7) {
        $issues.Add("operational-log-policy-unexpected")
    }
} elseif ($apiReachable) {
    $issues.Add("association-audit-unavailable")
}

$operationalLogFileCount = 0
$operationalLogTotalBytes = 0L
$operationalLogLargestFileBytes = 0L
$operationalLogFilesReadable = $false
$operationalLogRollThresholdBytes = 2MB
# Serilog rolls before the next event after the threshold is reached, so the
# event that crosses it can make the active file slightly larger.
$operationalLogOvershootAllowanceBytes = 64KB
try {
    if (Test-Path -LiteralPath $operationalLogDirectory -PathType Container) {
        $operationalLogFiles = @(
            Get-ChildItem `
                -LiteralPath $operationalLogDirectory `
                -Filter "agent-*.clef" `
                -File)
        $operationalLogFileCount = $operationalLogFiles.Count
        foreach ($operationalLogFile in $operationalLogFiles) {
            $operationalLogFile.Refresh()
            $length = [int64]$operationalLogFile.Length
            $operationalLogTotalBytes += $length
            if ($length -gt $operationalLogLargestFileBytes) {
                $operationalLogLargestFileBytes = $length
            }
        }
        $operationalLogFilesReadable = $true
    }
} catch {
    $issues.Add("operational-log-metadata-unreadable")
}

$operationalLogRetentionHealthy =
    $operationalLogFilesReadable -and
    $operationalLogFileCount -ge 1 -and
    $operationalLogFileCount -le 7
$operationalLogSizeHealthy =
    $operationalLogFilesReadable -and
    $operationalLogTotalBytes -gt 0 -and
    $operationalLogLargestFileBytes -le
        ($operationalLogRollThresholdBytes +
            $operationalLogOvershootAllowanceBytes)
$operationalLogsHealthy =
    $operationalLogsAvailable -and
    $null -eq $operationalLogLastError -and
    $operationalLogRetentionHealthy -and
    $operationalLogSizeHealthy
if (-not $operationalLogFilesReadable -or
    $operationalLogFileCount -lt 1) {
    $issues.Add("operational-log-files-missing")
}
if ($operationalLogFileCount -gt 7) {
    $issues.Add("operational-log-retention-exceeded")
}
if ($operationalLogLargestFileBytes -gt
    ($operationalLogRollThresholdBytes +
        $operationalLogOvershootAllowanceBytes)) {
    $issues.Add("operational-log-roll-threshold-exceeded")
}

$operatingSystem = Get-CimInstance Win32_OperatingSystem
$report = [ordered]@{
    schemaVersion = 7
    product = "DefaultAppGuard Community"
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    privacy = [ordered]@{
        containsPersonalPaths = $false
        containsRegistryExports = $false
        containsRuntimeFileContents = $false
        containsOperationalLogContents = $false
        containsTokens = $false
    }
    environment = [ordered]@{
        windowsCaption = $operatingSystem.Caption
        windowsVersion = $operatingSystem.Version
        windowsBuild = $operatingSystem.BuildNumber
        operatingSystemArchitecture = $operatingSystem.OSArchitecture
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
    package = [ordered]@{
        manifestPresent = $null -ne $manifest
        manifestSchemaVersion = if ($null -ne $manifest) {
            $manifest.schemaVersion
        } else {
            $null
        }
        version = if ($null -ne $manifest) {
            $manifest.version
        } else {
            $null
        }
        payload = $payloadCheck
        manifestMatchesInstallState = $manifestMatchesInstallState
        executablePresent = $executableExists
        executableFileVersion = $fileVersion
        executableSha256 = $executableSha256
        peSubsystem = $peSubsystem
        processMode = if ($peSubsystem -eq 2) {
            "background-no-console"
        } else {
            "unexpected"
        }
        signatureStatus = $signatureStatus
        signerSubject = $signerSubject
        signatureTimestamped = $signatureTimestamped
        setup = [ordered]@{
            present = $setupExists
            fileVersion = $setupFileVersion
            sha256 = $setupSha256
            peSubsystem = $setupPeSubsystem
            processMode = if ($setupPeSubsystem -eq 2) {
                "graphical-no-console"
            } else {
                "unexpected"
            }
            signatureStatus = $setupSignatureStatus
            signerSubject = $setupSignerSubject
            signatureTimestamped = $setupSignatureTimestamped
        }
    }
    scheduledTask = [ordered]@{
        present = $null -ne $task
        enabled = $taskEnabled
        state = $taskState
        stateHealthy = $taskStateHealthy
        runningAgeSeconds = $taskRunAgeSeconds
        actionMatchesInstall = $taskActionMatches
        action = [ordered]@{
            executableMatches = $taskExecutableMatches
            workingDirectoryMatches = $taskWorkingDirectoryMatches
            argumentsMatch = $taskArgumentsMatch
        }
        principalMatchesCurrentLimitedUser = $taskPrincipalMatches
        settingsMatch = $taskSettingsMatch
        triggersMatch = $taskTriggersMatch
        configurationHealthy = $taskConfigurationHealthy
        lastResult = $taskLastResult
        lastResultDisposition = $taskLastResultDisposition
        triggers = $triggerSummaries
    }
    watchdogTelemetry = [ordered]@{
        storage = "HKCU\Software\DefaultAppGuard\Watchdog\StatusJson"
        present = $watchdogTelemetryPresent
        readable = $watchdogStatusReadable
        schemaValid = $watchdogSchemaValid
        outcome = $watchdogOutcome
        exitCode = $watchdogExitCode
        completedAtUtc = if ($null -ne $watchdogCompletedAtUtc) {
            $watchdogCompletedAtUtc.ToString("O")
        } else {
            $null
        }
        completedAgeSeconds = $watchdogCompletedAgeSeconds
        recoveryAttempted = $watchdogRecoveryAttempted
        previousProcessId = $watchdogPreviousProcessId
        activeProcessId = $watchdogActiveProcessId
        activeProcessMatches = $watchdogProcessMatches
        consecutiveRecoveryFailures = $watchdogConsecutiveFailures
        nextRecoveryAllowedAtUtc = if (
            $null -ne $watchdogNextRecoveryAllowedAtUtc) {
            $watchdogNextRecoveryAllowedAtUtc.ToString("O")
        } else {
            $null
        }
        failureStage = $watchdogFailureStage
        outcomeHealthy = $watchdogOutcomeHealthy
        matchesLastTaskRun = $watchdogTelemetryMatchesTaskRun
    }
    uninstallRegistration = [ordered]@{
        present = $uninstallEntryPresent
        keyMatchesInstallState = $uninstallKeyNameMatches
        metadataMatches = $uninstallMetadataMatches
        hiddenCommandMatches = $uninstallCommandHidden
        quietCommandPresent = $quietUninstallPresent
        healthy = $uninstallRegistrationHealthy
    }
    process = [ordered]@{
        count = $agentProcesses.Count
        processIds = @($agentProcesses | ForEach-Object ProcessId)
        apiProcessMatches = $apiProcessMatches
        consoleChildCount = $consoleChildCount
        listenerAddresses = $listenerAddresses
        loopbackOnly = $loopbackOnly
    }
    mainAlgorithm = [ordered]@{
        apiReachable = $apiReachable
        ready = $readinessReady
        readinessCode = if ($null -ne $readiness) {
            $readiness.Code
        } else {
            $null
        }
        expectedHandlerCount = if ($null -ne $readiness) {
            $readiness.ExpectedHandlerCount
        } else {
            0
        }
        resolvedHandlerCount = if ($null -ne $readiness) {
            $readiness.ResolvedHandlerCount
        } else {
            0
        }
        distinctTargetCount = if ($null -ne $readiness) {
            $readiness.DistinctTargetCount
        } else {
            0
        }
        primarySnapshotCount = if ($null -ne $readiness) {
            $readiness.PrimarySnapshotCount
        } else {
            0
        }
        failedReadCount = if ($null -ne $readiness) {
            $readiness.FailedReadCount
        } else {
            0
        }
        auditFreshnessAvailable = $auditFreshnessAvailable
        auditFresh = $auditFresh
        auditAgeSeconds = $auditAgeSeconds
        maximumAuditAgeSeconds = $maximumAuditAgeSeconds
        query = $queryAlgorithm
        monitor = $monitorAlgorithm
        auditHealthy = $auditHealthy
        healthyCount = $healthyCount
        extensionCount = $extensionCount
        driftCount = $driftCount
        processMode = $processMode
        hasRuntimeError = $hasRuntimeError
    }
    configurationPersistence = [ordered]@{
        storage = if ($null -ne $health) {
            $health.ConfigurationStorage
        } else {
            $null
        }
        backupStorage = if ($null -ne $health) {
            $health.ConfigurationBackupStorage
        } else {
            $null
        }
        backupAvailable = $configurationBackupAvailable
        recovered = $configurationRecovered
        recoveryCode = $configurationRecoveryCode
        recoveredAtUtc = $configurationRecoveredAtUtc
        healthy = $configurationPersistenceHealthy
    }
    notifications = [ordered]@{
        channel = $notificationChannel
        available = $notificationsAvailable
        enabled = $notificationsEnabled
        lastQueuedKind = if (
            [string]::IsNullOrWhiteSpace($notificationLastQueuedKind)) {
            $null
        } else {
            $notificationLastQueuedKind
        }
        lastQueuedAtUtc = if (
            [string]::IsNullOrWhiteSpace($notificationLastQueuedAtUtc)) {
            $null
        } else {
            $notificationLastQueuedAtUtc
        }
        configurationRecoveryLastQueuedKind = if (
            [string]::IsNullOrWhiteSpace(
                $configurationRecoveryLastQueuedKind)) {
            $null
        } else {
            $configurationRecoveryLastQueuedKind
        }
        configurationRecoveryLastQueuedAtUtc = if (
            [string]::IsNullOrWhiteSpace(
                $configurationRecoveryLastQueuedAtUtc)) {
            $null
        } else {
            $configurationRecoveryLastQueuedAtUtc
        }
        telemetryHealthy = $notificationTelemetryHealthy
        configurationRecoveryExpected =
            $configurationRecoveryNotificationExpected
        configurationRecoveryQueuedVerified =
            $configurationRecoveryNotificationVerified
    }
    operationalLogs = [ordered]@{
        channel = $operationalLogChannel
        available = $operationalLogsAvailable
        format = $operationalLogFormat
        storage = $operationalLogStorage
        fileSizeLimitBytes = $operationalLogFileSizeLimitBytes
        retainedFileCountLimit = $operationalLogRetainedFileCountLimit
        lastErrorCode = $operationalLogLastError
        fileMetadataReadable = $operationalLogFilesReadable
        fileCount = $operationalLogFileCount
        totalBytes = $operationalLogTotalBytes
        largestFileBytes = $operationalLogLargestFileBytes
        rollThresholdBytes = $operationalLogRollThresholdBytes
        overshootAllowanceBytes = $operationalLogOvershootAllowanceBytes
        retentionHealthy = $operationalLogRetentionHealthy
        sizeHealthy = $operationalLogSizeHealthy
        healthy = $operationalLogsHealthy
    }
    issueCodes = @($issues | Sort-Object -Unique)
    noticeCodes = @($notices | Sort-Object -Unique)
}
$payloadPassed = $null -ne $payloadCheck -and [bool]$payloadCheck.Passed
$report["overallHealthy"] =
    @($report.issueCodes).Count -eq 0 -and
    $payloadPassed -and
    $manifestMatchesInstallState -and
    $taskActionMatches -and
    $taskEnabled -and
    $taskConfigurationHealthy -and
    $watchdogOutcomeHealthy -and
    $watchdogTelemetryMatchesTaskRun -and
    $watchdogProcessMatches -and
    $uninstallRegistrationHealthy -and
    $agentProcesses.Count -eq 1 -and
    $consoleChildCount -eq 0 -and
    $loopbackOnly -and
    $apiProcessMatches -and
    $notificationsAvailable -and
    $notificationTelemetryHealthy -and
    $configurationRecoveryNotificationVerified -and
    $operationalLogsHealthy -and
    $configurationPersistenceHealthy -and
    $readinessReady -and
    $auditFreshnessAvailable -and
    $auditFresh -and
    $auditHealthy -and
    $driftCount -eq 0

$outputDirectory = Split-Path -Parent $outputFile
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$report |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $outputFile -Encoding UTF8

[pscustomobject]@{
    ReportWritten = $true
    ReportPath = $outputFile
    OverallHealthy = $report["overallHealthy"]
    IssueCodes = $report.issueCodes
}
