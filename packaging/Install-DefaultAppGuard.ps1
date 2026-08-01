[CmdletBinding()]
param(
    [string]$InstallDirectory = (
        Join-Path $env:LOCALAPPDATA "Programs\DefaultAppGuard"),
    [string]$DataDirectory = (
        Join-Path $env:LOCALAPPDATA "DefaultAppGuard"),
    [string]$TaskName = "DefaultAppGuard Agent",
    [string]$AgentUrl = "http://127.0.0.1:51873",
    [ValidateRange(1, 60)]
    [int]$WatchdogIntervalMinutes = 5,
    [ValidateRange(5, 120)]
    [int]$HealthTimeoutSeconds = 20,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._ -]{0,79}$')]
    [string]$UninstallRegistryKeyName = "DefaultAppGuard Community",
    [switch]$NoStartMenuShortcut,
    [switch]$VerifyOnly,
    [string]$ResultPath
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

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-SafeDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = Get-NormalizedPath $Path
    $root = [System.IO.Path]::GetPathRoot($normalized).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar)
    if ($normalized -eq $root -or $normalized.Length -le ($root.Length + 3)) {
        throw "Refusing to manage an unsafe directory: $normalized"
    }

    return $normalized
}

function Test-IsPathWithin {
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

function Stop-InstalledAgent {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $target = Get-NormalizedPath $ExecutablePath
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $matchingProcesses = @(
            Get-CimInstance Win32_Process -Filter `
                "Name='DefaultAppGuard.Agent.exe'" |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace(
                        $_.ExecutablePath) -and
                    (Get-NormalizedPath $_.ExecutablePath) -eq $target
                })
        if ($matchingProcesses.Count -eq 0) {
            return
        }

        foreach ($process in $matchingProcesses) {
            Stop-Process -Id $process.ProcessId -Force `
                -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Installed Agent did not stop before the upgrade: $target"
}

function Remove-DirectoryWithRetry {
    param([Parameter(Mandatory)][string]$Path)

    $target = Assert-SafeDirectoryPath $Path
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Remove-Item -LiteralPath $target -Recurse -Force `
                -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 20) {
                throw
            }

            Start-Sleep -Milliseconds 250
        }
    }
}

function New-WatchdogScheduledTask {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$CurrentUser,
        [Parameter(Mandatory)][int]$IntervalMinutes
    )

    $action = New-ScheduledTaskAction `
        -Execute $ExecutablePath `
        -Argument $Arguments `
        -WorkingDirectory $WorkingDirectory
    $logonTrigger = New-ScheduledTaskTrigger `
        -AtLogOn `
        -User $CurrentUser
    $watchdogTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (
            New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal `
        -UserId $CurrentUser `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1
        )

    return New-ScheduledTask `
        -Action $action `
        -Trigger @($logonTrigger, $watchdogTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description (
            "Checks and recovers the current user's DefaultAppGuard Agent.")
}

function Wait-WatchdogTaskReady {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = "Missing"
    do {
        $task = Get-ScheduledTask -TaskName $TaskName `
            -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $lastState = [string]$task.State
            if ($lastState -eq "Ready") {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
                if ([int64]$taskInfo.LastTaskResult -ne 0) {
                    throw (
                        "The watchdog task exited with result 0x{0:X8}." -f
                        ([uint32]$taskInfo.LastTaskResult))
                }
                return $task
            }
        }

        Start-Sleep -Milliseconds 250
    } until ([DateTime]::UtcNow -ge $deadline)

    throw "The watchdog task did not return to Ready state: $lastState"
}

function Wait-AgentReady {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastFailure = "Agent did not answer."
    do {
        Start-Sleep -Milliseconds 250
        try {
            $health = Invoke-RestMethod `
                -Uri "$Url/api/health" `
                -TimeoutSec 1
            if ($health.Service -ne "DefaultAppGuard.Agent") {
                $lastFailure = "Health endpoint reported another service."
                continue
            }
            if ($health.Query -ne
                "IApplicationAssociationRegistration.QueryCurrentDefault" -or
                $health.Monitor -ne "RegNotifyChangeKeyValue") {
                $lastFailure = "Health endpoint reported a non-primary algorithm."
                continue
            }
            if ($health.ProcessMode -ne "background-no-console") {
                $lastFailure = "Health endpoint reported an unsafe process mode."
                continue
            }
            if ($health.NotificationChannel -ne "WindowsForms.NotifyIcon" -or
                -not [bool]$health.NotificationsAvailable) {
                $lastFailure = "System notification channel is unavailable."
                continue
            }
            if ($health.OperationalLogChannel -ne "Serilog.Sinks.File" -or
                -not [bool]$health.OperationalLogsAvailable -or
                $health.OperationalLogFormat -ne "CLEF" -or
                [int64]$health.OperationalLogFileSizeLimitBytes -ne
                    2MB -or
                [int]$health.OperationalLogRetainedFileCountLimit -ne 7) {
                $lastFailure = "Bounded operational logging is unavailable."
                continue
            }
            if (-not ([string]$health.Version).StartsWith(
                    "$ExpectedVersion.",
                    [StringComparison]::Ordinal)) {
                $lastFailure = "Health endpoint reported another version."
                continue
            }

            $processId = [int]$health.ProcessId
            $process = Get-CimInstance Win32_Process `
                -Filter "ProcessId=$processId" `
                -ErrorAction SilentlyContinue
            if ($null -eq $process -or
                [string]::IsNullOrWhiteSpace($process.ExecutablePath) -or
                (Get-NormalizedPath $process.ExecutablePath) -ne
                (Get-NormalizedPath $ExecutablePath)) {
                $lastFailure = "Health endpoint is not owned by the installed Agent."
                continue
            }

            $consoleChildren = @(
                Get-CimInstance Win32_Process |
                    Where-Object {
                        $_.ParentProcessId -eq $processId -and
                        $_.Name -in @(
                            "conhost.exe",
                            "OpenConsole.exe",
                            "WindowsTerminal.exe")
                    })
            if ($consoleChildren.Count -ne 0) {
                $lastFailure = "Installed Agent created a console child process."
                continue
            }

            $readiness = Invoke-RestMethod `
                -Uri "$Url/api/readiness" `
                -TimeoutSec 1
            if (-not [bool]$readiness.Ready -or
                $readiness.Code -ne "ready") {
                $lastFailure = (
                    "Agent readiness check failed: " +
                    [string]$readiness.Code)
                continue
            }
            if ($readiness.Query -ne $health.Query -or
                $readiness.Monitor -ne $health.Monitor) {
                $lastFailure = "Readiness reported another algorithm."
                continue
            }
            if ([string]::IsNullOrWhiteSpace(
                    [string]$readiness.TargetProgId) -or
                [string]::IsNullOrWhiteSpace(
                    [string]$readiness.TargetPackageId)) {
                $lastFailure = "Readiness did not resolve Microsoft Media Player."
                continue
            }
            if ([int]$readiness.AuditedExtensionCount -le 0 -or
                [int]$readiness.PrimarySnapshotCount -le 0) {
                $lastFailure = "Readiness did not produce primary query evidence."
                continue
            }

            return [pscustomobject]@{
                Health = $health
                Readiness = $readiness
                ProcessId = $processId
            }
        } catch {
            $lastFailure = $_.Exception.Message
        }
    } until ([DateTime]::UtcNow -ge $deadline)

    throw "Agent did not become ready: $lastFailure"
}

function Write-JsonAtomically {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory (
        ".{0}.{1}.tmp" -f (
            Split-Path -Leaf $Path),
            [Guid]::NewGuid().ToString("N"))
    $Value |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    $replacementBackupPath = Join-Path $directory (
        ".{0}.{1}.replace-backup" -f (
            Split-Path -Leaf $Path),
            [Guid]::NewGuid().ToString("N"))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace(
                $temporaryPath,
                $Path,
                $replacementBackupPath)
        } else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $replacementBackupPath) {
            Remove-Item -LiteralPath $replacementBackupPath -Force
        }
    }
}

function Get-UninstallRegistrySnapshot {
    param([Parameter(Mandatory)][string]$SubKeyPath)

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKeyPath)
    if ($null -eq $key) {
        return $null
    }

    try {
        if ($key.SubKeyCount -ne 0) {
            throw "Refusing to replace an uninstall key containing subkeys."
        }

        $values = @(
            foreach ($name in $key.GetValueNames()) {
                [pscustomobject]@{
                    Name = $name
                    Kind = [int]$key.GetValueKind($name)
                    Value = $key.GetValue(
                        $name,
                        $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            }
        )
        return [pscustomobject]@{
            Values = $values
        }
    } finally {
        $key.Dispose()
    }
}

function Get-UninstallSnapshotValue {
    param(
        $Snapshot,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Snapshot) {
        return $null
    }
    $entry = @($Snapshot.Values) |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1
    if ($null -eq $entry) {
        return $null
    }
    return $entry.Value
}

function Restore-UninstallRegistrySnapshot {
    param(
        [Parameter(Mandatory)][string]$SubKeyPath,
        $Snapshot
    )

    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $SubKeyPath,
        $false)
    if ($null -eq $Snapshot) {
        return
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKeyPath)
    if ($null -eq $key) {
        throw "Could not restore the previous uninstall registry key."
    }
    try {
        foreach ($entry in @($Snapshot.Values)) {
            $key.SetValue(
                [string]$entry.Name,
                $entry.Value,
                [Microsoft.Win32.RegistryValueKind]([int]$entry.Kind))
        }
    } finally {
        $key.Dispose()
    }
}

function ConvertTo-WindowsCommandArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Contains('"') -or
        $Value.Contains("`r") -or
        $Value.Contains("`n")) {
        throw "An uninstall command argument contains an unsupported character."
    }
    return '"' + $Value + '"'
}

function Set-UninstallRegistryEntry {
    param(
        [Parameter(Mandatory)][string]$SubKeyPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$RegistryKeyName
    )

    $uninstallerPath = Join-Path $InstallDirectory `
        "Uninstall-DefaultAppGuard.ps1"
    $setupPath = Join-Path $InstallDirectory "DefaultAppGuard.Setup.exe"
    if (-not (Test-Path -LiteralPath $uninstallerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "Installed uninstall components are missing."
    }

    $powerShellPath = Join-Path $env:SystemRoot `
        "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        throw "Windows PowerShell is unavailable for uninstallation."
    }

    $commandParts = @(
        (ConvertTo-WindowsCommandArgument $powerShellPath)
        "-NoLogo"
        "-NoProfile"
        "-NonInteractive"
        "-ExecutionPolicy Bypass"
        "-WindowStyle Hidden"
        "-File"
        (ConvertTo-WindowsCommandArgument $uninstallerPath)
        "-InstallDirectory"
        (ConvertTo-WindowsCommandArgument $InstallDirectory)
        "-DataDirectory"
        (ConvertTo-WindowsCommandArgument $DataDirectory)
        "-TaskName"
        (ConvertTo-WindowsCommandArgument $TaskName)
        "-UninstallRegistryKeyName"
        (ConvertTo-WindowsCommandArgument $RegistryKeyName)
    )
    $uninstallCommand = $commandParts -join " "
    $versionCore = $Version.Split("-")[0]
    $parsedVersion = [Version]$versionCore
    $sizeBytes = [long](
        Get-ChildItem -LiteralPath $InstallDirectory -Recurse -File |
            Measure-Object -Property Length -Sum).Sum
    $estimatedSize = [int][Math]::Min(
        [int]::MaxValue,
        [Math]::Max(1, [Math]::Ceiling($sizeBytes / 1KB)))

    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $SubKeyPath,
        $false)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKeyPath)
    if ($null -eq $key) {
        throw "Could not create the uninstall registry entry."
    }
    try {
        $stringKind = [Microsoft.Win32.RegistryValueKind]::String
        $dwordKind = [Microsoft.Win32.RegistryValueKind]::DWord
        $key.SetValue("DisplayName", "DefaultAppGuard Community", $stringKind)
        $key.SetValue("DisplayVersion", $Version, $stringKind)
        $key.SetValue("Publisher", "DefaultAppGuard Community", $stringKind)
        $key.SetValue("InstallLocation", $InstallDirectory, $stringKind)
        $key.SetValue("DisplayIcon", "$setupPath,0", $stringKind)
        $key.SetValue("UninstallString", $uninstallCommand, $stringKind)
        $key.SetValue("QuietUninstallString", $uninstallCommand, $stringKind)
        $key.SetValue("NoModify", 1, $dwordKind)
        $key.SetValue("NoRepair", 1, $dwordKind)
        $key.SetValue("EstimatedSize", $estimatedSize, $dwordKind)
        $key.SetValue("InstallDate", (Get-Date -Format "yyyyMMdd"), $stringKind)
        $key.SetValue("VersionMajor", $parsedVersion.Major, $dwordKind)
        $key.SetValue("VersionMinor", $parsedVersion.Minor, $dwordKind)
        $key.SetValue(
            "URLInfoAbout",
            "https://github.com/lycorismmoonlights/default-app-guard",
            $stringKind)
        $key.SetValue(
            "Comments",
            "Monitors Windows default video application associations.",
            $stringKind)
    } finally {
        $key.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($TaskName)) {
    throw "TaskName cannot be empty."
}
if ($TaskName.Contains('"') -or
    $TaskName.Contains("`r") -or
    $TaskName.Contains("`n")) {
    throw "TaskName contains an unsupported command-line character."
}

$sourceDirectory = Get-NormalizedPath $PSScriptRoot
$installPath = Assert-SafeDirectoryPath $InstallDirectory
$dataPath = Assert-SafeDirectoryPath $DataDirectory
$resultFile = $null
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $resultFile = [IO.Path]::GetFullPath($ResultPath)
    if ((Test-IsPathWithin -Path $resultFile -Parent $installPath) -or
        (Test-IsPathWithin -Path $resultFile -Parent $dataPath)) {
        throw "ResultPath must be outside the managed installation directories."
    }
}
if ($installPath -eq $dataPath -or
    (Test-IsPathWithin -Path $installPath -Parent $dataPath) -or
    (Test-IsPathWithin -Path $dataPath -Parent $installPath)) {
    throw "InstallDirectory and DataDirectory must not overlap."
}

