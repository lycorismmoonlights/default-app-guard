import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Apps24Regular,
  ArrowSync24Regular,
  CheckmarkCircle24Filled,
  Dismiss24Regular,
  History24Regular,
  Info24Regular,
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

const videoExtensions = [
  ".mp4",
  ".mkv",
  ".avi",
  ".mov",
  ".wmv",
  ".webm",
  ".mpeg",
  ".ts",
  ".3g2",
  ".3gp",
  ".3gp2",
  ".3gpp",
  ".asf",
  ".divx",
  ".m1v",
  ".m2t",
  ".m2ts",
  ".m2v",
  ".m4v",
  ".mod",
  ".mp2v",
  ".mp4v",
  ".mpe",
  ".mpg",
  ".mpg4",
  ".mpv2",
  ".mts",
  ".ogm",
  ".ogv",
  ".ogx",
  ".tod",
  ".tts",
  ".wm",
  ".xvid",
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

  const refresh = useCallback(async (manual = false) => {
    setIsRefreshing(true);
    try {
      const [nextStatus, nextHealth] = await Promise.all([
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
      ]);
      setStatus(nextStatus);
      setHealth(nextHealth);
      setError("");
    } catch (requestError) {
      setError(requestError.message || "无法连接本地 Agent");
    } finally {
      setIsRefreshing(false);
    }
  }, [request]);

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
    ])
      .then(([nextStatus, nextConfiguration, nextHealth]) => {
        setStatus(nextStatus);
        setConfiguration(nextConfiguration);
        setHealth(nextHealth);
        setError("");
      })
      .catch((requestError) => {
        setError(requestError.message || "无法连接本地 Agent");
      });
    const timer = window.setInterval(() => refresh(), 4000);
    return () => window.clearInterval(timer);
  }, [refresh, request]);

  return {
    status,
    configuration,
    health,
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
              aria-label={section.label}
              aria-current={activeSection === section.id ? "page" : undefined}
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
            ? `${agentStatus.audit.healthyCount} 个视频格式正常`
            : reachable
              ? agentStatus.lastError || "请立即复检并查看保护记录"
              : "本地监控服务未运行"}
        </span>
      </div>
    </aside>
  );
}

