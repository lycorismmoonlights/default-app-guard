Set-StrictMode -Version Latest

function Get-DagNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
}

function Test-DagPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $normalizedPath = Get-DagNormalizedPath $Path
    $normalizedParent = Get-DagNormalizedPath $Parent
    return $normalizedPath.StartsWith(
        "$normalizedParent$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-DagRelativePackagePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $normalizedRoot = Get-DagNormalizedPath $Root
    $normalizedPath = Get-DagNormalizedPath $Path
    if (-not (Test-DagPathWithin `
            -Path $normalizedPath `
            -Parent $normalizedRoot)) {
        throw "Package file is outside the package root."
    }

    return $normalizedPath.Substring($normalizedRoot.Length + 1)
}

function Get-DagFileFingerprint {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return [pscustomobject]@{
                Length = $stream.Length
                Sha256 = [BitConverter]::ToString($hashBytes).Replace("-", "")
            }
        } finally {
            $sha256.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-DagPeSubsystem {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "Agent does not contain a valid DOS header."
        }

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 94)) {
            throw "Agent contains an invalid PE header offset."
        }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Agent does not contain a valid PE signature."
        }

        $stream.Position = $peOffset + 24
        $optionalHeaderMagic = $reader.ReadUInt16()
        if ($optionalHeaderMagic -notin @(0x010B, 0x020B)) {
            throw "Agent contains an unsupported PE optional header."
        }

        $stream.Position = $peOffset + 24 + 68
        return $reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}

