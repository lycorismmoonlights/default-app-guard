import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Apps24Regular,
  ArrowSync24Regular,
  CheckmarkCircle24Filled,
  Dismiss24Regular,
  History24Regular,
  Info24Regular,
  Open24Regular,
  PlayCircle24Filled,
  Settings24Regular,
  Shield24Regular,
  ShieldCheckmark24Filled,
  Warning24Regular,
} from "@fluentui/react-icons";
import {
  acknowledgeRecoveryEvent,
  getConfigurationRecoveryNotice,
  getRecoveryStorage,
  readAcknowledgedRecoveryEvent,
} from "./configurationRecovery.js";

const sections = [
  { id: "status", label: "状态", icon: Shield24Regular },
  { id: "defaults", label: "默认应用", icon: Apps24Regular },
  { id: "history", label: "保护记录", icon: History24Regular },
  { id: "settings", label: "设置", icon: Settings24Regular },
];

function normalizeApplicationName(value) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (
    !normalized ||
    normalized.startsWith("@{") ||
    normalized.includes("ms-resource:")
  ) {
    return "";
  }
  return normalized;
}

const categoryLabels = {
  video: "视频",
  audio: "音频",
  document: "文档",
  image: "图片",
  archive: "压缩包",
  "web-data": "网页与数据",
};

const categoryOrder = [
  "video",
  "audio",
  "document",
  "image",
  "archive",
  "web-data",
];

const agentBaseUrl =
  import.meta.env.VITE_AGENT_BASE_URL ||
  (import.meta.env.DEV
    ? "http://127.0.0.1:51873"
    : window.location.origin);

