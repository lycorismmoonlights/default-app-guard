[CmdletBinding()]
param(
    [string]$InstallDirectory = (
        Join-Path $env:LOCALAPPDATA "Programs\DefaultAppGuard"),
    [string]$DataDirectory = (
        Join-Path $env:LOCALAPPDATA "DefaultAppGuard"),
    [string]$TaskName = "DefaultAppGuard Agent",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._ -]{0,79}$')]
    [string]$UninstallRegistryKeyName = "DefaultAppGuard Community",
    [switch]$KeepData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-RemovableDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker
    )

    $normalized = Get-NormalizedPath $Path
    $root = [System.IO.Path]::GetPathRoot($normalized).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar)
    if ($normalized -eq $root -or $normalized.Length -le ($root.Length + 3)) {
        throw "Refusing to remove unsafe directory: $normalized"
    }
    if (-not (Test-Path -LiteralPath (
        Join-Path $normalized $Marker))) {
        throw "Refusing to remove an unrecognized directory: $normalized"
    }

    return $normalized
}

function Remove-DirectoryWithRetry {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force `
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

$installPath = Get-NormalizedPath $InstallDirectory
$dataPath = Get-NormalizedPath $DataDirectory
$installedExecutable = Join-Path $installPath `
    "DefaultAppGuard.Agent.exe"

$verifiedInstall = $null
$packageManifest = $null
if (Test-Path -LiteralPath $installPath -PathType Container) {
    $verifiedInstall = Assert-RemovableDirectory `
        -Path $installPath `
        -Marker "package-manifest.json"
    try {
        $packageManifest = Get-Content `
            -LiteralPath (
                Join-Path $verifiedInstall "package-manifest.json") `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        throw "Refusing to remove an installation with an unreadable manifest."
    }
    if ($packageManifest.product -ne "DefaultAppGuard Community") {
        throw "Refusing to remove an installation for another product."
    }
}

$installState = $null
$verifiedData = $null
if (Test-Path -LiteralPath $dataPath -PathType Container) {
    $installStatePath = Join-Path $dataPath "install-state.json"
    if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
        try {
            $installState = Get-Content `
                -LiteralPath $installStatePath `
                -Raw `
                -Encoding UTF8 |
                ConvertFrom-Json
        } catch {
            throw "Refusing to remove data with an unreadable install state."
        }
        if ((Get-NormalizedPath $installState.installDirectory) -ne
            $installPath -or
            (Get-NormalizedPath $installState.dataDirectory) -ne $dataPath -or
            [string]$installState.taskName -ne $TaskName) {
            throw "Refusing to remove data owned by another installation."
        }
        $uninstallKeyProperty =
            $installState.PSObject.Properties["uninstallRegistryKeyName"]
        if ($null -ne $uninstallKeyProperty -and
            -not [string]::IsNullOrWhiteSpace(
                [string]$uninstallKeyProperty.Value) -and
            [string]$uninstallKeyProperty.Value -ne
                $UninstallRegistryKeyName) {
            throw "Refusing to remove an uninstall entry owned by another installation."
        }
    } elseif (-not $KeepData) {
        throw "Refusing to remove data without install-state.json."
    }

    if (-not $KeepData) {
        $verifiedData = Assert-RemovableDirectory `
            -Path $dataPath `
            -Marker "install-state.json"
    }
}

$uninstallSubKeyPath = (
    "Software\Microsoft\Windows\CurrentVersion\Uninstall\" +
    $UninstallRegistryKeyName)
$uninstallEntryPresent = $false
$uninstallKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $uninstallSubKeyPath)
if ($null -ne $uninstallKey) {
    try {
        $registeredName = [string]$uninstallKey.GetValue("DisplayName")
        $registeredLocation = [string]$uninstallKey.GetValue("InstallLocation")
        if ($registeredName -ne "DefaultAppGuard Community" -or
            [string]::IsNullOrWhiteSpace($registeredLocation) -or
            (Get-NormalizedPath $registeredLocation) -ne $installPath) {
            throw "Refusing to remove an uninstall entry owned by another product."
        }
        $uninstallEntryPresent = $true
    } finally {
        $uninstallKey.Dispose()
    }
}

$task = Get-ScheduledTask -TaskName $TaskName `
    -ErrorAction SilentlyContinue
if ($null -ne $task) {
    $taskExecutable = Get-NormalizedPath $task.Actions[0].Execute
    if ($taskExecutable -ne (Get-NormalizedPath $installedExecutable)) {
        throw "Refusing to remove a scheduled task owned by another installation."
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$targetExecutable = Get-NormalizedPath $installedExecutable
$processes = Get-CimInstance Win32_Process -Filter `
    "Name='DefaultAppGuard.Agent.exe'"
foreach ($process in $processes) {
    if ([string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
        continue
    }

    if ((Get-NormalizedPath $process.ExecutablePath) -eq
        $targetExecutable) {
        Stop-Process -Id $process.ProcessId -Force
        Wait-Process -Id $process.ProcessId -Timeout 10 `
            -ErrorAction SilentlyContinue
    }
}

$shortcutPath = if ($null -ne $installState) {
    if (-not [string]::IsNullOrWhiteSpace($installState.shortcutPath)) {
        [string]$installState.shortcutPath
    } else {
        $null
    }
} else {
    Join-Path $env:APPDATA `
        "Microsoft\Windows\Start Menu\Programs\DefaultAppGuard.lnk"
}
if (-not [string]::IsNullOrWhiteSpace($shortcutPath) -and
    (Test-Path -LiteralPath $shortcutPath)) {
    Remove-Item -LiteralPath $shortcutPath -Force
}

if (-not $KeepData -and $null -ne $verifiedData) {
    Remove-DirectoryWithRetry $verifiedData
}

if ($null -ne $verifiedInstall) {
    Remove-DirectoryWithRetry $verifiedInstall
}

if ($uninstallEntryPresent) {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $uninstallSubKeyPath,
        $false)
}

[pscustomobject]@{
    Uninstalled = $true
    TaskRemoved = $null -ne $task
    DataKept = [bool]$KeepData
    UninstallRegistrationRemoved = $uninstallEntryPresent
}
