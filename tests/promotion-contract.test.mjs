import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

async function read(path) {
  return readFile(new URL(path, root), "utf8");
}

test("release metadata and risk notice stay version-aligned", async () => {
  const packageMetadata = JSON.parse(await read("package.json"));
  const project = await read(
    "native/DefaultAppGuard.Agent/DefaultAppGuard.Agent.csproj",
  );
  const setupProject = await read(
    "native/DefaultAppGuard.Setup/DefaultAppGuard.Setup.csproj",
  );
  const notice = await read("ENVIRONMENT-AND-RISKS.txt");

  assert.match(
    project,
    new RegExp(`<Version>${packageMetadata.version.replaceAll(".", "\\.")}</Version>`),
  );
  assert.match(
    setupProject,
    new RegExp(`<Version>${packageMetadata.version.replaceAll(".", "\\.")}</Version>`),
  );
  assert.ok(project.includes("<OutputType>WinExe</OutputType>"));
  assert.ok(setupProject.includes("<OutputType>WinExe</OutputType>"));
  assert.ok(
    notice.includes(
      `适用版本 / Applies to version: ${packageMetadata.version}`,
    ),
  );
  assert.ok(notice.includes("中文"));
  assert.ok(notice.includes("English"));
  assert.ok(notice.includes("IApplicationAssociationRegistration.QueryCurrentDefault"));
  assert.ok(notice.includes("RegNotifyChangeKeyValue"));
  assert.ok(notice.includes("未签名 alpha 版本"));
  assert.ok(notice.includes("unsigned alpha release"));
  assert.ok(notice.includes("Smart App Control"));
  assert.ok(notice.includes("Get-FileHash"));
  assert.match(notice, /do not replace\s+Authenticode code signing/);
  assert.ok(notice.includes("不要把整台电脑的执行策略永久改为"));
  assert.ok(notice.includes("do not permanently change the computer-wide policy"));
  assert.ok(notice.includes("已安装的应用"));
  assert.ok(notice.includes("Windows Installed apps list"));
  assert.ok(notice.includes("0x800710E0"));
  assert.ok(notice.includes("scheduledTask.configurationHealthy"));
});

test("published package includes the bilingual risk notice", async () => {
  const publishScript = await read("packaging/Publish-Windows.ps1");
  const releaseGate = await read("packaging/Test-ReleaseGate.ps1");
  const ciWorkflow = await read(".github/workflows/ci.yml");
  const releaseWorkflow = await read(".github/workflows/release.yml");

  assert.ok(publishScript.includes('"ENVIRONMENT-AND-RISKS.txt"'));
  assert.ok(publishScript.includes("environmentAndRisks"));
  assert.ok(publishScript.includes('processMode = "background-no-console"'));
  assert.ok(publishScript.includes("Get-PublishSigningCertificate"));
  assert.ok(publishScript.includes("Set-AuthenticodeSignature"));
  assert.ok(publishScript.includes("TimestampServer is required"));
  assert.ok(publishScript.includes("schemaVersion = 2"));
  assert.ok(publishScript.includes("sha256 = (Get-FileHash"));
  assert.ok(publishScript.includes('"DefaultAppGuard.Package.psm1"'));
  assert.ok(publishScript.includes('"Get-DefaultAppGuardDiagnostics.ps1"'));
  assert.ok(releaseGate.includes('"ENVIRONMENT-AND-RISKS.txt"'));
  assert.ok(releaseGate.includes("Test-DagPackageIntegrity"));
  assert.ok(releaseGate.includes("Get-DagPeSubsystem"));
  assert.ok(releaseGate.includes("$peSubsystem -ne 2"));
  assert.ok(releaseGate.includes("packageIntegrity = [ordered]@{"));
  assert.ok(releaseGate.includes("[switch]$RequireSigned"));
  assert.ok(releaseGate.includes('codeSigningStatus = if'));
  assert.ok(releaseGate.includes('"mixed-or-invalid"'));
  assert.ok(releaseGate.includes("Get-AuthenticodeSignature"));
  assert.ok(releaseGate.includes("timestamped Authenticode signatures"));
  assert.ok(releaseGate.includes("SigningCertificateThumbprint"));
  assert.ok(releaseGate.includes("codeSigning = [ordered]@{"));
  assert.ok(releaseGate.includes("Test-ReleasePackageLifecycle.ps1"));
  assert.ok(releaseGate.includes("exactReleasePackagePassed"));
  assert.ok(releaseGate.includes("watchdogConfigurationVerified"));
  assert.ok(releaseGate.includes('"tool", "run", "sbom-tool"'));
  assert.ok(releaseGate.includes('"SPDX:2.2"'));
  assert.ok(releaseGate.includes("TotalPackagesInManifest"));
  assert.ok(releaseGate.includes("historicalArtifactsExcluded = $true"));
  assert.ok(releaseWorkflow.includes("signing_policy:"));
  assert.ok(releaseWorkflow.includes("unsigned-alpha"));
  assert.ok(releaseWorkflow.includes("require-signed"));
  assert.ok(releaseWorkflow.includes("signing_status="));
  assert.ok(releaseWorkflow.includes("Attest release SBOM"));
  assert.ok(releaseWorkflow.includes("sbom-path:"));
  assert.ok(ciWorkflow.includes("RedirectStandardError"));
  assert.ok(ciWorkflow.includes("setup-verify.stderr.txt"));
});

