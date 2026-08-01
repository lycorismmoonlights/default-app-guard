[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,
    [string]$OutputRoot,
    [string]$PackageManagerPath = "pnpm",
    [string]$NodePath = "node",
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer,
    [switch]$RequireSigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments |
        ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode."
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "The release gate must run on Windows."
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version without a v prefix."
}
if ($RequireSigned -and
    [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    throw (
        "RequireSigned needs SigningCertificateThumbprint so the fresh " +
        "release payload can be signed before its manifest is created.")
}
if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint) -and
    [string]::IsNullOrWhiteSpace($TimestampServer)) {
    throw "TimestampServer is required when release signing is configured."
}

$projectRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot ".."))
$packageModulePath = Join-Path $PSScriptRoot `
    "DefaultAppGuard.Package.psm1"
Import-Module -Name $packageModulePath -Force
$packageMetadata = Get-Content `
    -LiteralPath (Join-Path $projectRoot "package.json") `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
$packageVersion = [string]$packageMetadata.version
if ($packageVersion -ne $Version) {
    throw "Requested version $Version does not match package.json $packageVersion."
}
$riskNoticePath = Join-Path $projectRoot "ENVIRONMENT-AND-RISKS.txt"
$riskNoticeVersionLine = "Applies to version: $Version"
$riskNotice = Get-Content -LiteralPath $riskNoticePath -Raw -Encoding UTF8
if (-not $riskNotice.Contains($riskNoticeVersionLine)) {
    throw "ENVIRONMENT-AND-RISKS.txt is not updated for version $Version."
}

$dotnetCommand = (Get-Command dotnet -ErrorAction Stop).Source
$packageManagerCommand = (
    Get-Command $PackageManagerPath -ErrorAction Stop).Source
$nodeCommand = (Get-Command $NodePath -ErrorAction Stop).Source
$originalPath = $env:Path
$nodeDirectory = [IO.Path]::GetDirectoryName($nodeCommand)
$env:Path = "$nodeDirectory;$env:Path"
$globalJsonPath = Join-Path $projectRoot "global.json"
$globalJson = Get-Content `
    -LiteralPath $globalJsonPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
