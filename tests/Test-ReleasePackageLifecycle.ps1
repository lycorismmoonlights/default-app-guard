[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,
    [Parameter(Mandatory)]
    [string]$Version,
    [Parameter(Mandatory)]
    [string]$WorkRoot,
    [Parameter(Mandatory)]
    [string]$EvidencePath,
    [ValidateRange(1, 60)]
    [int]$WatchdogIntervalMinutes = 1,
    [ValidateRange(30, 180)]
    [int]$WatchdogTimeoutSeconds = 120,
    [ValidateRange(1, 100)]
    [int]$ExpectedExtensionCount = 34
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $normalizedPath = Get-NormalizedPath $Path
    $normalizedParent = Get-NormalizedPath $Parent
    return $normalizedPath.StartsWith(
        "$normalizedParent$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-AvailableLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new(
        [Net.IPAddress]::Loopback,
        0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-AgentProcesses {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $target = Get-NormalizedPath $ExecutablePath
    return @(
        Get-CimInstance Win32_Process -Filter `
            "Name='DefaultAppGuard.Agent.exe'" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                (Get-NormalizedPath $_.ExecutablePath) -eq $target
            })
}

function Wait-AgentHealthy {
    param(
        [Parameter(Mandatory)][string]$AgentUrl,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][DateTime]$Deadline,
        [int]$DifferentFromProcessId = 0
    )

    $lastFailure = "Agent did not answer."
    do {
        try {
            $health = Invoke-RestMethod `
                -Uri "$($AgentUrl.TrimEnd('/'))/api/health" `
                -TimeoutSec 1
            $processId = [int]$health.ProcessId
            $processes = @(
                Get-AgentProcesses `
                    -ExecutablePath $ExecutablePath)
            if ($health.Query -ne
                "IApplicationAssociationRegistration.QueryCurrentDefault" -or
                $health.Monitor -ne "RegNotifyChangeKeyValue") {
                $lastFailure = "Agent reported a non-primary algorithm."
            } elseif ($health.ProcessMode -ne "background-no-console") {
                $lastFailure = "Agent reported an unsafe process mode."
            } elseif (-not ([string]$health.Version).StartsWith(
                    "$ExpectedVersion.",
                    [StringComparison]::Ordinal)) {
                $lastFailure = "Agent reported another version."
            } elseif ($DifferentFromProcessId -ne 0 -and
                $processId -eq $DifferentFromProcessId) {
                $lastFailure = "Agent has not restarted with a new process."
            } elseif ($processes.Count -ne 1 -or
                [int]$processes[0].ProcessId -ne $processId) {
                $lastFailure = "Agent endpoint is not owned by the package process."
            } else {
                return [pscustomobject]@{
                    Health = $health
                    ProcessId = $processId
                }
            }
        } catch {
            $lastFailure = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 250
    } until ([DateTime]::UtcNow -ge $Deadline)

    throw "Packaged Agent did not become healthy: $lastFailure"
}

function Wait-WatchdogTaskReady {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][DateTime]$Deadline
    )

    $lastState = "Missing"
    do {
        $task = Get-ScheduledTask -TaskName $TaskName `
            -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $lastState = [string]$task.State
            if ($lastState -eq "Ready") {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
                Assert-True ([int64]$taskInfo.LastTaskResult -eq 0) `
                    "The watchdog task completed with a nonzero result."
                return $task
            }
        }

        Start-Sleep -Milliseconds 250
    } until ([DateTime]::UtcNow -ge $Deadline)

    throw "The watchdog task did not return to Ready state: $lastState"
}

function Get-OptionalFileHash {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "The release package lifecycle test must run on Windows."
}

$packagePath = Get-NormalizedPath $PackageDirectory
$workPath = Get-NormalizedPath $WorkRoot
$evidenceFile = [IO.Path]::GetFullPath($EvidencePath)
if (Test-Path -LiteralPath $workPath) {
    throw "Lifecycle work root already exists: $workPath"
}

