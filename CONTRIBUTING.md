# Contributing

DefaultAppGuard changes should stay small, reviewable, and explicit about the
Windows behavior they rely on.

## Development checks

Run the portable checks before opening a pull request:

```powershell
pnpm install --frozen-lockfile
pnpm run build
pnpm run test:sites
dotnet test native\DefaultAppGuard.Tests\DefaultAppGuard.Tests.csproj `
  --configuration Release `
  --filter "Category!=MainAlgorithmIntegration"
```

Release candidates require the main-algorithm integration gate on a real
Windows 11 x64 system with Microsoft Media Player installed and selected for
the declared video formats:

```powershell
.\packaging\Test-ReleaseGate.ps1 -Version 0.1.1 `
  -PackageManagerPath pnpm
```

Do not replace the COM query with registry evidence, and do not make a polling
or synthetic notification test satisfy the main-algorithm gate.

## Pull requests

- Explain the user-visible behavior and the Windows versions tested.
- Add focused tests for behavior changes.
- Keep generated packages, runtime state, logs, and local installation data out
  of commits.
- Do not submit code that directly writes or ACL-locks a user's `UserChoice`
  data.

By submitting a contribution, you agree to license it under the project's
PolyForm Noncommercial License 1.0.0 and represent that you have the right to
do so.
