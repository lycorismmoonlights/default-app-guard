using Microsoft.Win32;
using System.Security;
using System.Text;
using System.Text.Json;

namespace DefaultAppGuard.Setup;

internal sealed record WatchdogStatus(
    int SchemaVersion,
    string Outcome,
    DateTimeOffset InvokedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int ExitCode,
    bool PackageIntegrityPassed,
    bool InitialHealthPassed,
    bool RecoveryAttempted,
    int? PreviousProcessId,
    int? ActiveProcessId,
    int ConsecutiveRecoveryFailures,
    DateTimeOffset? NextRecoveryAllowedAtUtc,
    string? FailureStage);

internal static class WatchdogTelemetry
{
    internal const int SchemaVersion = 1;
    internal const string HealthyOutcome = "healthy";
    internal const string RecoveredOutcome = "recovered";
    internal const string DeferredOutcome = "recovery-deferred";
    internal const string FailedOutcome = "failed";
    internal const string IntegrityFailedOutcome = "package-integrity-failed";
    internal const string UnsupportedOutcome = "unsupported-platform";
    internal const string RegistrySubKeyPath =
        @"Software\DefaultAppGuard\Watchdog";
    internal const string RegistryValueName = "StatusJson";

    private static readonly TimeSpan[] RecoveryBackoffs =
    [
        TimeSpan.FromMinutes(5),
        TimeSpan.FromMinutes(10),
        TimeSpan.FromMinutes(20),
        TimeSpan.FromMinutes(40),
        TimeSpan.FromMinutes(60),
    ];

