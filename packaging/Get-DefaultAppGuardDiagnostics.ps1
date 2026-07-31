[CmdletBinding()]
param(
    [string]$InstallDirectory = (
        Join-Path $env:LOCALAPPDATA "Programs\DefaultAppGuard"),
    [string]$DataDirectory = (
        Join-Path $env:LOCALAPPDATA "DefaultAppGuard"),
    [string]$TaskName = "DefaultAppGuard Agent",
    [string]$OutputPath = (
        Join-Path (Get-Location) (
            "DefaultAppGuard-diagnostics-{0}.json" -f (
                Get-Date -Format "yyyyMMdd-HHmmss")))
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

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
}

$installPath = Get-NormalizedPath $InstallDirectory
$dataPath = Get-NormalizedPath $DataDirectory
$outputFile = [IO.Path]::GetFullPath($OutputPath)
$issues = [Collections.Generic.List[string]]::new()

$installState = $null
$installStatePath = Join-Path $dataPath "install-state.json"
if (Test-Path -LiteralPath $installStatePath -PathType Leaf) {
    try {
        $installState = Get-Content `
            -LiteralPath $installStatePath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        $issues.Add("install-state-unreadable")
    }
} else {
    $issues.Add("install-state-missing")
}

$manifestPath = Join-Path $installPath "package-manifest.json"
$packageCheck = Test-DagPackageIntegrity -PackageRoot $installPath
$manifest = $packageCheck.Manifest
$payloadCheck = [pscustomobject]@{
    DeclaredFileCount = $packageCheck.DeclaredFileCount
    ActualFileCount = $packageCheck.ActualFileCount
    Passed = $packageCheck.Passed
    IssueCodes = $packageCheck.IssueCodes
}
if (-not $packageCheck.Passed) {
    $issues.Add("package-integrity-failed")
    foreach ($issueCode in $packageCheck.IssueCodes) {
        $issues.Add([string]$issueCode)
    }
}

$manifestMatchesInstallState = $false
if ($null -ne $installState -and
    $null -ne $installState.packageManifestSha256 -and
    (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $manifestHash = (Get-FileHash `
        -LiteralPath $manifestPath `
        -Algorithm SHA256).Hash
    $manifestMatchesInstallState = $manifestHash.Equals(
        [string]$installState.packageManifestSha256,
        [StringComparison]::OrdinalIgnoreCase)
    if (-not $manifestMatchesInstallState) {
        $issues.Add("installed-manifest-hash-mismatch")
    }
}

$executableName = "DefaultAppGuard.Agent.exe"
if ($null -ne $manifest -and
    -not [string]::IsNullOrWhiteSpace($manifest.executable)) {
    $executableName = [string]$manifest.executable
}
$executablePath = Join-Path $installPath $executableName
$executableExists = Test-Path -LiteralPath $executablePath -PathType Leaf
$fileVersion = $null
$executableSha256 = $null
$peSubsystem = $null
$signatureStatus = "Missing"
$signerSubject = $null
$signatureTimestamped = $false
if ($executableExists) {
    $fileVersion = (Get-Item -LiteralPath $executablePath).VersionInfo.FileVersion
    $executableSha256 = (Get-FileHash `
        -LiteralPath $executablePath `
        -Algorithm SHA256).Hash
    $peSubsystem = Get-DagPeSubsystem -Path $executablePath
    $signature = Get-AuthenticodeSignature -LiteralPath $executablePath
    $signatureStatus = [string]$signature.Status
    if ($null -ne $signature.SignerCertificate) {
        $signerSubject = $signature.SignerCertificate.Subject
    }
    $signatureTimestamped = $null -ne $signature.TimeStamperCertificate
    if ($peSubsystem -ne 2) {
        $issues.Add("agent-console-subsystem")
    }
} else {
    $issues.Add("agent-executable-missing")
}

$setupPath = Join-Path $installPath "DefaultAppGuard.Setup.exe"
$setupExists = Test-Path -LiteralPath $setupPath -PathType Leaf
$setupFileVersion = $null
$setupSha256 = $null
$setupPeSubsystem = $null
$setupSignatureStatus = "Missing"
$setupSignerSubject = $null
$setupSignatureTimestamped = $false
if ($setupExists) {
    $setupFileVersion = (Get-Item -LiteralPath $setupPath).VersionInfo.FileVersion
    $setupSha256 = (Get-FileHash `
        -LiteralPath $setupPath `
        -Algorithm SHA256).Hash
    $setupPeSubsystem = Get-DagPeSubsystem -Path $setupPath
    $setupSignature = Get-AuthenticodeSignature -LiteralPath $setupPath
    $setupSignatureStatus = [string]$setupSignature.Status
    if ($null -ne $setupSignature.SignerCertificate) {
        $setupSignerSubject = $setupSignature.SignerCertificate.Subject
    }
    $setupSignatureTimestamped =
        $null -ne $setupSignature.TimeStamperCertificate
    if ($setupPeSubsystem -ne 2) {
        $issues.Add("setup-console-subsystem")
    }
} else {
    $issues.Add("setup-executable-missing")
}
if ($signatureStatus -ne $setupSignatureStatus) {
    $issues.Add("release-signature-state-mismatch")
}
if ($signatureStatus -eq "Valid" -and
    $signerSubject -ne $setupSignerSubject) {
    $issues.Add("release-signer-mismatch")
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = $null
$taskActionMatches = $false
$taskEnabled = $false
$taskState = "Missing"
$taskLastResult = $null
$triggerSummaries = @()
if ($null -ne $task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
    $taskActionMatches =
        (Get-NormalizedPath $task.Actions[0].Execute) -eq $executablePath
    $taskEnabled = [bool]$task.Settings.Enabled
    $taskState = [string]$task.State
    $taskLastResult = $taskInfo.LastTaskResult
    $triggerSummaries = @(
        $task.Triggers |
            ForEach-Object {
                [ordered]@{
                    type = $_.CimClass.CimClassName
                    enabled = [bool]$_.Enabled
                    repetitionInterval = [string]$_.Repetition.Interval
                }
            })
    if (-not $taskActionMatches) {
        $issues.Add("task-action-mismatch")
    }
} else {
    $issues.Add("scheduled-task-missing")
}

$agentProcesses = @()
$consoleChildCount = 0
if ($executableExists) {
    $agentProcesses = @(
        Get-CimInstance Win32_Process -Filter `
            "Name='DefaultAppGuard.Agent.exe'" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                (Get-NormalizedPath $_.ExecutablePath) -eq $executablePath
            })
    foreach ($agentProcess in $agentProcesses) {
        $consoleChildCount += @(
            Get-CimInstance Win32_Process |
                Where-Object {
                    $_.ParentProcessId -eq $agentProcess.ProcessId -and
                    $_.Name -in @(
                        "conhost.exe",
                        "OpenConsole.exe",
                        "WindowsTerminal.exe")
                }).Count
    }
}
if ($agentProcesses.Count -ne 1) {
    $issues.Add("agent-process-count")
}
if ($consoleChildCount -ne 0) {
    $issues.Add("agent-console-child")
}