$expectedDotnetVersion = [string]$globalJson.sdk.version
$expectedNodeVersion = [string]$packageMetadata.engines.node
$expectedPackageManagerVersion = [string]$packageMetadata.engines.pnpm
if ([string]$globalJson.sdk.rollForward -ne "disable" -or
    [bool]$globalJson.sdk.allowPrerelease) {
    throw "global.json must require an exact stable .NET SDK."
}
$nvmNodeVersion = (Get-Content `
    -LiteralPath (Join-Path $projectRoot ".nvmrc") `
    -Raw `
    -Encoding UTF8).Trim()
if ($nvmNodeVersion -ne $expectedNodeVersion) {
    throw ".nvmrc does not match package.json engines.node."
}
Push-Location $projectRoot
try {
    $actualDotnetVersion = [string](& $dotnetCommand --version)
    $actualNodeVersion = [string](& $nodeCommand -p "process.versions.node")
    $actualPackageManagerVersion =
        [string](& $packageManagerCommand --version)
} finally {
    Pop-Location
}
$actualDotnetVersion = $actualDotnetVersion.Trim()
$actualNodeVersion = $actualNodeVersion.Trim()
$actualPackageManagerVersion = $actualPackageManagerVersion.Trim()
if ($actualDotnetVersion -ne $expectedDotnetVersion) {
    throw (
        "Release SDK mismatch: expected $expectedDotnetVersion, " +
        "found $actualDotnetVersion.")
}
if ($actualNodeVersion -ne $expectedNodeVersion) {
    throw (
        "Release Node.js mismatch: expected $expectedNodeVersion, " +
        "found $actualNodeVersion.")
}
if ($actualPackageManagerVersion -ne $expectedPackageManagerVersion) {
    throw (
        "Release pnpm mismatch: expected $expectedPackageManagerVersion, " +
        "found $actualPackageManagerVersion.")
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss")
    $OutputRoot = Join-Path $projectRoot (
        "artifacts\release-gate-$Version-$stamp")
}
$releaseRoot = [System.IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $releaseRoot) {
    throw "Release gate output already exists: $releaseRoot"
}

$evidenceDirectory = Join-Path $releaseRoot "evidence"
$packageDirectory = Join-Path $releaseRoot (
    "DefaultAppGuard-$Version-win-x64")
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

$testProject = Join-Path $projectRoot (
    "native\DefaultAppGuard.Tests\DefaultAppGuard.Tests.csproj")
$portableTrx = Join-Path $evidenceDirectory "portable-tests.trx"
$mainTrx = Join-Path $evidenceDirectory "main-algorithm-tests.trx"
$lifecycleEvidencePath = Join-Path $evidenceDirectory `
    "package-lifecycle.json"
$lifecycleWorkRoot = Join-Path $releaseRoot "package-lifecycle-work"
$watchdogBackoffEvidencePath = Join-Path $evidenceDirectory `
    "watchdog-backoff.json"
$watchdogBackoffWorkRoot = Join-Path $releaseRoot "watchdog-backoff-work"
$sbomWorkingRoot = Join-Path $evidenceDirectory "sbom-work"
$sbomComponentRoot = Join-Path $releaseRoot "sbom-component-work"
$sbomValidationPath = Join-Path $evidenceDirectory `
    "sbom-validation.json"
$sbomPath = Join-Path $releaseRoot `
    "DefaultAppGuard-$Version.spdx.json"
$sbomChecksumPath = "$sbomPath.sha256"

Push-Location $projectRoot
try {
    Invoke-CheckedCommand $dotnetCommand @("tool", "restore")

    Invoke-CheckedCommand $dotnetCommand @(
        "test",
        $testProject,
        "--configuration", "Release",
        "--filter", "Category!=MainAlgorithmIntegration",
        "--logger", "trx;LogFileName=$([IO.Path]::GetFileName($portableTrx))",
        "--results-directory", $evidenceDirectory)

    Invoke-CheckedCommand $dotnetCommand @(
        "test",
        $testProject,
        "--configuration", "Release",
        "--no-build",
        "--filter", "Category=MainAlgorithmIntegration",
        "--logger", "trx;LogFileName=$([IO.Path]::GetFileName($mainTrx))",
        "--results-directory", $evidenceDirectory)

    [xml]$mainResultsDocument = Get-Content -LiteralPath $mainTrx -Raw
    $mainResults = @(
        $mainResultsDocument.SelectNodes(
            "//*[local-name()='UnitTestResult']"))
    $requiredTests = @(
        "PrimaryComQuery_ReturnsEffectiveProgIdForEveryProbeExtension",
        "MediaPlayerResolver_FindsOneRealProgIdCommonToEveryProbeExtension",
        "RealEffectivePlan_IsCurrentlySatisfiedByMediaPlayer",
        "MainMonitorAlgorithm_ReceivesRealKernelChangeNotification",
        "WaitForChange_RejectsPreCanceledRequestWithoutSyntheticSuccess",
        "RealAudit_ReportsEveryDeclaredVideoAssociationIndividually"
    )

    foreach ($requiredTest in $requiredTests) {
        $result = $mainResults |
            Where-Object {
                $_.testName -eq $requiredTest -or
                $_.testName.EndsWith(".$requiredTest")
            } |
            Select-Object -First 1
        if ($null -eq $result) {
            throw "Required main-algorithm test was not executed: $requiredTest"
        }
        if ($result.outcome -ne "Passed") {
            throw "Required main-algorithm test did not pass: $requiredTest"
        }
    }

    Invoke-CheckedCommand $packageManagerCommand @("run", "build")
    Invoke-CheckedCommand $packageManagerCommand @("run", "test:sites")
    Invoke-CheckedCommand $packageManagerCommand @("run", "test:promotion")
    & (Join-Path $projectRoot "tests\Test-PackageIntegrity.ps1") |
        ForEach-Object { Write-Host $_ }

    $parseFailures = @()
    $powerShellFiles = @(
        Get-ChildItem $PSScriptRoot -File |
            Where-Object { $_.Extension -in @(".ps1", ".psm1") }
        Get-ChildItem `
            (Join-Path $projectRoot "tests") `
            -Filter "*.ps1" `
            -File
    )
    foreach ($script in $powerShellFiles) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors)
        $parseFailures += $errors
    }
    if ($parseFailures.Count -gt 0) {
        $messages = $parseFailures |
            ForEach-Object {
                "$($_.Extent.File):$($_.Extent.StartLineNumber) $($_.Message)"
            }
        throw "PowerShell parse failures:`n$($messages -join "`n")"
    }

    & (Join-Path $PSScriptRoot "Publish-Windows.ps1") `
        -Version $Version `
        -OutputDirectory $packageDirectory `
        -PackageManagerPath $packageManagerCommand `
        -NodePath $nodeCommand `
        -SigningCertificateThumbprint $SigningCertificateThumbprint `
        -TimestampServer $TimestampServer `
        -CreateArchive |
        ForEach-Object { Write-Host $_ }
} finally {
    Pop-Location
    $env:Path = $originalPath
}