$agentUri = [Uri]$AgentUrl
$loopbackHosts = @("127.0.0.1", "localhost", "::1")
if ($agentUri.Scheme -ne "http" -or
    $agentUri.Host -notin $loopbackHosts -or
    $agentUri.AbsolutePath -ne "/" -or
    -not [string]::IsNullOrEmpty($agentUri.Query) -or
    -not [string]::IsNullOrEmpty($agentUri.Fragment)) {
    throw "AgentUrl must be an HTTP loopback origin without a path or query."
}
$AgentUrl = $AgentUrl.TrimEnd("/")

$manifest = Assert-DagPackageIntegrity -PackageRoot $sourceDirectory
if ($VerifyOnly) {
    [pscustomobject]@{
        PackageVerified = $true
        Version = [string]$manifest.version
        PackagePayloadFileCount = @($manifest.payload).Count
    }
    return
}
$installParent = Split-Path -Parent $installPath
$installLeaf = Split-Path -Leaf $installPath
$transactionId = [Guid]::NewGuid().ToString("N")
$stagingPath = Assert-SafeDirectoryPath (
    Join-Path $installParent ".$installLeaf.installing-$transactionId")
$backupPath = Assert-SafeDirectoryPath (
    Join-Path $installParent ".$installLeaf.backup-$transactionId")

