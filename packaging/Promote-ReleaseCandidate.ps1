[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CandidateDirectory,
    [Parameter(Mandatory)]
    [string]$Version,
    [string]$OutputRoot,
    [string]$Repository = "lycorismmoonlights/default-app-guard",
    [string]$ExpectedCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-CheckedSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ChecksumPath
    )

    $checksumText = (Get-Content `
        -LiteralPath $ChecksumPath `
        -Raw `
        -Encoding Ascii).Trim()
    if ($checksumText -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') {
        throw "Checksum file has an invalid format: $ChecksumPath"
    }
    $expectedHash = $Matches[1].ToUpperInvariant()
    $expectedName = $Matches[2].Trim()
    if ($expectedName -ne [IO.Path]::GetFileName($Path)) {
        throw "Checksum file names another artifact: $expectedName"
    }
    $actualHash = (Get-FileHash `
        -LiteralPath $Path `
        -Algorithm SHA256).Hash
    if (-not $actualHash.Equals(
            $expectedHash,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-256 verification failed for $([IO.Path]::GetFileName($Path))."
    }
    return $actualHash
}

function Invoke-AttestationVerification {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$Commit
    )

    $gh = Get-Command gh -ErrorAction Stop
    $stderrPath = "$EvidencePath.stderr"
    $arguments = @(
        "attestation", "verify", $Path,
        "--repo", $Repository,
        "--signer-workflow",
        "$Repository/.github/workflows/release-candidate.yml",
        "--source-digest", $Commit,
        "--source-ref", "refs/heads/main",
        "--deny-self-hosted-runners",
        "--format", "json"
    )
    $output = @(& $gh.Source @arguments 2> $stderrPath)
    $exitCode = $LASTEXITCODE
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    } else {
        ""
    }
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) {
        throw "GitHub attestation verification failed: $($stderr.Trim())"
    }
    $json = $output -join [Environment]::NewLine
    $verification = $json | ConvertFrom-Json
    if (@($verification).Count -eq 0) {
        throw "GitHub returned no verified attestation."
    }
    $json | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    return [pscustomobject]@{
        Passed = $true
        AttestationCount = @($verification).Count
        EvidencePath = $EvidencePath
    }
}

function Expand-CheckedArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        Assert-True ($archive.Entries.Count -gt 0) `
            "Candidate archive is empty."
        Assert-True ($archive.Entries.Count -le 10000) `
            "Candidate archive contains too many entries."
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        [long]$totalLength = 0
        foreach ($entry in $archive.Entries) {
            $entryName = ([string]$entry.FullName).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or
                $entryName.StartsWith('/') -or
                $entryName.StartsWith('\') -or
                $entryName -match '^[A-Za-z]:' -or
                $entryName.Contains(':')) {
                throw "Candidate archive contains an unsafe entry name."
            }
            $segments = @($entryName.Split('/') | Where-Object { $_ -ne "" })
            if ($segments.Count -eq 0 -or
                @($segments | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
                throw "Candidate archive contains a traversal entry."
            }
            if (-not $seen.Add($entryName)) {
                throw "Candidate archive contains duplicate entries."
            }
            [uint32]$attributes = [BitConverter]::ToUInt32(
                [BitConverter]::GetBytes([int]$entry.ExternalAttributes),
                0)
            $unixFileType = ($attributes -shr 16) -band 0xF000
            if ($unixFileType -eq 0xA000) {
                throw "Candidate archive contains a symbolic link."
            }
            $totalLength += [long]$entry.Length
            if ($totalLength -gt 1GB) {
                throw "Candidate archive expands beyond the allowed size."
            }
            $destinationPath = [IO.Path]::GetFullPath(
                (Join-Path $Destination $entryName))
            $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd(
                [IO.Path]::DirectorySeparatorChar)
            if (-not $destinationPath.StartsWith(
                    "$destinationRoot$([IO.Path]::DirectorySeparatorChar)",
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Candidate archive entry escapes the destination."
            }
        }
    } finally {
        $archive.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "Release candidate promotion must run on Windows."
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version without a v prefix."
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repository must use the owner/name form."
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$candidateRoot = [IO.Path]::GetFullPath($CandidateDirectory)
Assert-True (Test-Path -LiteralPath $candidateRoot -PathType Container) `
    "Candidate directory does not exist."
$sourceCommit = [string](& git -C $projectRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine the current source commit."
}
$sourceCommit = $sourceCommit.Trim().ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
    $ExpectedCommit = $sourceCommit
}
$ExpectedCommit = $ExpectedCommit.Trim().ToLowerInvariant()
if ($ExpectedCommit -notmatch '^[0-9a-f]{40}$') {
    throw "ExpectedCommit must be a full Git commit SHA."
}
Assert-True ($sourceCommit -eq $ExpectedCommit) `
    "Promotion source checkout does not match ExpectedCommit."
$trackedChanges = @(& git -C $projectRoot status `
    --short `
    --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect the promotion source checkout."
}
Assert-True ($trackedChanges.Count -eq 0) `
    "Promotion requires a clean checkout with no tracked changes."

