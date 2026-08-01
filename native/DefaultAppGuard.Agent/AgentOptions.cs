namespace DefaultAppGuard.Agent;

public sealed record AgentOptions(
    string Url,
    string StatePath,
    string ConfigurationPath,
    string OperationalLogDirectory,
    TimeSpan PeriodicAuditInterval,
    bool OpenUi,
    IReadOnlyList<string> AllowedOrigins)
{
    private static readonly TimeSpan MinimumAuditGracePeriod =
        TimeSpan.FromSeconds(30);

    public TimeSpan MaximumAuditAge
    {
        get
        {
            var proportionalGrace = TimeSpan.FromTicks(
                PeriodicAuditInterval.Ticks / 4);
            var grace = proportionalGrace > MinimumAuditGracePeriod
                ? proportionalGrace
                : MinimumAuditGracePeriod;
            return PeriodicAuditInterval + grace;
        }
    }

    public static AgentOptions Parse(string[] args)
    {
        var url = "http://127.0.0.1:51873";
        var statePath = Path.Combine(
            AppContext.BaseDirectory,
            "runtime",
            "agent-status.json");
        var configurationPath = Path.Combine(
            AppContext.BaseDirectory,
            "runtime",
            "guard-configuration.json");
        var periodicAuditInterval = TimeSpan.FromMinutes(15);
        var openUi = false;

        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--url":
                    url = ReadValue(args, ref index, "--url");
                    break;
                case "--state":
                    statePath = ReadValue(args, ref index, "--state");
                    break;
                case "--config":
                    configurationPath = ReadValue(args, ref index, "--config");
                    break;
                case "--audit-interval-seconds":
                    periodicAuditInterval = ParsePositiveInterval(
                        ReadValue(
                            args,
                            ref index,
                            "--audit-interval-seconds"));
                    break;
                case "--open-ui":
                    openUi = true;
                    break;
            }
        }

        var parsedUrl = new Uri(url, UriKind.Absolute);
        if (!parsedUrl.IsLoopback || parsedUrl.Scheme != Uri.UriSchemeHttp)
        {
            throw new ArgumentException(
                "Agent URL must be an HTTP loopback address.",
                nameof(args));
        }

        var normalizedStatePath = Path.GetFullPath(statePath);
        var stateDirectory = Path.GetDirectoryName(normalizedStatePath)
            ?? throw new ArgumentException(
                "Agent state path must have a parent directory.",
                nameof(args));

        return new AgentOptions(
            url.TrimEnd('/'),
            normalizedStatePath,
            Path.GetFullPath(configurationPath),
            Path.Combine(stateDirectory, "logs"),
            periodicAuditInterval,
            openUi,
            [
                "http://127.0.0.1:4173",
                "http://localhost:4173",
                url.TrimEnd('/'),
            ]);
    }

    private static TimeSpan ParsePositiveInterval(string value)
    {
        if (!int.TryParse(value, out var seconds) ||
            seconds is <= 0 or > 86400)
        {
            throw new ArgumentException(
                "--audit-interval-seconds must be an integer from 1 to 86400.");
        }

        return TimeSpan.FromSeconds(seconds);
    }

    private static string ReadValue(
        IReadOnlyList<string> args,
        ref int index,
        string option)
    {
        if (++index >= args.Count)
        {
            throw new ArgumentException($"{option} requires a value.");
        }

        return args[index];
    }
}
