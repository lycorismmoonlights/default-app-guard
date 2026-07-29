# Code Signing Plan

The current alpha package is unsigned. A SHA-256 checksum proves file integrity
after publication, but it does not establish a Windows publisher identity.

## SignPath Foundation

SignPath Foundation offers free code-signing certificates for qualifying open
source projects. Its GitHub integration verifies build origin and requires
GitHub-hosted runners for the jobs leading to an open-source signing request.

This route is not currently available to DefaultAppGuard because the project
uses the PolyForm Noncommercial License 1.0.0, which is source-available rather
than OSI-approved open source. Adopting this route would require an explicit
future relicensing decision by the project owner.

If the project is relicensed, this route requires:

1. A public repository with an OSI-approved license.
2. An accepted SignPath Foundation application.
3. A GitHub-hosted build-and-sign workflow.
4. A release policy that ties the signed artifact to the same commit that
   passed the main-algorithm gate on the dedicated Windows test machine.

References:

- https://signpath.org/
- https://docs.signpath.io/trusted-build-systems/github

## Alternative: Azure Artifact Signing

Azure Artifact Signing, formerly Trusted Signing, is Microsoft's recommended
managed signing option for applications distributed outside Microsoft Store.
Pricing and Public Trust identity eligibility vary by account type and region,
so the project owner must confirm the current terms before adoption. Production
signatures should use SHA-256 and an RFC 3161 timestamp.

References:

- https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options
- https://learn.microsoft.com/windows/msix/package/signing-package-overview
- https://learn.microsoft.com/windows/win32/seccrypto/signtool

## Microsoft Store MSIX

Microsoft Store signs submitted MSIX packages without requiring the publisher
to buy and manage a certificate. This is a possible future distribution path,
but it requires a separate MSIX packaging and Store submission project. An
unsigned sideloaded MSIX is not a shortcut: Windows requires sideloaded MSIX
packages to be signed by a certificate trusted on the target computer.

## Supply-chain evidence

The GitHub release workflow produces:

- a versioned ZIP;
- a SHA-256 checksum file;
- a JSON record naming every required main-algorithm test;
- a GitHub artifact attestation when the repository is public.

An artifact attestation links an archive to its workflow and commit. It does
not replace Windows Authenticode signing or prove that the software is free of
vulnerabilities.

## Release enforcement

`packaging/Test-ReleaseGate.ps1` inspects the Authenticode status of:

- `DefaultAppGuard.Agent.exe`;
- `Install-DefaultAppGuard.ps1`;
- `Uninstall-DefaultAppGuard.ps1`;
- `Get-DefaultAppGuardDiagnostics.ps1`;
- `DefaultAppGuard.Package.psm1`.

The gate permits only two coherent states: every file is unsigned, or every
file has a valid signature from the same certificate. Mixed and invalid states
always fail. Passing `-RequireSigned` also requires a timestamp on every file;
the signing procedure must use the RFC 3161 timestamp service described above.
The GitHub Release workflow exposes the corresponding
`unsigned-alpha` and `require-signed` policies and records the selected policy,
per-file status, signer identity, and timestamp presence in
`release-gate.json`.