$dataPathExisted = Test-Path -LiteralPath $dataPath
$runtimePath = Join-Path $dataPath "runtime"
$statePath = Join-Path $runtimePath "agent-status.json"
$configurationPath = Join-Path $runtimePath "guard-configuration.json"
$installStatePath = Join-Path $dataPath "install-state.json"
$installStateBackupPath = $null
$previousInstallState = $null
if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
    try {
        $previousInstallState = Get-Content `
            -LiteralPath $installStatePath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        Write-Warning "Existing install-state.json could not be parsed."
    }
}

$previousVersion = $null
if (Test-Path -LiteralPath $installPath -PathType Container) {
    $installedManifestPath = Join-Path $installPath "package-manifest.json"
    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
        throw "Refusing to replace an unrecognized install directory."
    }
    try {
        $installedManifest = Get-Content `
            -LiteralPath $installedManifestPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
        $previousVersion = [string]$installedManifest.version
    } catch {
        throw "Existing package manifest could not be parsed."
    }
}

$agentArguments = @(
    "--url `"$AgentUrl`""
    "--state `"$statePath`""
    "--config `"$configurationPath`""
) -join " "
$watchdogArguments = "--watchdog $agentArguments"
$installedExecutable = Join-Path $installPath `
    ([string]$manifest.executable)
$installedSetup = Join-Path $installPath "DefaultAppGuard.Setup.exe"
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$existingTask = Get-ScheduledTask -TaskName $TaskName `
    -ErrorAction SilentlyContinue
$existingTaskXml = $null
$existingTaskEnabled = $false
if ($null -ne $existingTask) {
    $existingTaskXml = Export-ScheduledTask -TaskName $TaskName
    $existingTaskEnabled = [bool]$existingTask.Settings.Enabled
}

$uninstallSubKeyPath = (
    "Software\Microsoft\Windows\CurrentVersion\Uninstall\" +
    $UninstallRegistryKeyName)
$uninstallRegistrySnapshot = Get-UninstallRegistrySnapshot `
    -SubKeyPath $uninstallSubKeyPath
if ($null -ne $uninstallRegistrySnapshot) {
    $registeredName = [string](Get-UninstallSnapshotValue `
        -Snapshot $uninstallRegistrySnapshot `
        -Name "DisplayName")
    $registeredLocation = [string](Get-UninstallSnapshotValue `
        -Snapshot $uninstallRegistrySnapshot `
        -Name "InstallLocation")
    if ($registeredName -ne "DefaultAppGuard Community") {
        throw "Refusing to replace an uninstall entry owned by another product."
    }
    if ([string]::IsNullOrWhiteSpace($registeredLocation) -or
        (Get-NormalizedPath $registeredLocation) -ne $installPath) {
        throw "Refusing to replace an uninstall entry owned by another installation."
    }
}

$shortcutPath = Join-Path $env:APPDATA `
    "Microsoft\Windows\Start Menu\Programs\DefaultAppGuard.lnk"
$shortcutBackupPath = $null
$previousShortcutPath = if ($null -ne $previousInstallState -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$previousInstallState.shortcutPath)) {
    Get-NormalizedPath ([string]$previousInstallState.shortcutPath)
} else {
    $null
}
$shouldManageShortcut = -not $NoStartMenuShortcut -or
    ($null -ne $previousShortcutPath -and
        $previousShortcutPath -eq (Get-NormalizedPath $shortcutPath))
$shortcutPreviouslyExisted = $shouldManageShortcut -and
    (Test-Path -LiteralPath $shortcutPath)
if ($shortcutPreviouslyExisted) {
    $shortcutBackupPath = Join-Path ([IO.Path]::GetTempPath()) (
        "DefaultAppGuard-shortcut-$transactionId.lnk")
}

try {
    New-Item `
        -ItemType Directory `
        -Path $installParent `
        -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    Get-ChildItem -LiteralPath $sourceDirectory -Force |
        Copy-Item -Destination $stagingPath -Recurse -Force
    [void](Assert-DagPackageIntegrity -PackageRoot $stagingPath)
    if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
        $installStateBackupPath = Join-Path ([IO.Path]::GetTempPath()) (
            "DefaultAppGuard-install-state-$transactionId.json")
        Copy-Item `
            -LiteralPath $installStatePath `
            -Destination $installStateBackupPath
    }
    if ($shortcutPreviouslyExisted) {
        Copy-Item `
            -LiteralPath $shortcutPath `
            -Destination $shortcutBackupPath
    }
} catch {
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        Remove-DirectoryWithRetry -Path $stagingPath
    }
    if ($null -ne $shortcutBackupPath -and
        (Test-Path -LiteralPath $shortcutBackupPath)) {
        Remove-Item -LiteralPath $shortcutBackupPath -Force
    }
    if ($null -ne $installStateBackupPath -and
        (Test-Path -LiteralPath $installStateBackupPath)) {
        Remove-Item -LiteralPath $installStateBackupPath -Force
    }
    throw
}

