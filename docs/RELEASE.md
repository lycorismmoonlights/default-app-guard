# Release Process

## Three distinct gates

The hosted `CI` workflow checks the frontend, PowerShell syntax, portable .NET
behavior, and a release-shaped package built on a clean GitHub Windows runner.
That package check compiles and executes the graphical Setup verifier. It
deliberately excludes tests that require a real Windows
default-app state. A green hosted CI run is not a release approval.

The hosted `Release Candidate` workflow builds one unsigned archive on a
GitHub-hosted Windows runner, validates its package manifest and SPDX SBOM,
records the exact pinned toolchain, and creates GitHub artifact attestations
for the archive, SBOM, and `candidate-build.json`. It does not publish a
release and it cannot approve the main algorithm by itself.

The manual `Release` workflow runs on a dedicated self-hosted Windows runner
with these labels:

```text
self-hosted
Windows
X64
default-app-guard-release
```

That runner must have Microsoft Media Player installed and selected for every
declared video format. It must be dedicated to trusted release commits and
must never run pull-request code from forks. It must not have another
DefaultAppGuard Agent running while the exact-package lifecycle gate executes.

When that runner is unavailable, an unsigned alpha may instead use
`packaging/Promote-ReleaseCandidate.ps1` on the dedicated validation computer.
The script verifies the GitHub attestations, exact source commit, `main` ref,
hosted-runner policy, checksums, safe ZIP structure, package manifest, SBOM,
unsigned status, and graphical PE subsystem. It then runs the occupied-port
watchdog test and full lifecycle test against the extracted bytes from that
same attested archive. It never rebuilds the package locally.

## Release gate

`packaging/Test-ReleaseGate.ps1`:

1. Requires the exact repository-pinned .NET SDK, Node.js, and pnpm versions
   and records them in release evidence.
2. Runs portable .NET tests.
3. Runs the real COM and kernel-notification tests separately.
4. Parses the TRX result and verifies every required main-algorithm test by
   name.
5. Builds and tests the frontend.
6. Parses every packaging PowerShell script.
7. Produces a fresh self-contained Windows package and NativeAOT graphical
   Setup launcher. When signed mode is selected, it signs the fresh Agent,
   Setup launcher, and packaged PowerShell files before
   generating their integrity manifest.
8. Parses the final Agent and Setup PE headers and requires the Windows GUI
   subsystem so scheduled starts and installation cannot create a console window.
9. Verifies the generated per-file package manifest, including Setup, the
   installer, uninstaller, diagnostics script, UI assets, and Agent executable.
10. Forces an Agent startup failure against an occupied loopback port and
    proves the watchdog cleans the failed process, writes redacted failure
    telemetry, applies bounded backoff, and suppresses an immediate relaunch.
11. Executes Setup's exact-package verification, installs the package in an
   isolated location, requires the readiness endpoint to report primary COM
    evidence for every declared format, requires that evidence to be within
    the published freshness threshold, and verifies the kernel notification
    before and after the short-lived native watchdog recovers a terminated
    Agent and returns its task to `Ready`, a deliberately failed transactional
    upgrade and rollback, the `WindowsForms.NotifyIcon` channel, notification
    preference round-trip without protected-scope loss, a real bounded CLEF
    operational-log write and retention diagnostics,
   diagnostics, Windows Installed apps registration, execution of the exact
   registered hidden uninstall command, clean removal, and no shortcut
   ownership violation.
12. Generates an SPDX 2.2 SBOM with the pinned Microsoft SBOM Tool and validates
    all package file hashes and detected dependencies. Component detection uses
    a clean staging set of lock files, project files, and restored dependency
    graphs so previous release artifacts cannot contaminate the SBOM.
13. Writes SHA-256 files and machine-readable release evidence.
14. Verifies the Authenticode status of the Agent, Setup, all packaged PowerShell
    scripts, and the package module. Mixed or invalid signatures always fail.
    `-RequireSigned` additionally requires every file to have a valid,
    timestamped signature from one certificate.

The gate fails if the COM query, Media Player resolver, effective plan, real
`RegNotifyChangeKeyValue` notification, re-arm behavior, or full 34-format
audit does not pass. It also fails if the final Agent uses the Windows Console
subsystem, cannot initialize its notification channel, or loses protected
formats while changing the notification preference. It also fails when the
installed Agent cannot create its bounded operational log or diagnostics find
missing, oversized, or excess log files.

## Publishing

### Signed release path

1. Merge the intended release commit into protected `main`.
2. Confirm the dedicated runner is online and its default associations are
   healthy.
3. Run the `Release` workflow with the version declared in `package.json`.
   The workflow defaults to `require-signed`. Select `unsigned-alpha` only for
   a deliberately unsigned prerelease that is clearly labeled as such.
4. Review the attached ZIP, checksum, evidence JSON, and artifact attestation.
   Confirm that `codeSigning.policy`, `codeSigning.status`, and every file
   record match the selected workflow policy. Review the SPDX SBOM, its
   checksum, `packageLifecycle`, `toolchain`, `watchdog-backoff.json`, and
   `sbom.validationResult` as well.
5. Confirm lifecycle evidence reports both early and late-stage rollback,
   including exact install-state and uninstall-entry restoration.
6. Keep the result marked as a prerelease while the project remains alpha.

The workflow creates the `v<version>` tag and GitHub prerelease only after the
main-algorithm gate succeeds.

### Attested unsigned-alpha path

Use this fallback only while Authenticode signing is unavailable:

1. Merge the reviewed release commit into protected `main` and record its full
   commit SHA.
2. Dispatch `Release Candidate` for the version in `package.json`.
3. Confirm the workflow is green, then download its single candidate artifact
   without renaming or editing any file.
4. Check out that exact commit with no tracked local changes. On the dedicated
   Windows validation computer, stop the production Agent and run:

```powershell
.\packaging\Promote-ReleaseCandidate.ps1 `
  -CandidateDirectory F:\path\to\downloaded-candidate `
  -Version 0.1.13 `
  -ExpectedCommit <full-main-commit-sha>
```

5. Require `release-gate.json`, `package-lifecycle.json`, and
   `watchdog-backoff.json` to report `passed: true`. In particular, require 34
   fresh primary snapshots, zero failed reads, both real monitor checks,
   freshness-aware watchdog recovery, exact-package configuration corruption
   and validated last-known-good restoration with preserved settings,
   notification-channel and preference round-trip evidence, bounded local-log
   evidence, rollback, diagnostics, and clean uninstall.
6. Publish the original candidate ZIP, its checksum, the original SBOM and its
   checksum, `candidate-build.json`, `release-gate.json`,
   `package-lifecycle.json`, and `watchdog-backoff.json`. Target the exact
   attested commit and mark the release as a prerelease.
7. Redownload the release assets, compare their hashes with the promoted files,
   and verify the ZIP and SBOM attestations again.

The GitHub attestations prove which hosted workflow and source commit built the
candidate. The local evidence proves that the exact attested archive passed the
real default-app environment. Neither is a Windows publisher identity or a
substitute for Authenticode. Release notes must prominently say `unsigned`.
