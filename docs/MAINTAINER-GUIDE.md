# Maintainer Guide

## Release Gate

Run all of the following on Windows:

```powershell
pnpm install --frozen-lockfile
.\packaging\Test-ReleaseGate.ps1 -Version 0.1.4 `
  -PackageManagerPath pnpm
```

Do not accept a release based only on unit tests. The integration suite must
exercise the real COM query and the real kernel registry notification.

Unsigned alpha releases may omit `-RequireSigned`, but their evidence must
report `codeSigning.status` as `unsigned`. Any release described as signed must
run:

```powershell
.\packaging\Test-ReleaseGate.ps1 -Version 0.1.4 `
  -PackageManagerPath pnpm `
  -RequireSigned
```

That mode requires valid, timestamped Authenticode signatures on the Agent,
installer, uninstaller, diagnostics script, and package module. All files must
use the same signer certificate.

## Main-Algorithm Evidence

The required signals are:

- Query source:
  `IApplicationAssociationRegistration.QueryCurrentDefault`.
- Monitor source: `RegNotifyChangeKeyValue`.
- A pending notification does not complete when the calling thread yields.
- A real registry write completes the notification.
- Re-arming receives a second real write.
- The post-notification audit checks each protected extension individually.
- Registry evidence never replaces a failed COM result.

## Installation Test

Use an isolated directory outside the installation defaults, a test task name,
and a non-production loopback port:

```powershell
$testRoot = Join-Path $env:TEMP "DefaultAppGuard-install-test"
.\Install-DefaultAppGuard.ps1 `
  -InstallDirectory (Join-Path $testRoot "app") `
  -DataDirectory (Join-Path $testRoot "data") `
  -TaskName "DefaultAppGuard Agent Integration Test" `
  -AgentUrl "http://127.0.0.1:51874" `
  -WatchdogIntervalMinutes 1 `
  -NoStartMenuShortcut
```

Verify:

1. The installer reports `PackageIntegrityVerified: True`,
   `TransactionalUpgrade: True`, and `ProcessMode: background-no-console`.
2. `/api/health` reports the COM query, registry monitor, expected PID, and
   background process mode.
3. `/api/status` reports all declared formats individually.
4. A harmless subkey created below the current user's `FileExts` tree increases
   `registryEventCount`.
5. The exact probe key is removed.
6. Killing the installed process produces a different PID after the watchdog
   trigger and a fresh 34-format startup audit.
7. A deliberately failed upgrade restores the previous package version, task
   definition, process, and healthy audit.
8. `Get-DefaultAppGuardDiagnostics.ps1` reports no issues and does not include
   personal paths or raw runtime contents.
9. Uninstallation leaves no task, process, install directory, data directory,
   or probe key.

## Packaging

The release is a compressed, self-contained `win-x64` executable plus a
`wwwroot` directory. Node.js and the .NET runtime are build dependencies only.

The publish script refuses to reuse an existing output directory so that a
release cannot silently contain stale assets.

See [RELEASE.md](RELEASE.md) for the GitHub Actions split between hosted
portable CI and the dedicated real-Windows main-algorithm release gate.

## Official Platform Boundaries

- Windows default apps platform:
  https://learn.microsoft.com/windows/apps/develop/windows-integration/default-apps-platform
- Effective default query:
  https://learn.microsoft.com/windows/win32/api/shobjidl_core/nf-shobjidl_core-iapplicationassociationregistration-querycurrentdefault
- Registry notifications:
  https://learn.microsoft.com/windows/win32/api/winreg/nf-winreg-regnotifychangekeyvalue
- Logon tasks:
  https://learn.microsoft.com/windows/win32/taskschd/starting-an-executable-when-a-user-logs-on
- Single-file deployment:
  https://learn.microsoft.com/dotnet/core/deploying/single-file/overview