test("graphical setup verifies before its process-only script policy", async () => {
  const setup = await read("native/DefaultAppGuard.Setup/Program.cs");
  const verifier = await read(
    "native/DefaultAppGuard.Setup/PackageIntegrityVerifier.cs",
  );
  const lifecycle = await read("tests/Test-ReleasePackageLifecycle.ps1");

  const verificationIndex = setup.indexOf(
    "PackageIntegrityVerifier.Verify(packageDirectory)",
  );
  const processStartIndex = setup.indexOf("Process.Start(startInfo)");
  assert.ok(verificationIndex >= 0);
  assert.ok(processStartIndex > verificationIndex);
  assert.ok(setup.includes('startInfo.ArgumentList.Add("Bypass")'));
  assert.ok(setup.includes("DefaultAppGuard-Setup-verify-install"));
  assert.ok(setup.includes("DefaultAppGuard-Setup-verify-data"));
  assert.equal(setup.includes("Set-ExecutionPolicy"), false);
  assert.ok(verifier.includes("SHA256.HashData(stream)"));
  assert.ok(verifier.includes('issues.Add("package-file-undeclared")'));
  assert.ok(verifier.includes('issues.Add("package-path-escape")'));
  assert.ok(lifecycle.includes("PSExecutionPolicyPreference = \"Restricted\""));
  assert.ok(lifecycle.includes("$env:LOCALAPPDATA = $null"));
  assert.ok(lifecycle.includes("Native Setup did not reject"));
  assert.ok(lifecycle.includes("tampered-script-executed.txt"));
});

