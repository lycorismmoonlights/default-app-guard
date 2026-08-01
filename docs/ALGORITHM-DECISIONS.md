# Algorithm Decisions

## Supported Main Path

DefaultAppGuard treats this chain as the product's main algorithm:

1. Query the effective handler with
   `IApplicationAssociationRegistration.QueryCurrentDefault`.
2. Resolve the installed Microsoft Media Player ProgID dynamically from its
   registered `OpenWithProgids`, package ID, company, and AUMID.
3. Cross-check `UserChoice` only as evidence. It never replaces a failed COM
   result.
4. Subscribe to the current user's `FileExts` tree with
   `RegNotifyChangeKeyValue`.
5. Include `REG_NOTIFY_THREAD_AGNOSTIC`, re-arm immediately after each signal,
   and wait for a 250 ms quiet period before auditing.
6. Re-audit every protected extension through the COM query after a registry
   notification.
7. Perform a 15-minute COM readback because Microsoft documents that
   `RegNotifyChangeKeyValue` cannot observe every registry restoration method.
8. Direct the user to Media Player's official Default Apps settings page for
   repair.

Main-path tests must prove that a notification remains pending without a real
write, completes after a real write, can be re-armed for a second real write,
and results in a COM audit. A polling or registry-only result cannot satisfy
these tests.

## Runtime Stability

- A per-user named mutex prevents duplicate Agents.
- The monitor subscription is armed before the startup audit, closing the
  startup read/subscribe race.
- The current-user scheduled task runs a short-lived native, no-console
  watchdog at logon and on a repeated trigger. The watchdog verifies package
  integrity, validates the loopback health endpoint and owning process, starts
  the Agent when needed, and returns the task to `Ready`.
- The Agent is not the long-running scheduled-task action. This avoids a Task
  Scheduler state where a force-terminated Agent can remain marked `Running`
  and cause `IgnoreNew` to suppress the recovery trigger.
- The watchdog has a one-minute execution limit and restart-on-failure policy.
  `IgnoreNew` applies only to overlapping short-lived checks.
- State and configuration files are replaced atomically.
- The loopback API rejects foreign origins and requires a local client header
  for mutating operations.

## Rejected Approaches

### Direct UserChoice ACL lock

Rejected on Windows 11 25H2 with UCPD enabled.

Changing the `UserChoice` DACL caused Windows to temporarily reject otherwise
valid associations. The transaction detected the failed COM verification,
removed every guard rule, and the 34-format COM audit recovered. This algorithm
must not be exposed by the application.

Evidence from the rejected experiment is retained locally under `runtime/`.

### Direct registry writes and default-setting APIs

Windows does not support registry-based changes to a user's default app data.
UCPD protects that data, and default changes require user interaction in the
system UI.

https://learn.microsoft.com/windows/apps/develop/windows-integration/default-apps-platform

Starting with Windows 8, the supported operation used here on
`IApplicationAssociationRegistration` is `QueryCurrentDefault`.

https://learn.microsoft.com/windows/win32/api/shobjidl_core/nn-shobjidl_core-iapplicationassociationregistration

### DISM import

DISM default-association imports apply to users during first logon. They are not
an existing-user repair or lock algorithm.

https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-default-application-association-servicing-command-line-options

### ApplicationDefaults policy

The policy is a valid managed-device enhancement for Pro, Enterprise,
Education, and IoT Enterprise. It is not the Windows Home main path.

https://learn.microsoft.com/windows/client-management/mdm/policy-csp-applicationdefaults

## Product Claim

On Windows Home, DefaultAppGuard can detect association drift, verify the
effective result with the Windows COM query, and take the user directly to the
supported repair surface. It must not claim silent restoration or an
unbreakable hard lock.

On supported managed editions, a versioned ApplicationDefaults policy may be
offered later as a separate administrator-controlled enhancement.
