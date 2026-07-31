# Release Process

## Two distinct gates

The hosted `CI` workflow checks the frontend, PowerShell syntax, and portable
.NET behavior. It deliberately excludes tests that require a real Windows
default-app state. A green hosted CI run is not a release approval.

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

## Release gate

`packaging/Test-ReleaseGate.ps1`:

1. Runs portable .NET tests.
2. Runs the real COM and kernel-notification tests separately.
3. Parses the TRX result and verifies every required main-algorithm test by
   name.
4. Builds and tests the frontend.
5. parses every packaging PowerShell script.
6. Produces a fresh self-contained Windows package. When signed mode is
   selected, it signs the fresh Agent and packaged PowerShell files before
   generating their integrity manifest.
7. Parses the final Agent PE header and requires the Windows GUI subsystem so
   scheduled starts cannot create a console window.
8. Verifies the generated per-file package manifest, including the installer,
   uninstaller, diagnostics script, UI assets, and Agent executable.
9. Installs the exact package in an isolated location and verifies the primary
   COM query and kernel notification before and after an automatic watchdog
   restart, a deliberately failed transactional upgrade and rollback,
   diagnostics, clean uninstall, and no shortcut ownership violation.
10. Generates an SPDX 2.2 SBOM with the pinned Microsoft SBOM Tool and validates
    all package file hashes and detected dependencies. Component detection uses
    a clean staging set of lock files, project files, and restored dependency
    graphs so previous release artifacts cannot contaminate the SBOM.
11. Writes SHA-256 files and machine-readable release evidence.
12. Verifies the Authenticode status of the Agent, all packaged PowerShell
    scripts, and the package module. Mixed or invalid signatures always fail.
    `-RequireSigned` additionally requires every file to have a valid,
    timestamped signature from one certificate.

The gate fails if the COM query, Media Player resolver, effective plan, real
`RegNotifyChangeKeyValue` notification, re-arm behavior, or full 34-format
audit does not pass. It also fails if the final Agent uses the Windows Console
subsystem.

## Publishing

1. Merge the intended release commit into protected `main`.
2. Confirm the dedicated runner is online and its default associations are
   healthy.
3. Run the `Release` workflow with the version declared in `package.json`.
   Select `unsigned-alpha` only while the release is explicitly an unsigned
   prerelease. Select `require-signed` for any release represented as signed.
4. Review the attached ZIP, checksum, evidence JSON, and artifact attestation.
   Confirm that `codeSigning.policy`, `codeSigning.status`, and every file
   record match the selected workflow policy. Review the SPDX SBOM, its
   checksum, `packageLifecycle`, and `sbom.validationResult` as well.
5. Keep the result marked as a prerelease while the project remains alpha.

The workflow creates the `v<version>` tag and GitHub prerelease only after the
main-algorithm gate succeeds.

A manual release is a fallback only. It cannot receive GitHub build provenance
from the release workflow and must state that limitation in its release notes.
