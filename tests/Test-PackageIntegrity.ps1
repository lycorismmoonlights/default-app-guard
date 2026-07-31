[CmdletBinding()]
param()

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

$projectRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot ".."))
Import-Module -Name (
    Join-Path $projectRoot "packaging\DefaultAppGuard.Package.psm1") `
    -Force

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "DefaultAppGuard-package-test-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $agentPath = Join-Path $testRoot "DefaultAppGuard.Agent.exe"
    $readmePath = Join-Path $testRoot "README.txt"
    Copy-Item `
        -LiteralPath (Join-Path $env:WINDIR "System32\notepad.exe") `
        -Destination $agentPath
    "fixture" | Set-Content -LiteralPath $readmePath -Encoding Ascii

    $versionInfo = (Get-Item -LiteralPath $agentPath).VersionInfo
    $version = "{0}.{1}.{2}" -f `
        $versionInfo.FileMajorPart,
        $versionInfo.FileMinorPart,
        $versionInfo.FileBuildPart
    $payload = @(
        Get-ChildItem -LiteralPath $testRoot -File |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    path = $_.Name
                    length = $_.Length
                    sha256 = (Get-FileHash `
                        -LiteralPath $_.FullName `
                        -Algorithm SHA256).Hash
                }
            })
    $manifest = [ordered]@{
        schemaVersion = 2
        product = "DefaultAppGuard Community"
        version = $version
        executable = "DefaultAppGuard.Agent.exe"
        processMode = "background-no-console"
        payload = $payload
    }
    $manifestPath = Join-Path $testRoot "package-manifest.json"
    $manifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $valid = Test-DagPackageIntegrity -PackageRoot $testRoot
    Assert-True $valid.Passed "A valid package fixture was rejected."

    "tampered" | Add-Content -LiteralPath $readmePath -Encoding Ascii
    $tampered = Test-DagPackageIntegrity -PackageRoot $testRoot
    Assert-True `
        (-not $tampered.Passed) `
        "A modified payload file was accepted."
    Assert-True `
        ("package-file-length" -in $tampered.IssueCodes -or
            "package-file-hash" -in $tampered.IssueCodes) `
        "Payload modification did not produce an integrity issue."

    "fixture" | Set-Content -LiteralPath $readmePath -Encoding Ascii
    $manifest.payload = @(
        Get-ChildItem -LiteralPath $testRoot -File |
            Where-Object { $_.Name -ne "package-manifest.json" } |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    path = $_.Name
                    length = $_.Length
                    sha256 = (Get-FileHash `
                        -LiteralPath $_.FullName `
                        -Algorithm SHA256).Hash
                }
            })
    $manifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    "undeclared" |
        Set-Content `
            -LiteralPath (Join-Path $testRoot "extra.txt") `
            -Encoding Ascii
    $mixed = Test-DagPackageIntegrity -PackageRoot $testRoot
    Assert-True `
        (-not $mixed.Passed) `
        "A package with an undeclared file was accepted."
    Assert-True `
        ("package-file-undeclared" -in $mixed.IssueCodes) `
        "The undeclared file was not reported."

    Remove-Item -LiteralPath (Join-Path $testRoot "extra.txt") -Force
    $manifest.payload[1].path = "..\outside.txt"
    $manifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $escaping = Test-DagPackageIntegrity -PackageRoot $testRoot
    Assert-True `
        (-not $escaping.Passed) `
        "A package with a path traversal entry was accepted."
    Assert-True `
        ("package-path-escape" -in $escaping.IssueCodes) `
        "The path traversal entry was not reported."

    $manifest.payload[1].path = "README.txt"
    $manifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    function global:Get-FileHash {
        throw "Package verification must not depend on Get-FileHash."
    }
    try {
        $validWithoutCmdlet = Test-DagPackageIntegrity -PackageRoot $testRoot
        Assert-True `
            $validWithoutCmdlet.Passed `
            "Package verification depends on the Get-FileHash command."
    } finally {
        Remove-Item Function:\Get-FileHash -Force
    }

    "Package integrity behavior tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