$expectedFiles = @(
    "DefaultAppGuard-$Version-win-x64.zip",
    "DefaultAppGuard-$Version-win-x64.zip.sha256",
    "DefaultAppGuard-$Version.spdx.json",
    "DefaultAppGuard-$Version.spdx.json.sha256",
    "candidate-build.json",
    "sbom-validation.json"
)
$candidateEntries = @(Get-ChildItem -LiteralPath $candidateRoot -Force)
Assert-True (@($candidateEntries | Where-Object { $_.PSIsContainer }).Count -eq 0) `
    "Candidate directory must not contain subdirectories."
$actualFiles = @(
    $candidateEntries |
        Where-Object { -not $_.PSIsContainer } |
        Select-Object -ExpandProperty Name |
        Sort-Object)
Assert-True (($actualFiles -join "`n") -eq
    (($expectedFiles | Sort-Object) -join "`n")) `
    "Candidate directory must contain exactly the expected six files."

$archivePath = Join-Path $candidateRoot $expectedFiles[0]
$archiveChecksumPath = Join-Path $candidateRoot $expectedFiles[1]
$sbomPath = Join-Path $candidateRoot $expectedFiles[2]
$sbomChecksumPath = Join-Path $candidateRoot $expectedFiles[3]
$candidateEvidencePath = Join-Path $candidateRoot $expectedFiles[4]
$sbomValidationPath = Join-Path $candidateRoot $expectedFiles[5]
$candidateEvidence = Get-Content `
    -LiteralPath $candidateEvidencePath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
$sbomValidation = Get-Content `
    -LiteralPath $sbomValidationPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json

Assert-True ([int]$candidateEvidence.schemaVersion -eq 1) `
    "Candidate evidence schema is unsupported."
Assert-True ([string]$candidateEvidence.product -eq
    "DefaultAppGuard Community") `
    "Candidate evidence names another product."
Assert-True ([string]$candidateEvidence.version -eq $Version) `
    "Candidate evidence version does not match."
Assert-True ([string]$candidateEvidence.repository -eq $Repository) `
    "Candidate evidence names another repository."
Assert-True ([string]$candidateEvidence.sourceRef -eq "refs/heads/main") `
    "Candidate was not built from main."
Assert-True ([string]$candidateEvidence.commit -eq $ExpectedCommit) `
    "Candidate source commit does not match the reviewed commit."
Assert-True ([string]$candidateEvidence.workflow -eq
    ".github/workflows/release-candidate.yml") `
    "Candidate evidence names another workflow."
Assert-True ([bool]$candidateEvidence.runner.hosted) `
    "Candidate evidence does not identify a GitHub-hosted runner."
Assert-True ([string]$candidateEvidence.toolchain.dotnetSdk -eq "10.0.302") `
    "Candidate used another .NET SDK."
Assert-True ([string]$candidateEvidence.toolchain.node -eq "24.18.0") `
    "Candidate used another Node.js version."
Assert-True ([string]$candidateEvidence.toolchain.pnpm -eq "11.9.0") `
    "Candidate used another pnpm version."
Assert-True ([bool]$candidateEvidence.toolchain.exactVersionsVerified) `
    "Candidate did not verify exact tool versions."
Assert-True ([bool]$candidateEvidence.portableValidationPassed) `
    "Candidate did not pass portable validation."
