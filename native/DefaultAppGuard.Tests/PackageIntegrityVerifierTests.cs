using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DefaultAppGuard.Setup;

namespace DefaultAppGuard.Tests;

public sealed class PackageIntegrityVerifierTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        "DefaultAppGuard.PackageIntegrityVerifierTests",
        Guid.NewGuid().ToString("N"));

    [Fact]
    public void Verify_AcceptsCompletePackage()
    {
        WritePackage(new Dictionary<string, string>
        {
            ["DefaultAppGuard.Agent.exe"] = "agent",
            ["wwwroot/index.html"] = "ui",
        });

        var result = PackageIntegrityVerifier.Verify(root);

        Assert.True(result.Passed);
        Assert.Equal("1.2.3", result.Version);
        Assert.Equal(2, result.DeclaredFileCount);
        Assert.Equal(2, result.ActualFileCount);
        Assert.Empty(result.IssueCodes);
    }

    [Fact]
    public void Verify_AcceptsWindowsPowerShellUtf8BomManifest()
    {
        WritePackage(new Dictionary<string, string>
        {
            ["DefaultAppGuard.Agent.exe"] = "agent",
        });
        var manifestPath = Path.Combine(root, "package-manifest.json");
        var json = File.ReadAllText(manifestPath);
        File.WriteAllText(manifestPath, json, new UTF8Encoding(true));

        var result = PackageIntegrityVerifier.Verify(root);

        Assert.True(result.Passed);
        Assert.Empty(result.IssueCodes);
    }

    [Fact]
    public void Verify_RejectsTamperedPayload()
    {
        WritePackage(new Dictionary<string, string>
        {
            ["Install-DefaultAppGuard.ps1"] = "original",
        });
        File.WriteAllText(
            Path.Combine(root, "Install-DefaultAppGuard.ps1"),
            "tampered");

        var result = PackageIntegrityVerifier.Verify(root);

        Assert.False(result.Passed);
        Assert.Contains("package-file-hash", result.IssueCodes);
    }

    [Fact]
    public void Verify_RejectsUndeclaredPayload()
    {
        WritePackage(new Dictionary<string, string>
        {
            ["DefaultAppGuard.Agent.exe"] = "agent",
        });
        File.WriteAllText(Path.Combine(root, "unexpected.dll"), "unexpected");

        var result = PackageIntegrityVerifier.Verify(root);

        Assert.False(result.Passed);
        Assert.Contains("package-file-undeclared", result.IssueCodes);
        Assert.Contains("package-file-count", result.IssueCodes);
    }

    [Fact]
    public void Verify_RejectsEscapingPath()
    {
        Directory.CreateDirectory(root);
        WriteManifest(
        [
            new PayloadEntry("../outside.ps1", 1, new string('0', 64)),
        ]);

        var result = PackageIntegrityVerifier.Verify(root);

        Assert.False(result.Passed);
        Assert.Contains("package-path-escape", result.IssueCodes);
    }

    [Fact]
    public void Verify_RejectsCaseInsensitiveDuplicatePath()
    {
        Directory.CreateDirectory(root);
        var filePath = Path.Combine(root, "payload.txt");
        File.WriteAllText(filePath, "payload");
        var entry = CreateEntry("payload.txt", filePath);
        WriteManifest(
        [
            entry,
            entry with { Path = "PAYLOAD.TXT" },
        ]);

        var result = PackageIntegrityVerifier.Verify(root);

        Assert.False(result.Passed);
        Assert.Contains("package-path-duplicate", result.IssueCodes);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private void WritePackage(IReadOnlyDictionary<string, string> files)
    {
        Directory.CreateDirectory(root);
        var entries = new List<PayloadEntry>();
        foreach (var (relativePath, content) in files)
        {
            var filePath = Path.Combine(
                root,
                relativePath.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
            File.WriteAllText(filePath, content);
            entries.Add(CreateEntry(relativePath, filePath));
        }

        WriteManifest(entries);
    }

    private void WriteManifest(IReadOnlyList<PayloadEntry> entries)
    {
        var manifest = new
        {
            schemaVersion = 2,
            product = "DefaultAppGuard Community",
            version = "1.2.3",
            processMode = "background-no-console",
            payload = entries.Select(entry => new
            {
                path = entry.Path,
                length = entry.Length,
                sha256 = entry.Sha256,
            }),
        };
        File.WriteAllText(
            Path.Combine(root, "package-manifest.json"),
            JsonSerializer.Serialize(manifest));
    }

    private static PayloadEntry CreateEntry(string relativePath, string filePath)
    {
        using var stream = File.OpenRead(filePath);
        return new PayloadEntry(
            relativePath,
            stream.Length,
            Convert.ToHexString(SHA256.HashData(stream)));
    }

    private sealed record PayloadEntry(string Path, long Length, string Sha256);
}
