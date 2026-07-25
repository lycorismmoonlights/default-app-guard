[CmdletBinding()]
param(
    [string]$InstallDirectory = (
        Join-Path $env:LOCALAPPDATA "Programs\DefaultAppGuard"),
    [string]$DataDirectory = (
        Join-Path $env:LOCALAPPDATA "DefaultAppGuard"),
    [string]$TaskName = "DefaultAppGuard Agent",
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

$task = Get-ScheduledTask -TaskName $TaskName `
    -ErrorAction SilentlyContinue
if ($null -ne $task) {
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

$shortcutPath = Join-Path $env:APPDATA `
    "Microsoft\Windows\Start Menu\Programs\DefaultAppGuard.lnk"
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
}

if (Test-Path -LiteralPath $installPath) {
    $verifiedInstall = Assert-RemovableDirectory `
        -Path $installPath `
        -Marker "package-manifest.json"
    Remove-DirectoryWithRetry $verifiedInstall
}

if (-not $KeepData -and (Test-Path -LiteralPath $dataPath)) {
    $verifiedData = Assert-RemovableDirectory `
        -Path $dataPath `
        -Marker "install-state.json"
    Remove-DirectoryWithRetry $verifiedData
}

[pscustomobject]@{
    Uninstalled = $true
    TaskRemoved = $null -ne $task
    DataKept = [bool]$KeepData
}