$archivePath = "$packageDirectory.zip"
$checksumPath = "$archivePath.sha256"
$publishedExecutable = Join-Path $packageDirectory `
    "DefaultAppGuard.Agent.exe"
$publishedSetup = Join-Path $packageDirectory `
    "DefaultAppGuard.Setup.exe"
$packageCheck = Test-DagPackageIntegrity -PackageRoot $packageDirectory
if (-not $packageCheck.Passed) {
    throw "Published package integrity failed: $(
        $packageCheck.IssueCodes -join ', ')"
}
$publishedManifest = $packageCheck.Manifest
if ($publishedManifest.version -ne $Version) {
    throw "Published package manifest version does not match the release."
}
$peSubsystem = Get-DagPeSubsystem $publishedExecutable
if ($peSubsystem -ne 2) {
    throw "Published Agent must use the Windows GUI PE subsystem. Actual: $peSubsystem"
}
$setupPeSubsystem = Get-DagPeSubsystem $publishedSetup
if ($setupPeSubsystem -ne 2) {
    throw "Published Setup must use the Windows GUI PE subsystem. Actual: $setupPeSubsystem"
}
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Release archive was not produced: $archivePath"
}
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "Release checksum was not produced: $checksumPath"
}

$signatureFileNames = @(
    "DefaultAppGuard.Agent.exe",
    "DefaultAppGuard.Setup.exe",
    "Install-DefaultAppGuard.ps1",
    "Uninstall-DefaultAppGuard.ps1",
    "Get-DefaultAppGuardDiagnostics.ps1",
    "DefaultAppGuard.Package.psm1"
)
$signatureEvidence = @(
    foreach ($fileName in $signatureFileNames) {
        $signature = Get-AuthenticodeSignature -LiteralPath (
            Join-Path $packageDirectory $fileName)
        [pscustomobject]@{
            path = $fileName
            status = [string]$signature.Status
            signerSubject = if ($null -ne $signature.SignerCertificate) {
                $signature.SignerCertificate.Subject
            } else {
                $null
            }
            signerThumbprint = if ($null -ne $signature.SignerCertificate) {
                $signature.SignerCertificate.Thumbprint
            } else {
                $null
            }
            timestamped = $null -ne $signature.TimeStamperCertificate
        }
    }
)
$notSignedCount = @(
    $signatureEvidence |
        Where-Object { $_.status -eq "NotSigned" }).Count
$validSignatureCount = @(
    $signatureEvidence |
        Where-Object { $_.status -eq "Valid" }).Count
