using DefaultAppGuard.Agent;

namespace DefaultAppGuard.Tests;

public sealed class AgentOptionsTests
{
    [Fact]
    public void Parse_UsesStableRuntimeDefaults()
    {
        var result = AgentOptions.Parse([]);

        Assert.Equal("http://127.0.0.1:51873", result.Url);
        Assert.Equal(TimeSpan.FromMinutes(15), result.PeriodicAuditInterval);
        Assert.Equal(
            TimeSpan.FromMinutes(18.75),
            result.MaximumAuditAge);
        Assert.Equal(
            Path.Combine(Path.GetDirectoryName(result.StatePath)!, "logs"),
            result.OperationalLogDirectory);
        Assert.False(result.OpenUi);
    }

    [Fact]
    public void Parse_AcceptsOpenUiAndTestableAuditInterval()
    {
        var result = AgentOptions.Parse(
            ["--open-ui", "--audit-interval-seconds", "2"]);

        Assert.True(result.OpenUi);
        Assert.Equal(TimeSpan.FromSeconds(2), result.PeriodicAuditInterval);
        Assert.Equal(TimeSpan.FromSeconds(32), result.MaximumAuditAge);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("invalid")]
    [InlineData("86401")]
    public void Parse_RejectsInvalidAuditInterval(string value)
    {
        Assert.Throws<ArgumentException>(
            () => AgentOptions.Parse(
                ["--audit-interval-seconds", value]));
    }

    [Fact]
    public void Parse_RejectsNonLoopbackUrl()
    {
        Assert.Throws<ArgumentException>(
            () => AgentOptions.Parse(
                ["--url", "http://0.0.0.0:51873"]));
    }

    [Fact]
    public void Parse_DerivesLogDirectoryFromCustomStateDirectory()
    {
        var statePath = Path.Combine(
            Path.GetTempPath(),
            Guid.NewGuid().ToString("N"),
            "state.json");

        var result = AgentOptions.Parse(["--state", statePath]);

        Assert.Equal(
            Path.Combine(Path.GetDirectoryName(statePath)!, "logs"),
            result.OperationalLogDirectory);
    }
}
