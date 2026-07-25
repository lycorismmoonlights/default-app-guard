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
        Assert.False(result.OpenUi);
    }

    [Fact]
    public void Parse_AcceptsOpenUiAndTestableAuditInterval()
    {
        var result = AgentOptions.Parse(
            ["--open-ui", "--audit-interval-seconds", "2"]);

        Assert.True(result.OpenUi);
        Assert.Equal(TimeSpan.FromSeconds(2), result.PeriodicAuditInterval);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("invalid")]
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
}