function useAgentStatus() {
  const [status, setStatus] = useState(null);
  const [configuration, setConfiguration] = useState(null);
  const [health, setHealth] = useState(null);
  const [catalog, setCatalog] = useState([]);
  const [inspections, setInspections] = useState([]);
  const [error, setError] = useState("");
  const [isRefreshing, setIsRefreshing] = useState(false);

  const request = useCallback(async (path, options) => {
    const response = await fetch(`${agentBaseUrl}${path}`, options);
    if (!response.ok) {
      const detail = await response.json().catch(() => null);
      throw new Error(detail?.error || `Agent 返回 ${response.status}`);
    }
    return response.json();
  }, []);

  const inspect = useCallback(
    async (extensions) => {
      if (!extensions?.length) return [];
      return request("/api/associations/inspect", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-DefaultAppGuard-Client": "local-ui",
        },
        body: JSON.stringify({ extensions }),
      });
    },
    [request],
  );

  const refresh = useCallback(
    async (manual = false) => {
      setIsRefreshing(true);
      try {
        const requests = [
          request(
            `/api/${manual ? "audit" : "status"}`,
            manual
              ? {
                  method: "POST",
                  headers: { "X-DefaultAppGuard-Client": "local-ui" },
                }
              : undefined,
          ),
          request("/api/health"),
        ];
        if (manual && catalog.length) {
          requests.push(inspect(catalog.map((item) => item.extension)));
        }
        const [nextStatus, nextHealth, nextInspections] =
          await Promise.all(requests);
        setStatus(nextStatus);
        setHealth(nextHealth);
        if (nextInspections) setInspections(nextInspections);
        setError("");
      } catch (requestError) {
        setError(requestError.message || "无法连接本地 Agent");
      } finally {
        setIsRefreshing(false);
      }
    },
    [catalog, inspect, request],
  );

  const saveConfiguration = useCallback(
    async (update) => {
      setIsRefreshing(true);
      try {
        const result = await request("/api/config", {
          method: "PUT",
          headers: {
            "Content-Type": "application/json",
            "X-DefaultAppGuard-Client": "local-ui",
          },
          body: JSON.stringify(update),
        });
        setConfiguration(result.configuration);
        setStatus(result.status);
        setError("");
        return true;
      } catch (requestError) {
        setError(requestError.message || "无法保存配置");
        return false;
      } finally {
        setIsRefreshing(false);
      }
    },
    [request],
  );

  const openSettings = useCallback(async () => {
    try {
      await request("/api/open-settings", {
        method: "POST",
        headers: { "X-DefaultAppGuard-Client": "local-ui" },
      });
      setError("");
      return true;
    } catch (requestError) {
      setError(requestError.message || "无法打开 Windows 默认应用设置");
      return false;
    }
  }, [request]);

  useEffect(() => {
    Promise.all([
      request("/api/status"),
      request("/api/config"),
      request("/api/health"),
      request("/api/association-catalog"),
    ])
      .then(async ([
        nextStatus,
        nextConfiguration,
        nextHealth,
        nextCatalog,
      ]) => {
        setStatus(nextStatus);
        setConfiguration(nextConfiguration);
        setHealth(nextHealth);
        setCatalog(nextCatalog);
        setInspections(
          await inspect(nextCatalog.map((item) => item.extension)),
        );
        setError("");
      })
      .catch((requestError) => {
        setError(requestError.message || "无法连接本地 Agent");
      });
  }, [inspect, request]);

  useEffect(() => {
    const timer = window.setInterval(() => refresh(), 4000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  return {
    status,
    configuration,
    health,
    catalog,
    inspections,
    error,
    isRefreshing,
    refresh,
    saveConfiguration,
    openSettings,
  };
}

function PrimaryNav({ activeSection, agentError, agentStatus, onChange }) {
  const healthy = agentStatus?.audit?.healthy === true && !agentError;
  const reachable = Boolean(agentStatus) && !agentError;
  return (
    <aside className="primary-nav" aria-label="主要导航">
      <nav className="primary-nav-list">
        {sections.map((section) => {
          const Icon = section.icon;
          return (
            <button
              aria-current={activeSection === section.id ? "page" : undefined}
              aria-label={section.label}
              className={`nav-item ${activeSection === section.id ? "active" : ""}`}
              key={section.id}
              onClick={() => onChange(section.id)}
              title={section.label}
              type="button"
            >
              <Icon />
              <span>{section.label}</span>
            </button>
          );
        })}
      </nav>
      <div className={`health ${healthy ? "" : "health-warning"}`}>
        <div className="health-title">
          {healthy ? <ShieldCheckmark24Filled /> : <Warning24Regular />}
          <span>
            {healthy
              ? "实时监控正常"
              : reachable
                ? "Agent 运行异常"
                : "Agent 未连接"}
          </span>
        </div>
        <span>
          {healthy
            ? `${agentStatus.audit.healthyCount} 个文件格式正常`
            : reachable
              ? agentStatus.lastError || "请立即复检并查看保护记录"
              : "本地监控服务未运行"}
        </span>
      </div>
    </aside>
  );
}

function AssociationDefaults({
  agentError,
  agentStatus,
  catalog,
  configuration,
  inspections,
  isRefreshing,
  onOpenSettings,
  onRefresh,
  onSaveConfiguration,
}) {
  const [activeCategory, setActiveCategory] = useState("video");
  const [selectedIds, setSelectedIds] = useState(new Set());
  const [focusedExtension, setFocusedExtension] = useState(null);
  const [recaptureIds, setRecaptureIds] = useState(new Set());
  const [isApplying, setIsApplying] = useState(false);
  const [notice, setNotice] = useState(null);

  const protectedRules = configuration?.protectedAssociations ?? [];
  const protectedRuleMap = useMemo(
    () => new Map(
      protectedRules.map((rule) => [rule.extension.toLowerCase(), rule]),
    ),
    [protectedRules],
  );
  const auditItemMap = useMemo(
    () => new Map(
      (agentStatus?.audit?.items ?? []).map((item) => [
        item.extension.toLowerCase(),
        item,
      ]),
    ),
    [agentStatus],
  );
  const inspectionMap = useMemo(
    () => new Map(
      inspections.map((item) => [item.extension.toLowerCase(), item]),
    ),
    [inspections],
  );

  useEffect(() => {
    if (configuration?.protectedAssociations) {
      setSelectedIds(new Set(
        configuration.protectedAssociations.map((rule) => rule.extension),
      ));
    }
  }, [configuration]);

  const categoryEntries = useMemo(
    () => catalog.filter((entry) => entry.category === activeCategory),
    [activeCategory, catalog],
  );

  useEffect(() => {
    if (!categoryEntries.some(
      (entry) => entry.extension === focusedExtension,
    )) {
      setFocusedExtension(categoryEntries[0]?.extension ?? null);
    }
  }, [categoryEntries, focusedExtension]);

  const rows = useMemo(
    () => categoryEntries.map((entry) => {
      const item = auditItemMap.get(entry.extension);
      const inspectionResult = inspectionMap.get(entry.extension);
      const inspection = inspectionResult?.snapshot;
      const isProtected = protectedRuleMap.has(entry.extension);
      const isSelected = selectedIds.has(entry.extension);
      const snapshot = item?.snapshot ?? inspection;
      let state = "not-protected";
      if (isSelected && !isProtected) state = "pending";
      else if (recaptureIds.has(entry.extension)) state = "recapture";
      else if (isProtected && item) state = item.healthy ? "healthy" : "mismatch";
      else if (isProtected) state = "pending";
      return {
        ...entry,
        currentApp:
          normalizeApplicationName(snapshot?.applicationName) ||
          snapshot?.effectiveProgId ||
          (agentError ? "Agent 未连接" : "未读取"),
        item,
        inspection,
        isProtected,
        isSelected,
        state,
      };
    }),
    [
      agentError,
      auditItemMap,
      categoryEntries,
      inspectionMap,
      protectedRuleMap,
      recaptureIds,
      selectedIds,
    ],
  );

  const focusedRow =
    rows.find((row) => row.extension === focusedExtension) ?? rows[0];
  const focusedRule = focusedRow
    ? protectedRuleMap.get(focusedRow.extension)
    : null;
  const focusedExpected = focusedRow?.item?.expected;
  const focusedTargetName =
    [
      focusedExpected?.applicationName,
      focusedRule?.expectedApplicationName,
      focusedRow?.inspection?.applicationName,
    ]
      .map(normalizeApplicationName)
      .find(Boolean) ||
    (activeCategory === "video"
      ? "Microsoft Media Player"
      : "尚未读取");
  const focusedProgId =
    focusedExpected?.progId ||
    focusedRule?.expectedProgId ||
    focusedRow?.inspection?.effectiveProgId ||
    "尚未读取";
  const focusedPackage =
    focusedExpected?.packageId ||
    focusedRule?.expectedPackageId ||
    focusedRow?.inspection?.packageId ||
    "非打包应用或未报告";
  const allSelected =
    rows.length > 0 && rows.every((row) => selectedIds.has(row.extension));

  const toggleRow = (extension) => {
    setNotice(null);
    setFocusedExtension(extension);
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(extension)) {
        next.delete(extension);
        setRecaptureIds((values) => {
          const updated = new Set(values);
          updated.delete(extension);
          return updated;
        });
      } else {
        next.add(extension);
      }
      return next;
    });
  };

  const toggleAll = () => {
    setNotice(null);
    setSelectedIds((current) => {
      const next = new Set(current);
      for (const row of rows) {
        if (allSelected) next.delete(row.extension);
        else next.add(row.extension);
      }
      return next;
    });
    if (allSelected) {
      setRecaptureIds((current) => {
        const next = new Set(current);
        rows.forEach((row) => next.delete(row.extension));
        return next;
      });
    }
  };

  const markRecapture = () => {
    if (!focusedRow || activeCategory === "video") return;
    setRecaptureIds((current) => new Set(current).add(
      focusedRow.extension,
    ));
    setNotice({
      type: "success",
      text: `${focusedRow.extension} 将在保存时更新为当前默认程序。`,
    });
  };

  const applyChanges = async () => {
    if (selectedIds.size === 0) {
      setNotice({ type: "error", text: "请至少选择一种文件格式。" });
      return;
    }
    const captureCurrentExtensions = [...selectedIds].filter((extension) => {
      const entry = catalog.find((item) => item.extension === extension);
      return entry?.category !== "video" &&
        (!protectedRuleMap.has(extension) || recaptureIds.has(extension));
    });

    setIsApplying(true);
    setNotice(null);
    const saved = await onSaveConfiguration({
      protectedExtensions: [...selectedIds],
      captureCurrentExtensions,
    });
    setIsApplying(false);
    if (!saved) {
      setNotice({ type: "error", text: "保护范围保存失败，请检查 Agent。" });
      return;
    }
    setRecaptureIds(new Set());
    setNotice({
      type: "success",
      text: `已保存 ${selectedIds.size} 种文件格式。`,
    });
  };

  return (
    <div className="defaults-page">
      <main className="defaults-workspace">
        <section className="extension-panel" aria-labelledby="association-title">
          <header className="workspace-header">
            <div>
              <h1 id="association-title">文件默认应用</h1>
              <p>
                共 {catalog.length} 个支持格式，当前保护{" "}
                {protectedRules.length} 个
              </p>
            </div>
            <button
              className="secondary-button scan-button"
              disabled={isRefreshing}
              onClick={() => onRefresh(true)}
              type="button"
            >
              <ArrowSync24Regular />
              {isRefreshing ? "正在复检" : "立即复检"}
            </button>
          </header>

          <div className="category-tabs" role="tablist" aria-label="文件类别">
            {categoryOrder.map((category) => (
              <button
                aria-selected={activeCategory === category}
                className={activeCategory === category ? "active" : ""}
                key={category}
                onClick={() => setActiveCategory(category)}
                role="tab"
                type="button"
              >
                {categoryLabels[category]}
              </button>
            ))}
          </div>

          <div className="extension-table" role="table" aria-label="文件格式">
            <div className="extension-header" role="row">
              <label className="check-cell">
                <input
                  aria-label={`选择全部${categoryLabels[activeCategory]}格式`}
                  checked={allSelected}
                  onChange={toggleAll}
                  type="checkbox"
                />
              </label>
              <span role="columnheader">扩展名</span>
              <span role="columnheader">当前打开方式</span>
              <span role="columnheader">状态</span>
            </div>
            <div className="extension-body">
              {rows.map((row) => (
                <div
                  className={`extension-row ${
                    focusedRow?.extension === row.extension ? "focused" : ""
                  }`}
                  key={row.extension}
                  onClick={() => setFocusedExtension(row.extension)}
                  role="row"
                >
                  <label className="check-cell">
                    <input
                      aria-label={`保护 ${row.extension}`}
                      checked={selectedIds.has(row.extension)}
                      onChange={() => toggleRow(row.extension)}
                      type="checkbox"
                    />
                  </label>
                  <strong>{row.extension}</strong>
                  <span>{row.currentApp}</span>
                  {row.state === "mismatch" ? (
                    <span className="row-status warning">
                      <Warning24Regular />
                      已偏移
                    </span>
                  ) : row.state === "healthy" ? (
                    <span className="row-status system">
                      <ShieldCheckmark24Filled />
                      已验证
                    </span>
                  ) : row.state === "recapture" ? (
                    <span className="row-status pending">待更新</span>
                  ) : row.state === "pending" ? (
                    <span className="row-status pending">待记录</span>
                  ) : (
                    <span className="row-status neutral">未保护</span>
                  )}
                </div>
              ))}
            </div>
            <div className="selection-summary">
              <div>
                <CheckmarkCircle24Filled
                  aria-hidden="true"
                  className={selectedIds.size > 0 ? "" : "inactive"}
                />
                <span>已选择 {selectedIds.size} 项</span>
              </div>
              <span>
                本类别 {rows.filter((row) => row.isSelected).length}/
                {rows.length}
              </span>
            </div>
          </div>
        </section>

        <aside className="target-panel" aria-labelledby="target-title">
          <div className="chooser-title">
            <h2 id="target-title">{focusedRow?.extension ?? "保护目标"}</h2>
            <Info24Regular aria-hidden="true" />
          </div>
          <div className="target-card">
            <span className="app-icon app-icon-media" aria-hidden="true">
              {activeCategory === "video" ? (
                <PlayCircle24Filled />
              ) : (
                <Apps24Regular />
              )}
            </span>
            <span className="app-copy">
              <strong>{focusedTargetName}</strong>
              <small>
                {activeCategory === "video"
                  ? "系统媒体播放器策略"
                  : "当前默认程序基线"}
              </small>
            </span>
            <span className={`target-state ${focusedRow ? "" : "pending"}`}>
              {focusedRow?.state === "mismatch" ? "已偏移" : "已识别"}
            </span>
          </div>
          <dl className="target-details">
            <div>
              <dt>ProgID</dt>
              <dd>{focusedProgId}</dd>
            </div>
            <div>
              <dt>Package</dt>
              <dd>{focusedPackage}</dd>
            </div>
          </dl>
          {activeCategory !== "video" &&
            focusedRow?.isProtected &&
            focusedRow?.isSelected && (
              <button
                className="secondary-button baseline-button"
                disabled={recaptureIds.has(focusedRow.extension)}
                onClick={markRecapture}
                type="button"
              >
                <ArrowSync24Regular />
                {recaptureIds.has(focusedRow.extension)
                  ? "等待保存"
                  : "更新为当前默认程序"}
              </button>
            )}
          <p className="target-note">
            {activeCategory === "video"
              ? "视频格式固定核验本机 Microsoft Media Player。"
              : "基线由本机主 COM 查询读取，不接受前端提交。"}
            守护只检测偏移并引导您到 Windows 设置，不会直接改写 Windows 的默认关联。
          </p>
        </aside>

        <footer className="action-bar">
          <div className="mode-field">
            <strong>当前机制</strong>
            <span className="mechanism-badge">实时检测</span>
            <small>RegNotifyChangeKeyValue</small>
          </div>
          <div className="apply-area">
            <button
              className="secondary-button"
              onClick={onOpenSettings}
              type="button"
            >
              <Open24Regular />
              Windows 默认应用
            </button>
            <div>
              <button
                className="primary-button"
                disabled={isApplying || selectedIds.size === 0}
                onClick={applyChanges}
                type="button"
              >
                {isApplying ? "正在保存..." : "保存保护范围"}
              </button>
              <p>{selectedIds.size} 种格式 · {recaptureIds.size} 项待更新</p>
            </div>
          </div>
        </footer>

        {notice && (
          <div className={`toast ${notice.type}`} role="status">
            {notice.type === "success" ? (
              <CheckmarkCircle24Filled />
            ) : (
              <Warning24Regular />
            )}
            <span>{notice.text}</span>
            <button
              aria-label="关闭提示"
              className="icon-button"
              onClick={() => setNotice(null)}
              title="关闭提示"
              type="button"
            >
              <Dismiss24Regular />
            </button>
          </div>
        )}
      </main>
    </div>
  );
}