$swapCompleted = $false
$transactionSucceeded = $false
$installationResult = $null
try {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

    if ($null -ne $existingTask) {
        Disable-ScheduledTask -TaskName $TaskName | Out-Null
        Stop-ScheduledTask -TaskName $TaskName `
            -ErrorAction SilentlyContinue
    }
    Stop-InstalledAgent -ExecutablePath $installedExecutable

    if (Test-Path -LiteralPath $installPath -PathType Container) {
        Move-Item -LiteralPath $installPath -Destination $backupPath
    }
    Move-Item -LiteralPath $stagingPath -Destination $installPath
    $swapCompleted = $true

    $scheduledTask = New-WatchdogScheduledTask `
        -ExecutablePath $installedSetup `
        -WorkingDirectory $installPath `
        -Arguments $watchdogArguments `
        -CurrentUser $currentUser `
        -IntervalMinutes $WatchdogIntervalMinutes
    Register-ScheduledTask `
        -TaskName $TaskName `
        -InputObject $scheduledTask `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    $agent = Wait-AgentReady `
        -Url $AgentUrl `
        -ExecutablePath $installedExecutable `
        -ExpectedVersion ([string]$manifest.version) `
        -TimeoutSeconds $HealthTimeoutSeconds
    $watchdogTask = Wait-WatchdogTaskReady `
        -TaskName $TaskName `
        -TimeoutSeconds $HealthTimeoutSeconds

    if ($NoStartMenuShortcut) {
        if ($shouldManageShortcut -and
            (Test-Path -LiteralPath $shortcutPath)) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
        $recordedShortcutPath = $null
    } else {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $installedExecutable
        $shortcut.Arguments = "--open-ui $agentArguments"
        $shortcut.WorkingDirectory = $installPath
        $shortcut.Description = "Open DefaultAppGuard"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        $recordedShortcutPath = $shortcutPath
    }

    $installedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    if ($null -ne $previousInstallState -and
        $null -ne $previousInstallState.installedAtUtc) {
        $installedAtUtc = [string]$previousInstallState.installedAtUtc
    }
    $installState = [ordered]@{
        schemaVersion = 2
        version = [string]$manifest.version
        previousVersion = $previousVersion
        installDirectory = $installPath
        dataDirectory = $dataPath
        taskName = $TaskName
        agentUrl = $AgentUrl
        shortcutPath = $recordedShortcutPath
        watchdogIntervalMinutes = $WatchdogIntervalMinutes
        uninstallRegistryKeyName = $UninstallRegistryKeyName
        packageManifestSha256 = (
            Get-FileHash `
                -LiteralPath (
                    Join-Path $installPath "package-manifest.json") `
                -Algorithm SHA256).Hash
        packagePayloadFileCount = @($manifest.payload).Count
        installedAtUtc = $installedAtUtc
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-JsonAtomically -Value $installState -Path $installStatePath

    Set-UninstallRegistryEntry `
        -SubKeyPath $uninstallSubKeyPath `
        -Version ([string]$manifest.version) `
        -InstallDirectory $installPath `
        -DataDirectory $dataPath `
        -TaskName $TaskName `
        -RegistryKeyName $UninstallRegistryKeyName

    $installationResult = [pscustomobject]@{
        Installed = $true
        TransactionalUpgrade = $true
        InstallDirectory = $installPath
        DataDirectory = $dataPath
        TaskName = $TaskName
        AgentUrl = $AgentUrl
        Version = $agent.Health.Version
        ProcessId = $agent.ProcessId
        ProcessMode = $agent.Health.ProcessMode
        MainQuery = $agent.Health.Query
        MainMonitor = $agent.Health.Monitor
        NotificationChannel = $agent.Health.NotificationChannel
        NotificationsAvailable = $agent.Health.NotificationsAvailable
        NotificationsEnabled = $agent.Health.NotificationsEnabled
        OperationalLogChannel = $agent.Health.OperationalLogChannel
        OperationalLogsAvailable = $agent.Health.OperationalLogsAvailable
        OperationalLogFormat = $agent.Health.OperationalLogFormat
        OperationalLogFileSizeLimitBytes =
            $agent.Health.OperationalLogFileSizeLimitBytes
        OperationalLogRetainedFileCountLimit =
            $agent.Health.OperationalLogRetainedFileCountLimit
        Ready = $agent.Readiness.Ready
        ReadinessCode = $agent.Readiness.Code
        TargetProgId = $agent.Readiness.TargetProgId
        TargetPackageId = $agent.Readiness.TargetPackageId
        AuditedExtensionCount = $agent.Readiness.AuditedExtensionCount
        PrimarySnapshotCount = $agent.Readiness.PrimarySnapshotCount
        FailedReadCount = $agent.Readiness.FailedReadCount
        HealthyCount = $agent.Readiness.HealthyCount
        DriftCount = $agent.Readiness.DriftCount
        PackageIntegrityVerified = $true
        PackagePayloadFileCount = @($manifest.payload).Count
        WatchdogIntervalMinutes = $WatchdogIntervalMinutes
        WatchdogTaskState = [string]$watchdogTask.State
        UninstallRegistryKeyName = $UninstallRegistryKeyName
        UninstallRegistered = $true
    }
    if ($null -ne $resultFile) {
        New-Item `
            -ItemType Directory `
            -Path (Split-Path -Parent $resultFile) `
            -Force | Out-Null
        Write-JsonAtomically -Value $installationResult -Path $resultFile
    }
    $transactionSucceeded = $true
} catch {
    $installFailure = $_.Exception.Message
    $rollbackFailure = $null
    try {
        Stop-ScheduledTask -TaskName $TaskName `
            -ErrorAction SilentlyContinue
        Unregister-ScheduledTask `
            -TaskName $TaskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
        Stop-InstalledAgent -ExecutablePath $installedExecutable

        if ($swapCompleted -and
            (Test-Path -LiteralPath $installPath -PathType Container)) {
            Remove-DirectoryWithRetry -Path $installPath
        }
        if (Test-Path -LiteralPath $backupPath -PathType Container) {
            Move-Item -LiteralPath $backupPath -Destination $installPath
        }

        if ($null -ne $existingTaskXml) {
            Register-ScheduledTask `
                -TaskName $TaskName `
                -Xml $existingTaskXml `
                -Force | Out-Null
            if ($existingTaskEnabled) {
                Start-ScheduledTask -TaskName $TaskName
            }
        }

        if ($shouldManageShortcut) {
            if ($shortcutPreviouslyExisted -and
                $null -ne $shortcutBackupPath) {
                Copy-Item `
                    -LiteralPath $shortcutBackupPath `
                    -Destination $shortcutPath `
                    -Force
            } elseif (Test-Path -LiteralPath $shortcutPath) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }
        }

        Restore-UninstallRegistrySnapshot `
            -SubKeyPath $uninstallSubKeyPath `
            -Snapshot $uninstallRegistrySnapshot

        if ($dataPathExisted) {
            if ($null -ne $installStateBackupPath -and
                (Test-Path -LiteralPath $installStateBackupPath -PathType Leaf)) {
                Copy-Item `
                    -LiteralPath $installStateBackupPath `
                    -Destination $installStatePath `
                    -Force
            } elseif (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
                Remove-Item -LiteralPath $installStatePath -Force
            }
        } elseif (
            (Test-Path -LiteralPath $dataPath -PathType Container)) {
            Remove-DirectoryWithRetry -Path $dataPath
        }
    } catch {
        $rollbackFailure = $_.Exception.Message
    }

    if ($null -ne $rollbackFailure) {
        throw [InvalidOperationException]::new(
            "Installation failed: $installFailure Rollback also failed: " +
            $rollbackFailure)
    }
    throw [InvalidOperationException]::new(
        "Installation failed and the previous installation was restored: " +
        $installFailure)
} finally {
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        Remove-DirectoryWithRetry -Path $stagingPath
    }
    if ($null -ne $shortcutBackupPath -and
        (Test-Path -LiteralPath $shortcutBackupPath)) {
        Remove-Item -LiteralPath $shortcutBackupPath -Force
    }
    if ($null -ne $installStateBackupPath -and
        (Test-Path -LiteralPath $installStateBackupPath)) {
        Remove-Item -LiteralPath $installStateBackupPath -Force
    }
}

if ($transactionSucceeded -and
    (Test-Path -LiteralPath $backupPath -PathType Container)) {
    try {
        Remove-DirectoryWithRetry -Path $backupPath
    } catch {
        Write-Warning "Upgrade succeeded, but the backup could not be removed."
    }
}

$installationResult
