using System.Security.Cryptography;
using System.Text.Json;

namespace DefaultAppGuard.Setup;

public sealed record PackageIntegrityResult(
    bool Passed,
    string? Version,
    int DeclaredFileCount,
    int ActualFileCount,
    IReadOnlyList<string> IssueCodes);

public static class PackageIntegrityVerifier
{
    private const string ManifestFileName = "package-manifest.json";

    public static PackageIntegrityResult Verify(string packageRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageRoot);

        var issues = new HashSet<string>(StringComparer.Ordinal);
        var declaredFileCount = 0;
        var actualFileCount = 0;
        string? version = null;

        try
        {
            var root = Path.GetFullPath(packageRoot).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar);
            var manifestPath = Path.Combine(root, ManifestFileName);
            if (!Directory.Exists(root))
            {
                issues.Add("package-root-missing");
                return CreateResult();
            }

            if (!File.Exists(manifestPath))
            {
                issues.Add("package-manifest-missing");
                return CreateResult();
            }

            var manifestBytes = File.ReadAllBytes(manifestPath);
            var manifestOffset = manifestBytes.Length >= 3 &&
                manifestBytes[0] == 0xEF &&
                manifestBytes[1] == 0xBB &&
                manifestBytes[2] == 0xBF
                ? 3
                : 0;
            using var document = JsonDocument.Parse(
                manifestBytes.AsMemory(manifestOffset));
            var manifest = document.RootElement;
            if (manifest.ValueKind != JsonValueKind.Object)
            {
                issues.Add("package-manifest-schema");
                return CreateResult();
            }

            if (!manifest.TryGetProperty("schemaVersion", out var schema) ||
                !schema.TryGetInt32(out var schemaVersion) ||
                schemaVersion != 2)
            {
                issues.Add("package-manifest-schema");
            }

            if (!TryGetString(manifest, "product", out var product) ||
                !string.Equals(
                    product,
                    "DefaultAppGuard Community",
                    StringComparison.Ordinal))
            {
                issues.Add("package-product");
            }

            if (!TryGetString(manifest, "version", out version))
            {
                issues.Add("package-version");
            }

            if (!TryGetString(manifest, "processMode", out var processMode) ||
                !string.Equals(
                    processMode,
                    "background-no-console",
                    StringComparison.Ordinal))
            {
                issues.Add("package-process-mode");
            }

            if (!manifest.TryGetProperty("payload", out var payload) ||
                payload.ValueKind != JsonValueKind.Array)
            {
                issues.Add("package-payload-missing");
                return CreateResult();
            }

            declaredFileCount = payload.GetArrayLength();
            if (declaredFileCount == 0)
            {
                issues.Add("package-payload-empty");
            }

            var declaredPaths = new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);
            foreach (var entry in payload.EnumerateArray())
            {
                VerifyEntry(root, manifestPath, entry, declaredPaths, issues);
            }

            var actualPaths = Directory.EnumerateFiles(
                    root,
                    "*",
                    SearchOption.AllDirectories)
                .Where(path => !string.Equals(
                    Path.GetFullPath(path),
                    manifestPath,
                    StringComparison.OrdinalIgnoreCase))
                .Select(path => Path.GetRelativePath(root, path))
                .ToArray();
            actualFileCount = actualPaths.Length;
            foreach (var actualPath in actualPaths)
            {
                if (!declaredPaths.Contains(actualPath))
                {
                    issues.Add("package-file-undeclared");
                }
            }

            if (actualFileCount != declaredFileCount)
            {
                issues.Add("package-file-count");
            }
        }
        catch (JsonException)
        {
            issues.Add("package-manifest-unreadable");
        }
        catch (IOException)
        {
            issues.Add("package-io-error");
        }
        catch (UnauthorizedAccessException)
        {
            issues.Add("package-access-denied");
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException)
        {
            issues.Add("package-entry-invalid");
        }

        return CreateResult();

        PackageIntegrityResult CreateResult()
        {
            var issueCodes = issues.Order(StringComparer.Ordinal).ToArray();
            return new PackageIntegrityResult(
                issueCodes.Length == 0,
                version,
                declaredFileCount,
                actualFileCount,
                issueCodes);
        }
    }

    private static void VerifyEntry(
        string root,
        string manifestPath,
        JsonElement entry,
        ISet<string> declaredPaths,
        ISet<string> issues)
    {
        if (entry.ValueKind != JsonValueKind.Object ||
            !TryGetString(entry, "path", out var relativePath) ||
            Path.IsPathRooted(relativePath))
        {
            issues.Add("package-path-unsafe");
            return;
        }

        var candidate = Path.GetFullPath(Path.Combine(root, relativePath));
        if (!IsWithin(candidate, root) ||
            string.Equals(
                candidate,
                manifestPath,
                StringComparison.OrdinalIgnoreCase))
        {
            issues.Add("package-path-escape");
            return;
        }

        var normalizedRelativePath = Path.GetRelativePath(root, candidate);
        if (!declaredPaths.Add(normalizedRelativePath))
        {
            issues.Add("package-path-duplicate");
            return;
        }

        if (!File.Exists(candidate))
        {
            issues.Add("package-file-missing");
            return;
        }

        if (!entry.TryGetProperty("length", out var lengthElement) ||
            !lengthElement.TryGetInt64(out var expectedLength) ||
            expectedLength < 0 ||
            new FileInfo(candidate).Length != expectedLength)
        {
            issues.Add("package-file-length");
            return;
        }

        if (!TryGetString(entry, "sha256", out var expectedHash) ||
            expectedHash.Length != 64 ||
            !expectedHash.All(Uri.IsHexDigit))
        {
            issues.Add("package-file-hash");
            return;
        }

        using var stream = File.OpenRead(candidate);
        var actualHash = Convert.ToHexString(SHA256.HashData(stream));
        if (!string.Equals(
                actualHash,
                expectedHash,
                StringComparison.OrdinalIgnoreCase))
        {
            issues.Add("package-file-hash");
        }
    }

    private static bool TryGetString(
        JsonElement element,
        string propertyName,
        out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(propertyName, out var property) ||
            property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        var candidate = property.GetString();
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return false;
        }

        value = candidate;
        return true;
    }

    private static bool IsWithin(string path, string root)
    {
        return path.StartsWith(
            root + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);
    }
}