$packageModulePath = Join-Path $packagePath `
    "DefaultAppGuard.Package.psm1"
Import-Module -Name $packageModulePath -Force
$packageCheck = Test-DagPackageIntegrity -PackageRoot $packagePath
Assert-True $packageCheck.Passed `
    "The release package failed integrity validation."
Assert-True ($packageCheck.Manifest.version -eq $Version) `
    "The release package version does not match the requested version."
$setupExecutable = Join-Path $packagePath "DefaultAppGuard.Setup.exe"
Assert-True (Test-Path -LiteralPath $setupExecutable -PathType Leaf) `
    "The release package is missing the graphical setup launcher."
Assert-True ((Get-DagPeSubsystem -Path $setupExecutable) -eq 2) `
    "The graphical setup launcher must use the Windows GUI subsystem."
$originalLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $null
    $setupVerification = Start-Process `
        -FilePath $setupExecutable `
        -ArgumentList @("--quiet", "--verify-only") `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
}
Assert-True ($setupVerification.ExitCode -eq 0) `
    "The graphical setup launcher depends on a user-profile environment to verify the package."
$preexistingAgents = @(
    Get-CimInstance Win32_Process -Filter `
        "Name='DefaultAppGuard.Agent.exe'")
if ($preexistingAgents.Count -ne 0) {
    throw (
        "The release lifecycle test requires a dedicated runner with no " +
        "pre-existing DefaultAppGuard.Agent process.")
}

$installPath = Join-Path $workPath "install"
$dataPath = Join-Path $workPath "data"
$taskName = "DefaultAppGuard Release Lifecycle $([Guid]::NewGuid().ToString('N'))"
$uninstallRegistryKeyName = (
    "DefaultAppGuard Release Lifecycle " +
    [Guid]::NewGuid().ToString("N"))
$uninstallSubKeyPath = (
    "Software\Microsoft\Windows\CurrentVersion\Uninstall\" +
    $uninstallRegistryKeyName)
$agentPort = Get-AvailableLoopbackPort
$blockedPort = Get-AvailableLoopbackPort
while ($blockedPort -eq $agentPort) {
    $blockedPort = Get-AvailableLoopbackPort
}
$agentUrl = "http://127.0.0.1:$agentPort"
$blockedAgentUrl = "http://127.0.0.1:$blockedPort"
$installedExecutable = Join-Path $installPath `
    "DefaultAppGuard.Agent.exe"
$installedSetupExecutable = Join-Path $installPath `
    "DefaultAppGuard.Setup.exe"
$installerPath = Join-Path $packagePath `
    "Install-DefaultAppGuard.ps1"
$setupInstallResultPath = Join-Path $workPath "setup-install-result.json"
$originalAppData = $env:APPDATA
$isolatedAppData = Join-Path $workPath "profile\AppData\Roaming"
$shortcutPath = Join-Path $isolatedAppData `
    "Microsoft\Windows\Start Menu\Programs\DefaultAppGuard.lnk"
$shortcutHashBefore = $null
$installed = $false
$uninstalled = $false
$lifecyclePassed = $false
$installResult = $null
$firstMonitor = $null
$rollbackResult = $null
$watchdogResult = $null
$secondMonitor = $null
$diagnosticsResult = $null
$diagnosticsReport = $null
$downloadPolicyProbe = $null
$nativeTamperProbe = $null
$uninstallRegistrationVerified = $false
$taskConfigurationVerified = $false