test("GitHub Actions use immutable action revisions", async () => {
  const workflows = [
    await read(".github/workflows/ci.yml"),
    await read(".github/workflows/release.yml"),
  ];

  for (const workflow of workflows) {
    const actions = [...workflow.matchAll(/^\s*uses:\s*([^\s#]+)/gm)].map(
      (match) => match[1],
    );
    assert.ok(actions.length > 0);
    for (const action of actions) {
      assert.match(action, /@[0-9a-f]{40}$/);
    }
    assert.ok(workflow.includes("persist-credentials: false"));
  }

  const releaseWorkflow = workflows[1];
  assert.match(releaseWorkflow, /default:\s*require-signed/);
  assert.ok(releaseWorkflow.includes("SIGNING_STATUS:"));
  assert.equal(
    releaseWorkflow.includes("$signingStatus = '${{ steps.gate.outputs"),
    false,
  );
});

test("installer validates, stages, and can roll back an upgrade", async () => {
  const installer = await read("packaging/Install-DefaultAppGuard.ps1");
  const sourceCheckIndex = installer.indexOf(
    "Assert-DagPackageIntegrity -PackageRoot $sourceDirectory",
  );
  const stagingCheckIndex = installer.indexOf(
    "Assert-DagPackageIntegrity -PackageRoot $stagingPath",
  );
  const disableIndex = installer.indexOf("Disable-ScheduledTask");
  const stopIndex = installer.indexOf(
    "Stop-InstalledAgent -ExecutablePath $installedExecutable",
  );

  assert.ok(sourceCheckIndex >= 0);
  assert.ok(stagingCheckIndex > sourceCheckIndex);
  assert.ok(disableIndex > stagingCheckIndex);
  assert.ok(stopIndex > disableIndex);
  assert.ok(installer.includes("for ($attempt = 1; $attempt -le 20; $attempt++)"));
  assert.ok(installer.includes("Installed Agent did not stop before the upgrade"));
  assert.ok(installer.includes("Export-ScheduledTask"));
  assert.ok(installer.includes(".$installLeaf.backup-$transactionId"));
  assert.ok(installer.includes("Move-Item -LiteralPath $backupPath -Destination $installPath"));
  assert.ok(installer.includes("the previous installation was restored"));
  assert.ok(installer.includes("Health endpoint is not owned by the installed Agent"));
  assert.ok(installer.includes("ProcessMode -ne \"background-no-console\""));
  assert.ok(installer.includes("$replacementBackupPath"));
  assert.ok(installer.includes("$shouldManageShortcut"));
  assert.ok(installer.includes("Set-UninstallRegistryEntry"));
  assert.ok(installer.includes("Restore-UninstallRegistrySnapshot"));
  assert.ok(installer.includes("$installStateBackupPath"));
  assert.ok(installer.includes("QuietUninstallString"));
  assert.ok(installer.includes("-WindowStyle Hidden"));
  assert.equal(installer.includes("[IO.File]::Replace($temporaryPath, $Path, $null)"), false);
});

test("diagnostics are packaged, redacted, and inspect the primary algorithm", async () => {
  const diagnostics = await read(
    "packaging/Get-DefaultAppGuardDiagnostics.ps1",
  );

  assert.ok(diagnostics.includes("Test-DagPackageIntegrity"));
  assert.ok(diagnostics.includes("containsPersonalPaths = $false"));
  assert.ok(diagnostics.includes("containsRegistryExports = $false"));
  assert.ok(diagnostics.includes("containsRuntimeFileContents = $false"));
  assert.ok(
    diagnostics.includes(
      "IApplicationAssociationRegistration.QueryCurrentDefault",
    ),
  );
  assert.ok(diagnostics.includes('RegNotifyChangeKeyValue'));
  assert.ok(diagnostics.includes("consoleChildCount"));
  assert.ok(diagnostics.includes("loopbackOnly"));
  assert.ok(diagnostics.includes("uninstallRegistration"));
  assert.ok(diagnostics.includes("uninstall-registration-missing"));
  assert.ok(diagnostics.includes("quiet-uninstall-missing"));
  assert.ok(diagnostics.includes("task-principal-mismatch"));
  assert.ok(diagnostics.includes("task-settings-mismatch"));
  assert.ok(diagnostics.includes("task-triggers-mismatch"));
  assert.ok(diagnostics.includes("configurationHealthy"));
  assert.ok(
    diagnostics.includes('"expected-ignore-new-while-running"'),
  );
});

test("uninstaller verifies ownership before removing task or directories", async () => {
  const uninstaller = await read("packaging/Uninstall-DefaultAppGuard.ps1");
  const ownershipIndex = uninstaller.indexOf(
    "Refusing to remove a scheduled task owned by another installation.",
  );
  const unregisterIndex = uninstaller.indexOf("Unregister-ScheduledTask");
  const removeRegistrationIndex = uninstaller.lastIndexOf(
    "DeleteSubKeyTree",
  );
  const removeInstallIndex = uninstaller.indexOf(
    "Remove-DirectoryWithRetry $verifiedInstall",
  );

  assert.ok(uninstaller.includes('product -ne "DefaultAppGuard Community"'));
  assert.ok(uninstaller.includes("data owned by another installation"));
  assert.ok(uninstaller.includes("$null -ne $installState"));
  assert.ok(ownershipIndex >= 0);
  assert.ok(unregisterIndex > ownershipIndex);
  assert.ok(removeInstallIndex > unregisterIndex);
  assert.ok(removeRegistrationIndex > removeInstallIndex);
  assert.ok(uninstaller.includes("UninstallRegistrationRemoved"));
});

test("production UI exposes only implemented product capabilities", async () => {
  const app = await read("src/App.jsx");

  for (const unsupported of [
    "VLC media player",
    "Quark Technology",
    "电影和电视",
    "备份与恢复",
    "浏览器默认应用",
    "window-actions",
  ]) {
    assert.equal(app.includes(unsupported), false, unsupported);
  }

  assert.ok(app.includes("保护目标"));
  assert.ok(app.includes("不会直接改写 Windows 的默认关联"));
  assert.ok(app.includes("aria-label={section.label}"));
  assert.ok(app.includes('startsWith("@{")'));
  assert.ok(app.includes('includes("ms-resource:")'));
  assert.ok(app.includes("Agent 运行异常"));
});

test("Vite includes the patched 6.4.3 release", async () => {
  const packageMetadata = JSON.parse(await read("package.json"));
  assert.equal(packageMetadata.dependencies.vite, "6.4.3");
});
