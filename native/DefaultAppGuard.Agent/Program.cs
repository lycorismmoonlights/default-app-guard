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
    builder.Services.AddSingleton<WindowsAssociationReader>();
    builder.Services.AddSingleton<IAssociationSnapshotReader>(services =>
        services.GetRequiredService<WindowsAssociationReader>());
    builder.Services.AddSingleton<MediaPlayerTargetResolver>();
    builder.Services.AddSingleton<IMediaPlayerTargetResolver>(services =>
        services.GetRequiredService<MediaPlayerTargetResolver>());
    builder.Services.AddSingleton<AssociationRuleFactory>();
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
    builder.Services.AddHostedService<ConfigurationRecoveryNotificationWorker>();

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
        var configurationStatus =
            configurationStore.SnapshotPersistenceStatus();
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
            NotificationLastQueuedKind =
                notificationStatus.LastQueuedKind,
            NotificationLastQueuedAtUtc =
                notificationStatus.LastQueuedAtUtc,
            ConfigurationRecoveryNotificationLastQueuedKind =
                notificationStatus.ConfigurationRecoveryLastQueuedKind,
            ConfigurationRecoveryNotificationLastQueuedAtUtc =
                notificationStatus.ConfigurationRecoveryLastQueuedAtUtc,
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
            ConfigurationStorage = configurationStatus.Storage,
            ConfigurationBackupStorage =
                configurationStatus.BackupStorage,
            ConfigurationBackupAvailable =
                configurationStatus.BackupAvailable,
            ConfigurationRecovered = configurationStatus.Recovered,
            ConfigurationRecoveryCode =
                configurationStatus.RecoveryCode,
            ConfigurationRecoveredAtUtc =
                configurationStatus.RecoveredAtUtc,
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

    app.MapGet("/api/association-catalog", () =>
        Results.Ok(AssociationCatalog.Entries));

    app.MapPost("/api/associations/inspect", (
        HttpRequest request,
        AssociationInspectionRequest inspection,
        IAssociationSnapshotReader reader) =>
    {
        RequireLocalClient(request);
        try
        {
            var extensions = NormalizeInspectionExtensions(
                inspection.Extensions);
            var results = extensions.Select(extension =>
            {
                try
                {
                    return new AssociationInspectionResult(
                        extension,
                        reader.Read(extension),
                        null);
                }
                catch (Exception exception) when (
                    AssociationReadFailure.IsExpected(exception))
                {
                    return new AssociationInspectionResult(
                        extension,
                        null,
                        $"{exception.GetType().Name}: {exception.Message}");
                }
            }).ToArray();
            return Results.Ok(results);
        }
        catch (ArgumentException exception)
        {
            return Results.BadRequest(new { Error = exception.Message });
        }
    });

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
        catch (Exception exception) when (
            exception is ArgumentException or InvalidOperationException)
        {
            return Results.BadRequest(new { Error = exception.Message });
        }
    });

    app.MapPost("/api/open-settings", (HttpRequest request) =>
    {
        RequireLocalClient(request);
        const string settingsUri = "ms-settings:defaultapps";
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

static string[] NormalizeInspectionExtensions(
    IReadOnlyList<string>? extensions)
{
    if (extensions is null)
    {
        throw new ArgumentException("Extensions are required.");
    }

    var normalized = extensions
        .Select(ExtensionName.Normalize)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .Order(StringComparer.OrdinalIgnoreCase)
        .ToArray();
    if (normalized.Length is 0 or > 128)
    {
        throw new ArgumentException(
            "Inspect between 1 and 128 supported file extensions.");
    }

    foreach (var extension in normalized)
    {
        _ = AssociationCatalog.Get(extension);
    }

    return normalized;
}

internal sealed record AssociationInspectionRequest(
    IReadOnlyList<string>? Extensions);

internal sealed record AssociationInspectionResult(
    string Extension,
    AssociationSnapshot? Snapshot,
    string? Error);
