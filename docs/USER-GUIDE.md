# DefaultAppGuard Alpha User Guide

Before installation, read the package's `ENVIRONMENT-AND-RISKS.txt`. It is a
version-matched bilingual notice covering environment requirements, unsigned
artifact warnings, privacy behavior, known limitations, and license terms.

## Requirements

- Windows 11 x64.
- Microsoft Media Player installed for the built-in video policy.
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
and PID, no-console process mode, a resolved target for every protected
format, and real primary COM-query evidence for every protected format. It also requires
the system-notification channel and a real write to the bounded local
operational log. Existing association drift is reported to the user but does
not make installation fail. A failed upgrade
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
- Choose **Video**, **Audio**, **Document**, **Image**, **Archive**, or
  **Web & data**, then select the formats to protect.
- Video formats always use the dynamically resolved Microsoft Media Player
  target. A newly selected non-video format records its current Windows
  default as the baseline when the scope is saved.
- Select a protected non-video format and use **Update to current default** to
  replace only that baseline during the next save.
- **Windows Default Apps** opens the supported system page. Make the intended
  change there first, return to DefaultAppGuard, update the baseline when
  appropriate, and run an immediate recheck.
- **Save protected scope** persists the selected formats. The browser UI never
  submits a ProgID; the local Agent reads each new baseline through the primary
  COM query.
- **Settings > System notifications** enables or disables tray alerts. Turning
  alerts off does not stop monitoring.

When the primary audit detects drift, the Agent attempts to show a Windows
tray balloon. The first drift and any change in the affected format set can
alert immediately; unchanged drift is limited to one reminder per 30 minutes.
Focus Assist, Do Not Disturb, notification permissions, Explorer restarts, or
organization policy can suppress the visible balloon. Check the application
status rather than treating the presence or absence of a balloon as proof.

The application does not silently change Windows defaults. After completing a
change in Windows Settings, return to DefaultAppGuard and run another check.

## Configuration recovery notice

If the Agent repaired its configuration during startup, the application keeps
a notice visible until you dismiss it. A backup-restored notice means the last
validated protected-format and notification settings were recovered. A
safe-default notice means both configuration copies were unusable; protection
was reset to the 34 video safe defaults with notifications enabled. Previously
selected non-video formats and their baselines may have been lost. Use
**Review protected formats** before
dismissing that warning.

When **System notifications** is enabled and the tray channel is available,
the Agent also queues one bilingual alert for that recovery event. A backup
restore uses an informational alert; a safe-default restore uses a warning.
Clicking either alert opens the local application. The alert is deduplicated by
recovery type and timestamp, so the same startup recovery is not repeated.
Windows may suppress the visible balloon through Focus Assist, Do Not Disturb,
notification permissions, Explorer state, or organization policy. Diagnostics
therefore says **queued**, not **displayed** or **seen**. The persistent page
notice remains the review path even when the system alert is disabled or hidden.

Dismissing a notice acknowledges only that recovery event. It does not stop the
Agent, disable monitoring, change protected formats, delete the backup, or clear
diagnostics. The acknowledgement remains in local browser storage and is not
uploaded. A later recovery is shown again. If browser policy blocks local
storage, the notice can return when the application is reopened.

## Diagnostics

Generate a constrained support report:

```powershell
& "$env:LOCALAPPDATA\Programs\DefaultAppGuard\Get-DefaultAppGuardDiagnostics.ps1"
```

The command writes a timestamped JSON report in the current directory. It
checks package integrity, Agent and Setup signature status, the scheduled task,
including its exact action, current-user privilege, triggers, single-instance
and restart settings, standard uninstall registration, Agent process identity,
watchdog recovery outcome and backoff state, loopback listener, console
children, readiness, and the current main-algorithm audit. The report also
checks the `WindowsForms.NotifyIcon` channel and records whether the user
enabled alerts. A user-disabled preference is not a fault; an unavailable
notification channel is. It also verifies the operational-log channel, format,
retention limits, file count, and aggregate byte counts without reading or
including log contents. Diagnostics schema 7 also verifies the local
configuration backup and reports `configuration-backup-restored` or
`configuration-defaults-restored` as a notice after successful recovery. The
latter means custom selections may have been lost and should be reviewed in
the application. When a recovery alert is expected, diagnostics also requires
the dedicated queued kind and timestamp to match that recovery event; a later
association-drift alert cannot overwrite this evidence. It does not include
personal paths, registry exports, raw runtime file contents, log contents, or
tokens. Review it before attaching it to an issue.

The default runtime files are:

```text
%LOCALAPPDATA%\DefaultAppGuard\runtime\agent-status.json
%LOCALAPPDATA%\DefaultAppGuard\runtime\guard-configuration.json
%LOCALAPPDATA%\DefaultAppGuard\runtime\guard-configuration.json.bak
%LOCALAPPDATA%\DefaultAppGuard\runtime\logs\agent-YYYYMMDD.clef
%LOCALAPPDATA%\DefaultAppGuard\install-state.json
```

The `.clef` files contain structured local operational events such as startup,
audit reason and counts, shutdown, and technical exceptions. They are never
uploaded automatically. The Agent rolls by day and at 2 MiB, retaining at most
seven files. Logs may still contain technical details such as an exception
stack, so do not post raw log files publicly without reviewing and redacting
them. The diagnostics JSON is the preferred first support attachment because
it reports only constrained log metadata.

The watchdog recovery summary is stored under the fixed current-user product
key `HKCU\Software\DefaultAppGuard\Watchdog`. It is local troubleshooting
state, not uploaded telemetry, and standard uninstall removes it unless data
is deliberately kept. After repeated startup failures, it records a bounded
delay before the next recovery attempt so the computer is not caught in a
rapid restart loop. Non-technical users should run Setup again for repair if
diagnostics report `watchdog-last-outcome-unhealthy` or
`watchdog-telemetry-stale`.

The `.bak` file is the previous validated configuration, not a versioned or
cloud backup. Do not edit, delete, or permission-lock either configuration
file. If the Agent cannot start, run diagnostics and rerun Setup for repair;
permission, sharing, and disk I/O failures are intentionally not converted into
a silent reset.

The scheduled task is named `DefaultAppGuard Agent`.

## Uninstall

Open **Settings > Apps > Installed apps**, find **DefaultAppGuard Community**,
open its menu, and select **Uninstall**. Windows launches the registered
current-user uninstaller in the background, so no terminal should appear.

Advanced users can run the same uninstaller directly:

```powershell
& "$env:LOCALAPPDATA\Programs\DefaultAppGuard\Uninstall-DefaultAppGuard.ps1"
```

Use `-KeepData` to retain the monitored-format configuration, last status, and
local operational logs.

The uninstaller removes only a recognized installation containing the package
manifest. It stops and unregisters the task before removing files.

## License

DefaultAppGuard is provided under the PolyForm Noncommercial License 1.0.0.
The package includes `LICENSE.md`, the required `NOTICE`,
`THIRD-PARTY-NOTICES.md`, and the applicable third-party license text.
Commercial use is not granted.

## Supported Claim

DefaultAppGuard detects and verifies default-app drift. It does not provide a
silent hard lock on Windows Home. Windows requires the user to approve default
app changes in the system UI.
