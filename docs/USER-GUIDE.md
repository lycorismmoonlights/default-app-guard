# DefaultAppGuard Alpha User Guide

Before installation, read the package's `ENVIRONMENT-AND-RISKS.txt`. It is a
version-matched bilingual notice covering environment requirements, unsigned
artifact warnings, privacy behavior, known limitations, and license terms.

## Requirements

- Windows 11 x64.
- Microsoft Media Player installed.
- A normal interactive Windows user account.

The package is self-contained and does not require Node.js or a separate .NET
installation.

## Install

1. Extract the complete package to a temporary folder.
2. Read `ENVIRONMENT-AND-RISKS.txt`.
3. Double-click `DefaultAppGuard.Setup.exe`.
4. Review the bilingual confirmation and select **OK** to install or upgrade.

Setup does not request administrator elevation or open a terminal. It first
checks the complete package in native code, then uses a process-only
`ExecutionPolicy Bypass` for its hidden PowerShell child. This temporary value
ends with Setup, does not change the current-user or computer policy, and does
not override company or school Group Policy. Advanced users may review and run
the same transactional installer directly:

```powershell
.\Install-DefaultAppGuard.ps1
```

The default installation is per-user and does not request administrator
privileges. It installs below `%LOCALAPPDATA%`, registers a current-user logon
task, starts the Agent, creates a Start menu shortcut, and adds
**DefaultAppGuard Community** to Windows **Settings > Apps > Installed apps**.

Before changing an existing installation, the installer verifies every package
file against `package-manifest.json` and prepares a complete staging directory.
An upgrade is committed only after the new Agent reports the expected version
and PID, no-console process mode, a resolved Microsoft Media Player target, and
real primary COM-query evidence for every protected format. Existing association drift is
reported to the user but does not make installation fail. A failed upgrade
restores the previous files, scheduled task, install-state file, shortcut, and
standard uninstall registration.

The Agent is a long-running background process compiled without a console
window. The scheduled task runs the graphical, no-console Setup executable in
`--watchdog` mode. That short-lived watchdog verifies the installed package,
checks whether the correct Agent owns the local health endpoint, starts it when
needed, and exits. The task should normally show `Ready` while the Agent remains
`Running`; it should not open Windows Terminal.

`IgnoreNew` only prevents overlapping watchdog checks. A task that remains
`Running` for more than 90 seconds, repeatedly reports `0x800710E0`, or fails to
return to `Ready` is not treated as healthy. Run diagnostics and reinstall or
report the JSON file if `scheduledTask.configurationHealthy` is `false`.

The scripts and executables are not yet code-signed. Windows may display a
warning for files downloaded from the internet.

Do not permanently disable Windows security controls or bypass organization
policy to install the application.

## Use

Open **DefaultAppGuard** from the Start menu.

- **Immediately recheck** runs a fresh effective-handler audit.
- Select the video formats that should remain in the monitored set.
- **Save scope and open Settings** persists that set and opens Microsoft's
  Default Apps page for Media Player.

The application does not silently change Windows defaults. After completing a
change in Windows Settings, return to DefaultAppGuard and run another check.

## Diagnostics

Generate a constrained support report:

```powershell
& "$env:LOCALAPPDATA\Programs\DefaultAppGuard\Get-DefaultAppGuardDiagnostics.ps1"
```

The command writes a timestamped JSON report in the current directory. It
checks package integrity, Agent and Setup signature status, the scheduled task,
including its exact action, current-user privilege, triggers, single-instance
and restart settings, standard uninstall registration, Agent process identity,
loopback listener, console children, readiness, and the current main-algorithm
audit. The report
does not include personal paths, registry exports, raw runtime file contents,
or tokens. Review it before attaching it to an issue.

The default runtime files are:

```text
%LOCALAPPDATA%\DefaultAppGuard\runtime\agent-status.json
%LOCALAPPDATA%\DefaultAppGuard\runtime\guard-configuration.json
%LOCALAPPDATA%\DefaultAppGuard\install-state.json
```

The scheduled task is named `DefaultAppGuard Agent`.

## Uninstall

Open **Settings > Apps > Installed apps**, find **DefaultAppGuard Community**,
open its menu, and select **Uninstall**. Windows launches the registered
current-user uninstaller in the background, so no terminal should appear.

Advanced users can run the same uninstaller directly:

```powershell
& "$env:LOCALAPPDATA\Programs\DefaultAppGuard\Uninstall-DefaultAppGuard.ps1"
```

Use `-KeepData` to retain the monitored-format configuration and last status.

The uninstaller removes only a recognized installation containing the package
manifest. It stops and unregisters the task before removing files.

## License

DefaultAppGuard is provided under the PolyForm Noncommercial License 1.0.0.
The package includes `LICENSE.md` and the required `NOTICE`. Commercial use is
not granted.

## Supported Claim

DefaultAppGuard detects and verifies default-app drift. It does not provide a
silent hard lock on Windows Home. Windows requires the user to approve default
app changes in the system UI.