$agentUrl = "http://127.0.0.1:51873"
if ($null -ne $installState -and
    -not [string]::IsNullOrWhiteSpace($installState.agentUrl)) {
    $agentUrl = [string]$installState.agentUrl
}
$health = $null
$status = $null
$readiness = $null
$apiReachable = $false
$readinessReady = $false
try {
    $agentUri = [Uri]$agentUrl
    if (-not $agentUri.IsLoopback -or
        $agentUri.Scheme -ne [Uri]::UriSchemeHttp) {
        throw "Stored Agent URL is not a loopback HTTP origin."
    }
    $health = Invoke-RestMethod `
        -Uri "$($agentUrl.TrimEnd('/'))/api/health" `
        -TimeoutSec 2
    $status = Invoke-RestMethod `
        -Uri "$($agentUrl.TrimEnd('/'))/api/status" `
        -TimeoutSec 2
    $apiReachable = $health.Service -eq "DefaultAppGuard.Agent"
} catch {
    $issues.Add("agent-api-unreachable")
}
if ($apiReachable) {
    try {
        $readiness = Invoke-RestMethod `
            -Uri "$($agentUrl.TrimEnd('/'))/api/readiness" `
            -TimeoutSec 2
        $readinessReady = [bool]$readiness.Ready -and
            $readiness.Code -eq "ready"
        if (-not $readinessReady) {
            $issues.Add("agent-not-ready")
        }
    } catch {
        $issues.Add("agent-not-ready")
    }
}

