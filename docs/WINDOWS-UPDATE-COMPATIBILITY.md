# Windows Update Compatibility

Version: 0.2.1. Target: Windows 11 26H2, build 26300.9711.

## Failure and Fix

The 0.2.0 watchdog required a completed primary snapshot for every format.
After Windows updates removed some defaults, COM returned 0x80070483. The
watchdog treated these known missing associations as failed startup, terminated
the monitoring process, and entered recovery backoff. A missing default now
produces an explicit snapshot containing that HRESULT and an empty ProgID.
It remains drift and never satisfies capture of a new baseline.

`primarySnapshotCount` counts completed primary COM observations, including
explicit no-association results. `missingAssociationCount` exposes that subset;
`healthyCount` excludes it. `failedReadCount` still includes unrecognized COM
failures and invalid snapshots. Readiness means the monitor is operational with
fresh primary evidence, not that the user's defaults all match their baselines.

Watchdog telemetry also records the verified package version. Recovery backoff
is retained only for the same version. Upgrades (including legacy telemetry
without a version) get a fresh recovery attempt instead of waiting up to an
hour for failures caused by the old implementation. Same-version failures
still use bounded backoff, and integrity verification runs before recovery.

Package full names contain a version. ProgIDs can also change during an app
update. A changed ProgID is accepted only when the original and current package
families match and their AppUserModelIDs match. New captured baselines persist
the app ID. Older schema 3 data can obtain it from the original ProgID registration
only if that registration still belongs to the originally captured package family.
If identity is unavailable, the old exact-ProgID comparison remains conservative.

## Verification

Run portable tests, WindowsUpdateCompatibilityIntegrationTests, and the real
RegistryChangeMonitorIntegrationTests. The compatibility suite compares all 99
catalog observations against separate raw QueryCurrentDefault invocations and
also probes a fresh unregistered extension without creating a registry default.
The registry monitor must still prove two real writes and no synthetic success.

Keep absence, drift and query failure distinct in package lifecycle evidence.
The packaged watchdog must leave an Agent with missing defaults running, reset
recovery backoff after successful readiness, and recover a terminated process.
Never silently recapture baselines or create defaults to make a test green.

For a task-launched installed Agent, run the independent writer in the same
interactive scheduled-task environment when a development command host fails
to deliver registry notifications to that Agent:

```powershell
.\tests\Test-InstalledMonitorInTask.ps1 `
  -WorkRoot F:\ins_mag\default-app-guard\artifacts\monitor-probe `
  -EvidencePath F:\ins_mag\default-app-guard\artifacts\monitor-evidence.json `
  -AllowAssociationDrift
```

Both output paths must be new. The temporary, hidden task runs the original
monitor probe, performs two real FileExts writes in an independent process,
checks fresh primary COM evidence, removes the probe key, and is unregistered
afterwards. This is a test execution context, not a monitor fallback. Omit
`-AllowAssociationDrift` when every protected association must also match.
The strict release gate is unchanged. In-process tests alone do not prove the
installed monitor works. The precise cause of the development-host versus
interactive-task notification difference has not been established.

## Local Validation, 2026-10-23

- 128 .NET tests passed, including eight real primary-algorithm integration
  cases; 14 UI/worker tests and 13 promotion contract tests passed.
- All 99 catalog observations matched independent raw COM queries. The
  installed Agent completed all 80 selected primary observations with zero
  failed reads. Fifteen confirmed missing defaults and two other mismatches
  remained visible as drift; they were not accepted as healthy defaults.
- The original configuration remained byte-identical. Five Photos baselines
  were recognized across the package/ProgID update without recapturing them.
- Independent interactive-task writes proved notification delivery and rearm
  before and after watchdog recovery. A normal watchdog run preserved the
  running process, and termination of that process was recovered automatically.
- The exact packaged watchdog passed forced failure/backoff/failed-process
  cleanup checks. Package integrity tests passed in PowerShell 7 and 5.1.
- Strict monitor verification without the drift opt-in correctly failed for
  the remaining mismatches. The full promotion gate was not run and is not
  claimed to pass. This remains unsigned, single-machine compatibility evidence,
  not evidence for every Windows build or a broadly qualified stable release.

## Microsoft References

- [QueryCurrentDefault](https://learn.microsoft.com/windows/win32/api/shobjidl_core/nf-shobjidl_core-iapplicationassociationregistration-querycurrentdefault)
- [PackageFamilyNameFromFullName](https://learn.microsoft.com/windows/win32/api/appmodel/nf-appmodel-packagefamilynamefromfullname)
