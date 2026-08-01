using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace DefaultAppGuard.Setup;

internal sealed record WatchdogOptions(
    Uri AgentUri,
    string StatePath,
    string ConfigurationPath)
{
    internal static WatchdogOptions Create(
        string? url,
        string? statePath,
        string? configurationPath)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            !uri.IsLoopback ||
            uri.Scheme != Uri.UriSchemeHttp ||
            uri.AbsolutePath != "/" ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) ||
            !string.IsNullOrEmpty(uri.UserInfo))
        {
            throw new ArgumentException(
                "--url must be a loopback HTTP origin without a path or query.");
        }

        if (string.IsNullOrWhiteSpace(statePath) ||
            !Path.IsPathFullyQualified(statePath))
        {
            throw new ArgumentException("--state must be an absolute file path.");
        }

        if (string.IsNullOrWhiteSpace(configurationPath) ||
            !Path.IsPathFullyQualified(configurationPath))
        {
            throw new ArgumentException("--config must be an absolute file path.");
        }

        var normalizedStatePath = Path.GetFullPath(statePath);
        var normalizedConfigurationPath = Path.GetFullPath(configurationPath);
        if (string.Equals(
                normalizedStatePath,
                normalizedConfigurationPath,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "--state and --config must use different files.");
        }

        return new WatchdogOptions(
            new Uri(uri.AbsoluteUri.TrimEnd('/') + "/"),
            normalizedStatePath,
            normalizedConfigurationPath);
    }
}

internal static class WatchdogRunner
{
    private const string AgentFileName = "DefaultAppGuard.Agent.exe";
    private const string ExpectedService = "DefaultAppGuard.Agent";
    private const string ExpectedQuery =
        "IApplicationAssociationRegistration.QueryCurrentDefault";
    private const string ExpectedMonitor = "RegNotifyChangeKeyValue";
    private const string ExpectedProcessMode = "background-no-console";
    private const string ExpectedNotificationChannel =
        "WindowsForms.NotifyIcon";
    private const string ExpectedConfigurationStorage =
        "runtime/guard-configuration.json";
    private const string ExpectedConfigurationBackupStorage =
        "runtime/guard-configuration.json.bak";

    internal static int Run(WatchdogOptions options)
    {
        var invokedAtUtc = DateTimeOffset.UtcNow;
        var previousStatus = WatchdogTelemetry.TryRead();

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ||
            !Environment.Is64BitOperatingSystem)
        {
            WriteStatus(
                invokedAtUtc,
                WatchdogTelemetry.UnsupportedOutcome,
                exitCode: 4,
                failureStage: "platform");
            return 4;
        }

        using var watchdogMutex = new Mutex(
            initiallyOwned: false,
            @"Local\DefaultAppGuard.Watchdog");
        if (!TryAcquire(watchdogMutex))
        {
            return 0;
        }

