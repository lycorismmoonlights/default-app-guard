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
$agentPort = Get-AvailableLoopbackPort
$blockedPort = Get-AvailableLoopbackPort
while ($blockedPort -eq $agentPort) {
    $blockedPort = Get-AvailableLoopbackPort
}
$agentUrl = "http://127.0.0.1:$agentPort"
$blockedAgentUrl = "http://127.0.0.1:$blockedPort"
$installedExecutable = Join-Path $installPath `
    "DefaultAppGuard.Agent.exe"
$installerPath = Join-Path $packagePath `
    "Install-DefaultAppGuard.ps1"
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

try {
    New-Item -ItemType Directory -Path $workPath | Out-Null
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $shortcutPath) `
        -Force | Out-Null
    "DefaultAppGuard lifecycle shortcut ownership sentinel" |
        Set-Content -LiteralPath $shortcutPath -Encoding Ascii
    $shortcutHashBefore = Get-OptionalFileHash -Path $shortcutPath
    $env:APPDATA = $isolatedAppData

    $installResult = & $installerPath `
        -InstallDirectory $installPath `
        -DataDirectory $dataPath `
        -TaskName $taskName `
        -AgentUrl $agentUrl `
        -WatchdogIntervalMinutes $WatchdogIntervalMinutes `
        -HealthTimeoutSeconds 30 `
        -NoStartMenuShortcut
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
        -ExistingAgentUrl $agentUrl `
        -BlockedAgentUrl $blockedAgentUrl `
        -ExpectedPreviousVersion $Version
    Assert-True ([bool]$rollbackResult.RollbackVerified) `
        "The packaged transactional rollback test failed."

    $beforeWatchdog = Wait-AgentHealthy `
        -AgentUrl $agentUrl `
        -ExecutablePath $installedExecutable `
        -ExpectedVersion $Version `
        -Deadline ([DateTime]::UtcNow.AddSeconds(20))
    $task = Get-ScheduledTask -TaskName $taskName
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
    $repeatingTriggers = @(
        $task.Triggers |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace(
                    [string]$_.Repetition.Interval)
            })
    Assert-True ($repeatingTriggers.Count -eq 1) `
        "The installed watchdog repetition trigger is missing."
    Assert-True ([bool]$task.Settings.Enabled) `
        "The installed watchdog task is disabled."

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
    $watchdogResult = [pscustomobject]@{
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

    $candidateManifestHash = (Get-FileHash `
        -LiteralPath (Join-Path $packagePath "package-manifest.json") `
        -Algorithm SHA256).Hash
    $installedManifestHash = (Get-FileHash `
        -LiteralPath (Join-Path $installPath "package-manifest.json") `
        -Algorithm SHA256).Hash
    Assert-True ($candidateManifestHash -eq $installedManifestHash) `
        "The installed package manifest differs from the release candidate."

    $uninstallerPath = Join-Path $installPath `
        "Uninstall-DefaultAppGuard.ps1"
    $uninstallResult = & $uninstallerPath `
        -InstallDirectory $installPath `
        -DataDirectory $dataPath `
        -TaskName $taskName
    $uninstalled = [bool]$uninstallResult.Uninstalled
    Assert-True $uninstalled "The packaged uninstaller did not report success."
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
            exactManifestInstalled = $candidateManifestHash -eq
                $installedManifestHash
        }
        install = [ordered]@{
            transactional = [bool]$installResult.TransactionalUpgrade
            integrityVerified = [bool]$installResult.PackageIntegrityVerified
            processMode = $installResult.ProcessMode
        }
        mainAlgorithm = [ordered]@{
            query = $installResult.MainQuery
            monitor = $installResult.MainMonitor
            expectedExtensionCount = $ExpectedExtensionCount
            initialMonitorVerified = [bool]$firstMonitor.InstalledMonitorVerified
            postRestartMonitorVerified = [bool]$secondMonitor.InstalledMonitorVerified
        }
        rollback = [ordered]@{
            passed = [bool]$rollbackResult.RollbackVerified
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
                -TaskName $taskName |
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
