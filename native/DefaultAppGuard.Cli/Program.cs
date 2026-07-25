using DefaultAppGuard.Core;
using System.Text.Json;
using System.Text.Json.Serialization;

return Run(args);

static int Run(string[] args)
{
    if (!OperatingSystem.IsWindows())
    {
        Console.Error.WriteLine("DefaultAppGuard native commands require Windows.");
        return 10;
    }

    try
    {
        var parsed = ParsedArguments.Parse(args);
        return parsed.Command switch
        {
            "scan" => Scan(parsed),
            "audit-media-player" => Audit(parsed),
            "resolve-media-player" => Resolve(parsed),
            "plan-media-player" => Plan(parsed),
            "open-media-player-settings" => OpenMediaPlayerSettings(parsed),
            _ => Usage(parsed.Command),
        };
    }
    catch (Exception exception)
    {
        Console.Error.WriteLine($"{exception.GetType().Name}: {exception.Message}");
        if (exception.InnerException is not null)
        {
            Console.Error.WriteLine(
                $"Caused by {exception.InnerException.GetType().Name}: " +
                exception.InnerException.Message);
        }

        return 20;
    }
}

static int Scan(ParsedArguments parsed)
{
    var snapshots = new WindowsAssociationReader().ReadMany(parsed.Extensions);
    Write(snapshots, parsed.Json);
    return 0;
}

static int Resolve(ParsedArguments parsed)
{
    var target = new MediaPlayerTargetResolver().Resolve(parsed.Extensions);
    Write(target, parsed.Json);
    return 0;
}

static int Audit(ParsedArguments parsed)
{
    var audit = new AssociationAuditService().Audit(parsed.Extensions);
    Write(audit, parsed.Json);
    return audit.Healthy ? 0 : 3;
}

static int Plan(ParsedArguments parsed)
{
    var reader = new WindowsAssociationReader();
    var target = new MediaPlayerTargetResolver().Resolve(parsed.Extensions);
    var plan = AssociationPlanEvaluator.Create(
        target,
        reader.ReadMany(parsed.Extensions));
    Write(plan, parsed.Json);
    return plan.IsSatisfied ? 0 : 3;
}

static int OpenMediaPlayerSettings(ParsedArguments parsed)
{
    const string settingsUri =
        "ms-settings:defaultapps?registeredAUMID=" +
        "Microsoft.ZuneMusic_8wekyb3d8bbwe%21Microsoft.ZuneMusic";
    using var process = System.Diagnostics.Process.Start(
        new System.Diagnostics.ProcessStartInfo(settingsUri)
        {
            UseShellExecute = true,
        });
    if (process is null)
    {
        throw new InvalidOperationException(
            "Windows could not open the Media Player default-app settings page.");
    }

    Write(new
    {
        Opened = true,
        Uri = settingsUri,
    }, parsed.Json);
    return 0;
}

static void Write<T>(T value, bool indented)
{
    var options = new JsonSerializerOptions
    {
        WriteIndented = indented,
    };
    options.Converters.Add(new JsonStringEnumConverter());
    Console.WriteLine(JsonSerializer.Serialize(value, options));
}

static int Usage(string command)
{
    Console.Error.WriteLine($"Unknown command: {command}");
    Console.Error.WriteLine(
        "Commands: scan, resolve-media-player, plan-media-player, " +
        "audit-media-player, open-media-player-settings");
    Console.Error.WriteLine(
        "Options: [extensions] [--json]");
    return 2;
}

internal sealed record ParsedArguments(
    string Command,
    IReadOnlyList<string> Extensions,
    bool Json)
{
    public static ParsedArguments Parse(string[] args)
    {
        var command = args.FirstOrDefault()?.ToLowerInvariant()
            ?? "plan-media-player";
        var json = false;
        var extensions = new List<string>();

        for (var index = args.Length == 0 ? 0 : 1; index < args.Length; index++)
        {
            var argument = args[index];
            if (string.Equals(
                    argument,
                    "--json",
                    StringComparison.OrdinalIgnoreCase))
            {
                json = true;
                continue;
            }

            if (argument.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Unknown option: {argument}");
            }

            extensions.Add(ExtensionName.Normalize(argument));
        }

        return new ParsedArguments(
            command,
            extensions.Count == 0
                ? AssociationConstants.VideoExtensions
                : extensions,
            json);
    }
}