function StatusPage({
  agentError,
  agentStatus,
  isRefreshing,
  onOpenDefaults,
  onRefresh,
}) {
  const connected = agentStatus?.serviceState === "running" && !agentError;
  const healthy = connected && agentStatus?.audit?.healthy === true;
  const auditedAt = agentStatus?.audit?.auditedAtUtc
    ? new Intl.DateTimeFormat("zh-CN", {
        dateStyle: "medium",
        timeStyle: "medium",
      }).format(new Date(agentStatus.audit.auditedAtUtc))
    : "尚未完成";
  return (
    <main className="simple-page status-page">
      <div className="status-heading">
        <div>
          <span className="eyebrow">DefaultAppGuard Community</span>
          <h1>
            {healthy
              ? "文件默认应用检查正常"
              : connected
                ? "发现需要处理的关联"
                : "本地 Agent 未连接"}
          </h1>
          <p>最近检查：{auditedAt}{agentError ? ` · ${agentError}` : ""}</p>
        </div>
        <span className={`large-status-icon ${healthy ? "" : "warning"}`}>
          {healthy ? <ShieldCheckmark24Filled /> : <Warning24Regular />}
        </span>
      </div>
      <div className="status-list">
        <div>
          <strong>{agentStatus?.audit?.healthyCount ?? 0}</strong>
          <span>已验证格式</span>
        </div>
        <div>
          <strong>{agentStatus?.audit?.driftCount ?? 0}</strong>
          <span>异常格式</span>
        </div>
        <div>
          <strong>{agentStatus?.registryEventCount ?? 0}</strong>
          <span>注册表事件</span>
        </div>
      </div>
      <div className="status-actions">
        <button className="primary-button" onClick={onOpenDefaults} type="button">
          管理默认应用
        </button>
        <button
          className="secondary-button"
          disabled={isRefreshing}
          onClick={() => onRefresh(true)}
          type="button"
        >
          {isRefreshing ? "正在复检" : "立即复检"}
        </button>
      </div>
    </main>
  );
}

