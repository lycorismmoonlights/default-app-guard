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
2. Review `Install-DefaultAppGuard.ps1`.
3. Open PowerShell in that folder.
4. Run:

```powershell
.\Install-DefaultAppGuard.ps1
```

The default installation is per-user and does not request administrator
privileges. It installs below `%LOCALAPPDATA%`, registers a current-user logon
task, starts the Agent, and creates a Start menu shortcut.

Before changing an existing installation, the installer verifies every package
file against `package-manifest.json` and prepares a complete staging directory.
An upgrade is committed only after the new Agent reports the primary algorithms,
the expected version and PID, and the no-console process mode. A failed upgrade
restores the previous files and scheduled task.

The Agent is a long-running background process compiled without a console
window. The watchdog task may check or restart it in the background, but it
should not open Windows Terminal. If an Agent terminal remains visible, verify
that version 0.1.2 or later is installed.

The scripts and binary are not yet code-signed. Windows may display a warning
for files downloaded from the internet.

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
checks package integrity, version and signature status, the scheduled task,
Agent process identity, loopback listener, console children, and the current
main-algorithm audit. The report does not include personal paths, registry
exports, raw runtime file contents, or tokens. Review it before attaching it
to an issue.

The default runtime files are:

```text
%LOCALAPPDATA%\DefaultAppGuard\runtime\agent-status.json
%LOCALAPPDATA%\DefaultAppGuard\runtime\guard-configuration.json
%LOCALAPPDATA%\DefaultAppGuard\install-state.json
```

The scheduled task is named `DefaultAppGuard Agent`.

## Uninstall

Run the uninstaller from the installation directory:

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