$codeSigningStatus = if (
    $notSignedCount -eq $signatureEvidence.Count) {
    "unsigned"
} elseif ($validSignatureCount -eq $signatureEvidence.Count) {
    "valid"
} else {
    "mixed-or-invalid"
}
if ($codeSigningStatus -eq "mixed-or-invalid") {
    $summary = $signatureEvidence |
        ForEach-Object { "$($_.path)=$($_.status)" }
    throw "Release contains mixed or invalid signatures: $($summary -join ', ')"
}

$signerThumbprints = @(
    $signatureEvidence |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.signerThumbprint)
        } |
        Select-Object -ExpandProperty signerThumbprint -Unique
)
if ($codeSigningStatus -eq "valid" -and $signerThumbprints.Count -ne 1) {
    throw "All signed release files must use the same signer certificate."
}
if ($RequireSigned -and $codeSigningStatus -ne "valid") {
    throw "This release requires trusted Authenticode signatures."
}
if ($RequireSigned -and @(
        $signatureEvidence |
            Where-Object { -not $_.timestamped }).Count -gt 0) {
    throw "This release requires timestamped Authenticode signatures."
}

$watchdogBackoffResult = & (Join-Path $projectRoot `
    "tests\Test-WatchdogBackoff.ps1") `
    -PackageDirectory $packageDirectory `
    -WorkRoot $watchdogBackoffWorkRoot `
    -EvidencePath $watchdogBackoffEvidencePath
if (-not [bool]$watchdogBackoffResult.Passed) {
    throw "The exact release package watchdog backoff test did not pass."
}
$watchdogBackoffEvidence = Get-Content `
    -LiteralPath $watchdogBackoffEvidencePath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
if (-not [bool]$watchdogBackoffEvidence.passed -or
    [int]$watchdogBackoffEvidence.firstAttempt.exitCode -ne 24 -or
    [string]$watchdogBackoffEvidence.firstAttempt.outcome -ne "failed" -or
    -not [bool]$watchdogBackoffEvidence.firstAttempt.failedProcessCleaned -or
    [int]$watchdogBackoffEvidence.immediateRetry.exitCode -ne 0 -or
    [string]$watchdogBackoffEvidence.immediateRetry.outcome -ne
        "recovery-deferred" -or
    -not [bool]$watchdogBackoffEvidence.immediateRetry.agentLaunchSuppressed -or
    -not [bool]$watchdogBackoffEvidence.telemetryRedacted) {
    throw "The exact release package lacks watchdog backoff evidence."
}

$lifecycleResult = & (Join-Path $projectRoot `
    "tests\Test-ReleasePackageLifecycle.ps1") `
    -PackageDirectory $packageDirectory `
    -Version $Version `
    -WorkRoot $lifecycleWorkRoot `
    -EvidencePath $lifecycleEvidencePath
