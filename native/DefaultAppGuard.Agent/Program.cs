using DefaultAppGuard.Agent;
using DefaultAppGuard.Core;
using Microsoft.Extensions.FileProviders;
using Serilog;

var options = AgentOptions.Parse(args);
using var instanceLease = AgentInstanceLease.TryAcquire();
if (instanceLease is null)
{
    if (options.OpenUi)
    {
        OpenAgentUi(options.Url);
    }

    return;
}

using var operationalLogging = OperationalLoggingSession.Start(options);
try
{
    var builder = WebApplication.CreateBuilder(args);
    builder.WebHost.UseUrls(options.Url);
    builder.Logging.ClearProviders();
    builder.Services.AddSerilog(operationalLogging.Logger, dispose: false);
    builder.Services.AddSingleton(options);
    builder.Services.AddSingleton(operationalLogging.Health);
    builder.Services.AddSingleton<AgentRuntimeState>();
    builder.Services.AddSingleton<AssociationAuditService>();
    builder.Services.AddSingleton<GuardConfigurationStore>();
    builder.Services.AddSingleton<AssociationAuditCoordinator>();
    builder.Services.AddSingleton<TrayUserNotificationSink>();
    builder.Services.AddSingleton<IUserNotificationSink>(services =>
        services.GetRequiredService<TrayUserNotificationSink>());
    builder.Services.AddHostedService<TrayUserNotificationSink>(services =>
        services.GetRequiredService<TrayUserNotificationSink>());
    builder.Services.AddHostedService<AssociationMonitorWorker>();
    builder.Services.AddHostedService<DriftNotificationWorker>();

    var app = builder.Build();
    var packagedUiPath = Path.Combine(AppContext.BaseDirectory, "wwwroot");
    var packagedUiAvailable = Directory.Exists(packagedUiPath);
    PhysicalFileProvider? packagedUiProvider = null;

    if (options.OpenUi)
    {
        app.Lifetime.ApplicationStarted.Register(
            () => OpenAgentUi(options.Url));
    }

    if (packagedUiAvailable)
    {
        packagedUiProvider = new PhysicalFileProvider(packagedUiPath);
        app.UseDefaultFiles(new DefaultFilesOptions
        {
            FileProvider = packagedUiProvider,
        });
        app.UseStaticFiles(new StaticFileOptions
        {
            FileProvider = packagedUiProvider,
        });
    }

    app.Use(async (context, next) =>
    {
        var origin = context.Request.Headers.Origin.ToString();
        var allowed = string.IsNullOrEmpty(origin) ||
                      options.AllowedOrigins.Contains(
                          origin,
                          StringComparer.OrdinalIgnoreCase);
        if (!allowed)
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }

        if (!string.IsNullOrEmpty(origin))
        {
            context.Response.Headers.AccessControlAllowOrigin = origin;
            context.Response.Headers.AccessControlAllowHeaders =
                "Content-Type,X-DefaultAppGuard-Client";
            context.Response.Headers.AccessControlAllowMethods =
                "GET,POST,PUT,OPTIONS";
        }

        if (HttpMethods.IsOptions(context.Request.Method))
        {
            context.Response.StatusCode = StatusCodes.Status204NoContent;
            return;
        }

        await next();
    });

    app.MapGet("/api/health", (
        TrayUserNotificationSink notifications,
        OperationalLogHealth operationalLogs,
        GuardConfigurationStore configurationStore) =>
    {
        var notificationStatus = notifications.Snapshot();
        var operationalLogStatus = operationalLogs.Snapshot();
        return Results.Ok(new
        {
            Service = "DefaultAppGuard.Agent",
            Version = typeof(Program).Assembly.GetName().Version?.ToString(),
            Monitor = "RegNotifyChangeKeyValue",
            Query = "IApplicationAssociationRegistration.QueryCurrentDefault",
            ProcessId = Environment.ProcessId,
            ProcessMode = "background-no-console",
            PeriodicReadbackSeconds =
                (int)options.PeriodicAuditInterval.TotalSeconds,
            MaximumAuditAgeSeconds =
                (int)options.MaximumAuditAge.TotalSeconds,
            PackagedUi = packagedUiAvailable,
            NotificationChannel = notificationStatus.Channel,
            NotificationsAvailable = notificationStatus.Available,
            NotificationsEnabled =
                configurationStore.Snapshot().NotificationsEnabled,
            NotificationLastError = notificationStatus.LastError,
            OperationalLogChannel = operationalLogStatus.Channel,
            OperationalLogsAvailable = operationalLogStatus.Available,
            OperationalLogFormat = operationalLogStatus.Format,
            OperationalLogFileSizeLimitBytes =
                operationalLogStatus.FileSizeLimitBytes,
            OperationalLogRetainedFileCountLimit =
                operationalLogStatus.RetainedFileCountLimit,
            OperationalLogStorage = operationalLogStatus.Storage,
            OperationalLogLastError = operationalLogStatus.LastErrorCode,
            OperationalLogLastErrorAtUtc =
                operationalLogStatus.LastErrorAtUtc,
        });
    });

    app.MapGet("/api/readiness", (AgentRuntimeState state) =>
    {
        var readiness = AgentReadinessEvaluator.Evaluate(
            state.Snapshot(),
            options.MaximumAuditAge);
        return readiness.Ready
            ? Results.Ok(readiness)
            : Results.Json(readiness, statusCode: StatusCodes.Status503ServiceUnavailable);
    });

    app.MapGet("/api/status", (AgentRuntimeState state) =>
        Results.Ok(state.Snapshot()));

    app.MapGet("/api/config", (GuardConfigurationStore store) =>
        Results.Ok(store.Snapshot()));

    app.MapPost("/api/audit", async (
        HttpRequest request,
        AssociationAuditCoordinator coordinator,
        CancellationToken cancellationToken) =>
    {
        RequireLocalClient(request);
        return Results.Ok(await coordinator.AuditNowAsync(
            "manual-api",
            cancellationToken));
    });

    app.MapPut("/api/config", async Task<IResult> (
        HttpRequest request,
        GuardConfigurationUpdate update,
        GuardConfigurationStore store,
        AssociationAuditCoordinator coordinator,
        CancellationToken cancellationToken) =>
    {
        RequireLocalClient(request);
        try
        {
            var configuration = await store.UpdateAsync(
                update,
                cancellationToken);
            var status = await coordinator.AuditNowAsync(
                "configuration-change",
                cancellationToken);
            return Results.Ok(new { Configuration = configuration, Status = status });
        }
        catch (ArgumentException exception)
        {
            return Results.BadRequest(new { Error = exception.Message });
        }
    });

    app.MapPost("/api/open-settings", (HttpRequest request) =>
    {
        RequireLocalClient(request);
        const string settingsUri =
            "ms-settings:defaultapps?registeredAUMID=" +
            "Microsoft.ZuneMusic_8wekyb3d8bbwe%21Microsoft.ZuneMusic";
        using var process = System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo(settingsUri)
            {
                UseShellExecute = true,
            });
        return process is null
            ? Results.Problem("Windows could not open Default Apps settings.")
            : Results.Ok(new { Opened = true });
    });

    if (packagedUiProvider is not null)
    {
        var indexPath = Path.Combine(packagedUiPath, "index.html");
        app.MapFallback((HttpRequest request) =>
            request.Path.StartsWithSegments("/api") ||
            Path.HasExtension(request.Path.Value)
                ? Results.NotFound()
                : Results.File(indexPath, "text/html"));
    }

    app.Lifetime.ApplicationStarted.Register(() =>
        operationalLogging.Logger.Information(
            "DefaultAppGuard Agent started in {ProcessMode} mode.",
            "background-no-console"));
    app.Lifetime.ApplicationStopping.Register(() =>
        operationalLogging.Logger.Information(
            "DefaultAppGuard Agent is stopping."));
    app.Run();
}
catch (Exception exception)
{
    operationalLogging.Logger.Fatal(
        exception,
        "DefaultAppGuard Agent terminated unexpectedly.");
    throw;
}

static void OpenAgentUi(string url)
{
    using var process = System.Diagnostics.Process.Start(
        new System.Diagnostics.ProcessStartInfo(url)
        {
            UseShellExecute = true,
        });
}

static void RequireLocalClient(HttpRequest request)
{
    if (!string.Equals(
            request.Headers["X-DefaultAppGuard-Client"].ToString(),
            "local-ui",
            StringComparison.Ordinal))
    {
        throw new BadHttpRequestException(
            "Missing local client header.",
            StatusCodes.Status400BadRequest);
    }
}
