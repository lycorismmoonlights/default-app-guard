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
  const notice = await read("ENVIRONMENT-AND-RISKS.txt");

  assert.match(
    project,
    new RegExp(`<Version>${packageMetadata.version.replaceAll(".", "\\.")}</Version>`),
  );
  assert.ok(project.includes("<OutputType>WinExe</OutputType>"));
  assert.ok(
    notice.includes(
      `适用版本 / Applies to version: ${packageMetadata.version}`,
    ),
  );
  assert.ok(notice.includes("中文"));
  assert.ok(notice.includes("English"));
  assert.ok(notice.includes("IApplicationAssociationRegistration.QueryCurrentDefault"));
  assert.ok(notice.includes("RegNotifyChangeKeyValue"));
});

test("published package includes the bilingual risk notice", async () => {
  const publishScript = await read("packaging/Publish-Windows.ps1");
  const releaseGate = await read("packaging/Test-ReleaseGate.ps1");

  assert.ok(publishScript.includes('"ENVIRONMENT-AND-RISKS.txt"'));
  assert.ok(publishScript.includes("environmentAndRisks"));
  assert.ok(publishScript.includes('processMode = "background-no-console"'));
  assert.ok(releaseGate.includes('"ENVIRONMENT-AND-RISKS.txt"'));
  assert.ok(releaseGate.includes("Get-PeSubsystem"));
  assert.ok(releaseGate.includes("$peSubsystem -ne 2"));
});

test("installer disables the watchdog before replacing a running Agent", async () => {
  const installer = await read("packaging/Install-DefaultAppGuard.ps1");
  const disableIndex = installer.indexOf("Disable-ScheduledTask");
  const stopIndex = installer.indexOf("Stop-InstalledAgent $installedExecutable");

  assert.ok(disableIndex >= 0);
  assert.ok(stopIndex > disableIndex);
  assert.ok(installer.includes("for ($attempt = 1; $attempt -le 20; $attempt++)"));
  assert.ok(installer.includes("Installed Agent did not stop before the upgrade"));
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
