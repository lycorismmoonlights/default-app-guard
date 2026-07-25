[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,
    [string]$OutputRoot,
    [string]$PackageManagerPath = "pnpm",
    [string]$NodePath = "node"
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

    $parseFailures = @()
    foreach ($script in Get-ChildItem $PSScriptRoot -Filter "*.ps1" -File) {
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
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Release archive was not produced: $archivePath"
}
if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "Release checksum was not produced: $checksumPath"
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
    archive = [IO.Path]::GetFileName($archivePath)
    sha256 = $archiveHash
} |
    ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $evidenceFile -Encoding UTF8

[pscustomobject]@{
    OutputRoot = $releaseRoot
    PackageDirectory = $packageDirectory
    Archive = $archivePath
    ChecksumFile = $checksumPath
    EvidenceFile = $evidenceFile
    Sha256 = $archiveHash
}
