using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace DefaultAppGuard.Setup;

internal static class Program
{
    private const string ProductName = "DefaultAppGuard";
    private const string InstallerFileName = "Install-DefaultAppGuard.ps1";
    private const string DefaultUiUrl = "http://127.0.0.1:51873";
    private const int OkButtonId = 1;
    private const int CancelButtonId = 2;
    private const uint OkButton = 0x0001;
    private const uint CancelButton = 0x0008;
    private static readonly nint InformationIcon = (nint)0xFFFD;
    private static readonly nint ErrorIcon = (nint)0xFFFE;

    [STAThread]
    private static int Main(string[] args)
    {
        SetupOptions options;
        try
        {
            options = SetupOptions.Parse(args);
        }
        catch (ArgumentException exception)
        {
            if (!args.Contains("--quiet", StringComparer.Ordinal))
            {
                ShowError("Invalid setup option / 安装参数无效", exception.Message);
            }

            return 2;
        }

        using var setupMutex = new Mutex(
            initiallyOwned: false,
            @"Local\DefaultAppGuard.Setup");
        var ownsMutex = TryAcquire(setupMutex);
        if (!ownsMutex)
        {
            if (!options.Quiet)
            {
                ShowError(
                    "Setup is already running / 安装程序正在运行",
                    "Wait for the current installation to finish.\n\n" +
                    "请等待当前安装过程完成。");
            }

            return 3;
        }

        try
        {
            var platformIssue = GetPlatformIssue();
            if (platformIssue is not null)
            {
                if (!options.Quiet)
                {
                    ShowError(
                        "Unsupported system / 系统不受支持",
                        platformIssue);
                }

                return 4;
            }

            if (!options.Quiet && !options.VerifyOnly && !ConfirmInstallation())
            {
                return 1;
            }

            var result = RunInstaller(options);
            if (result.ExitCode != 0)
            {
                if (options.Quiet)
                {
                    Console.Error.WriteLine(BuildFailureMessage(result));
                }

                if (!options.Quiet)
                {
                    ShowError(
                        "Installation did not complete / 安装未完成",
                        BuildFailureMessage(result));
                }

                return result.ExitCode;
            }

            if (!options.Quiet && !options.VerifyOnly)
            {
                ShowInformation(
                    "Installation complete / 安装完成",
                    "DefaultAppGuard is running in the background. " +
                    "No terminal window will remain open.\n\n" +
                    "DefaultAppGuard 已在后台运行，不会保留终端窗口。");
                OpenUi(options.AgentUrl ?? DefaultUiUrl);
            }

            return 0;
        }
        catch (Exception exception)
        {
            if (options.Quiet)
            {
                Console.Error.WriteLine(exception.Message);
            }

            if (!options.Quiet)
            {
                ShowError(
                    "Unexpected setup error / 安装程序发生意外错误",
                    exception.Message);
            }

            return 10;
        }
        finally
        {
            setupMutex.ReleaseMutex();
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

    private static string? GetPlatformIssue()
    {
        if (!Environment.Is64BitOperatingSystem)
        {
            return "DefaultAppGuard requires 64-bit Windows.\n\n" +
                   "DefaultAppGuard 需要 64 位 Windows。";
        }

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            return "DefaultAppGuard currently supports Windows 11 x64.\n\n" +
                   "DefaultAppGuard 当前支持 Windows 11 x64。";
        }

        return null;
    }

    private static bool ConfirmInstallation()
    {
        var button = ShowTaskDialog(
            "DefaultAppGuard Setup",
            "Install or upgrade DefaultAppGuard?\n安装或升级 DefaultAppGuard？",
            "This per-user installation normally does not require " +
            "administrator rights. It installs a background monitor and a " +
            "Start menu shortcut. Read ENVIRONMENT-AND-RISKS.txt before " +
            "continuing.\n\n" +
            "本程序按当前用户安装，通常不需要管理员权限。它会安装后台监控和" +
            "开始菜单快捷方式。继续前请阅读 ENVIRONMENT-AND-RISKS.txt。",
            OkButton | CancelButton,
            InformationIcon);
        return button == OkButtonId;
    }

    private static InstallerResult RunInstaller(SetupOptions options)
    {
        var packageDirectory = AppContext.BaseDirectory;
        var installerPath = Path.Combine(packageDirectory, InstallerFileName);
        var requiredFiles = new[]
        {
            installerPath,
            Path.Combine(packageDirectory, "DefaultAppGuard.Package.psm1"),
            Path.Combine(packageDirectory, "DefaultAppGuard.Agent.exe"),
            Path.Combine(packageDirectory, "package-manifest.json"),
            Path.Combine(packageDirectory, "ENVIRONMENT-AND-RISKS.txt"),
        };
        var missingFile = requiredFiles.FirstOrDefault(file => !File.Exists(file));
        if (missingFile is not null)
        {
            return new InstallerResult(
                5,
                string.Empty,
                "The release package is incomplete. Extract the entire ZIP " +
                "before running Setup. Missing: " +
                Path.GetFileName(missingFile));
        }

        var packageCheck = PackageIntegrityVerifier.Verify(packageDirectory);
        if (!packageCheck.Passed)
        {
            return new InstallerResult(
                5,
                string.Empty,
                "The release package failed its native integrity check: " +
                string.Join(", ", packageCheck.IssueCodes));
        }

        var powerShellPath = Path.Combine(
            Environment.SystemDirectory,
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(powerShellPath))
        {
            return new InstallerResult(
                6,
                string.Empty,
                "Windows PowerShell is unavailable.");
        }

        var startInfo = new ProcessStartInfo(powerShellPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = packageDirectory,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-WindowStyle");
        startInfo.ArgumentList.Add("Hidden");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(installerPath);
        if (options.VerifyOnly)
        {
            startInfo.ArgumentList.Add("-VerifyOnly");
        }

        foreach (var argument in options.InstallerArguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException(
                "Windows could not start the package verifier.");
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        Task.WaitAll(outputTask, errorTask);
        return new InstallerResult(
            process.ExitCode,
            outputTask.Result,
            errorTask.Result);
    }

    private static string BuildFailureMessage(InstallerResult result)
    {
        var details = string.IsNullOrWhiteSpace(result.StandardError)
            ? result.StandardOutput
            : result.StandardError;
        details = details.Trim();
        if (details.Length > 1200)
        {
            details = details[..1200] + "...";
        }

        var message =
            $"Setup exit code: {result.ExitCode}. " +
            "The previous installation is preserved or restored when the " +
            "transaction cannot complete.\n\n" +
            "安装退出代码：" + result.ExitCode +
            "。事务无法完成时，先前安装会被保留或恢复。";
        return string.IsNullOrWhiteSpace(details)
            ? message
            : message + "\n\n" + details;
    }

    private static void OpenUi(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            !uri.IsLoopback ||
            uri.Scheme != Uri.UriSchemeHttp)
        {
            return;
        }

        using var process = Process.Start(new ProcessStartInfo(uri.AbsoluteUri)
        {
            UseShellExecute = true,
        });
    }

    private static void ShowInformation(string instruction, string content)
    {
        _ = ShowTaskDialog(
            ProductName,
            instruction,
            content,
            OkButton,
            InformationIcon);
    }

    private static void ShowError(string instruction, string content)
    {
        _ = ShowTaskDialog(
            ProductName,
            instruction,
            content,
            OkButton,
            ErrorIcon);
    }

    private static int ShowTaskDialog(
        string title,
        string instruction,
        string content,
        uint buttons,
        nint icon)
    {
        var result = TaskDialog(
            nint.Zero,
            nint.Zero,
            title,
            instruction,
            content,
            buttons,
            icon,
            out var button);
        return result >= 0 ? button : CancelButtonId;
    }

    [DllImport("comctl32.dll", CharSet = CharSet.Unicode)]
    private static extern int TaskDialog(
        nint owner,
        nint instance,
        string windowTitle,
        string mainInstruction,
        string content,
        uint commonButtons,
        nint icon,
        out int button);

    private sealed record InstallerResult(
        int ExitCode,
        string StandardOutput,
        string StandardError);
}

internal sealed record SetupOptions(
    bool Quiet,
    bool VerifyOnly,
    string? AgentUrl,
    IReadOnlyList<string> InstallerArguments)
{
    public static SetupOptions Parse(IReadOnlyList<string> args)
    {
        var quiet = false;
        var verifyOnly = false;
        string? agentUrl = null;
        var installerArguments = new List<string>();

        for (var index = 0; index < args.Count; index++)
        {
            var option = args[index];
            switch (option)
            {
                case "--quiet":
                    quiet = true;
                    break;
                case "--verify-only":
                    verifyOnly = true;
                    break;
                case "--no-start-menu-shortcut":
                    installerArguments.Add("-NoStartMenuShortcut");
                    break;
                case "--install-directory":
                    AddValue(args, ref index, option, "-InstallDirectory", installerArguments);
                    break;
                case "--data-directory":
                    AddValue(args, ref index, option, "-DataDirectory", installerArguments);
                    break;
                case "--task-name":
                    AddValue(args, ref index, option, "-TaskName", installerArguments);
                    break;
                case "--agent-url":
                    agentUrl = ReadValue(args, ref index, option);
                    installerArguments.Add("-AgentUrl");
                    installerArguments.Add(agentUrl);
                    break;
                case "--watchdog-minutes":
                    AddValue(args, ref index, option, "-WatchdogIntervalMinutes", installerArguments);
                    break;
                case "--health-timeout-seconds":
                    AddValue(args, ref index, option, "-HealthTimeoutSeconds", installerArguments);
                    break;
                case "--result-path":
                    AddValue(args, ref index, option, "-ResultPath", installerArguments);
                    break;
                default:
                    throw new ArgumentException($"Unknown option: {option}");
            }
        }

        return new SetupOptions(
            quiet,
            verifyOnly,
            agentUrl,
            installerArguments);
    }

    private static void AddValue(
        IReadOnlyList<string> args,
        ref int index,
        string option,
        string installerOption,
        ICollection<string> installerArguments)
    {
        installerArguments.Add(installerOption);
        installerArguments.Add(ReadValue(args, ref index, option));
    }

    private static string ReadValue(
        IReadOnlyList<string> args,
        ref int index,
        string option)
    {
        if (++index >= args.Count || string.IsNullOrWhiteSpace(args[index]))
        {
            throw new ArgumentException($"{option} requires a value.");
        }

        return args[index];
    }
}
