[CmdletBinding()]
param(
    [string]$AgentUrl = "http://127.0.0.1:51873",
    [ValidateRange(2, 30)]
    [int]$TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-RegistryEventCount {
    param(
        [Parameter(Mandatory)][int]$GreaterThan,
        [Parameter(Mandatory)][DateTime]$Deadline
    )

    do {
        Start-Sleep -Milliseconds 200
        $status = Invoke-RestMethod `
            -Uri "$($AgentUrl.TrimEnd('/'))/api/status" `
            -TimeoutSec 1
        if ([int]$status.registryEventCount -gt $GreaterThan) {
            return $status
        }
    } until ([DateTime]::UtcNow -ge $Deadline)

    throw "Installed Agent did not receive the registry change."
}

$health = Invoke-RestMethod `
    -Uri "$($AgentUrl.TrimEnd('/'))/api/health" `
    -TimeoutSec 2
if ($health.Query -ne
    "IApplicationAssociationRegistration.QueryCurrentDefault" -or
    $health.Monitor -ne "RegNotifyChangeKeyValue") {
    throw "Installed Agent is not reporting the primary algorithms."
}

$before = Invoke-RestMethod `
    -Uri "$($AgentUrl.TrimEnd('/'))/api/status" `
    -TimeoutSec 2
$probePath = (
    "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\" +
    ".defaultappguard-probe-{0}" -f [Guid]::NewGuid().ToString("N"))

try {
    $probe = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($probePath)
    if ($null -eq $probe) {
        throw "Could not create the monitor probe key."
    }
    $probe.Dispose()

    $first = Wait-RegistryEventCount `
        -GreaterThan ([int]$before.registryEventCount) `
        -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
    Start-Sleep -Milliseconds 300

    $probe = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $probePath,
        $true)
    if ($null -eq $probe) {
        throw "Could not reopen the monitor probe key."
    }
    try {
        $probe.SetValue(
            "RearmProbe",
            [Guid]::NewGuid().ToString("N"),
            [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $probe.Dispose()
    }

    $second = Wait-RegistryEventCount `
        -GreaterThan ([int]$first.registryEventCount) `
        -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds))
} finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
        $probePath,
        $false)
}

Start-Sleep -Milliseconds 500
$after = Invoke-RestMethod `
    -Uri "$($AgentUrl.TrimEnd('/'))/api/status" `
    -TimeoutSec 2
if (-not [bool]$after.audit.healthy -or
    [int]$after.audit.driftCount -ne 0) {
    throw "Installed Agent audit was unhealthy after the monitor probe."
}

[pscustomobject]@{
    InstalledMonitorVerified = $true
    BeforeEventCount = $before.registryEventCount
    FirstNotificationCount = $first.registryEventCount
    RearmedNotificationCount = $second.registryEventCount
    ProbeRemoved = $null -eq (
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probePath))
    MainQuery = $health.Query
    MainMonitor = $health.Monitor
    HealthyCount = $after.audit.healthyCount
    DriftCount = $after.audit.driftCount
}