if (-not [bool]$lifecycleResult.Passed) {
    throw "The exact release package lifecycle test did not pass."
}
$lifecycleEvidence = Get-Content `
    -LiteralPath $lifecycleEvidencePath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
if (-not [bool]$lifecycleEvidence.passed -or
    -not [bool]$lifecycleEvidence.mainAlgorithm.auditFresh -or
    [int64]$lifecycleEvidence.mainAlgorithm.auditAgeSeconds -lt 0 -or
    [int64]$lifecycleEvidence.mainAlgorithm.maximumAuditAgeSeconds -le 0 -or
    [int64]$lifecycleEvidence.mainAlgorithm.auditAgeSeconds -gt
        [int64]$lifecycleEvidence.mainAlgorithm.maximumAuditAgeSeconds -or
    -not [bool]$lifecycleEvidence.mainAlgorithm.initialMonitorVerified -or
    -not [bool]$lifecycleEvidence.mainAlgorithm.postRestartMonitorVerified -or
    [string]$lifecycleEvidence.notifications.channel -ne
        "WindowsForms.NotifyIcon" -or
    -not [bool]$lifecycleEvidence.notifications.available -or
    -not [bool]$lifecycleEvidence.notifications.enabledByDefault -or
    -not [bool](
        $lifecycleEvidence.notifications.configurationRoundTripVerified) -or
    [string]$lifecycleEvidence.operationalLogs.channel -ne
        "Serilog.Sinks.File" -or
    -not [bool]$lifecycleEvidence.operationalLogs.available -or
    [string]$lifecycleEvidence.operationalLogs.format -ne "CLEF" -or
    [int64]$lifecycleEvidence.operationalLogs.fileSizeLimitBytes -ne 2MB -or
    [int]$lifecycleEvidence.operationalLogs.retainedFileCountLimit -ne 7 -or
    -not [bool]$lifecycleEvidence.operationalLogs.diagnosticsHealthy -or
    [int]$lifecycleEvidence.operationalLogs.fileCount -lt 1 -or
    [int64]$lifecycleEvidence.operationalLogs.totalBytes -lt 1 -or
    -not [bool]$lifecycleEvidence.install.uninstallRegistrationVerified -or
    -not [bool]$lifecycleEvidence.rollback.lateStagePassed -or
    -not [bool]$lifecycleEvidence.rollback.installStateRestored -or
    -not [bool]$lifecycleEvidence.rollback.uninstallEntryRestored -or
    -not [bool]$lifecycleEvidence.watchdog.TaskConfigurationVerified -or
    [string]$lifecycleEvidence.watchdog.TelemetryOutcome -ne "recovered" -or
    -not [bool]$lifecycleEvidence.watchdog.TelemetryActiveProcessMatches -or
    -not [bool]$lifecycleEvidence.watchdog.TelemetryRedacted -or
    -not [bool]$lifecycleEvidence.watchdog.ReadinessFresh -or
    [int64]$lifecycleEvidence.watchdog.AuditAgeSeconds -lt 0 -or
    [int64]$lifecycleEvidence.watchdog.MaximumAuditAgeSeconds -le 0 -or
    [int64]$lifecycleEvidence.watchdog.AuditAgeSeconds -gt
        [int64]$lifecycleEvidence.watchdog.MaximumAuditAgeSeconds -or
    -not [bool]$lifecycleEvidence.diagnostics.auditFresh -or
    -not [bool]$lifecycleEvidence.diagnostics.watchdogTelemetryHealthy -or
    -not [bool]$lifecycleEvidence.diagnostics.watchdogTelemetryMatchesTaskRun -or
    -not [bool]$lifecycleEvidence.diagnostics.watchdogProcessMatches -or
    -not [bool]$lifecycleEvidence.uninstall.watchdogTelemetryRemoved -or
    -not [bool]$lifecycleEvidence.uninstall.registrationRemoved) {
    throw "The exact release package lacks primary-algorithm lifecycle evidence."
}

New-Item -ItemType Directory -Path $sbomWorkingRoot | Out-Null
$sbomComponentFiles = @(
    Get-Item -LiteralPath (Join-Path $projectRoot "package.json")
    Get-Item -LiteralPath (Join-Path $projectRoot "pnpm-lock.yaml")
    Get-Item -LiteralPath (Join-Path $projectRoot "pnpm-workspace.yaml")
    Get-ChildItem `
        -LiteralPath (Join-Path $projectRoot "native") `
        -Filter "*.csproj" `
        -Recurse `
        -File
    Get-ChildItem `
        -LiteralPath (Join-Path $projectRoot "native") `
        -Filter "project.assets.json" `
        -Recurse `
        -File
)
$projectAssetCount = @(
    $sbomComponentFiles |
        Where-Object { $_.Name -eq "project.assets.json" }).Count
if ($projectAssetCount -eq 0) {
    throw "No restored .NET dependency graph was available for the SBOM."
}
New-Item -ItemType Directory -Path $sbomComponentRoot | Out-Null
foreach ($componentFile in $sbomComponentFiles) {
    $relativePath = Get-DagRelativePackagePath `
        -Root $projectRoot `
        -Path $componentFile.FullName
    $destination = Join-Path $sbomComponentRoot $relativePath
    New-Item `
        -ItemType Directory `
        -Path (Split-Path -Parent $destination) `
        -Force | Out-Null
    Copy-Item -LiteralPath $componentFile.FullName -Destination $destination
}

