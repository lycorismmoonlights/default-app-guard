import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  acknowledgeRecoveryEvent,
  getConfigurationRecoveryNotice,
  getRecoveryStorage,
  readAcknowledgedRecoveryEvent,
  recoveryAcknowledgementStorageKey,
} from "../src/configurationRecovery.js";

test("maps backup recovery to a stable informational event", () => {
  const notice = getConfigurationRecoveryNotice({
    configurationRecovered: true,
    configurationRecoveryCode: "backup-restored",
    configurationRecoveredAtUtc: "2026-08-01T10:11:12Z",
  });

  assert.equal(notice.severity, "info");
  assert.equal(notice.code, "backup-restored");
  assert.equal(notice.recoveredAtUtc, "2026-08-01T10:11:12.000Z");
  assert.equal(
    notice.eventKey,
    "backup-restored:2026-08-01T10:11:12.000Z",
  );
  assert.match(notice.title, /备份恢复/);
});

test("warns when invalid primary and backup settings required safe defaults", () => {
  const notice = getConfigurationRecoveryNotice({
    configurationRecovered: true,
    configurationRecoveryCode: "defaults-restored",
    configurationRecoveredAtUtc: "2026-08-01T10:11:12.345Z",
  });

  assert.equal(notice.severity, "warning");
  assert.match(notice.title, /安全默认值/);
  assert.match(notice.message, /34 种视频格式的安全默认保护/);
  assert.match(notice.message, /自定义选择可能已丢失/);
});

test("does not invent notices for normal or unsupported health states", () => {
  assert.equal(getConfigurationRecoveryNotice(null), null);
  assert.equal(
    getConfigurationRecoveryNotice({
      configurationRecovered: false,
      configurationRecoveryCode: "none",
    }),
    null,
  );
  assert.equal(
    getConfigurationRecoveryNotice({
      configurationRecovered: true,
      configurationRecoveryCode: "future-recovery-code",
    }),
    null,
  );
});

test("still surfaces a supported recovery when its timestamp is malformed", () => {
  const missingTimestamp = getConfigurationRecoveryNotice({
    configurationRecovered: true,
    configurationRecoveryCode: "backup-restored",
  });
  const malformedTimestamp = getConfigurationRecoveryNotice({
    configurationRecovered: true,
    configurationRecoveryCode: "backup-restored",
    configurationRecoveredAtUtc: "not-a-time",
  });

  assert.equal(missingTimestamp.recoveredAtUtc, "unknown-time");
  assert.equal(
    malformedTimestamp.eventKey,
    "backup-restored:invalid-time:not-a-time",
  );
});

test("acknowledges one recovery event without failing on blocked storage", () => {
  const values = new Map();
  const storage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };

  assert.equal(readAcknowledgedRecoveryEvent(storage), "");
  assert.equal(acknowledgeRecoveryEvent(storage, "backup-restored:event"), true);
  assert.equal(
    values.get(recoveryAcknowledgementStorageKey),
    "backup-restored:event",
  );
  assert.equal(
    readAcknowledgedRecoveryEvent(storage),
    "backup-restored:event",
  );

  const blockedStorage = {
    getItem: () => {
      throw new Error("blocked");
    },
    setItem: () => {
      throw new Error("blocked");
    },
  };
  assert.equal(readAcknowledgedRecoveryEvent(blockedStorage), "");
  assert.equal(
    acknowledgeRecoveryEvent(blockedStorage, "backup-restored:event"),
    false,
  );
  assert.equal(acknowledgeRecoveryEvent(storage, ""), false);
});

test("treats an inaccessible browser storage property as unavailable", () => {
  const browserWindow = {};
  Object.defineProperty(browserWindow, "localStorage", {
    get() {
      throw new DOMException("blocked", "SecurityError");
    },
  });

  assert.equal(getRecoveryStorage(browserWindow), null);
  assert.equal(getRecoveryStorage(undefined), null);
});

test("wires the persistent recovery notice into the application shell", async () => {
  const appSource = await readFile(
    new URL("../src/App.jsx", import.meta.url),
    "utf8",
  );
  const styles = await readFile(
    new URL("../src/styles.css", import.meta.url),
    "utf8",
  );

  assert.match(appSource, /function ConfigurationRecoveryNotice/);
  assert.match(appSource, /role=\{isWarning \? "alert" : "status"\}/);
  assert.match(appSource, /aria-label="关闭配置恢复提示"/);
  assert.match(appSource, /onReview=\{\(\) => setActiveSection\("defaults"\)\}/);
  assert.match(styles, /\.recovery-notice\.warning/);
  assert.match(styles, /grid-template-columns: 28px minmax\(0, 1fr\) auto 36px/);
});