function VideoDefaults({
  agentError,
  agentStatus,
  configuration,
  isRefreshing,
  onOpenSettings,
  onRefresh,
  onSaveConfiguration,
}) {
  const [selectedIds, setSelectedIds] = useState(
    () => new Set(videoExtensions),
  );
  const [isApplying, setIsApplying] = useState(false);
  const [notice, setNotice] = useState(null);

  useEffect(() => {
    if (configuration?.protectedVideoExtensions) {
      setSelectedIds(new Set(configuration.protectedVideoExtensions));
    }
  }, [configuration]);

  const rows = useMemo(() => {
    const auditItems = new Map(
      (agentStatus?.audit?.items ?? []).map((item) => [
        item.extension.toLowerCase(),
        item,
      ]),
    );
    return videoExtensions.map((extension) => {
      const item = auditItems.get(extension);
      const snapshot = item?.snapshot;
      return {
        id: extension,
        extension,
        currentApp: item?.healthy
          ? "媒体播放器"
          : snapshot?.applicationName ||
            snapshot?.effectiveProgId ||
            (agentError ? "Agent 未连接" : "未读取"),
        status: item
          ? item.healthy
            ? "healthy"
            : "mismatch"
          : "not-monitored",
      };
    });
  }, [agentError, agentStatus]);

  const allSelected = selectedIds.size === videoExtensions.length;
  const target = agentStatus?.audit?.target;
  const targetName =
    target?.applicationName &&
    !target.applicationName.startsWith("@{") &&
    !target.applicationName.includes("ms-resource:")
      ? target.applicationName
      : "Microsoft Media Player";

  const toggleRow = (id) => {
    setNotice(null);
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const toggleAll = () => {
    setNotice(null);
    setSelectedIds(
      allSelected ? new Set() : new Set(videoExtensions),
    );
  };

  const applyChanges = async () => {
    if (selectedIds.size === 0) {
      setNotice({ type: "error", text: "请至少选择一种视频格式。" });
      return;
    }

    setIsApplying(true);
    setNotice(null);
    const saved = await onSaveConfiguration({
      protectedVideoExtensions: [...selectedIds],
    });
    if (!saved) {
      setIsApplying(false);
      setNotice({ type: "error", text: "监控范围保存失败，请检查 Agent。" });
      return;
    }

    const opened = await onOpenSettings();
    setIsApplying(false);
    setNotice(
      opened
        ? {
            type: "success",
            text: `已保存 ${selectedIds.size} 种格式，并打开 Windows 默认应用设置。`,
          }
        : {
            type: "error",
            text: "监控范围已保存，但 Windows 设置未能打开。",
          },
    );
  };

  return (
    <div className="defaults-page">
      <main className="defaults-workspace">
        <section className="extension-panel" aria-labelledby="video-title">
          <header className="workspace-header">
            <div>
              <h1 id="video-title">视频默认应用</h1>
              <p>
                共 34 个已声明格式，当前监控{" "}
                {configuration?.protectedVideoExtensions?.length ?? 0} 个
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

          <div className="extension-table" role="table" aria-label="视频文件格式">
            <div className="extension-header" role="row">
              <label className="check-cell">
                <input
                  aria-label="选择全部视频格式"
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
                <div className="extension-row" role="row" key={row.id}>
                  <label className="check-cell">
                    <input
                      aria-label={`选择 ${row.extension}`}
                      checked={selectedIds.has(row.id)}
                      onChange={() => toggleRow(row.id)}
                      type="checkbox"
                    />
                  </label>
                  <strong>{row.extension}</strong>
                  <span>{row.currentApp}</span>
                  {row.status === "mismatch" ? (
                    <span className="row-status warning">
                      <Warning24Regular />
                      与建议不符
                    </span>
                  ) : row.status === "healthy" ? (
                    <span className="row-status system">
                      <ShieldCheckmark24Filled />
                      已验证
                    </span>
                  ) : (
                    <span className="row-status neutral">未监控</span>
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
                <span>
                  已选择 {selectedIds.size} 项（共 {videoExtensions.length} 项）
                </span>
              </div>
              <button
                className="text-button"
                onClick={() => setSelectedIds(new Set())}
                type="button"
              >
                全不选
              </button>
            </div>
          </div>
        </section>

        <aside className="target-panel" aria-labelledby="target-title">
          <div className="chooser-title">
            <h2 id="target-title">保护目标</h2>
            <Info24Regular aria-hidden="true" />
          </div>

          <div className="target-card">
            <span className="app-icon app-icon-media" aria-hidden="true">
              <PlayCircle24Filled />
            </span>
            <span className="app-copy">
              <strong>{targetName}</strong>
              <small>本机动态解析的系统应用</small>
            </span>
            <span className={`target-state ${target ? "" : "pending"}`}>
              {target ? "已识别" : "等待 Agent"}
            </span>
          </div>

          <dl className="target-details">
            <div>
              <dt>ProgID</dt>
              <dd>{target?.progId || "尚未读取"}</dd>
            </div>
            <div>
              <dt>Package</dt>
              <dd>{target?.packageId || "尚未读取"}</dd>
            </div>
          </dl>

          <p className="target-note">
            应用只核验并监控该目标，不会直接改写 Windows 的默认关联。
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
              className="text-button"
              onClick={() => setSelectedIds(new Set())}
              type="button"
            >
              取消选择
            </button>
            <div>
              <button
                className="primary-button"
                disabled={isApplying || selectedIds.size === 0}
                onClick={applyChanges}
                type="button"
              >
                {isApplying ? "正在处理..." : "保存范围并打开设置"}
              </button>
              <p>
                目标：{targetName} · {selectedIds.size} 种格式
              </p>
            </div>
          </div>
        </footer>

        {notice && (
          <div
            className={`toast ${notice.type}`}
            role="status"
          >
            {notice.type === "success" ? (
              <CheckmarkCircle24Filled />
            ) : (
              <Warning24Regular />
            )}
            <span>{notice.text}</span>
            <button
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

function DefaultsPage({
  agentError,
  agentStatus,
  configuration,
  isRefreshing,
  onOpenSettings,
  onRefresh,
  onSaveConfiguration,
}) {
  return (
    <VideoDefaults
      agentError={agentError}
      agentStatus={agentStatus}
      configuration={configuration}
      isRefreshing={isRefreshing}
      onOpenSettings={onOpenSettings}
      onRefresh={onRefresh}
      onSaveConfiguration={onSaveConfiguration}
    />
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
              ? "视频默认应用检查正常"
              : connected
                ? "发现需要处理的关联"
                : "本地 Agent 未连接"}
          </h1>
          <p>
            最近检查：{auditedAt}
            {agentError ? ` · ${agentError}` : ""}
          </p>
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
        <button
          className="primary-button"
          onClick={onOpenDefaults}
          type="button"
        >
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
          <span
            className={`history-icon ${
              hasAudit && !agentError ? "success" : "neutral"
            }`}
          >
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

  const setNotificationsEnabled = async (enabled) => {
    await onSaveConfiguration({ notificationsEnabled: enabled });
  };

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
              void setNotificationsEnabled(event.target.checked);
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

  const content = useMemo(() => {
    if (activeSection === "status") {
      return (
        <StatusPage
          agentError={agentError}
          agentStatus={agentStatus}
          isRefreshing={isRefreshing}
          onOpenDefaults={() => setActiveSection("defaults")}
          onRefresh={refresh}
        />
      );
    }
    if (activeSection === "history") {
      return (
        <HistoryPage agentError={agentError} agentStatus={agentStatus} />
      );
    }
    if (activeSection === "settings") {
      return (
        <SettingsPage
          agentHealth={agentHealth}
          agentStatus={agentStatus}
          configuration={configuration}
          isRefreshing={isRefreshing}
          onSaveConfiguration={saveConfiguration}
        />
      );
    }
    return (
      <DefaultsPage
        agentError={agentError}
        agentStatus={agentStatus}
        configuration={configuration}
        isRefreshing={isRefreshing}
        onOpenSettings={openSettings}
        onRefresh={refresh}
        onSaveConfiguration={saveConfiguration}
      />
    );
  }, [
    activeSection,
    agentError,
    agentHealth,
    agentStatus,
    configuration,
    isRefreshing,
    openSettings,
    refresh,
    saveConfiguration,
  ]);

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
