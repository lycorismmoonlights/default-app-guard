[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,
    [Parameter(Mandatory)]
    [string]$InstallDirectory,
    [Parameter(Mandatory)]
    [string]$DataDirectory,
    [string]$TaskName = "DefaultAppGuard Agent",
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
            return [pscustomobject]@{
                Health = $health
                Status = $status
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    } until ([DateTime]::UtcNow -ge $deadline)

    throw "The previous Agent did not become healthy after rollback."
}

$packagePath = [IO.Path]::GetFullPath($PackageDirectory)
$installPath = [IO.Path]::GetFullPath($InstallDirectory)
$dataPath = [IO.Path]::GetFullPath($DataDirectory)
$installerPath = Join-Path $packagePath "Install-DefaultAppGuard.ps1"
$executablePath = Join-Path $installPath "DefaultAppGuard.Agent.exe"
$manifestPath = Join-Path $installPath "package-manifest.json"
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
$beforeTask = Get-ScheduledTask -TaskName $TaskName
$beforeAction = $beforeTask.Actions[0].Execute
$beforeArguments = $beforeTask.Actions[0].Arguments
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
    $afterProcess = Get-InstalledAgent -ExecutablePath $executablePath
    $transactionResidue = @(
        Get-ChildItem `
            -LiteralPath (Split-Path -Parent $installPath) `
            -Directory `
            -Force |
            Where-Object {
                $_.Name -like ".DefaultAppGuard.installing-*" -or
                $_.Name -like ".DefaultAppGuard.backup-*"
            })

    $checks = [ordered]@{
        versionRestored =
            $afterManifest.version -eq $beforeManifest.version
        executableRestored = $afterHash -eq $beforeHash
        taskActionRestored =
            $afterTask.Actions[0].Execute -eq $beforeAction
        taskArgumentsRestored =
            $afterTask.Actions[0].Arguments -eq $beforeArguments
        oneAgentRunning = @($afterProcess).Count -eq 1
        primaryQuery =
            $restored.Health.Query -eq
            "IApplicationAssociationRegistration.QueryCurrentDefault"
        primaryMonitor =
            $restored.Health.Monitor -eq "RegNotifyChangeKeyValue"
        associationsHealthy =
            [bool]$restored.Status.audit.healthy -and
            [int]$restored.Status.audit.driftCount -eq 0
        noTransactionResidue = $transactionResidue.Count -eq 0
    }
    $failedChecks = @(
        $checks.GetEnumerator() |
            Where-Object { -not $_.Value } |
            ForEach-Object Key)
    if ($failedChecks.Count -ne 0) {
        throw "Rollback checks failed: $($failedChecks -join ', ')"
    }

    [pscustomobject]@{
        RollbackVerified = $true
        FailureMessage = $failureMessage
        RestoredVersion = $afterManifest.version
        PreviousProcessId = $beforeProcess.ProcessId
        RestoredProcessId = $afterProcess.ProcessId
        HealthyCount = $restored.Status.audit.healthyCount
        DriftCount = $restored.Status.audit.driftCount
        MainQuery = $restored.Health.Query
        MainMonitor = $restored.Health.Monitor
        TransactionResidueCount = $transactionResidue.Count
    }
} finally {
    Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $readyFile) {
        Remove-Item -LiteralPath $readyFile -Force
    }
}
