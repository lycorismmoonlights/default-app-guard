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
must never run pull-request code from forks.

## Release gate

`packaging/Test-ReleaseGate.ps1`:

1. Runs portable .NET tests.
2. Runs the real COM and kernel-notification tests separately.
3. Parses the TRX result and verifies every required main-algorithm test by
   name.
4. Builds and tests the frontend.
5. parses every packaging PowerShell script.
6. Produces a fresh self-contained Windows package.
7. Writes a SHA-256 file and machine-readable release evidence.

The gate fails if the COM query, Media Player resolver, effective plan, real
`RegNotifyChangeKeyValue` notification, re-arm behavior, or full 34-format
audit does not pass.

## Publishing

1. Merge the intended release commit into protected `main`.
2. Confirm the dedicated runner is online and its default associations are
   healthy.
3. Run the `Release` workflow with a semantic version such as `0.1.0`.
4. Review the attached ZIP, checksum, evidence JSON, and artifact attestation.
5. Keep the result marked as a prerelease while the project remains alpha.

The workflow creates the `v<version>` tag and GitHub prerelease only after the
main-algorithm gate succeeds.
