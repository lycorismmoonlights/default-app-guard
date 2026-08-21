namespace DefaultAppGuard.Core;

public static class AssociationConstants
{
    public const string PrimaryQueryAlgorithm =
        "IApplicationAssociationRegistration.QueryCurrentDefault";
    public const string PrimaryMonitorAlgorithm = "RegNotifyChangeKeyValue";
    public const string MediaPlayerTargetStrategy = "system-media-player";
    public const string CapturedCurrentTargetStrategy = "captured-current";

    public static readonly IReadOnlyList<string> VideoExtensions =
    [
        ".3g2",
        ".3gp",
        ".3gp2",
        ".3gpp",
        ".asf",
        ".avi",
        ".divx",
        ".m1v",
        ".m2t",
        ".m2ts",
        ".m2v",
        ".m4v",
        ".mkv",
        ".mod",
        ".mov",
        ".mp2v",
        ".mp4",
        ".mp4v",
        ".mpe",
        ".mpeg",
        ".mpg",
        ".mpg4",
        ".mpv2",
        ".mts",
        ".ogm",
        ".ogv",
        ".ogx",
        ".tod",
        ".ts",
        ".tts",
        ".webm",
        ".wm",
        ".wmv",
        ".xvid",
    ];

    public const string MediaPlayerPackageName = "Microsoft.ZuneMusic";
}
