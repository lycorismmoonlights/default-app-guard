[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,
    [Parameter(Mandatory)]
    [string]$InstallDirectory,
    [Parameter(Mandatory)]
    [string]$DataDirectory,
    [string]$TaskName = "DefaultAppGuard Agent",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._ -]{0,79}$')]
    [string]$UninstallRegistryKeyName = "DefaultAppGuard Community",
    [string]$ExistingAgentUrl = "http://127.0.0.1:51873",
    [string]$BlockedAgentUrl = "http://127.0.0.1:51874",
    [string]$ExpectedPreviousVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-InstalledAgent {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    return Get-CimInstance Win32_Process -Filter `
        "Name='DefaultAppGuard.Agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $ExecutablePath }
}

function Wait-ExistingAgentHealthy {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $health = Invoke-RestMethod `
                -Uri "$($Url.TrimEnd('/'))/api/health" `
                -TimeoutSec 1
            $status = Invoke-RestMethod `
                -Uri "$($Url.TrimEnd('/'))/api/status" `
                -TimeoutSec 1
            $readiness = Invoke-RestMethod `
                -Uri "$($Url.TrimEnd('/'))/api/readiness" `
                -TimeoutSec 1
            if ([bool]$readiness.ready) {
                return [pscustomobject]@{
                    Health = $health
                    Status = $status
                    Readiness = $readiness
                }
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    } until ([DateTime]::UtcNow -ge $deadline)

    throw "The previous Agent did not become healthy after rollback."
}

function Get-UninstallEntryFingerprint {
    param([Parameter(Mandatory)][string]$SubKeyPath)

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKeyPath)
    if ($null -eq $key) {
        throw "The uninstall registry entry is missing."
    }
    try {
        return [ordered]@{
            DisplayName = [string]$key.GetValue("DisplayName")
            DisplayVersion = [string]$key.GetValue("DisplayVersion")
            InstallLocation = [string]$key.GetValue("InstallLocation")
            UninstallString = [string]$key.GetValue("UninstallString")
            QuietUninstallString = [string]$key.GetValue("QuietUninstallString")
            NoModify = [int]$key.GetValue("NoModify", 0)
            NoRepair = [int]$key.GetValue("NoRepair", 0)
        } | ConvertTo-Json -Compress
    } finally {
        $key.Dispose()
    }
}

$packagePath = [IO.Path]::GetFullPath($PackageDirectory)
$installPath = [IO.Path]::GetFullPath($InstallDirectory)
$dataPath = [IO.Path]::GetFullPath($DataDirectory)
$installerPath = Join-Path $packagePath "Install-DefaultAppGuard.ps1"
$executablePath = Join-Path $installPath "DefaultAppGuard.Agent.exe"
$manifestPath = Join-Path $installPath "package-manifest.json"
$installStatePath = Join-Path $dataPath "install-state.json"
$uninstallSubKeyPath = (
    "Software\Microsoft\Windows\CurrentVersion\Uninstall\" +
    $UninstallRegistryKeyName)
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Candidate installer is missing."
}

$blockedUri = [Uri]$BlockedAgentUrl
if (-not $blockedUri.IsLoopback -or
    $blockedUri.Scheme -ne [Uri]::UriSchemeHttp -or
    $blockedUri.Port -lt 1024) {
    throw "BlockedAgentUrl must use an unprivileged loopback HTTP port."
}

$beforeManifest = Get-Content `
    -LiteralPath $manifestPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
if (-not [string]::IsNullOrWhiteSpace($ExpectedPreviousVersion) -and
    $beforeManifest.version -ne $ExpectedPreviousVersion) {
    throw "Installed version does not match ExpectedPreviousVersion."
}
$beforeHash = (Get-FileHash `
    -LiteralPath $executablePath `
    -Algorithm SHA256).Hash
$beforeInstallStateHash = (Get-FileHash `
    -LiteralPath $installStatePath `
    -Algorithm SHA256).Hash
$beforeTask = Get-ScheduledTask -TaskName $TaskName
$beforeAction = $beforeTask.Actions[0].Execute
$beforeArguments = $beforeTask.Actions[0].Arguments
$beforeUninstallEntry = Get-UninstallEntryFingerprint `
    -SubKeyPath $uninstallSubKeyPath
$beforeProcess = Get-InstalledAgent -ExecutablePath $executablePath
if (@($beforeProcess).Count -ne 1) {
    throw "Expected exactly one installed Agent before the rollback test."
}

$readyFile = Join-Path $dataPath (
    "rollback-port-{0}.ready" -f [Guid]::NewGuid().ToString("N"))
$helperPath = Join-Path $PSScriptRoot "Hold-LoopbackPort.ps1"
$powerShellPath = Join-Path $env:SystemRoot `
    "System32\WindowsPowerShell\v1.0\powershell.exe"
$helperArguments = @(
    "-NoProfile"
    "-ExecutionPolicy Bypass"
    "-File `"$helperPath`""
    "-Port $($blockedUri.Port)"
    "-ReadyFile `"$readyFile`""
) -join " "
$holder = Start-Process `
    -FilePath $powerShellPath `
    -ArgumentList $helperArguments `
    -WindowStyle Hidden `
    -PassThru
$lateFailureParent = Join-Path (Split-Path -Parent $dataPath) (
    "late-rollback-result-parent-{0}" -f [Guid]::NewGuid().ToString("N"))

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyFile) -and
        [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $readyFile)) {
        throw "The loopback port holder did not become ready."
    }

    $failureMessage = $null
    try {
        & $installerPath `
            -InstallDirectory $installPath `
            -DataDirectory $dataPath `
            -TaskName $TaskName `
            -UninstallRegistryKeyName $UninstallRegistryKeyName `
            -AgentUrl $BlockedAgentUrl `
            -WatchdogIntervalMinutes 5 `
            -HealthTimeoutSeconds 5 `
            -NoStartMenuShortcut
    } catch {
        $failureMessage = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($failureMessage) -or
        $failureMessage -notlike
        "*previous installation was restored*") {
        throw "The candidate upgrade did not report a successful rollback."
    }

    $restored = Wait-ExistingAgentHealthy `
        -Url $ExistingAgentUrl `
        -TimeoutSeconds 20
    $afterManifest = Get-Content `
        -LiteralPath $manifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    $afterHash = (Get-FileHash `
        -LiteralPath $executablePath `
        -Algorithm SHA256).Hash
    $afterTask = Get-ScheduledTask -TaskName $TaskName
    $afterUninstallEntry = Get-UninstallEntryFingerprint `
        -SubKeyPath $uninstallSubKeyPath
    $afterProcess = Get-InstalledAgent -ExecutablePath $executablePath
    $transactionResidue = @(
        Get-ChildItem `
            -LiteralPath (Split-Path -Parent $installPath) `
            -Directory `
            -Force |
            Where-Object {
                $installLeaf = Split-Path -Leaf $installPath
                $_.Name -like ".$installLeaf.installing-*" -or
                $_.Name -like ".$installLeaf.backup-*"
            })

    $checks = [ordered]@{
        versionRestored =
            $afterManifest.version -eq $beforeManifest.version
        executableRestored = $afterHash -eq $beforeHash
        taskActionRestored =
            $afterTask.Actions[0].Execute -eq $beforeAction
        taskArgumentsRestored =
            $afterTask.Actions[0].Arguments -eq $beforeArguments
        uninstallEntryRestored =
            $afterUninstallEntry -eq $beforeUninstallEntry
        oneAgentRunning = @($afterProcess).Count -eq 1
        primaryQuery =
            $restored.Readiness.Query -eq
            "IApplicationAssociationRegistration.QueryCurrentDefault"
        primaryMonitor =
            $restored.Readiness.Monitor -eq "RegNotifyChangeKeyValue"
        associationsHealthy =
            [bool]$restored.Readiness.Ready -and
            [bool]$restored.Readiness.AuditFresh -and
            [int]$restored.Readiness.ExpectedHandlerCount -eq
                [int]$restored.Readiness.ResolvedHandlerCount -and
            [int]$restored.Readiness.AuditedExtensionCount -eq
                [int]$restored.Readiness.PrimarySnapshotCount -and
            [int]$restored.Readiness.ExpectedHandlerCount -eq
                [int]$restored.Readiness.AuditedExtensionCount -and
            [int]$restored.Readiness.FailedReadCount -eq 0 -and
            [int]$restored.Readiness.DriftCount -eq 0
        noTransactionResidue = $transactionResidue.Count -eq 0
    }
    $failedChecks = @(
        $checks.GetEnumerator() |
            Where-Object { -not $_.Value } |
            ForEach-Object Key)
    if ($failedChecks.Count -ne 0) {
        throw "Rollback checks failed: $($failedChecks -join ', ')"
    }

    "This file intentionally prevents creation of a result directory." |
        Set-Content -LiteralPath $lateFailureParent -Encoding Ascii
    $lateFailureMessage = $null
    try {
        & $installerPath `
            -InstallDirectory $installPath `
            -DataDirectory $dataPath `
            -TaskName $TaskName `
            -UninstallRegistryKeyName $UninstallRegistryKeyName `
            -AgentUrl $ExistingAgentUrl `
            -WatchdogIntervalMinutes 5 `
            -HealthTimeoutSeconds 20 `
            -NoStartMenuShortcut `
            -ResultPath (Join-Path $lateFailureParent "result.json")
    } catch {
        $lateFailureMessage = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($lateFailureMessage) -or
        $lateFailureMessage -notlike
        "*previous installation was restored*") {
        throw "A late installation failure did not report a successful rollback."
    }

    $lateRestored = Wait-ExistingAgentHealthy `
        -Url $ExistingAgentUrl `
        -TimeoutSeconds 20
    $lateManifest = Get-Content `
        -LiteralPath $manifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    $lateTask = Get-ScheduledTask -TaskName $TaskName
    $lateProcess = Get-InstalledAgent -ExecutablePath $executablePath
    $lateUninstallEntry = Get-UninstallEntryFingerprint `
        -SubKeyPath $uninstallSubKeyPath
    $lateInstallStateHash = (Get-FileHash `
        -LiteralPath $installStatePath `
        -Algorithm SHA256).Hash
    $lateTransactionResidue = @(
        Get-ChildItem `
            -LiteralPath (Split-Path -Parent $installPath) `
            -Directory `
            -Force |
            Where-Object {
                $installLeaf = Split-Path -Leaf $installPath
                $_.Name -like ".$installLeaf.installing-*" -or
                $_.Name -like ".$installLeaf.backup-*"
            })
    $lateChecks = [ordered]@{
        versionRestored =
            $lateManifest.version -eq $beforeManifest.version
        executableRestored = (Get-FileHash `
            -LiteralPath $executablePath `
            -Algorithm SHA256).Hash -eq $beforeHash
        installStateRestored =
            $lateInstallStateHash -eq $beforeInstallStateHash
        taskActionRestored =
            $lateTask.Actions[0].Execute -eq $beforeAction
        taskArgumentsRestored =
            $lateTask.Actions[0].Arguments -eq $beforeArguments
        uninstallEntryRestored =
            $lateUninstallEntry -eq $beforeUninstallEntry
        oneAgentRunning = @($lateProcess).Count -eq 1
        primaryQuery =
            $lateRestored.Readiness.Query -eq
            "IApplicationAssociationRegistration.QueryCurrentDefault"
        primaryMonitor =
            $lateRestored.Readiness.Monitor -eq "RegNotifyChangeKeyValue"
        associationsHealthy =
            [bool]$lateRestored.Readiness.Ready -and
            [bool]$lateRestored.Readiness.AuditFresh -and
            [int]$lateRestored.Readiness.ExpectedHandlerCount -eq
                [int]$lateRestored.Readiness.ResolvedHandlerCount -and
            [int]$lateRestored.Readiness.AuditedExtensionCount -eq
                [int]$lateRestored.Readiness.PrimarySnapshotCount -and
            [int]$lateRestored.Readiness.ExpectedHandlerCount -eq
                [int]$lateRestored.Readiness.AuditedExtensionCount -and
            [int]$lateRestored.Readiness.FailedReadCount -eq 0 -and
            [int]$lateRestored.Readiness.DriftCount -eq 0
        noTransactionResidue = $lateTransactionResidue.Count -eq 0
    }
    $failedLateChecks = @(
        $lateChecks.GetEnumerator() |
            Where-Object { -not $_.Value } |
            ForEach-Object Key)
    if ($failedLateChecks.Count -ne 0) {
        throw "Late rollback checks failed: $($failedLateChecks -join ', ')"
    }

    [pscustomobject]@{
        RollbackVerified = $true
        LateRollbackVerified = $true
        FailureMessage = $failureMessage
        LateFailureMessage = $lateFailureMessage
        RestoredVersion = $afterManifest.version
        PreviousProcessId = $beforeProcess.ProcessId
        RestoredProcessId = $afterProcess.ProcessId
        HealthyCount = $restored.Readiness.HealthyCount
        DriftCount = $restored.Readiness.DriftCount
        MainQuery = $restored.Readiness.Query
        MainMonitor = $restored.Readiness.Monitor
        TransactionResidueCount = $transactionResidue.Count
        UninstallEntryRestored =
            $lateUninstallEntry -eq $beforeUninstallEntry
        InstallStateRestored =
            $lateInstallStateHash -eq $beforeInstallStateHash
    }
} finally {
    Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $readyFile) {
        Remove-Item -LiteralPath $readyFile -Force
    }
    if (Test-Path -LiteralPath $lateFailureParent -PathType Leaf) {
        Remove-Item -LiteralPath $lateFailureParent -Force
    }
}
