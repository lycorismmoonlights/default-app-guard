[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,
    [string]$OutputRoot,
    [string]$PackageManagerPath = "pnpm",
    [string]$NodePath = "node",
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

$projectRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot ".."))
$packageModulePath = Join-Path $PSScriptRoot `
    "DefaultAppGuard.Package.psm1"
Import-Module -Name $packageModulePath -Force
$packageVersion = (
    Get-Content -LiteralPath (Join-Path $projectRoot "package.json") -Raw |
        ConvertFrom-Json).version
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

Push-Location $projectRoot
try {
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
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Release archive was not produced: $archivePath"
}
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "Release checksum was not produced: $checksumPath"
}

$signatureFileNames = @(
    "DefaultAppGuard.Agent.exe",
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

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $archiveEntries = @(
        $archive.Entries |
            ForEach-Object { $_.FullName.Replace("\", "/") })
    $requiredPackageEntries = @(
        "DefaultAppGuard.Agent.exe",
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
    mainAlgorithm = [ordered]@{
        query = "IApplicationAssociationRegistration.QueryCurrentDefault"
        monitor = "RegNotifyChangeKeyValue"
        requiredTests = $requiredTests
        passed = $true
    }
    process = [ordered]@{
        mode = "background-no-console"
        peSubsystem = $peSubsystem
        passed = $true
    }
    packageIntegrity = [ordered]@{
        manifestSchemaVersion = $publishedManifest.schemaVersion
        declaredFileCount = $packageCheck.DeclaredFileCount
        actualFileCount = $packageCheck.ActualFileCount
        passed = $packageCheck.Passed
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
    Sha256 = $archiveHash
    CodeSigningStatus = $codeSigningStatus
}