        var packageIntegrityPassed = false;
        var recoveryAttempted = false;
        int? previousProcessId = null;
        var failureStage = "package-integrity";
        try
        {
            var packageDirectory = Path.GetFullPath(AppContext.BaseDirectory);
            var packageCheck = PackageIntegrityVerifier.Verify(packageDirectory);
            if (!packageCheck.Passed)
            {
                WriteStatus(
                    invokedAtUtc,
                    WatchdogTelemetry.IntegrityFailedOutcome,
                    exitCode: 20,
                    failureStage: "package-integrity");
                return 20;
            }
            packageIntegrityPassed = true;

            var agentPath = Path.Combine(packageDirectory, AgentFileName);
            failureStage = "initial-health-check";
            var initialHealth = GetHealthAsync(
                    options.AgentUri,
                    agentPath,
                    packageCheck.Version,
                    TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
            if (initialHealth.Healthy)
            {
                WriteStatus(
                    invokedAtUtc,
                    WatchdogTelemetry.HealthyOutcome,
                    exitCode: 0,
                    packageIntegrityPassed: true,
                    initialHealthPassed: true,
                    activeProcessId: initialHealth.ProcessId);
                return 0;
            }

            var now = DateTimeOffset.UtcNow;
            if (WatchdogTelemetry.ShouldDeferRecovery(previousStatus, now))
            {
                WriteStatus(
                    invokedAtUtc,
                    WatchdogTelemetry.DeferredOutcome,
                    exitCode: 0,
                    packageIntegrityPassed: true,
                    consecutiveRecoveryFailures:
                        previousStatus!.ConsecutiveRecoveryFailures,
                    nextRecoveryAllowedAtUtc:
                        previousStatus.NextRecoveryAllowedAtUtc,
                    failureStage: "recovery-backoff");
                return 0;
            }

            failureStage = "stop-unhealthy-agent";
            previousProcessId = StopUnhealthyAgents(agentPath) ??
                WatchdogTelemetry.GetLastHealthyProcessId(previousStatus);
            recoveryAttempted = true;
            failureStage = "agent-launch";
            var startInfo = new ProcessStartInfo(agentPath)
            {
                UseShellExecute = true,
                WorkingDirectory = packageDirectory,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            startInfo.ArgumentList.Add("--url");
            startInfo.ArgumentList.Add(options.AgentUri.AbsoluteUri.TrimEnd('/'));
            startInfo.ArgumentList.Add("--state");
            startInfo.ArgumentList.Add(options.StatePath);
            startInfo.ArgumentList.Add("--config");
            startInfo.ArgumentList.Add(options.ConfigurationPath);

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                WriteRecoveryFailure(
                    invokedAtUtc,
                    previousStatus,
                    exitCode: 23,
                    previousProcessId,
                    failureStage: "agent-launch");
                return 23;
            }

            failureStage = "recovery-health-check";
            var recoveredHealth = GetHealthAsync(
                    options.AgentUri,
                    agentPath,
                    packageCheck.Version,
                    TimeSpan.FromSeconds(20)).GetAwaiter().GetResult();
            if (recoveredHealth.Healthy)
            {
                WriteStatus(
                    invokedAtUtc,
                    WatchdogTelemetry.RecoveredOutcome,
                    exitCode: 0,
                    packageIntegrityPassed: true,
                    recoveryAttempted: true,
                    previousProcessId: previousProcessId,
                    activeProcessId: recoveredHealth.ProcessId);
                return 0;
            }

            StopFailedLaunch(process, agentPath);
            WriteRecoveryFailure(
                invokedAtUtc,
                previousStatus,
                exitCode: 24,
                previousProcessId,
                failureStage: "recovery-health-check");
            return 24;
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            InvalidOperationException or
            System.ComponentModel.Win32Exception or
            HttpRequestException or
            TaskCanceledException)
        {
            if (recoveryAttempted)
            {
                WriteRecoveryFailure(
                    invokedAtUtc,
                    previousStatus,
                    exitCode: 25,
                    previousProcessId: previousProcessId,
                    failureStage: failureStage);
            }
            else
            {
                WriteStatus(
                    invokedAtUtc,
                    WatchdogTelemetry.FailedOutcome,
                    exitCode: 25,
                    packageIntegrityPassed: packageIntegrityPassed,
                    failureStage: failureStage);
            }
            return 25;
        }
        finally
        {
            watchdogMutex.ReleaseMutex();
        }
    }

    private static bool TryAcquire(Mutex mutex)
    {
        try
        {
            return mutex.WaitOne(TimeSpan.Zero);
        }
        catch (AbandonedMutexException)
        {
            return true;
        }
    }