$apiProcessMatches = $false
if ($apiReachable -and $agentProcesses.Count -eq 1) {
    $apiProcessMatches =
        [int]$health.ProcessId -eq [int]$agentProcesses[0].ProcessId
    if (-not $apiProcessMatches) {
        $issues.Add("agent-api-process-mismatch")
    }
}

$listenerAddresses = @()
if ($agentProcesses.Count -eq 1) {
    try {
        $listenerAddresses = @(
            Get-NetTCPConnection `
                -State Listen `
                -OwningProcess $agentProcesses[0].ProcessId `
                -ErrorAction Stop |
                ForEach-Object {
                    "{0}:{1}" -f $_.LocalAddress, $_.LocalPort
                })
    } catch {
        $issues.Add("listener-query-failed")
    }
}
$loopbackOnly = $listenerAddresses.Count -gt 0 -and
    @($listenerAddresses | Where-Object {
        -not $_.StartsWith("127.0.0.1:") -and
        -not $_.StartsWith("[::1]:") -and
        -not $_.StartsWith("::1:")
    }).Count -eq 0
if (-not $loopbackOnly) {
    $issues.Add("listener-not-loopback-only")
}

$auditHealthy = $false
$healthyCount = 0
$driftCount = $null
$extensionCount = 0
$queryAlgorithm = $null
$monitorAlgorithm = $null
$processMode = $null
$hasRuntimeError = $false
if ($apiReachable -and $null -ne $status -and
    $null -ne $status.audit) {
    $auditHealthy = [bool]$status.audit.healthy
    $healthyCount = [int]$status.audit.healthyCount
    $driftCount = [int]$status.audit.driftCount
    $extensionCount = @($status.audit.items).Count
    $queryAlgorithm = [string]$status.queryAlgorithm
    $monitorAlgorithm = [string]$status.monitorAlgorithm
    $processMode = [string]$health.ProcessMode
    $hasRuntimeError = $null -ne $status.lastError
    if ($queryAlgorithm -ne
        "IApplicationAssociationRegistration.QueryCurrentDefault" -or
        $monitorAlgorithm -ne "RegNotifyChangeKeyValue") {
        $issues.Add("non-primary-algorithm")
    }
    if (-not $auditHealthy -or $driftCount -ne 0) {
        $issues.Add("association-drift")
    }
    if ($processMode -ne "background-no-console") {
        $issues.Add("agent-process-mode")
    }
} elseif ($apiReachable) {
    $issues.Add("association-audit-unavailable")
}

$operatingSystem = Get-CimInstance Win32_OperatingSystem
$report = [ordered]@{
    schemaVersion = 1
    product = "DefaultAppGuard Community"
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    privacy = [ordered]@{
        containsPersonalPaths = $false
        containsRegistryExports = $false
        containsRuntimeFileContents = $false
        containsTokens = $false
    }
    environment = [ordered]@{
        windowsCaption = $operatingSystem.Caption
        windowsVersion = $operatingSystem.Version
        windowsBuild = $operatingSystem.BuildNumber
        operatingSystemArchitecture = $operatingSystem.OSArchitecture
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
    package = [ordered]@{
        manifestPresent = $null -ne $manifest
        manifestSchemaVersion = if ($null -ne $manifest) {
            $manifest.schemaVersion
        } else {
            $null
        }
        version = if ($null -ne $manifest) {
            $manifest.version
        } else {
            $null
        }
        payload = $payloadCheck
        manifestMatchesInstallState = $manifestMatchesInstallState
        executablePresent = $executableExists
        executableFileVersion = $fileVersion
        executableSha256 = $executableSha256
        peSubsystem = $peSubsystem
        processMode = if ($peSubsystem -eq 2) {
            "background-no-console"
        } else {
            "unexpected"
        }
        signatureStatus = $signatureStatus
        signerSubject = $signerSubject
        signatureTimestamped = $signatureTimestamped
        setup = [ordered]@{
            present = $setupExists
            fileVersion = $setupFileVersion
            sha256 = $setupSha256
            peSubsystem = $setupPeSubsystem
            processMode = if ($setupPeSubsystem -eq 2) {
                "graphical-no-console"
            } else {
                "unexpected"
            }
            signatureStatus = $setupSignatureStatus
            signerSubject = $setupSignerSubject
            signatureTimestamped = $setupSignatureTimestamped
        }
    }
    scheduledTask = [ordered]@{
        present = $null -ne $task
        enabled = $taskEnabled
        state = $taskState
        actionMatchesInstall = $taskActionMatches
        lastResult = $taskLastResult
        triggers = $triggerSummaries
    }
    process = [ordered]@{
        count = $agentProcesses.Count
        processIds = @($agentProcesses | ForEach-Object ProcessId)
        apiProcessMatches = $apiProcessMatches
        consoleChildCount = $consoleChildCount
        listenerAddresses = $listenerAddresses
        loopbackOnly = $loopbackOnly
    }
    mainAlgorithm = [ordered]@{
        apiReachable = $apiReachable
        ready = $readinessReady
        readinessCode = if ($null -ne $readiness) {
            $readiness.Code
        } else {
            $null
        }
        targetProgId = if ($null -ne $readiness) {
            $readiness.TargetProgId
        } else {
            $null
        }
        targetPackageId = if ($null -ne $readiness) {
            $readiness.TargetPackageId
        } else {
            $null
        }
        primarySnapshotCount = if ($null -ne $readiness) {
            $readiness.PrimarySnapshotCount
        } else {
            0
        }
        failedReadCount = if ($null -ne $readiness) {
            $readiness.FailedReadCount
        } else {
            0
        }
        query = $queryAlgorithm
        monitor = $monitorAlgorithm
        auditHealthy = $auditHealthy
        healthyCount = $healthyCount
        extensionCount = $extensionCount
        driftCount = $driftCount
        processMode = $processMode
        hasRuntimeError = $hasRuntimeError
    }
    issueCodes = @($issues | Sort-Object -Unique)
}
$payloadPassed = $null -ne $payloadCheck -and [bool]$payloadCheck.Passed
$report["overallHealthy"] =
    @($report.issueCodes).Count -eq 0 -and
    $payloadPassed -and
    $manifestMatchesInstallState -and
    $taskActionMatches -and
    $taskEnabled -and
    $agentProcesses.Count -eq 1 -and
    $consoleChildCount -eq 0 -and
    $loopbackOnly -and
    $apiProcessMatches -and
    $readinessReady -and
    $auditHealthy -and
    $driftCount -eq 0

$outputDirectory = Split-Path -Parent $outputFile
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$report |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $outputFile -Encoding UTF8

[pscustomobject]@{
    ReportWritten = $true
    ReportPath = $outputFile
    OverallHealthy = $report["overallHealthy"]
    IssueCodes = $report.issueCodes
}
