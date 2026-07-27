[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory,
    [Alias("PnpmPath")]
    [string]$PackageManagerPath = "pnpm",
    [string]$NodePath = "node",
    [switch]$CreateArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot ".."))
Import-Module -Name (
    Join-Path $PSScriptRoot "DefaultAppGuard.Package.psm1") `
    -Force
$packageMetadata = Get-Content `
    -LiteralPath (Join-Path $projectRoot "package.json") `
    -Raw |
    ConvertFrom-Json
$riskNoticePath = Join-Path $projectRoot "ENVIRONMENT-AND-RISKS.txt"
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $packageMetadata.version
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version without a v prefix."
}
if ($Version -ne $packageMetadata.version) {
    throw "Requested version $Version does not match package.json."
}
$riskNoticeVersionLine = "Applies to version: $Version"
$riskNotice = Get-Content -LiteralPath $riskNoticePath -Raw -Encoding UTF8
if (-not $riskNotice.Contains($riskNoticeVersionLine)) {
    throw "ENVIRONMENT-AND-RISKS.txt is not updated for version $Version."
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot `
        "artifacts\DefaultAppGuard-$Version-win-x64"
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)

if (Test-Path -LiteralPath $outputPath) {
    throw "Output directory already exists: $outputPath"
}

New-Item -ItemType Directory -Path $outputPath | Out-Null

$nodeCommand = Get-Command $NodePath -ErrorAction Stop
$originalPath = $env:Path
$env:Path = "$([System.IO.Path]::GetDirectoryName($nodeCommand.Source));$env:Path"

Push-Location $projectRoot
try {
    & $PackageManagerPath run build
    if ($LASTEXITCODE -ne 0) {
        throw "Frontend production build failed with exit code $LASTEXITCODE."
    }

    dotnet publish `
        "native\DefaultAppGuard.Agent\DefaultAppGuard.Agent.csproj" `
        --configuration Release `
        --runtime win-x64 `
        --self-contained true `
        -p:PublishProfile=win-x64 `
        -p:DebugType=None `
        -p:DebugSymbols=false `
        --output $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw "Agent publish failed with exit code $LASTEXITCODE."
    }

    $webRoot = Join-Path $outputPath "wwwroot"
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "dist\client") `
        -Destination $webRoot `
        -Recurse
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot "Install-DefaultAppGuard.ps1") `
        -Destination $outputPath
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot "Uninstall-DefaultAppGuard.ps1") `
        -Destination $outputPath
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot "Get-DefaultAppGuardDiagnostics.ps1") `
        -Destination $outputPath
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot "DefaultAppGuard.Package.psm1") `
        -Destination $outputPath
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "docs\USER-GUIDE.md") `
        -Destination (Join-Path $outputPath "README.md")
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "LICENSE.md") `
        -Destination $outputPath
    Copy-Item `
        -LiteralPath (Join-Path $projectRoot "NOTICE") `
        -Destination $outputPath
    Copy-Item `
        -LiteralPath $riskNoticePath `
        -Destination $outputPath
} catch {
    Write-Error $_
    throw
} finally {
    Pop-Location
    $env:Path = $originalPath
}

$payload = @(
    Get-ChildItem -LiteralPath $outputPath -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            [ordered]@{
                path = Get-DagRelativePackagePath `
                    -Root $outputPath `
                    -Path $_.FullName
                length = $_.Length
                sha256 = (Get-FileHash `
                    -LiteralPath $_.FullName `
                    -Algorithm SHA256).Hash
            }
        }
)

$manifest = [ordered]@{
    schemaVersion = 2
    product = "DefaultAppGuard Community"
    version = $Version
    runtime = "win-x64"
    executable = "DefaultAppGuard.Agent.exe"
    processMode = "background-no-console"
    ui = "wwwroot\index.html"
    license = "PolyForm Noncommercial License 1.0.0"
    environmentAndRisks = "ENVIRONMENT-AND-RISKS.txt"
    builtAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    payload = $payload
}
$manifest |
    ConvertTo-Json |
    Set-Content `
        -LiteralPath (Join-Path $outputPath "package-manifest.json") `
        -Encoding UTF8
$packageCheck = Test-DagPackageIntegrity -PackageRoot $outputPath
if (-not $packageCheck.Passed) {
    throw "Published package integrity failed: $(
        $packageCheck.IssueCodes -join ', ')"
}

$archivePath = $null
$checksumPath = $null
$archiveHash = $null
if ($CreateArchive) {
    $archivePath = "$outputPath.zip"
    if (Test-Path -LiteralPath $archivePath) {
        throw "Archive already exists: $archivePath"
    }

    Compress-Archive `
        -Path (Join-Path $outputPath "*") `
        -DestinationPath $archivePath `
        -CompressionLevel Optimal

    $archiveHash = (Get-FileHash -LiteralPath $archivePath `
        -Algorithm SHA256).Hash
    $checksumPath = "$archivePath.sha256"
    "$archiveHash  $([IO.Path]::GetFileName($archivePath))" |
        Set-Content -LiteralPath $checksumPath -Encoding Ascii
}

[pscustomobject]@{
    OutputDirectory = $outputPath
    Archive = $archivePath
    ChecksumFile = $checksumPath
    Sha256 = $archiveHash
}
