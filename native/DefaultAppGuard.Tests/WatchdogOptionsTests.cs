using DefaultAppGuard.Setup;

namespace DefaultAppGuard.Tests;

public sealed class WatchdogOptionsTests
{
    [Fact]
    public void Parse_AcceptsCompleteWatchdogCommand()
    {
        var options = SetupOptions.Parse(new[]
        {
            "--watchdog",
            "--url",
            "http://127.0.0.1:51873",
            "--state",
            @"C:\Users\Test\AppData\Local\DefaultAppGuard\state.json",
            "--config",
            @"C:\Users\Test\AppData\Local\DefaultAppGuard\config.json",
        });

        Assert.NotNull(options.Watchdog);
        Assert.Equal("http://127.0.0.1:51873/", options.Watchdog.AgentUri.AbsoluteUri);
        Assert.Empty(options.InstallerArguments);
    }

    [Fact]
    public void Parse_RejectsIncompleteWatchdogCommand()
    {
        Assert.Throws<ArgumentException>(() => SetupOptions.Parse(new[]
        {
            "--watchdog",
            "--url",
            "http://127.0.0.1:51873",
        }));
    }

    [Fact]
    public void Parse_RejectsRemoteWatchdogOrigin()
    {
        Assert.Throws<ArgumentException>(() => SetupOptions.Parse(new[]
        {
            "--watchdog",
            "--url",
            "https://example.com",
            "--state",
            @"C:\Temp\state.json",
            "--config",
            @"C:\Temp\config.json",
        }));
    }

    [Fact]
    public void Parse_RejectsWatchdogAndInstallOptionsTogether()
    {
        Assert.Throws<ArgumentException>(() => SetupOptions.Parse(new[]
        {
            "--watchdog",
            "--url",
            "http://127.0.0.1:51873",
            "--state",
            @"C:\Temp\state.json",
            "--config",
            @"C:\Temp\config.json",
            "--install-directory",
            @"C:\Temp\DefaultAppGuard",
        }));
    }
}