Assert-True ([string]$candidateEvidence.codeSigning.policy -eq
    "unsigned-alpha") `
    "Candidate signing policy is not the expected unsigned alpha policy."
Assert-True ([string]$candidateEvidence.codeSigning.status -eq "unsigned") `
    "Candidate is not consistently unsigned."
Assert-True ([string]$sbomValidation.Result -eq "Success") `
    "Candidate SBOM validation did not pass."
Assert-True ([int]$sbomValidation.ValidationErrors.Count -eq 0) `
    "Candidate SBOM validation reported errors."

$archiveHash = Get-CheckedSha256 `
    -Path $archivePath `
    -ChecksumPath $archiveChecksumPath
$sbomHash = Get-CheckedSha256 `
    -Path $sbomPath `
    -ChecksumPath $sbomChecksumPath
Assert-True ($archiveHash.Equals(
        [string]$candidateEvidence.package.sha256,
        [StringComparison]::OrdinalIgnoreCase)) `
    "Candidate archive hash does not match build evidence."
Assert-True ($sbomHash.Equals(
        [string]$candidateEvidence.sbom.sha256,
        [StringComparison]::OrdinalIgnoreCase)) `
    "Candidate SBOM hash does not match build evidence."

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss")
    $OutputRoot = Join-Path $projectRoot `
        "artifacts\candidate-promotion-$Version-$stamp"
}
$promotionRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $promotionRoot) {
    throw "Promotion output already exists: $promotionRoot"
}
$evidenceRoot = Join-Path $promotionRoot "evidence"
$packageRoot = Join-Path $promotionRoot `
    "DefaultAppGuard-$Version-win-x64"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

$archiveAttestation = Invoke-AttestationVerification `
    -Path $archivePath `
    -EvidencePath (Join-Path $evidenceRoot "archive-attestation.json") `
    -Commit $ExpectedCommit
$sbomAttestation = Invoke-AttestationVerification `
    -Path $sbomPath `
    -EvidencePath (Join-Path $evidenceRoot "sbom-attestation.json") `
    -Commit $ExpectedCommit
$buildEvidenceAttestation = Invoke-AttestationVerification `
    -Path $candidateEvidencePath `
    -EvidencePath (Join-Path $evidenceRoot `
        "candidate-build-attestation.json") `
    -Commit $ExpectedCommit

Expand-CheckedArchive -ArchivePath $archivePath -Destination $packageRoot
$packageModulePath = Join-Path $packageRoot `
    "DefaultAppGuard.Package.psm1"
Import-Module -Name $packageModulePath -Force
$packageCheck = Test-DagPackageIntegrity -PackageRoot $packageRoot
Assert-True ([bool]$packageCheck.Passed) `
    "Promoted package failed per-file integrity verification."
Assert-True ([string]$packageCheck.Manifest.version -eq $Version) `
    "Promoted package manifest version does not match."
$manifestPath = Join-Path $packageRoot "package-manifest.json"
$manifestHash = (Get-FileHash `
    -LiteralPath $manifestPath `
    -Algorithm SHA256).Hash
Assert-True ($manifestHash.Equals(
        [string]$candidateEvidence.package.manifestSha256,
        [StringComparison]::OrdinalIgnoreCase)) `
    "Promoted package manifest differs from candidate build evidence."
Assert-True ([int]$packageCheck.DeclaredFileCount -eq
    [int]$candidateEvidence.package.declaredFileCount) `
    "Promoted package declared-file count differs from build evidence."
Assert-True ([int]$packageCheck.ActualFileCount -eq
    [int]$candidateEvidence.package.actualFileCount) `
    "Promoted package actual-file count differs from build evidence."

$agentPath = Join-Path $packageRoot "DefaultAppGuard.Agent.exe"
$setupPath = Join-Path $packageRoot "DefaultAppGuard.Setup.exe"
Assert-True ((Get-DagPeSubsystem -Path $agentPath) -eq 2) `
    "Promoted Agent does not use the Windows GUI subsystem."
Assert-True ((Get-DagPeSubsystem -Path $setupPath) -eq 2) `
    "Promoted Setup does not use the Windows GUI subsystem."
$setupVerification = Start-Process `
    -FilePath $setupPath `
    -ArgumentList @("--quiet", "--verify-only") `
    -WindowStyle Hidden `
    -Wait `
    -PassThru
Assert-True ($setupVerification.ExitCode -eq 0) `
    "Promoted Setup verification failed."

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
        $signature = Get-AuthenticodeSignature `
            -LiteralPath (Join-Path $packageRoot $fileName)
        Assert-True ([string]$signature.Status -eq "NotSigned") `
            "Unsigned candidate contains a signed, mixed, or invalid file."
        [ordered]@{
            path = $fileName
            status = [string]$signature.Status
        }
    })