function HistoryPage({ agentError, agentStatus }) {
  const hasAudit = Boolean(agentStatus?.audit);
  const time = agentStatus?.updatedAtUtc
    ? new Intl.DateTimeFormat("zh-CN", {
        dateStyle: "short",
        timeStyle: "medium",
      }).format(new Date(agentStatus.updatedAtUtc))
    : "尚无记录";
  return (
    <main className="simple-page">
      <header className="page-heading">
        <h1>保护记录</h1>
        <p>来自本地 Agent 的最近一次真实检查。</p>
      </header>
      <div className="history-list">
        <article>
          <span className={`history-icon ${
            hasAudit && !agentError ? "success" : "neutral"
          }`}>
            {hasAudit && !agentError ? (
              <CheckmarkCircle24Filled />
            ) : (
              <Warning24Regular />
            )}
          </span>
          <div>
            <strong>
              {agentError
                ? "Agent 连接失败"
                : `检查完成：${agentStatus?.lastAuditReason ?? "等待启动"}`}
            </strong>
            <p>
              {hasAudit
                ? `${agentStatus.audit.healthyCount} 个正常，${agentStatus.audit.driftCount} 个异常`
                : "尚未收到审计结果"}
            </p>
          </div>
          <time>{time}</time>
        </article>
      </div>
    </main>
  );
}