    internal static WatchdogStatus? TryRead()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistrySubKeyPath);
            return key?.GetValue(
                    RegistryValueName,
                    null,
                    RegistryValueOptions.DoNotExpandEnvironmentNames) is string json
                ? TryDeserialize(json)
                : null;
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            SecurityException or
            ObjectDisposedException)
        {
            return null;
        }
    }

    internal static WatchdogStatus? TryDeserialize(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            if (!TryGetInt32(root, "schemaVersion", out var schemaVersion) ||
                schemaVersion != SchemaVersion ||
                !TryGetString(root, "outcome", out var outcome) ||
                !TryGetDateTimeOffset(root, "invokedAtUtc", out var invokedAt) ||
                !TryGetDateTimeOffset(root, "completedAtUtc", out var completedAt) ||
                completedAt < invokedAt ||
                !TryGetInt32(root, "exitCode", out var exitCode) ||
                !TryGetBoolean(root, "packageIntegrityPassed", out var integrityPassed) ||
                !TryGetBoolean(root, "initialHealthPassed", out var initialHealthPassed) ||
                !TryGetBoolean(root, "recoveryAttempted", out var recoveryAttempted) ||
                !TryGetInt32(root, "consecutiveRecoveryFailures", out var failureCount) ||
                failureCount is < 0 or > 100)
            {
                return null;
            }

            return new WatchdogStatus(
                schemaVersion,
                outcome,
                invokedAt,
                completedAt,
                exitCode,
                integrityPassed,
                initialHealthPassed,
                recoveryAttempted,
                GetNullableInt32(root, "previousProcessId"),
                GetNullableInt32(root, "activeProcessId"),
                failureCount,
                GetNullableDateTimeOffset(root, "nextRecoveryAllowedAtUtc"),
                GetNullableString(root, "failureStage"));
        }
        catch (Exception exception) when (
            exception is JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    internal static bool ShouldDeferRecovery(
        WatchdogStatus? previous,
        DateTimeOffset now)
    {
        if (previous is null ||
            previous.ConsecutiveRecoveryFailures <= 0 ||
            previous.NextRecoveryAllowedAtUtc is not { } nextAllowed ||
            previous.CompletedAtUtc > now.AddMinutes(1) ||
            previous.CompletedAtUtc < now.AddHours(-2) ||
            nextAllowed > previous.CompletedAtUtc.AddMinutes(60))
        {
            return false;
        }

        return nextAllowed > now;
    }

    internal static int? GetLastHealthyProcessId(WatchdogStatus? previous)
    {
        return previous is
        {
            ExitCode: 0,
            ConsecutiveRecoveryFailures: 0,
            ActiveProcessId: > 0,
            Outcome: HealthyOutcome or RecoveredOutcome,
        }
            ? previous.ActiveProcessId
            : null;
    }

    internal static (int FailureCount, DateTimeOffset NextAllowedAtUtc)
        NextRecoveryFailure(WatchdogStatus? previous, DateTimeOffset now)
    {
        var priorFailures = previous?.ConsecutiveRecoveryFailures ?? 0;
        var failureCount = Math.Clamp(priorFailures + 1, 1, 100);
        var backoffIndex = Math.Min(
            failureCount - 1,
            RecoveryBackoffs.Length - 1);
        return (failureCount, now + RecoveryBackoffs[backoffIndex]);
    }

    internal static bool TryWrite(WatchdogStatus status)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(
                RegistrySubKeyPath,
                writable: true);
            if (key is null)
            {
                return false;
            }

            key.SetValue(
                RegistryValueName,
                Serialize(status),
                RegistryValueKind.String);
            key.Flush();
            return true;
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            SecurityException or
            ObjectDisposedException)
        {
            return false;
        }
    }

    internal static string Serialize(WatchdogStatus status)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(
                   stream,
                   new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", status.SchemaVersion);
            writer.WriteString("outcome", status.Outcome);
            writer.WriteString("invokedAtUtc", status.InvokedAtUtc);
            writer.WriteString("completedAtUtc", status.CompletedAtUtc);
            writer.WriteNumber("exitCode", status.ExitCode);
            writer.WriteBoolean(
                "packageIntegrityPassed",
                status.PackageIntegrityPassed);
            writer.WriteBoolean(
                "initialHealthPassed",
                status.InitialHealthPassed);
            writer.WriteBoolean("recoveryAttempted", status.RecoveryAttempted);
            WriteNullableNumber(
                writer,
                "previousProcessId",
                status.PreviousProcessId);
            WriteNullableNumber(writer, "activeProcessId", status.ActiveProcessId);
            writer.WriteNumber(
                "consecutiveRecoveryFailures",
                status.ConsecutiveRecoveryFailures);
            if (status.NextRecoveryAllowedAtUtc is { } nextAllowed)
            {
                writer.WriteString("nextRecoveryAllowedAtUtc", nextAllowed);
            }
            else
            {
                writer.WriteNull("nextRecoveryAllowedAtUtc");
            }

            if (status.FailureStage is { } failureStage)
            {
                writer.WriteString("failureStage", failureStage);
            }
            else
            {
                writer.WriteNull("failureStage");
            }

            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static bool TryGetInt32(
        JsonElement element,
        string name,
        out int value)
    {
        value = 0;
        return element.TryGetProperty(name, out var property) &&
            property.TryGetInt32(out value);
    }

    private static bool TryGetBoolean(
        JsonElement element,
        string name,
        out bool value)
    {
        value = false;
        if (!element.TryGetProperty(name, out var property) ||
            property.ValueKind is not (
                JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }

        value = property.GetBoolean();
        return true;
    }

    private static bool TryGetString(
        JsonElement element,
        string name,
        out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(name, out var property) ||
            property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value);
    }

    private static bool TryGetDateTimeOffset(
        JsonElement element,
        string name,
        out DateTimeOffset value)
    {
        value = default;
        return element.TryGetProperty(name, out var property) &&
            property.ValueKind == JsonValueKind.String &&
            property.TryGetDateTimeOffset(out value);
    }

    private static int? GetNullableInt32(JsonElement element, string name)
    {
        return element.TryGetProperty(name, out var property) &&
            property.ValueKind != JsonValueKind.Null &&
            property.TryGetInt32(out var value)
                ? value
                : null;
    }

    private static DateTimeOffset? GetNullableDateTimeOffset(
        JsonElement element,
        string name)
    {
        return element.TryGetProperty(name, out var property) &&
            property.ValueKind != JsonValueKind.Null &&
            property.TryGetDateTimeOffset(out var value)
                ? value
                : null;
    }

    private static string? GetNullableString(JsonElement element, string name)
    {
        return element.TryGetProperty(name, out var property) &&
            property.ValueKind == JsonValueKind.String
                ? property.GetString()
                : null;
    }

    private static void WriteNullableNumber(
        Utf8JsonWriter writer,
        string name,
        int? value)
    {
        if (value is { } number)
        {
            writer.WriteNumber(name, number);
        }
        else
        {
            writer.WriteNull(name);
        }
    }
}
