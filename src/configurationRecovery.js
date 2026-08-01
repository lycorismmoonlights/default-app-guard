export const recoveryAcknowledgementStorageKey =
  "default-app-guard.configuration-recovery.acknowledged-event";

const recoveryNotices = Object.freeze({
  "backup-restored": Object.freeze({
    severity: "info",
    title: "保护设置已从备份恢复",
    message:
      "上次保存的保护范围和通知设置已恢复。建议检查一次保护范围。",
  }),
  "defaults-restored": Object.freeze({
    severity: "warning",
    title: "保护设置已恢复为安全默认值",
    message:
      "配置文件和备份均无法读取，现已保护全部 34 种视频格式并开启通知。你之前的自定义选择可能已丢失，请检查。",
  }),
});

function normalizeRecoveryTimestamp(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    return "unknown-time";
  }

  const trimmed = value.trim();
  const timestamp = Date.parse(trimmed);
  return Number.isFinite(timestamp)
    ? new Date(timestamp).toISOString()
    : `invalid-time:${trimmed}`;
}

export function getConfigurationRecoveryNotice(health) {
  if (!health || health.configurationRecovered !== true) {
    return null;
  }

  const code = health.configurationRecoveryCode;
  const notice = recoveryNotices[code];
  if (!notice) {
    return null;
  }

  const recoveredAtUtc = normalizeRecoveryTimestamp(
    health.configurationRecoveredAtUtc,
  );

  return {
    ...notice,
    code,
    eventKey: `${code}:${recoveredAtUtc}`,
    recoveredAtUtc,
  };
}

export function readAcknowledgedRecoveryEvent(storage) {
  try {
    return storage?.getItem(recoveryAcknowledgementStorageKey) || "";
  } catch {
    return "";
  }
}

export function getRecoveryStorage(browserWindow = globalThis.window) {
  try {
    return browserWindow?.localStorage ?? null;
  } catch {
    return null;
  }
}

export function acknowledgeRecoveryEvent(storage, eventKey) {
  if (typeof eventKey !== "string" || eventKey.length === 0) {
    return false;
  }

  try {
    storage?.setItem(recoveryAcknowledgementStorageKey, eventKey);
    return Boolean(storage);
  } catch {
    return false;
  }
}
