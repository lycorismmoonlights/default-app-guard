[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-2022", "windows-2025")]
    [string]$RequestedLabel,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expected = switch ($RequestedLabel) {
    "windows-2022" {
        [pscustomobject]@{
            ImagePrefix = "win22"
            OsBuild = 20348
        }
    }
    "windows-2025" {
        [pscustomobject]@{
            ImagePrefix = "win25"
            OsBuild = 26100
        }
    }
}

if ($env:GITHUB_ACTIONS -ne "true") {
    throw "Hosted Windows runner validation must run in GitHub Actions."
}
if ($env:RUNNER_OS -ne "Windows") {
    throw "The requested compatibility job is not running on Windows."
}
if ($env:RUNNER_ARCH -ne "X64") {
    throw "The requested compatibility job is not running on x64."
}
if ([string]::IsNullOrWhiteSpace($env:ImageOS) -or
    -not $env:ImageOS.StartsWith(
        $expected.ImagePrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw (
        "Runner image '$($env:ImageOS)' does not match requested label " +
        "'$RequestedLabel'.")
}
if ([string]::IsNullOrWhiteSpace($env:ImageVersion)) {
    throw "GitHub runner image version is unavailable."
}

$osVersion = [Environment]::OSVersion.Version
if ($osVersion.Major -ne 10 -or
    $osVersion.Minor -ne 0 -or
    $osVersion.Build -ne $expected.OsBuild) {
    throw (
        "Runner OS version '$osVersion' does not match requested label " +
        "'$RequestedLabel'.")
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$evidence = [ordered]@{
    schemaVersion = 1
    requestedLabel = $RequestedLabel
    imageOS = [string]$env:ImageOS
    imageVersion = [string]$env:ImageVersion
    runnerOS = [string]$env:RUNNER_OS
    runnerArchitecture = [string]$env:RUNNER_ARCH
    operatingSystem = [Environment]::OSVersion.VersionString
    operatingSystemBuild = $osVersion.Build
    validationPassed = $true
}
$evidence | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $OutputPath -Encoding UTF8

[pscustomobject]$evidence