$watchdogBackoffEvidencePath = Join-Path $evidenceRoot `
    "watchdog-backoff.json"
$watchdogBackoffResult = & (Join-Path $projectRoot `
    "tests\Test-WatchdogBackoff.ps1") `
    -PackageDirectory $packageRoot `
    -WorkRoot (Join-Path $promotionRoot "watchdog-backoff-work") `
    -EvidencePath $watchdogBackoffEvidencePath
Assert-True ([bool]$watchdogBackoffResult.Passed) `
    "Exact candidate watchdog backoff test did not pass."
$watchdogBackoffEvidence = Get-Content `
    -LiteralPath $watchdogBackoffEvidencePath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ([bool]$watchdogBackoffEvidence.passed -and
    [int]$watchdogBackoffEvidence.firstAttempt.exitCode -eq 24 -and
    [string]$watchdogBackoffEvidence.firstAttempt.outcome -eq "failed" -and
    [bool]$watchdogBackoffEvidence.firstAttempt.failedProcessCleaned -and
    [int]$watchdogBackoffEvidence.immediateRetry.exitCode -eq 0 -and
    [string]$watchdogBackoffEvidence.immediateRetry.outcome -eq
        "recovery-deferred" -and
    [bool]$watchdogBackoffEvidence.immediateRetry.agentLaunchSuppressed -and
    [bool]$watchdogBackoffEvidence.telemetryRedacted) `
    "Exact candidate lacks complete watchdog backoff evidence."