try {
    New-Item -ItemType Directory -Path $workPath | Out-Null
    $downloadedPackagePath = Join-Path $workPath "downloaded-package"
    New-Item -ItemType Directory -Path $downloadedPackagePath | Out-Null
    Copy-Item `
        -Path (Join-Path $packagePath "*") `
        -Destination $downloadedPackagePath `
        -Recurse
    $zoneIdentifier = "[ZoneTransfer]`r`nZoneId=3"
    foreach ($fileName in @(
            "Install-DefaultAppGuard.ps1",
            "DefaultAppGuard.Package.psm1")) {
        Set-Content `
            -LiteralPath (Join-Path $downloadedPackagePath $fileName) `
            -Stream "Zone.Identifier" `
            -Value $zoneIdentifier `
            -NoNewline
    }
    $originalPolicyPreference = $env:PSExecutionPolicyPreference
    try {
        $env:PSExecutionPolicyPreference = "Restricted"
        $downloadPolicyProbe = Start-Process `
            -FilePath (Join-Path $downloadedPackagePath `
                "DefaultAppGuard.Setup.exe") `
            -ArgumentList @("--quiet", "--verify-only") `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    } finally {
        $env:PSExecutionPolicyPreference = $originalPolicyPreference
    }
    Assert-True ($downloadPolicyProbe.ExitCode -eq 0) `
        "Setup could not verify a downloaded package under a restricted process policy."
    $tamperMarkerPath = Join-Path $workPath "tampered-script-executed.txt"
    $tamperedInstallerPath = Join-Path $downloadedPackagePath `
        "Install-DefaultAppGuard.ps1"
    $tamperedInstaller = Get-Content `
        -LiteralPath $tamperedInstallerPath `
        -Raw `
        -Encoding UTF8
    $escapedMarkerPath = $tamperMarkerPath.Replace("'", "''")
    ("Set-Content -LiteralPath '$escapedMarkerPath' -Value 'executed'`r`n" +
        $tamperedInstaller) |
        Set-Content `
            -LiteralPath $tamperedInstallerPath `
            -Encoding UTF8
    $nativeTamperProbe = Start-Process `
        -FilePath (Join-Path $downloadedPackagePath `
            "DefaultAppGuard.Setup.exe") `
        -ArgumentList @("--quiet", "--verify-only") `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    Assert-True ($nativeTamperProbe.ExitCode -eq 5) `
        "Native Setup did not reject a package with a modified installer."
    Assert-True (-not (Test-Path -LiteralPath $tamperMarkerPath)) `
        "Setup executed a modified installer before native integrity verification."
    if (-not (Test-PathWithin `
            -Path $downloadedPackagePath `
            -Parent $workPath)) {
        throw "Refusing to clean an unsafe policy-probe package path."
    }
    Remove-Item `
        -LiteralPath $downloadedPackagePath `
        -Recurse `
        -Force

    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $shortcutPath) `
        -Force | Out-Null
    "DefaultAppGuard lifecycle shortcut ownership sentinel" |
        Set-Content -LiteralPath $shortcutPath -Encoding Ascii
    $shortcutHashBefore = Get-OptionalFileHash -Path $shortcutPath
    $env:APPDATA = $isolatedAppData

    $setupInstallArguments = @(
        "--quiet"
        "--install-directory"
        ('"{0}"' -f $installPath)
        "--data-directory"
        ('"{0}"' -f $dataPath)
        "--task-name"
        ('"{0}"' -f $taskName)
        "--agent-url"
        $agentUrl
        "--watchdog-minutes"
        [string]$WatchdogIntervalMinutes
        "--health-timeout-seconds"
        "30"
        "--uninstall-registry-key-name"
        ('"{0}"' -f $uninstallRegistryKeyName)
        "--no-start-menu-shortcut"
        "--result-path"
        ('"{0}"' -f $setupInstallResultPath)
    ) -join " "
    $setupInstall = Start-Process `
        -FilePath $setupExecutable `
        -ArgumentList $setupInstallArguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    Assert-True ($setupInstall.ExitCode -eq 0) `
        "The graphical Setup launcher failed to install the release package."
    Assert-True (Test-Path `
        -LiteralPath $setupInstallResultPath `
        -PathType Leaf) `
        "The graphical Setup launcher did not produce installation evidence."
    $installResult = Get-Content `
        -LiteralPath $setupInstallResultPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    $installed = $true

    Assert-True ([bool]$installResult.Installed) `
        "The candidate installer did not report success."
    Assert-True ([bool]$installResult.TransactionalUpgrade) `
        "The candidate installer did not report transactional behavior."
    Assert-True ([bool]$installResult.PackageIntegrityVerified) `
        "The candidate installer did not verify package integrity."
    Assert-True ($installResult.MainQuery -eq
        "IApplicationAssociationRegistration.QueryCurrentDefault") `
        "The installed candidate did not use the primary query."
    Assert-True ($installResult.MainMonitor -eq
        "RegNotifyChangeKeyValue") `
        "The installed candidate did not use the primary monitor."
    Assert-True ($installResult.ProcessMode -eq
        "background-no-console") `
        "The installed candidate did not use hidden background mode."
    Assert-True ([bool]$installResult.Ready) `
        "The installed candidate did not pass the readiness gate."
    Assert-True ($installResult.ReadinessCode -eq "ready") `
        "The installed candidate reported an unexpected readiness code."
    Assert-True ([int]$installResult.AuditedExtensionCount -eq
        $ExpectedExtensionCount) `
        "The readiness gate did not audit every declared extension."
    Assert-True ([int]$installResult.PrimarySnapshotCount -eq
        $ExpectedExtensionCount) `
        "The readiness gate did not obtain primary COM evidence for every extension."
    Assert-True ([int]$installResult.FailedReadCount -eq 0) `
        "The readiness gate reported failed primary association reads."
    Assert-True ([bool]$installResult.UninstallRegistered) `
        "The candidate installer did not register standard uninstallation."
    Assert-True ($installResult.UninstallRegistryKeyName -eq
        $uninstallRegistryKeyName) `
        "The candidate installer registered another uninstall key."

    $uninstallKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $uninstallSubKeyPath)
    Assert-True ($null -ne $uninstallKey) `
        "The standard per-user uninstall registry entry is missing."
    try {
        $registeredName = [string]$uninstallKey.GetValue("DisplayName")
        $registeredVersion = [string]$uninstallKey.GetValue("DisplayVersion")
        $registeredLocation = [string]$uninstallKey.GetValue("InstallLocation")
        $uninstallCommand = [string]$uninstallKey.GetValue("UninstallString")
        $quietUninstallCommand = [string]$uninstallKey.GetValue(
            "QuietUninstallString")
        $uninstallRegistrationVerified =
            $registeredName -eq "DefaultAppGuard Community" -and
            $registeredVersion -eq $Version -and
            (Get-NormalizedPath $registeredLocation) -eq $installPath -and
            $uninstallCommand -eq $quietUninstallCommand -and
            $uninstallCommand.Contains("-ExecutionPolicy Bypass") -and
            $uninstallCommand.Contains("-WindowStyle Hidden") -and
            $uninstallCommand.Contains($uninstallRegistryKeyName) -and
            [int]$uninstallKey.GetValue("NoModify", 0) -eq 1 -and
            [int]$uninstallKey.GetValue("NoRepair", 0) -eq 1
    } finally {
        $uninstallKey.Dispose()
    }
    Assert-True $uninstallRegistrationVerified `
        "The standard per-user uninstall metadata is incomplete or unsafe."
    Assert-True ((Get-OptionalFileHash -Path $shortcutPath) -eq
        $shortcutHashBefore) `
        "An isolated no-shortcut install changed the user's shortcut."

    $initialStatus = Invoke-RestMethod `
        -Uri "$agentUrl/api/status" `
        -TimeoutSec 2
    Assert-True ([bool]$initialStatus.audit.healthy) `
        "The installed candidate's initial audit was unhealthy."
    Assert-True ([int]$initialStatus.audit.driftCount -eq 0) `
        "The installed candidate reported association drift."
    Assert-True (@($initialStatus.audit.items).Count -eq
        $ExpectedExtensionCount) `
        "The installed candidate did not audit every declared extension."

    $firstMonitor = & (Join-Path $PSScriptRoot `
        "Test-InstalledMonitor.ps1") `
        -AgentUrl $agentUrl `
        -TimeoutSeconds 15
    Assert-True ([bool]$firstMonitor.InstalledMonitorVerified) `
        "The packaged primary monitor failed before rollback."

    $rollbackResult = & (Join-Path $PSScriptRoot `
        "Test-InstalledUpgradeRollback.ps1") `
        -PackageDirectory $packagePath `
        -InstallDirectory $installPath `
        -DataDirectory $dataPath `
        -TaskName $taskName `
        -UninstallRegistryKeyName $uninstallRegistryKeyName `
        -ExistingAgentUrl $agentUrl `
        -BlockedAgentUrl $blockedAgentUrl `
        -ExpectedPreviousVersion $Version
    Assert-True ([bool]$rollbackResult.RollbackVerified) `
        "The packaged transactional rollback test failed."
    Assert-True ([bool]$rollbackResult.LateRollbackVerified) `
        "The packaged late-stage transactional rollback test failed."

    $beforeWatchdog = Wait-AgentHealthy `
        -AgentUrl $agentUrl `
        -ExecutablePath $installedExecutable `
        -ExpectedVersion $Version `
        -Deadline ([DateTime]::UtcNow.AddSeconds(20))
    $task = Wait-WatchdogTaskReady `
        -TaskName $taskName `
        -Deadline ([DateTime]::UtcNow.AddSeconds(20))
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
    $taskActions = @($task.Actions)
    $expectedAgentArguments = @(
        "--url `"$agentUrl`""
        "--state `"$(Join-Path $dataPath "runtime\agent-status.json")`""
        "--config `"$(Join-Path $dataPath "runtime\guard-configuration.json")`""
    ) -join " "
    $expectedTaskArguments = "--watchdog $expectedAgentArguments"
    Assert-True ($taskActions.Count -eq 1) `
        "The installed watchdog task has an unexpected action count."
    Assert-True ((Get-NormalizedPath $taskActions[0].Execute) -eq
        $installedSetupExecutable) `
        "The installed watchdog launcher does not match the package."
    Assert-True ((Get-NormalizedPath $taskActions[0].WorkingDirectory) -eq
        $installPath) `
        "The installed watchdog working directory does not match the package."
    Assert-True ([string]$taskActions[0].Arguments -eq
        $expectedTaskArguments) `
        "The installed watchdog arguments do not match the package."

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
    Assert-True ($principalSid -eq
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) `
        "The installed watchdog does not run as the current user."
    Assert-True ([string]$task.Principal.RunLevel -eq "Limited") `
        "The installed watchdog unexpectedly requests elevation."
    Assert-True ([string]$task.Principal.LogonType -eq "Interactive") `
        "The installed watchdog does not use the interactive user token."

    Assert-True ([string]$task.Settings.MultipleInstances -eq "IgnoreNew") `
        "The installed watchdog does not reject duplicate instances."
    Assert-True ([bool]$task.Settings.StartWhenAvailable) `
        "The installed watchdog does not recover a missed scheduled start."
    Assert-True ([int]$task.Settings.RestartCount -eq 3) `
        "The installed watchdog restart count is unexpected."
    Assert-True ([string]$task.Settings.RestartInterval -eq "PT1M") `
        "The installed watchdog restart interval is unexpected."
    Assert-True ([string]$task.Settings.ExecutionTimeLimit -eq "PT1M") `
        "The installed watchdog execution limit is unexpected."
    Assert-True (-not [bool]$task.Settings.DisallowStartIfOnBatteries) `
        "The installed watchdog is disabled on battery power."
    Assert-True (-not [bool]$task.Settings.StopIfGoingOnBatteries) `
        "The installed watchdog stops when battery power begins."

    $allTriggers = @($task.Triggers)
    $logonTriggers = @(
        $allTriggers |
            Where-Object {
                $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger"
            })
    $repeatingTriggers = @(
        $allTriggers |
            Where-Object {
                $_.CimClass.CimClassName -eq "MSFT_TaskTimeTrigger"
            })
    Assert-True ($allTriggers.Count -eq 2) `
        "The installed watchdog task has unexpected triggers."
    Assert-True ($logonTriggers.Count -eq 1 -and
        [bool]$logonTriggers[0].Enabled) `
        "The installed watchdog logon trigger is missing or disabled."
    Assert-True ($repeatingTriggers.Count -eq 1) `
        "The installed watchdog repetition trigger is missing."
    Assert-True ([bool]$repeatingTriggers[0].Enabled) `
        "The installed watchdog repetition trigger is disabled."
    Assert-True ([string]$repeatingTriggers[0].Repetition.Interval -eq
        [Xml.XmlConvert]::ToString(
            [TimeSpan]::FromMinutes($WatchdogIntervalMinutes))) `
        "The installed watchdog repetition interval is unexpected."
    Assert-True ([bool]$task.Settings.Enabled) `
        "The installed watchdog task is disabled."
    Assert-True ([string]$task.State -eq "Ready") `
        "The installed watchdog task did not return to Ready state."
    $taskConfigurationVerified = $true

    Stop-Process -Id $beforeWatchdog.ProcessId -Force
    Wait-Process -Id $beforeWatchdog.ProcessId -Timeout 10 `
        -ErrorAction SilentlyContinue
    $afterWatchdog = Wait-AgentHealthy `
        -AgentUrl $agentUrl `
        -ExecutablePath $installedExecutable `
        -ExpectedVersion $Version `
        -DifferentFromProcessId $beforeWatchdog.ProcessId `
        -Deadline ([DateTime]::UtcNow.AddSeconds(
            $WatchdogTimeoutSeconds))
    $recoveredTask = Wait-WatchdogTaskReady `
        -TaskName $taskName `
        -Deadline ([DateTime]::UtcNow.AddSeconds(20))
    $watchdogResult = [pscustomobject]@{
        TaskConfigurationVerified = $taskConfigurationVerified
        TaskState = [string]$recoveredTask.State
        RepetitionInterval = [string]$repeatingTriggers[0].Repetition.Interval
        ScheduledNextRun = $taskInfo.NextRunTime.ToUniversalTime().ToString("O")
        PreviousProcessId = $beforeWatchdog.ProcessId
        RestartedProcessId = $afterWatchdog.ProcessId
        AutomaticRestartVerified = $true
    }

    $secondMonitor = & (Join-Path $PSScriptRoot `
        "Test-InstalledMonitor.ps1") `
        -AgentUrl $agentUrl `
        -TimeoutSeconds 15
    Assert-True ([bool]$secondMonitor.InstalledMonitorVerified) `
        "The packaged primary monitor failed after watchdog recovery."

    $diagnosticsPath = Join-Path (
        Split-Path -Parent $evidenceFile) `
        "package-lifecycle-diagnostics.json"
    $diagnosticsResult = & (Join-Path $installPath `
        "Get-DefaultAppGuardDiagnostics.ps1") `
        -InstallDirectory $installPath `
        -DataDirectory $dataPath `
        -TaskName $taskName `
        -UninstallRegistryKeyName $uninstallRegistryKeyName `
        -OutputPath $diagnosticsPath
    Assert-True ([bool]$diagnosticsResult.OverallHealthy) `
        "Packaged diagnostics reported an unhealthy installation."
    $diagnosticsReport = Get-Content `
        -LiteralPath $diagnosticsPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (@($diagnosticsReport.issueCodes).Count -eq 0) `
        "Packaged diagnostics reported issue codes."
    Assert-True ([bool]$diagnosticsReport.process.loopbackOnly) `
        "The packaged Agent listened outside loopback."
    Assert-True ([int]$diagnosticsReport.process.consoleChildCount -eq 0) `
        "The packaged Agent created a console child."
    Assert-True ([int]$diagnosticsReport.mainAlgorithm.extensionCount -eq
        $ExpectedExtensionCount) `
        "Diagnostics did not report every declared extension."
    Assert-True ([bool]$diagnosticsReport.uninstallRegistration.healthy) `
        "Diagnostics rejected the standard uninstall registration."
    Assert-True ([bool]$diagnosticsReport.scheduledTask.configurationHealthy) `
        "Diagnostics rejected the installed watchdog configuration."

    $candidateManifestHash = (Get-FileHash `
        -LiteralPath (Join-Path $packagePath "package-manifest.json") `
        -Algorithm SHA256).Hash
    $installedManifestHash = (Get-FileHash `
        -LiteralPath (Join-Path $installPath "package-manifest.json") `
        -Algorithm SHA256).Hash
    Assert-True ($candidateManifestHash -eq $installedManifestHash) `
        "The installed package manifest differs from the release candidate."

    if ($uninstallCommand -notmatch '^"([^"]+)"\s+(.+)$') {
        throw "The registered uninstall command could not be parsed safely."
    }
    $registeredUninstallerExecutable = $Matches[1]
    $registeredUninstallerArguments = $Matches[2]
    $uninstallProcess = Start-Process `
        -FilePath $registeredUninstallerExecutable `
        -ArgumentList $registeredUninstallerArguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    $uninstalled = $uninstallProcess.ExitCode -eq 0
    Assert-True $uninstalled `
        "The registered standard uninstall command did not complete successfully."
    Assert-True (-not (Test-Path -LiteralPath $installPath)) `
        "The package install directory remained after uninstall."
    Assert-True (-not (Test-Path -LiteralPath $dataPath)) `
        "The package data directory remained after uninstall."
    Assert-True ($null -eq (Get-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue)) `
        "The package watchdog task remained after uninstall."
    Assert-True (@(Get-AgentProcesses `
        -ExecutablePath $installedExecutable).Count -eq 0) `
        "The packaged Agent remained after uninstall."
    $remainingUninstallKey =
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            $uninstallSubKeyPath)
    $uninstallRegistrationRemoved = $null -eq $remainingUninstallKey
    if ($null -ne $remainingUninstallKey) {
        $remainingUninstallKey.Dispose()
    }
    Assert-True $uninstallRegistrationRemoved `
        "The standard uninstall registry entry remained after uninstall."
    Assert-True ((Get-OptionalFileHash -Path $shortcutPath) -eq
        $shortcutHashBefore) `
        "The isolated package lifecycle changed the user's shortcut."

    $transactionResidue = @(
        Get-ChildItem -LiteralPath $workPath -Directory -Force |
            Where-Object {
                $_.Name -like ".install.installing-*" -or
                $_.Name -like ".install.backup-*"
            })
    Assert-True ($transactionResidue.Count -eq 0) `
        "Transaction directories remained after the package lifecycle."

    $evidence = [ordered]@{
        schemaVersion = 1
        product = "DefaultAppGuard Community"
        version = $Version
        generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        package = [ordered]@{
            manifestSha256 = $candidateManifestHash
            executableSha256 = (Get-FileHash `
                -LiteralPath (Join-Path $packagePath `
                    "DefaultAppGuard.Agent.exe") `
                -Algorithm SHA256).Hash
            declaredFileCount = $packageCheck.DeclaredFileCount
            setupVerifierPassed = $setupVerification.ExitCode -eq 0
            downloadPolicyProbePassed = $downloadPolicyProbe.ExitCode -eq 0
            nativeTamperRejected = (
                $nativeTamperProbe.ExitCode -eq 5 -and
                -not (Test-Path -LiteralPath $tamperMarkerPath))
            setupPeSubsystem = Get-DagPeSubsystem -Path $setupExecutable
            exactManifestInstalled = $candidateManifestHash -eq
                $installedManifestHash
        }
        install = [ordered]@{
            graphicalSetupUsed = $setupInstall.ExitCode -eq 0
            transactional = [bool]$installResult.TransactionalUpgrade
            integrityVerified = [bool]$installResult.PackageIntegrityVerified
            processMode = $installResult.ProcessMode
            uninstallRegistrationVerified = $uninstallRegistrationVerified
        }
        mainAlgorithm = [ordered]@{
            query = $installResult.MainQuery
            monitor = $installResult.MainMonitor
            expectedExtensionCount = $ExpectedExtensionCount
            readinessCode = $installResult.ReadinessCode
            auditedExtensionCount = $installResult.AuditedExtensionCount
            primarySnapshotCount = $installResult.PrimarySnapshotCount
            failedReadCount = $installResult.FailedReadCount
            initialMonitorVerified = [bool]$firstMonitor.InstalledMonitorVerified
            postRestartMonitorVerified = [bool]$secondMonitor.InstalledMonitorVerified
        }
        rollback = [ordered]@{
            passed = [bool]$rollbackResult.RollbackVerified
            lateStagePassed = [bool]$rollbackResult.LateRollbackVerified
            installStateRestored = [bool]$rollbackResult.InstallStateRestored
            uninstallEntryRestored = [bool]$rollbackResult.UninstallEntryRestored
            restoredVersion = $rollbackResult.RestoredVersion
            transactionResidueCount = $rollbackResult.TransactionResidueCount
        }
        watchdog = $watchdogResult
        diagnostics = [ordered]@{
            overallHealthy = [bool]$diagnosticsResult.OverallHealthy
            issueCount = @($diagnosticsReport.issueCodes).Count
            loopbackOnly = [bool]$diagnosticsReport.process.loopbackOnly
            consoleChildCount = [int]$diagnosticsReport.process.consoleChildCount
        }
        uninstall = [ordered]@{
            passed = $uninstalled
            registeredCommandUsed = $true
            registrationRemoved = $uninstallRegistrationRemoved
            taskRemoved = $true
            processRemoved = $true
            directoriesRemoved = $true
            shortcutUnchanged = $true
            transactionResidueCount = $transactionResidue.Count
        }
        passed = $true
    }
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $evidenceFile) `
        -Force | Out-Null
    $evidence |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $evidenceFile -Encoding UTF8
    $lifecyclePassed = $true

    [pscustomobject]@{
        Passed = $true
        EvidencePath = $evidenceFile
        MainQuery = $installResult.MainQuery
        MainMonitor = $installResult.MainMonitor
        ExtensionCount = $ExpectedExtensionCount
        RollbackVerified = [bool]$rollbackResult.RollbackVerified
        WatchdogVerified = [bool]$watchdogResult.AutomaticRestartVerified
        DiagnosticsHealthy = [bool]$diagnosticsResult.OverallHealthy
        UninstallVerified = $uninstalled
    }
} finally {
    if (-not $uninstalled -and $installed -and
        (Test-Path -LiteralPath (Join-Path $installPath `
            "Uninstall-DefaultAppGuard.ps1") -PathType Leaf)) {
        try {
            & (Join-Path $installPath "Uninstall-DefaultAppGuard.ps1") `
                -InstallDirectory $installPath `
                -DataDirectory $dataPath `
                -TaskName $taskName `
                -UninstallRegistryKeyName $uninstallRegistryKeyName |
                Out-Null
        } catch {
            Write-Warning "Lifecycle cleanup uninstaller failed: $($_.Exception.Message)"
        }
    }

    $task = Get-ScheduledTask -TaskName $taskName `
        -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Stop-ScheduledTask -TaskName $taskName `
            -ErrorAction SilentlyContinue
        Unregister-ScheduledTask `
            -TaskName $taskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
    foreach ($process in Get-AgentProcesses `
        -ExecutablePath $installedExecutable) {
        Stop-Process -Id $process.ProcessId -Force `
            -ErrorAction SilentlyContinue
    }

    $cleanupUninstallKey =
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
            $uninstallSubKeyPath)
    if ($null -ne $cleanupUninstallKey) {
        try {
            $cleanupName = [string]$cleanupUninstallKey.GetValue("DisplayName")
            $cleanupLocation = [string]$cleanupUninstallKey.GetValue(
                "InstallLocation")
        } finally {
            $cleanupUninstallKey.Dispose()
        }
        if ($cleanupName -eq "DefaultAppGuard Community" -and
            -not [string]::IsNullOrWhiteSpace($cleanupLocation) -and
            (Get-NormalizedPath $cleanupLocation) -eq $installPath) {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
                $uninstallSubKeyPath,
                $false)
        }
    }

    $env:APPDATA = $originalAppData

    if (Test-Path -LiteralPath $workPath) {
        $workParent = Split-Path -Parent $workPath
        if (-not (Test-PathWithin -Path $workPath -Parent $workParent)) {
            throw "Refusing to clean an unsafe lifecycle work root."
        }
        Remove-Item -LiteralPath $workPath -Recurse -Force
    }

    if ($lifecyclePassed -and
        -not (Test-Path -LiteralPath $evidenceFile -PathType Leaf)) {
        throw "Lifecycle evidence was not written."
    }
}