    private static int? StopUnhealthyAgents(string expectedPath)
    {
        int? firstStoppedProcessId = null;
        foreach (var process in Process.GetProcessesByName(
                     Path.GetFileNameWithoutExtension(AgentFileName)))
        {
            using (process)
            {
                try
                {
                    if (!string.Equals(
                            process.MainModule?.FileName,
                            expectedPath,
                            StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    firstStoppedProcessId ??= process.Id;
                    process.Kill(entireProcessTree: false);
                    process.WaitForExit(5000);
                }
                catch (Exception exception) when (
                    exception is InvalidOperationException or
                    System.ComponentModel.Win32Exception or
                    NotSupportedException)
                {
                    // The next launch and health check provide the final result.
                }
            }
        }

        return firstStoppedProcessId;
    }

    private static void StopFailedLaunch(Process process, string expectedPath)
    {
        try
        {
            if (!process.HasExited &&
                string.Equals(
                    process.MainModule?.FileName,
                    expectedPath,
                    StringComparison.OrdinalIgnoreCase))
            {
                process.Kill(entireProcessTree: false);
                process.WaitForExit(5000);
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or
            System.ComponentModel.Win32Exception or
            NotSupportedException)
        {
            // The next scheduled health check still verifies the active owner.
        }
    }

    private static async Task<WatchdogHealth> GetHealthAsync(
        Uri agentUri,
        string expectedPath,
        string? expectedVersion,
        TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        using var handler = new SocketsHttpHandler { UseProxy = false };
        using var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(2),
        };

        do
        {
            try
            {
                using var response = await client.GetAsync(
                    new Uri(agentUri, "api/health"));
                if (response.IsSuccessStatusCode)
                {
                    await using var stream = await response.Content.ReadAsStreamAsync();
                    using var document = await JsonDocument.ParseAsync(stream);
                    if (TryMatchHealth(
                            document.RootElement,
                            expectedPath,
                            expectedVersion,
                            out var processId))
                    {
                        using var readinessResponse = await client.GetAsync(
                            new Uri(agentUri, "api/readiness"));
                        if (readinessResponse.IsSuccessStatusCode)
                        {
                            await using var readinessStream =
                                await readinessResponse.Content
                                    .ReadAsStreamAsync();
                            using var readinessDocument =
                                await JsonDocument.ParseAsync(readinessStream);
                            if (TryMatchReadiness(
                                    readinessDocument.RootElement))
                            {
                                return new WatchdogHealth(true, processId);
                            }
                        }
                    }
                }
            }
            catch (Exception exception) when (
                exception is HttpRequestException or
                TaskCanceledException or
                JsonException or
                IOException)
            {
                // Retry until the bounded health deadline expires.
            }

            await Task.Delay(250);
        }
        while (DateTime.UtcNow < deadline);

        return new WatchdogHealth(false, null);
    }

    private static bool TryMatchHealth(
        JsonElement health,
        string expectedPath,
        string? expectedVersion,
        out int processId)
    {
        processId = 0;
        if (!TryGetString(health, "service", out var service) ||
            service != ExpectedService ||
            !TryGetString(health, "query", out var query) ||
            query != ExpectedQuery ||
            !TryGetString(health, "monitor", out var monitor) ||
            monitor != ExpectedMonitor ||
            !TryGetString(health, "processMode", out var processMode) ||
            processMode != ExpectedProcessMode ||
            !TryGetString(
                health,
                "notificationChannel",
                out var notificationChannel) ||
            notificationChannel != ExpectedNotificationChannel ||
            !TryGetBoolean(
                health,
                "notificationsAvailable",
                out var notificationsAvailable) ||
            !notificationsAvailable ||
            !TryGetString(health, "version", out var version) ||
            string.IsNullOrWhiteSpace(expectedVersion) ||
            !version.StartsWith(
                expectedVersion + ".",
                StringComparison.Ordinal) ||
            !health.TryGetProperty("processId", out var processIdElement) ||
            !processIdElement.TryGetInt32(out processId) ||
            processId <= 0 ||
            !TryMatchConfigurationPersistence(health))
        {
            return false;
        }

        try
        {
            using var process = Process.GetProcessById(processId);
            return string.Equals(
                process.MainModule?.FileName,
                expectedPath,
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (
            exception is ArgumentException or
            InvalidOperationException or
            System.ComponentModel.Win32Exception or
            NotSupportedException)
        {
            return false;
        }
    }

    internal static bool TryMatchConfigurationPersistence(
        JsonElement health)
    {
        if (!TryGetString(
                health,
                "configurationStorage",
                out var storage) ||
            storage != ExpectedConfigurationStorage ||
            !TryGetString(
                health,
                "configurationBackupStorage",
                out var backupStorage) ||
            backupStorage != ExpectedConfigurationBackupStorage ||
            !TryGetBoolean(
                health,
                "configurationBackupAvailable",
                out var backupAvailable) ||
            !backupAvailable ||
            !TryGetBoolean(
                health,
                "configurationRecovered",
                out var recovered) ||
            !TryGetString(
                health,
                "configurationRecoveryCode",
                out var recoveryCode))
        {
            return false;
        }

        if (recoveryCode == "none")
        {
            return !recovered;
        }

        return recovered &&
            recoveryCode is "backup-restored" or "defaults-restored" &&
            TryGetString(
                health,
                "configurationRecoveredAtUtc",
                out var recoveredAtUtc) &&
            DateTimeOffset.TryParse(
                recoveredAtUtc,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out _);
    }

    internal static bool TryMatchReadiness(JsonElement readiness)
    {
        return TryGetBoolean(readiness, "ready", out var ready) &&
            ready &&
            TryGetString(readiness, "code", out var code) &&
            code == "ready" &&
            TryGetString(
                readiness,
                "serviceState",
                out var serviceState) &&
            serviceState == "running" &&
            TryGetString(readiness, "query", out var query) &&
            query == ExpectedQuery &&
            TryGetString(readiness, "monitor", out var monitor) &&
            monitor == ExpectedMonitor &&
            TryGetString(
                readiness,
                "targetProgId",
                out _) &&
            TryGetString(
                readiness,
                "targetPackageId",
                out _) &&
            TryGetInt32(
                readiness,
                "auditedExtensionCount",
                out var auditedExtensionCount) &&
            auditedExtensionCount > 0 &&
            TryGetInt32(
                readiness,
                "primarySnapshotCount",
                out var primarySnapshotCount) &&
            primarySnapshotCount == auditedExtensionCount &&
            TryGetInt32(
                readiness,
                "failedReadCount",
                out var failedReadCount) &&
            failedReadCount == 0 &&
            TryGetBoolean(
                readiness,
                "auditFresh",
                out var auditFresh) &&
            auditFresh &&
            TryGetInt64(
                readiness,
                "auditAgeSeconds",
                out var auditAgeSeconds) &&
            auditAgeSeconds >= 0 &&
            TryGetInt64(
                readiness,
                "maximumAuditAgeSeconds",
                out var maximumAuditAgeSeconds) &&
            maximumAuditAgeSeconds > 0 &&
            auditAgeSeconds <= maximumAuditAgeSeconds;
    }

    private static bool TryGetString(
        JsonElement element,
        string propertyName,
        out string value)
    {
        value = string.Empty;
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(propertyName, out var property) ||
            property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value);
    }

    private static bool TryGetBoolean(
        JsonElement element,
        string propertyName,
        out bool value)
    {
        value = false;
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(propertyName, out var property) ||
            property.ValueKind is not (
                JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }

        value = property.GetBoolean();
        return true;
    }

    private static bool TryGetInt32(
        JsonElement element,
        string propertyName,
        out int value)
    {
        value = 0;
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(propertyName, out var property) &&
            property.TryGetInt32(out value);
    }

    private static bool TryGetInt64(
        JsonElement element,
        string propertyName,
        out long value)
    {
        value = 0;
        return element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(propertyName, out var property) &&
            property.TryGetInt64(out value);
    }

    private static void WriteRecoveryFailure(
        DateTimeOffset invokedAtUtc,
        WatchdogStatus? previousStatus,
        int exitCode,
        int? previousProcessId,
        string failureStage)
    {
        var completedAtUtc = DateTimeOffset.UtcNow;
        var failure = WatchdogTelemetry.NextRecoveryFailure(
            previousStatus,
            completedAtUtc);
        WriteStatus(
            invokedAtUtc,
            WatchdogTelemetry.FailedOutcome,
            exitCode,
            packageIntegrityPassed: true,
            recoveryAttempted: true,
            previousProcessId: previousProcessId,
            consecutiveRecoveryFailures: failure.FailureCount,
            nextRecoveryAllowedAtUtc: failure.NextAllowedAtUtc,
            failureStage: failureStage,
            completedAtUtc: completedAtUtc);
    }

    private static void WriteStatus(
        DateTimeOffset invokedAtUtc,
        string outcome,
        int exitCode,
        bool packageIntegrityPassed = false,
        bool initialHealthPassed = false,
        bool recoveryAttempted = false,
        int? previousProcessId = null,
        int? activeProcessId = null,
        int consecutiveRecoveryFailures = 0,
        DateTimeOffset? nextRecoveryAllowedAtUtc = null,
        string? failureStage = null,
        DateTimeOffset? completedAtUtc = null)
    {
        WatchdogTelemetry.TryWrite(
            new WatchdogStatus(
                WatchdogTelemetry.SchemaVersion,
                outcome,
                invokedAtUtc,
                completedAtUtc ?? DateTimeOffset.UtcNow,
                exitCode,
                packageIntegrityPassed,
                initialHealthPassed,
                recoveryAttempted,
                previousProcessId,
                activeProcessId,
                consecutiveRecoveryFailures,
                nextRecoveryAllowedAtUtc,
                failureStage));
    }
}

internal readonly record struct WatchdogHealth(bool Healthy, int? ProcessId);
