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
    [switch]$NoStartMenuShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar)
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

$sourceDirectory = Get-NormalizedPath $PSScriptRoot
$installPath = Get-NormalizedPath $InstallDirectory
$dataPath = Get-NormalizedPath $DataDirectory
$sourceExecutable = Join-Path $sourceDirectory `
    "DefaultAppGuard.Agent.exe"
$sourceUi = Join-Path $sourceDirectory "wwwroot"

if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
    throw "Package executable is missing: $sourceExecutable"
}
if (-not (Test-Path -LiteralPath $sourceUi -PathType Container)) {
    throw "Packaged UI is missing: $sourceUi"
}

$agentUri = [Uri]$AgentUrl
$loopbackHosts = @("127.0.0.1", "localhost", "::1")
if ($agentUri.Scheme -ne "http" -or
    $agentUri.Host -notin $loopbackHosts) {
    throw "AgentUrl must be an HTTP loopback address."
}

$existingTask = Get-ScheduledTask -TaskName $TaskName `
    -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

$installedExecutable = Join-Path $installPath `
    "DefaultAppGuard.Agent.exe"
Stop-InstalledAgent $installedExecutable

New-Item -ItemType Directory -Path $installPath -Force | Out-Null
New-Item -ItemType Directory -Path $dataPath -Force | Out-Null

Get-ChildItem -LiteralPath $sourceDirectory -File |
    Where-Object {
        $_.Name -notin @(
            "Install-DefaultAppGuard.ps1",
            "Uninstall-DefaultAppGuard.ps1")
    } |
    Copy-Item -Destination $installPath -Force
Copy-Item -LiteralPath $sourceUi -Destination $installPath `
    -Recurse -Force
Copy-Item `
    -LiteralPath (Join-Path $sourceDirectory `
        "Uninstall-DefaultAppGuard.ps1") `
    -Destination $installPath `
    -Force

$runtimePath = Join-Path $dataPath "runtime"
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
$statePath = Join-Path $runtimePath "agent-status.json"
$configurationPath = Join-Path $runtimePath `
    "guard-configuration.json"
$taskArguments = @(
    "--url `"$AgentUrl`""
    "--state `"$statePath`""
    "--config `"$configurationPath`""
) -join " "

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction `
    -Execute $installedExecutable `
    -Argument $taskArguments `
    -WorkingDirectory $installPath
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$watchdogTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At ((Get-Date).AddMinutes(1)) `
    -RepetitionInterval (
        New-TimeSpan -Minutes $WatchdogIntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$task = New-ScheduledTask `
    -Action $action `
    -Trigger @($logonTrigger, $watchdogTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description "Monitors the current user's Windows default video applications."
Register-ScheduledTask `
    -TaskName $TaskName `
    -InputObject $task `
    -Force | Out-Null

$shortcutPath = $null
if (-not $NoStartMenuShortcut) {
    $shortcutPath = Join-Path $env:APPDATA `
        "Microsoft\Windows\Start Menu\Programs\DefaultAppGuard.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $installedExecutable
    $shortcut.Arguments = "--open-ui $taskArguments"
    $shortcut.WorkingDirectory = $installPath
    $shortcut.Description = "Open DefaultAppGuard"
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

$installState = [ordered]@{
    schemaVersion = 1
    installDirectory = $installPath
    dataDirectory = $dataPath
    taskName = $TaskName
    agentUrl = $AgentUrl
    shortcutPath = $shortcutPath
    watchdogIntervalMinutes = $WatchdogIntervalMinutes
    installedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
}
$installState |
    ConvertTo-Json |
    Set-Content `
        -LiteralPath (Join-Path $dataPath "install-state.json") `
        -Encoding UTF8

Start-ScheduledTask -TaskName $TaskName
$deadline = [DateTime]::UtcNow.AddSeconds(15)
$health = $null
do {
    Start-Sleep -Milliseconds 250
    try {
        $health = Invoke-RestMethod `
            -Uri "$AgentUrl/api/health" `
            -TimeoutSec 1
    } catch {
        $health = $null
    }
    $agentHealthy =
        $null -ne $health -and
        $health.Service -eq "DefaultAppGuard.Agent"
} until ($agentHealthy -or [DateTime]::UtcNow -ge $deadline)

if (-not $agentHealthy) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    throw "Agent did not become healthy. LastTaskResult: $($taskInfo.LastTaskResult)"
}

[pscustomobject]@{
    Installed = $true
    InstallDirectory = $installPath
    DataDirectory = $dataPath
    TaskName = $TaskName
    AgentUrl = $AgentUrl
    Version = $health.Version
    MainQuery = $health.Query
    MainMonitor = $health.Monitor
    WatchdogIntervalMinutes = $WatchdogIntervalMinutes
}