try {
    Invoke-CheckedCommand $dotnetCommand @(
        "tool", "run", "sbom-tool", "--", "generate",
        "-b", $packageDirectory,
        "-bc", $sbomComponentRoot,
        "-pn", "DefaultAppGuard Community",
        "-pv", $Version,
        "-ps", "Organization: DefaultAppGuard Community",
        "-nsb", "https://github.com/lycorismmoonlights/default-app-guard",
        "-m", $sbomWorkingRoot,
        "-mi", "SPDX:2.2",
        "-V", "Warning")
    $generatedSbomPath = Join-Path $sbomWorkingRoot `
        "_manifest\spdx_2.2\manifest.spdx.json"
    if (-not (Test-Path -LiteralPath $generatedSbomPath -PathType Leaf)) {
        throw "Microsoft SBOM Tool did not produce the expected SPDX document."
    }
    Invoke-CheckedCommand $dotnetCommand @(
        "tool", "run", "sbom-tool", "--", "validate",
        "-b", $packageDirectory,
        "-m", (Join-Path $sbomWorkingRoot "_manifest"),
        "-o", $sbomValidationPath,
        "-mi", "SPDX:2.2",
        "-n",
        "-V", "Warning")
    $sbomValidation = Get-Content `
        -LiteralPath $sbomValidationPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
    if ($sbomValidation.Result -ne "Success" -or
        [int]$sbomValidation.ValidationErrors.Count -ne 0 -or
        [int]$sbomValidation.Summary.ValidationTelemetery.FilesFailedCount -ne 0 -or
        [int]$sbomValidation.Summary.ValidationTelemetery.TotalPackagesInManifest -le 0) {
        throw "The generated SBOM did not pass package validation."
    }
    Copy-Item -LiteralPath $generatedSbomPath -Destination $sbomPath
} finally {
    if (Test-Path -LiteralPath $sbomComponentRoot) {
        if (-not (Test-DagPathWithin `
                -Path $sbomComponentRoot `
                -Parent $releaseRoot)) {
            throw "Refusing to clean an unsafe SBOM component directory."
        }
        Remove-Item -LiteralPath $sbomComponentRoot -Recurse -Force
    }
}
$sbomHash = (Get-FileHash -LiteralPath $sbomPath `
    -Algorithm SHA256).Hash
"$sbomHash  $([IO.Path]::GetFileName($sbomPath))" |
    Set-Content -LiteralPath $sbomChecksumPath -Encoding Ascii
$toolManifest = Get-Content `
    -LiteralPath (Join-Path $projectRoot ".config\dotnet-tools.json") `
    -Raw |
    ConvertFrom-Json
$sbomToolVersion = [string]$toolManifest.tools.PSObject.Properties[
    "microsoft.sbom.dotnettool"].Value.version

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $archiveEntries = @(
        $archive.Entries |
            ForEach-Object { $_.FullName.Replace("\", "/") })
    $requiredPackageEntries = @(
        "DefaultAppGuard.Agent.exe",
        "DefaultAppGuard.Setup.exe",
        "Install-DefaultAppGuard.ps1",
        "Uninstall-DefaultAppGuard.ps1",
        "Get-DefaultAppGuardDiagnostics.ps1",
        "DefaultAppGuard.Package.psm1",
        "package-manifest.json",
        "LICENSE.md",
        "NOTICE",
        "ENVIRONMENT-AND-RISKS.txt",
        "wwwroot/index.html"
    )
    foreach ($requiredEntry in $requiredPackageEntries) {
        if ($requiredEntry -notin $archiveEntries) {
            throw "Required package entry is missing: $requiredEntry"
        }
    }
} finally {
    $archive.Dispose()
}

$commit = $env:GITHUB_SHA
if ([string]::IsNullOrWhiteSpace($commit)) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git -and
        (Test-Path -LiteralPath (Join-Path $projectRoot ".git"))) {
        & $git.Source -C $projectRoot show-ref --verify --quiet HEAD
        if ($LASTEXITCODE -eq 0) {
            $commit = (& $git.Source -C $projectRoot rev-parse HEAD)
        }
    }
}

$archiveHash = (Get-FileHash -LiteralPath $archivePath `
    -Algorithm SHA256).Hash
