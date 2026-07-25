namespace DefaultAppGuard.Agent;

public sealed record AgentOptions(
    string Url,
    string StatePath,
    string ConfigurationPath,
    TimeSpan PeriodicAuditInterval,
    bool OpenUi,
    IReadOnlyList<string> AllowedOrigins)
{
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

        return new AgentOptions(
            url.TrimEnd('/'),
            Path.GetFullPath(statePath),
            Path.GetFullPath(configurationPath),
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
        if (!int.TryParse(value, out var seconds) || seconds <= 0)
        {
            throw new ArgumentException(
                "--audit-interval-seconds must be a positive integer.");
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
