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
    [switch]$NoStartMenuShortcut
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

function New-AgentScheduledTask {
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
        -ExecutionTimeLimit ([TimeSpan]::Zero
        )

    return New-ScheduledTask `
        -Action $action `
        -Trigger @($logonTrigger, $watchdogTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description (
            "Monitors the current user's Windows default video applications.")
}

function Wait-AgentHealthy {
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

            return [pscustomobject]@{
                Health = $health
                ProcessId = $processId
            }
        } catch {
            $lastFailure = $_.Exception.Message
        }
    } until ([DateTime]::UtcNow -ge $deadline)

    throw "Agent did not become healthy: $lastFailure"
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

if ([string]::IsNullOrWhiteSpace($TaskName)) {
    throw "TaskName cannot be empty."
}

$sourceDirectory = Get-NormalizedPath $PSScriptRoot
$installPath = Assert-SafeDirectoryPath $InstallDirectory
$dataPath = Assert-SafeDirectoryPath $DataDirectory
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

$taskArguments = @(
    "--url `"$AgentUrl`""
    "--state `"$statePath`""
    "--config `"$configurationPath`""
) -join " "
$installedExecutable = Join-Path $installPath `
    ([string]$manifest.executable)
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$existingTask = Get-ScheduledTask -TaskName $TaskName `
    -ErrorAction SilentlyContinue
$existingTaskXml = $null
$existingTaskEnabled = $false
if ($null -ne $existingTask) {
    $existingTaskXml = Export-ScheduledTask -TaskName $TaskName
    $existingTaskEnabled = [bool]$existingTask.Settings.Enabled
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
    throw
}

$swapCompleted = $false
$transactionSucceeded = $false
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

    $scheduledTask = New-AgentScheduledTask `
        -ExecutablePath $installedExecutable `
        -WorkingDirectory $installPath `
        -Arguments $taskArguments `
        -CurrentUser $currentUser `
        -IntervalMinutes $WatchdogIntervalMinutes
    Register-ScheduledTask `
        -TaskName $TaskName `
        -InputObject $scheduledTask `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    $agent = Wait-AgentHealthy `
        -Url $AgentUrl `
        -ExecutablePath $installedExecutable `
        -ExpectedVersion ([string]$manifest.version) `
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
        $shortcut.Arguments = "--open-ui $taskArguments"
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

        if (-not $dataPathExisted -and
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
}

if ($transactionSucceeded -and
    (Test-Path -LiteralPath $backupPath -PathType Container)) {
    try {
        Remove-DirectoryWithRetry -Path $backupPath
    } catch {
        Write-Warning "Upgrade succeeded, but the backup could not be removed."
    }
}

[pscustomobject]@{
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
    PackageIntegrityVerified = $true
    PackagePayloadFileCount = @($manifest.payload).Count
    WatchdogIntervalMinutes = $WatchdogIntervalMinutes
}
