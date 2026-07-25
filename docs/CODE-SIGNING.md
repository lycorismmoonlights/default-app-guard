# Code Signing Plan

The current alpha package is unsigned. A SHA-256 checksum proves file integrity
after publication, but it does not establish a Windows publisher identity.

## Preferred route: SignPath Foundation

SignPath Foundation offers free code-signing certificates for qualifying open
source projects. Its GitHub integration verifies build origin and requires
GitHub-hosted runners for the jobs leading to an open-source signing request.

This route requires:

1. A public repository with an OSI-approved license.
2. An accepted SignPath Foundation application.
3. A GitHub-hosted build-and-sign workflow.
4. A release policy that ties the signed artifact to the same commit that
   passed the main-algorithm gate on the dedicated Windows test machine.

References:

- https://signpath.org/
- https://docs.signpath.io/trusted-build-systems/github

## Alternative: Microsoft Artifact Signing

Microsoft Artifact Signing provides publicly trusted Windows code signing.
The Basic tier is currently USD 9.99 per month for up to 5,000 signatures.
Public Trust identity validation is region-limited, so eligibility must be
confirmed before adopting it.

References:

- https://learn.microsoft.com/azure/artifact-signing/quickstart
- https://learn.microsoft.com/azure/artifact-signing/how-to-change-sku
- https://learn.microsoft.com/azure/artifact-signing/concept-trust-models

## Supply-chain evidence

The GitHub release workflow produces:

- a versioned ZIP;
- a SHA-256 checksum file;
- a JSON record naming every required main-algorithm test;
- a GitHub artifact attestation when the repository is public.

An artifact attestation links an archive to its workflow and commit. It does
not replace Windows Authenticode signing or prove that the software is free of
vulnerabilities.