function SettingsPage({
  agentHealth,
  agentStatus,
  configuration,
  isRefreshing,
  onSaveConfiguration,
}) {
  const notificationsEnabled =
    configuration?.notificationsEnabled === true;
  const operationalLogSizeMiB = Math.round(
    (agentHealth?.operationalLogFileSizeLimitBytes ?? 0) / (1024 * 1024),
  );
  const operationalLogDescription = !agentHealth
    ? "未连接"
    : !agentHealth.operationalLogChannel
      ? "当前 Agent 版本不支持日志健康检查"
      : agentHealth.operationalLogsAvailable
        ? `${agentHealth.operationalLogFormat} · ${operationalLogSizeMiB} MiB 滚动 · 保留 ${agentHealth.operationalLogRetainedFileCountLimit} 个`
        : "不可用，请运行诊断";

  return (
    <main className="simple-page">
      <header className="page-heading">
        <h1>设置</h1>
        <p>本地 Agent 诊断信息。</p>
      </header>
      <div className="settings-list">
        <label className="setting-row" htmlFor="notification-toggle">
          <span>
            <strong>系统通知</strong>
            <small>
              {notificationsEnabled
                ? agentHealth?.notificationsAvailable === false
                  ? "通知通道不可用"
                  : "默认应用发生偏移时提醒"
                : "已关闭"}
            </small>
          </span>
          <input
            aria-label="系统通知"
            checked={notificationsEnabled}
            className="notification-switch"
            disabled={!configuration || isRefreshing}
            id="notification-toggle"
            onChange={(event) => {
              void onSaveConfiguration({
                notificationsEnabled: event.target.checked,
              });
            }}
            role="switch"
            type="checkbox"
          />
        </label>
        <div className="setting-row">
          <span>
            <strong>关联查询</strong>
            <small>{agentStatus?.queryAlgorithm ?? "未连接"}</small>
          </span>
        </div>
        <div className="setting-row">
          <span>
            <strong>变化监控</strong>
            <small>{agentStatus?.monitorAlgorithm ?? "未连接"}</small>
          </span>
        </div>
        <div className="setting-row">
          <span>
            <strong>本地运行日志</strong>
            <small>{operationalLogDescription}</small>
          </span>
        </div>
      </div>
    </main>
  );
}