function Test-DagPackageIntegrity {
    param([Parameter(Mandatory)][string]$PackageRoot)

    $root = Get-DagNormalizedPath $PackageRoot
    $manifestPath = Join-Path $root "package-manifest.json"
    $issues = [Collections.Generic.List[string]]::new()
    $invalidEntryDetails = [Collections.Generic.List[string]]::new()
    $manifest = $null
    $declaredFileCount = 0
    $actualFileCount = 0

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $issues.Add("package-manifest-missing")
    } else {
        try {
            $manifest = Get-Content `
                -LiteralPath $manifestPath `
                -Raw `
                -Encoding UTF8 |
                ConvertFrom-Json
        } catch {
            $issues.Add("package-manifest-unreadable")
        }
    }

    if ($null -ne $manifest) {
        if ($null -eq $manifest.PSObject.Properties["schemaVersion"] -or
            $manifest.schemaVersion -ne 2) {
            $issues.Add("package-manifest-schema")
        }
        if ($null -eq $manifest.PSObject.Properties["product"] -or
            $manifest.product -ne "DefaultAppGuard Community") {
            $issues.Add("package-product")
        }
        if ($null -eq $manifest.PSObject.Properties["version"] -or
            [string]::IsNullOrWhiteSpace($manifest.version)) {
            $issues.Add("package-version")
        }
        if ($null -eq $manifest.PSObject.Properties["processMode"] -or
            $manifest.processMode -ne "background-no-console") {
            $issues.Add("package-process-mode")
        }

        $entries = @()
        if ($null -eq $manifest.PSObject.Properties["payload"]) {
            $issues.Add("package-payload-missing")
        } else {
            $entries = @($manifest.payload)
        }
        $declaredFileCount = $entries.Count
        if ($declaredFileCount -eq 0) {
            $issues.Add("package-payload-empty")
        }

        $declaredPaths = @{}
        foreach ($entry in $entries) {
            $relativePath = "<unknown>"
            $entryStage = "read-entry"
            try {
                $relativePath = [string]$entry.path
                if ([string]::IsNullOrWhiteSpace($relativePath) -or
                    [IO.Path]::IsPathRooted($relativePath)) {
                    $issues.Add("package-path-unsafe")
                    continue
                }

                $entryStage = "normalize-path"
                $candidate = [IO.Path]::GetFullPath(
                    (Join-Path $root $relativePath))
                $entryStage = "check-containment"
                if (-not (Test-DagPathWithin `
                        -Path $candidate `
                        -Parent $root)) {
                    $issues.Add("package-path-escape")
                    continue
                }
                $entryStage = "check-duplicate"
                if ($declaredPaths.ContainsKey($relativePath)) {
                    $issues.Add("package-path-duplicate")
                    continue
                }
                $declaredPaths[$relativePath] = $true

                $entryStage = "check-file"
                if (-not (Test-Path `
                        -LiteralPath $candidate `
                        -PathType Leaf)) {
                    $issues.Add("package-file-missing")
                    continue
                }
                $entryStage = "fingerprint-file"
                $fingerprint = Get-DagFileFingerprint -Path $candidate
                $entryStage = "check-length"
                if ($null -eq $entry.PSObject.Properties["length"] -or
                    $fingerprint.Length -ne [long]$entry.length) {
                    $issues.Add("package-file-length")
                    continue
                }

                $entryStage = "check-hash"
                if ($null -eq $entry.PSObject.Properties["sha256"] -or
                    -not $fingerprint.Sha256.Equals(
                        [string]$entry.sha256,
                        [StringComparison]::OrdinalIgnoreCase)) {
                    $issues.Add("package-file-hash")
                }
            } catch {
                $issues.Add("package-entry-invalid")
                $safeRelativePath = $relativePath -replace '[\r\n]', '?'
                $invalidEntryDetails.Add(
                    "$safeRelativePath [$entryStage/$($_.Exception.GetType().Name)]")
            }
        }

        $actualPayloadPaths = @(
            Get-ChildItem -LiteralPath $root -Recurse -File |
                Where-Object {
                    (Get-DagNormalizedPath $_.FullName) -ne
                    (Get-DagNormalizedPath $manifestPath)
                } |
                ForEach-Object {
                    Get-DagRelativePackagePath `
                        -Root $root `
                        -Path $_.FullName
                }
        )
        $actualFileCount = $actualPayloadPaths.Count
        foreach ($actualPath in $actualPayloadPaths) {
            if (-not $declaredPaths.ContainsKey($actualPath)) {
                $issues.Add("package-file-undeclared")
            }
        }
        if ($actualFileCount -ne $declaredFileCount) {
            $issues.Add("package-file-count")
        }

        if ($null -eq $manifest.PSObject.Properties["executable"] -or
            [string]::IsNullOrWhiteSpace($manifest.executable)) {
            $issues.Add("package-executable-name")
        } else {
            $agentPath = Join-Path $root ([string]$manifest.executable)
            if (-not (Test-Path `
                    -LiteralPath $agentPath `
                    -PathType Leaf)) {
                $issues.Add("package-executable-missing")
            } else {
                try {
                    if ((Get-DagPeSubsystem -Path $agentPath) -ne 2) {
                        $issues.Add("package-executable-subsystem")
                    }
                } catch {
                    $issues.Add("package-executable-invalid")
                }

                try {
                    $versionCore = ([string]$manifest.version).Split("-")[0]
                    $version = [Version]$versionCore
                    $versionInfo = (
                        Get-Item -LiteralPath $agentPath).VersionInfo
                    if ($versionInfo.FileMajorPart -ne $version.Major -or
                        $versionInfo.FileMinorPart -ne $version.Minor -or
                        $versionInfo.FileBuildPart -ne $version.Build) {
                        $issues.Add("package-executable-version")
                    }
                } catch {
                    $issues.Add("package-version-invalid")
                }
            }
        }
    }

    $uniqueIssues = @($issues | Sort-Object -Unique)
    return [pscustomobject]@{
        Passed = $uniqueIssues.Count -eq 0
        Manifest = $manifest
        DeclaredFileCount = $declaredFileCount
        ActualFileCount = $actualFileCount
        IssueCodes = $uniqueIssues
        InvalidEntryDetails = @(
            $invalidEntryDetails |
                Sort-Object -Unique)
    }
}

function Assert-DagPackageIntegrity {
    param([Parameter(Mandatory)][string]$PackageRoot)

    $result = Test-DagPackageIntegrity -PackageRoot $PackageRoot
    if (-not $result.Passed) {
        $entryDetails = if ($result.InvalidEntryDetails.Count -gt 0) {
            ". Invalid entries: $($result.InvalidEntryDetails -join '; ')"
        } else {
            ""
        }
        throw "Package integrity verification failed: $(
            $result.IssueCodes -join ', ')$entryDetails"
    }

    return $result.Manifest
}

Export-ModuleMember -Function @(
    "Assert-DagPackageIntegrity",
    "Get-DagNormalizedPath",
    "Get-DagPeSubsystem",
    "Get-DagRelativePackagePath",
    "Test-DagPackageIntegrity",
    "Test-DagPathWithin"
)