$evidenceFile = Join-Path $releaseRoot "release-gate.json"
[ordered]@{
    product = "DefaultAppGuard Community"
    version = $Version
    commit = $commit
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    operatingSystem = [Environment]::OSVersion.VersionString
    architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    toolchain = [ordered]@{
        dotnetSdk = $actualDotnetVersion
        dotnetRollForward = [string]$globalJson.sdk.rollForward
        dotnetPrereleaseAllowed = [bool]$globalJson.sdk.allowPrerelease
        node = $actualNodeVersion
        pnpm = $actualPackageManagerVersion
        exactVersionsVerified = $true
    }
    mainAlgorithm = [ordered]@{
        query = "IApplicationAssociationRegistration.QueryCurrentDefault"
        monitor = "RegNotifyChangeKeyValue"
        requiredTests = $requiredTests
        exactReleasePackagePassed = [bool]$lifecycleEvidence.passed
        auditFresh = [bool]$lifecycleEvidence.mainAlgorithm.auditFresh
        auditAgeSeconds =
            [int64]$lifecycleEvidence.mainAlgorithm.auditAgeSeconds
        maximumAuditAgeSeconds =
            [int64]$lifecycleEvidence.mainAlgorithm.maximumAuditAgeSeconds
        installedMonitorBeforeRecovery =
            [bool]$lifecycleEvidence.mainAlgorithm.initialMonitorVerified
        installedMonitorAfterRecovery =
            [bool]$lifecycleEvidence.mainAlgorithm.postRestartMonitorVerified
        notificationChannel =
            [string]$lifecycleEvidence.notifications.channel
        notificationsAvailable =
            [bool]$lifecycleEvidence.notifications.available
        notificationConfigurationVerified =
            [bool](
                $lifecycleEvidence.notifications.configurationRoundTripVerified)
        passed = $true
    }
    operationalLogs = [ordered]@{
        channel = [string]$lifecycleEvidence.operationalLogs.channel
        available = [bool]$lifecycleEvidence.operationalLogs.available
        format = [string]$lifecycleEvidence.operationalLogs.format
        fileSizeLimitBytes =
            [int64]$lifecycleEvidence.operationalLogs.fileSizeLimitBytes
        retainedFileCountLimit =
            [int]$lifecycleEvidence.operationalLogs.retainedFileCountLimit
        diagnosticsHealthy =
            [bool]$lifecycleEvidence.operationalLogs.diagnosticsHealthy
        fileCount = [int]$lifecycleEvidence.operationalLogs.fileCount
        totalBytes = [int64]$lifecycleEvidence.operationalLogs.totalBytes
        passed = $true
    }
    process = [ordered]@{
        mode = "background-no-console"
        agentPeSubsystem = $peSubsystem
        setupPeSubsystem = $setupPeSubsystem
        passed = $true
    }
    packageIntegrity = [ordered]@{
        manifestSchemaVersion = $publishedManifest.schemaVersion
        declaredFileCount = $packageCheck.DeclaredFileCount
        actualFileCount = $packageCheck.ActualFileCount
        passed = $packageCheck.Passed
    }
    packageLifecycle = [ordered]@{
        evidence = [IO.Path]::GetFileName($lifecycleEvidencePath)
        transactionalRollback = [bool]$lifecycleEvidence.rollback.passed
        lateStageRollback = [bool]$lifecycleEvidence.rollback.lateStagePassed
        automaticWatchdogRecovery =
            [bool]$lifecycleEvidence.watchdog.AutomaticRestartVerified
        watchdogConfigurationVerified =
            [bool]$lifecycleEvidence.watchdog.TaskConfigurationVerified
        watchdogRecoveryTelemetryVerified =
            [string]$lifecycleEvidence.watchdog.TelemetryOutcome -eq
                "recovered" -and
            [bool]$lifecycleEvidence.watchdog.TelemetryActiveProcessMatches -and
            [bool]$lifecycleEvidence.watchdog.TelemetryRedacted
        watchdogRestartStormSuppressed =
            [bool]$watchdogBackoffEvidence.passed -and
            [bool]$watchdogBackoffEvidence.firstAttempt.failedProcessCleaned -and
            [bool]$watchdogBackoffEvidence.immediateRetry.agentLaunchSuppressed
        diagnosticsHealthy =
            [bool]$lifecycleEvidence.diagnostics.overallHealthy
        operationalLogsHealthy =
            [bool]$lifecycleEvidence.diagnostics.operationalLogsHealthy
        uninstallRegistered =
            [bool]$lifecycleEvidence.install.uninstallRegistrationVerified
        uninstallClean = [bool]$lifecycleEvidence.uninstall.passed
        uninstallRegistrationRemoved =
            [bool]$lifecycleEvidence.uninstall.registrationRemoved
        watchdogTelemetryRemoved =
            [bool]$lifecycleEvidence.uninstall.watchdogTelemetryRemoved
        passed = [bool]$lifecycleEvidence.passed
    }
    sbom = [ordered]@{
        format = "SPDX-2.2"
        tool = "Microsoft.Sbom.DotNetTool"
        toolVersion = $sbomToolVersion
        file = [IO.Path]::GetFileName($sbomPath)
        sha256 = $sbomHash
        filesValidated = [int](
            $sbomValidation.Summary.ValidationTelemetery.FilesValidatedCount)
        packages = [int](
            $sbomValidation.Summary.ValidationTelemetery.TotalPackagesInManifest)
        componentInputFiles = $sbomComponentFiles.Count
        historicalArtifactsExcluded = $true
        validationResult = [string]$sbomValidation.Result
        passed = $sbomValidation.Result -eq "Success"
    }
    codeSigning = [ordered]@{
        policy = if ($RequireSigned) {
            "require-signed"
        } else {
            "allow-unsigned-alpha"
        }
        status = $codeSigningStatus
        trustedOnReleaseMachine = $codeSigningStatus -eq "valid"
        signerSubjects = @(
            $signatureEvidence |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.signerSubject)
                } |
                Select-Object -ExpandProperty signerSubject -Unique
        )
        files = $signatureEvidence
        passed = $codeSigningStatus -ne "mixed-or-invalid" -and (
            -not $RequireSigned -or $codeSigningStatus -eq "valid")
    }
    archive = [IO.Path]::GetFileName($archivePath)
    sha256 = $archiveHash
} |
    ConvertTo-Json -Depth 7 |
    Set-Content -LiteralPath $evidenceFile -Encoding UTF8

[pscustomobject]@{
    OutputRoot = $releaseRoot
    PackageDirectory = $packageDirectory
    Archive = $archivePath
    ChecksumFile = $checksumPath
    EvidenceFile = $evidenceFile
    EvidenceDirectory = $evidenceDirectory
    LifecycleEvidenceFile = $lifecycleEvidencePath
    WatchdogBackoffEvidenceFile = $watchdogBackoffEvidencePath
    SbomFile = $sbomPath
    SbomChecksumFile = $sbomChecksumPath
    SbomValidationFile = $sbomValidationPath
    Sha256 = $archiveHash
    CodeSigningStatus = $codeSigningStatus
}
