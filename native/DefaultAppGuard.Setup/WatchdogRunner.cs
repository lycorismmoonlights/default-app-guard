using System.Diagnostics;
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

    internal static int Run(WatchdogOptions options)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ||
            !Environment.Is64BitOperatingSystem)
        {
            return 4;
        }

        using var watchdogMutex = new Mutex(
            initiallyOwned: false,
            @"Local\DefaultAppGuard.Watchdog");
        if (!TryAcquire(watchdogMutex))
        {
            return 0;
        }

        try
        {
            var packageDirectory = Path.GetFullPath(AppContext.BaseDirectory);
            var packageCheck = PackageIntegrityVerifier.Verify(packageDirectory);
            if (!packageCheck.Passed)
            {
                return 20;
            }

            var agentPath = Path.Combine(packageDirectory, AgentFileName);
            if (IsHealthyAsync(
                    options.AgentUri,
                    agentPath,
                    packageCheck.Version,
                    TimeSpan.FromSeconds(5)).GetAwaiter().GetResult())
            {
                return 0;
            }

            StopUnhealthyAgents(agentPath);
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
                return 23;
            }

            return IsHealthyAsync(
                    options.AgentUri,
                    agentPath,
                    packageCheck.Version,
                    TimeSpan.FromSeconds(20)).GetAwaiter().GetResult()
                ? 0
                : 24;
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            InvalidOperationException or
            System.ComponentModel.Win32Exception or
            HttpRequestException or
            TaskCanceledException)
        {
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

    private static void StopUnhealthyAgents(string expectedPath)
    {
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
    }

    private static async Task<bool> IsHealthyAsync(
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
                    if (HealthMatches(
                            document.RootElement,
                            expectedPath,
                            expectedVersion))
                    {
                        return true;
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

        return false;
    }

    private static bool HealthMatches(
        JsonElement health,
        string expectedPath,
        string? expectedVersion)
    {
        if (!TryGetString(health, "service", out var service) ||
            service != ExpectedService ||
            !TryGetString(health, "query", out var query) ||
            query != ExpectedQuery ||
            !TryGetString(health, "monitor", out var monitor) ||
            monitor != ExpectedMonitor ||
            !TryGetString(health, "processMode", out var processMode) ||
            processMode != ExpectedProcessMode ||
            !TryGetString(health, "version", out var version) ||
            string.IsNullOrWhiteSpace(expectedVersion) ||
            !version.StartsWith(
                expectedVersion + ".",
                StringComparison.Ordinal) ||
            !health.TryGetProperty("processId", out var processIdElement) ||
            !processIdElement.TryGetInt32(out var processId) ||
            processId <= 0)
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

        value = property.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value);
    }
}