$lifecycleEvidencePath = Join-Path $evidenceRoot "package-lifecycle.json"
$lifecycleResult = & (Join-Path $projectRoot `
    "tests\Test-ReleasePackageLifecycle.ps1") `
    -PackageDirectory $packageRoot `
    -Version $Version `
    -WorkRoot (Join-Path $promotionRoot "package-lifecycle-work") `
    -EvidencePath $lifecycleEvidencePath
Assert-True ([bool]$lifecycleResult.Passed) `
    "Exact candidate lifecycle test did not pass."
$lifecycleEvidence = Get-Content `
    -LiteralPath $lifecycleEvidencePath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ([bool]$lifecycleEvidence.passed -and
    [bool]$lifecycleEvidence.package.exactManifestInstalled -and
    [string]$lifecycleEvidence.mainAlgorithm.query -eq
        "IApplicationAssociationRegistration.QueryCurrentDefault" -and
    [string]$lifecycleEvidence.mainAlgorithm.monitor -eq
        "RegNotifyChangeKeyValue" -and
    [int]$lifecycleEvidence.mainAlgorithm.expectedExtensionCount -eq 34 -and
    [int]$lifecycleEvidence.mainAlgorithm.auditedExtensionCount -eq 34 -and
    [int]$lifecycleEvidence.mainAlgorithm.primarySnapshotCount -eq 34 -and
    [int]$lifecycleEvidence.mainAlgorithm.failedReadCount -eq 0 -and
    [bool]$lifecycleEvidence.mainAlgorithm.initialMonitorVerified -and
    [bool]$lifecycleEvidence.mainAlgorithm.postRestartMonitorVerified -and
    [bool]$lifecycleEvidence.rollback.passed -and
    [bool]$lifecycleEvidence.rollback.lateStagePassed -and
    [bool]$lifecycleEvidence.rollback.installStateRestored -and
    [bool]$lifecycleEvidence.rollback.uninstallEntryRestored -and
    [bool]$lifecycleEvidence.watchdog.TaskConfigurationVerified -and
    [string]$lifecycleEvidence.watchdog.TelemetryOutcome -eq "recovered" -and
    [bool]$lifecycleEvidence.watchdog.TelemetryActiveProcessMatches -and
    [bool]$lifecycleEvidence.watchdog.TelemetryRedacted -and
    [bool]$lifecycleEvidence.diagnostics.overallHealthy -and
    [int]$lifecycleEvidence.diagnostics.issueCount -eq 0 -and
    [bool]$lifecycleEvidence.diagnostics.loopbackOnly -and
    [int]$lifecycleEvidence.diagnostics.consoleChildCount -eq 0 -and
    [bool]$lifecycleEvidence.diagnostics.watchdogTelemetryHealthy -and
    [bool]$lifecycleEvidence.diagnostics.watchdogTelemetryMatchesTaskRun -and
    [bool]$lifecycleEvidence.diagnostics.watchdogProcessMatches -and
    [bool]$lifecycleEvidence.uninstall.passed -and
    [bool]$lifecycleEvidence.uninstall.registrationRemoved -and
    [bool]$lifecycleEvidence.uninstall.taskRemoved -and
    [bool]$lifecycleEvidence.uninstall.processRemoved -and
    [bool]$lifecycleEvidence.uninstall.watchdogTelemetryRemoved -and
    [bool]$lifecycleEvidence.uninstall.directoriesRemoved -and
    [int]$lifecycleEvidence.uninstall.transactionResidueCount -eq 0) `
    "Exact candidate lacks complete primary-algorithm lifecycle evidence."

$releaseGatePath = Join-Path $promotionRoot "release-gate.json"
[ordered]@{
    schemaVersion = 1
    product = "DefaultAppGuard Community"
    version = $Version
    commit = $ExpectedCommit
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    promotionMode = "github-hosted-build-local-main-algorithm-gate"
    provenance = [ordered]@{
        repository = $Repository
        sourceRef = "refs/heads/main"
        workflow = ".github/workflows/release-candidate.yml"
        runId = [string]$candidateEvidence.runId
        hostedRunnerRequired = $true
        selfHostedAttestationsDenied = $true
        archiveAttestationCount = $archiveAttestation.AttestationCount
        sbomAttestationCount = $sbomAttestation.AttestationCount
        buildEvidenceAttestationCount =
            $buildEvidenceAttestation.AttestationCount
        passed = $true
    }
    toolchain = $candidateEvidence.toolchain
    package = [ordered]@{
        archive = [IO.Path]::GetFileName($archivePath)
        sha256 = $archiveHash
        manifestSha256 = $manifestHash
        integrityPassed = [bool]$packageCheck.Passed
        setupVerifierPassed = $setupVerification.ExitCode -eq 0
        exactAttestedArchivePromoted = $true
    }
    sbom = [ordered]@{
        file = [IO.Path]::GetFileName($sbomPath)
        sha256 = $sbomHash
        validationResult = [string]$sbomValidation.Result
        attestationVerified = $true
    }
    codeSigning = [ordered]@{
        policy = "unsigned-alpha"
        status = "unsigned"
        files = $signatureEvidence
    }
    watchdogBackoff = [ordered]@{
        exactReleasePackagePassed = [bool]$watchdogBackoffEvidence.passed
        failedProcessCleaned =
            [bool]$watchdogBackoffEvidence.firstAttempt.failedProcessCleaned
        restartStormSuppressed =
            [bool]$watchdogBackoffEvidence.immediateRetry.agentLaunchSuppressed
        telemetryRedacted = [bool]$watchdogBackoffEvidence.telemetryRedacted
    }
    packageLifecycle = [ordered]@{
        exactReleasePackagePassed = [bool]$lifecycleEvidence.passed
        mainAlgorithm = $lifecycleEvidence.mainAlgorithm
        rollback = $lifecycleEvidence.rollback
        watchdog = $lifecycleEvidence.watchdog
        diagnostics = $lifecycleEvidence.diagnostics
        uninstall = $lifecycleEvidence.uninstall
    }
    passed = $true
} | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $releaseGatePath -Encoding UTF8

[pscustomobject]@{
    Passed = $true
    Archive = $archivePath
    ChecksumFile = $archiveChecksumPath
    SbomFile = $sbomPath
    SbomChecksumFile = $sbomChecksumPath
    CandidateEvidenceFile = $candidateEvidencePath
    ReleaseGateFile = $releaseGatePath
    LifecycleEvidenceFile = $lifecycleEvidencePath
    WatchdogBackoffEvidenceFile = $watchdogBackoffEvidencePath
    EvidenceDirectory = $evidenceRoot
    PackageDirectory = $packageRoot
}