function ConfigurationRecoveryNotice({ agentHealth, onReview }) {
  const recoveryNotice = useMemo(
    () => getConfigurationRecoveryNotice(agentHealth),
    [agentHealth],
  );
  const [acknowledgedEvent, setAcknowledgedEvent] = useState(() =>
    readAcknowledgedRecoveryEvent(getRecoveryStorage()),
  );
  if (!recoveryNotice || acknowledgedEvent === recoveryNotice.eventKey) {
    return null;
  }
  const dismiss = () => {
    acknowledgeRecoveryEvent(getRecoveryStorage(), recoveryNotice.eventKey);
    setAcknowledgedEvent(recoveryNotice.eventKey);
  };
  const isWarning = recoveryNotice.severity === "warning";
  return (
    <section
      aria-atomic="true"
      className={`recovery-notice ${recoveryNotice.severity}`}
      role={isWarning ? "alert" : "status"}
    >
      <span className="recovery-notice-icon" aria-hidden="true">
        {isWarning ? <Warning24Regular /> : <Info24Regular />}
      </span>
      <div className="recovery-notice-copy">
        <strong>{recoveryNotice.title}</strong>
        <span>{recoveryNotice.message}</span>
      </div>
      <button
        className="secondary-button recovery-review-button"
        onClick={onReview}
        type="button"
      >
        检查保护范围
      </button>
      <button
        aria-label="关闭配置恢复提示"
        className="icon-button recovery-dismiss-button"
        onClick={dismiss}
        title="关闭提示"
        type="button"
      >
        <Dismiss24Regular />
      </button>
    </section>
  );
}

