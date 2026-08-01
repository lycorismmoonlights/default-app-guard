using System.Text.Json;
using DefaultAppGuard.Setup;

namespace DefaultAppGuard.Tests;

public sealed class WatchdogReadinessTests
{
    [Fact]
    public void TryMatchReadiness_AcceptsFreshCompletePrimaryEvidence()
    {
        using var document = CreateReadiness();

        Assert.True(WatchdogRunner.TryMatchReadiness(document.RootElement));
    }

    [Theory]
    [InlineData("audit-stale", false, 1201, 1200, 34, 34, 0)]
    [InlineData("ready", true, 1201, 1200, 34, 34, 0)]
    [InlineData("ready", true, 30, 1200, 34, 33, 0)]
    [InlineData("ready", true, 30, 1200, 34, 34, 1)]
    public void TryMatchReadiness_RejectsUnusableEvidence(
        string code,
        bool auditFresh,
        long auditAgeSeconds,
        long maximumAuditAgeSeconds,
        int auditedExtensionCount,
        int primarySnapshotCount,
        int failedReadCount)
    {
        using var document = CreateReadiness(
            code,
            auditFresh,
            auditAgeSeconds,
            maximumAuditAgeSeconds,
            auditedExtensionCount,
            primarySnapshotCount,
            failedReadCount);

        Assert.False(WatchdogRunner.TryMatchReadiness(document.RootElement));
    }

    [Fact]
    public void TryMatchReadiness_RejectsMissingFreshnessContract()
    {
        using var document = JsonDocument.Parse(
            """
            {
              "ready": true,
              "code": "ready",
              "serviceState": "running",
              "query": "IApplicationAssociationRegistration.QueryCurrentDefault",
              "monitor": "RegNotifyChangeKeyValue",
              "targetProgId": "Media.Player",
              "targetPackageId": "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
              "auditedExtensionCount": 34,
              "primarySnapshotCount": 34,
              "failedReadCount": 0
            }
            """);

        Assert.False(WatchdogRunner.TryMatchReadiness(document.RootElement));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("true")]
    public void TryMatchReadiness_RejectsNonObjectJson(string json)
    {
        using var document = JsonDocument.Parse(json);

        Assert.False(WatchdogRunner.TryMatchReadiness(document.RootElement));
    }

    private static JsonDocument CreateReadiness(
        string code = "ready",
        bool auditFresh = true,
        long auditAgeSeconds = 30,
        long maximumAuditAgeSeconds = 1200,
        int auditedExtensionCount = 34,
        int primarySnapshotCount = 34,
        int failedReadCount = 0)
    {
        return JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            ready = code == "ready",
            code,
            serviceState = "running",
            query = "IApplicationAssociationRegistration.QueryCurrentDefault",
            monitor = "RegNotifyChangeKeyValue",
            targetProgId = "Media.Player",
            targetPackageId =
                "Microsoft.ZuneMusic_1.0_x64__8wekyb3d8bbwe",
            auditedExtensionCount,
            primarySnapshotCount,
            failedReadCount,
            auditFresh,
            auditAgeSeconds,
            maximumAuditAgeSeconds,
        }));
    }
}