export function App() {
  const [activeSection, setActiveSection] = useState("defaults");
  const {
    status: agentStatus,
    configuration,
    health: agentHealth,
    catalog,
    inspections,
    error: agentError,
    isRefreshing,
    refresh,
    saveConfiguration,
    openSettings,
  } = useAgentStatus();
  const reachable = Boolean(agentStatus) && !agentError;
  const agentRunning = agentStatus?.serviceState === "running" && reachable;
  const agentLabel = !reachable
    ? "Agent 未连接"
    : agentRunning
      ? "Agent 已连接"
      : "Agent 运行异常";

  let content;
  if (activeSection === "status") {
    content = (
      <StatusPage
        agentError={agentError}
        agentStatus={agentStatus}
        isRefreshing={isRefreshing}
        onOpenDefaults={() => setActiveSection("defaults")}
        onRefresh={refresh}
      />
    );
  } else if (activeSection === "history") {
    content = <HistoryPage agentError={agentError} agentStatus={agentStatus} />;
  } else if (activeSection === "settings") {
    content = (
      <SettingsPage
        agentHealth={agentHealth}
        agentStatus={agentStatus}
        configuration={configuration}
        isRefreshing={isRefreshing}
        onSaveConfiguration={saveConfiguration}
      />
    );
  } else {
    content = (
      <AssociationDefaults
        agentError={agentError}
        agentStatus={agentStatus}
        catalog={catalog}
        configuration={configuration}
        inspections={inspections}
        isRefreshing={isRefreshing}
        onOpenSettings={openSettings}
        onRefresh={refresh}
        onSaveConfiguration={saveConfiguration}
      />
    );
  }

  return (
    <div className="app-shell">
      <header className="window-bar">
        <div className="window-title">
          <span className="brand-mark">
            <ShieldCheckmark24Filled />
          </span>
          <span>DefaultAppGuard</span>
        </div>
        <div className={`topbar-status ${agentRunning ? "" : "warning"}`}>
          <span aria-hidden="true" />
          {agentLabel}
        </div>
      </header>
      <div className="app-frame">
        <PrimaryNav
          activeSection={activeSection}
          agentError={agentError}
          agentStatus={agentStatus}
          onChange={setActiveSection}
        />
        <div className="content-frame">
          <ConfigurationRecoveryNotice
            agentHealth={agentHealth}
            onReview={() => setActiveSection("defaults")}
          />
          <div className="content-body">{content}</div>
        </div>
      </div>
    </div>
  );
}
