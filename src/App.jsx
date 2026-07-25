import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Apps24Regular,
  Archive24Regular,
  ArrowSync24Regular,
  CheckmarkCircle24Filled,
  Dismiss24Regular,
  Document24Regular,
  Globe24Regular,
  History24Regular,
  Image24Regular,
  Info24Regular,
  MoviesAndTv24Regular,
  MusicNote224Regular,
  PlayCircle24Filled,
  Settings24Regular,
  Shield24Regular,
  ShieldCheckmark24Filled,
  Video24Regular,
  Warning24Regular,
  WindowApps24Regular,
} from "@fluentui/react-icons";

const sections = [
  { id: "status", label: "状态", icon: Shield24Regular },
  { id: "defaults", label: "默认应用", icon: Apps24Regular },
  { id: "history", label: "保护记录", icon: History24Regular },
  { id: "backup", label: "备份与恢复", icon: ArrowSync24Regular },
  { id: "settings", label: "设置", icon: Settings24Regular },
];

const categories = [
  { id: "browser", label: "浏览器", count: 4, icon: Globe24Regular },
  { id: "document", label: "文档", count: 15, icon: Document24Regular },
  { id: "image", label: "图片", count: 8, icon: Image24Regular },
  { id: "audio", label: "音频", count: 22, icon: MusicNote224Regular },
  { id: "video", label: "视频", count: 34, icon: Video24Regular },
  { id: "archive", label: "压缩文件", count: 9, icon: Archive24Regular },
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

const appChoices = [
  {
    id: "media-player",
    name: "媒体播放器",
    publisher: "Microsoft Corporation",
    note: "系统应用",
    icon: PlayCircle24Filled,
    color: "media",
  },
  {
    id: "movies-tv",
    name: "电影和电视",
    publisher: "Microsoft Corporation",
    note: "",
    icon: MoviesAndTv24Regular,
    color: "movies",
    disabled: true,
  },
  {
    id: "vlc",
    name: "VLC media player",
    publisher: "VideoLAN",
    note: "",
    icon: WindowApps24Regular,
    color: "vlc",
    disabled: true,
  },
  {
    id: "quark",
    name: "夸克",
    publisher: "Quark Technology Co. Ltd.",
    note: "",
    icon: Globe24Regular,
    color: "quark",
    disabled: true,
  },
];

const agentBaseUrl =
  import.meta.env.VITE_AGENT_BASE_URL ||
  (import.meta.env.DEV
    ? "http://127.0.0.1:51873"
    : window.location.origin);

function useAgentStatus() {
  const [status, setStatus] = useState(null);
  const [configuration, setConfiguration] = useState(null);
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
      const nextStatus = await request(
        `/api/${manual ? "audit" : "status"}`,
        manual
          ? {
              method: "POST",
              headers: { "X-DefaultAppGuard-Client": "local-ui" },
            }
          : undefined,
      );
      setStatus(nextStatus);
      setError("");
    } catch (requestError) {
      setError(requestError.message || "无法连接本地 Agent");
    } finally {
      setIsRefreshing(false);
    }
  }, [request]);

  const saveConfiguration = useCallback(
    async (extensions) => {
      setIsRefreshing(true);
      try {
        const result = await request("/api/config", {
          method: "PUT",
          headers: {
            "Content-Type": "application/json",
            "X-DefaultAppGuard-Client": "local-ui",
          },
          body: JSON.stringify({ protectedVideoExtensions: extensions }),
        });
        setConfiguration(result.configuration);
        setStatus(result.status);
        setError("");
        return true;
      } catch (requestError) {
        setError(requestError.message || "无法保存保护范围");
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
    ])
      .then(([nextStatus, nextConfiguration]) => {
        setStatus(nextStatus);
        setConfiguration(nextConfiguration);
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
    error,
    isRefreshing,
    refresh,
    saveConfiguration,
    openSettings,
  };
}

function AppIcon({ app }) {
  const Icon = app.icon;
  return (
    <span className={`app-icon app-icon-${app.color}`} aria-hidden="true">
      <Icon />
    </span>
  );
}

function PrimaryNav({ activeSection, agentError, agentStatus, onChange }) {
  const healthy = agentStatus?.audit?.healthy === true && !agentError;
  const connected = agentStatus?.serviceState === "running" && !agentError;
  return (
    <aside className="primary-nav" aria-label="主要导航">
      <nav className="primary-nav-list">
        {sections.map((section) => {
          const Icon = section.icon;
          return (
            <button
              aria-current={activeSection === section.id ? "page" : undefined}
              className={`nav-item ${activeSection === section.id ? "active" : ""}`}
              key={section.id}
              onClick={() => onChange(section.id)}
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
              : connected
                ? "发现关联变化"
                : "Agent 未连接"}
          </span>
        </div>
        <span>
          {healthy
            ? `${agentStatus.audit.healthyCount} 个视频格式正常`
            : connected
              ? `${agentStatus.audit?.driftCount ?? 0} 个格式需要检查`
              : "本地监控服务未运行"}
        </span>
      </div>
    </aside>
  );
}

function CategoryNav({ activeCategory, onChange }) {
  return (
    <aside className="category-nav" aria-label="默认应用类别">
      {categories.map((category) => {
        const Icon = category.icon;
        return (
          <button
            aria-pressed={activeCategory === category.id}
            className={`category-item ${activeCategory === category.id ? "active" : ""}`}
            key={category.id}
            onClick={() => onChange(category.id)}
            type="button"
          >
            <Icon />
            <span>{category.label}</span>
          </button>
        );
      })}
    </aside>
  );
}

function VideoDefaults({
  activeCategory,
  agentError,
  agentStatus,
  configuration,
  isRefreshing,
  onCategoryChange,
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
    const saved = await onSaveConfiguration([...selectedIds]);
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
      <CategoryNav
        activeCategory={activeCategory}
        onChange={onCategoryChange}
      />

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
                <input checked={selectedIds.size > 0} readOnly type="checkbox" />
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

        <aside className="app-chooser" aria-labelledby="chooser-title">
          <div className="chooser-title">
            <h2 id="chooser-title">选择打开方式</h2>
            <button
              className="icon-button"
              title="只显示支持所选格式的已安装应用"
              type="button"
            >
              <Info24Regular />
            </button>
          </div>

          <div className="app-list">
            {appChoices.map((app) => (
              <label
                className={`app-choice ${
                  app.id === "media-player" ? "selected" : ""
                } ${app.disabled ? "disabled" : ""}`}
                key={app.id}
              >
                <input
                  checked={app.id === "media-player"}
                  disabled={app.disabled}
                  name="application"
                  onChange={() => setNotice(null)}
                  type="radio"
                />
                <AppIcon app={app} />
                <span className="app-copy">
                  <strong>{app.name}</strong>
                  <small>{app.publisher}</small>
                </span>
                {app.note && <span className="app-note">{app.note}</span>}
              </label>
            ))}
          </div>
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
                目标：媒体播放器 · {selectedIds.size} 种格式
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
  const [activeCategory, setActiveCategory] = useState("video");

  if (activeCategory === "video") {
    return (
      <VideoDefaults
        activeCategory={activeCategory}
        agentError={agentError}
        agentStatus={agentStatus}
        configuration={configuration}
        isRefreshing={isRefreshing}
        onCategoryChange={setActiveCategory}
        onOpenSettings={onOpenSettings}
        onRefresh={onRefresh}
        onSaveConfiguration={onSaveConfiguration}
      />
    );
  }

  const category = categories.find((item) => item.id === activeCategory);
  const Icon = category.icon;
  return (
    <div className="defaults-page">
      <CategoryNav
        activeCategory={activeCategory}
        onChange={setActiveCategory}
      />
      <main className="simple-page">
        <div className="simple-page-heading">
          <span className="simple-page-icon">
            <Icon />
          </span>
          <div>
            <h1>{category.label}默认应用</h1>
            <p>此类别中有 {category.count} 个可保护的关联。</p>
          </div>
        </div>
        <div className="empty-state">
          <h2>选择一个格式开始配置</h2>
          <p>应用会只显示本机已经安装并且明确支持该格式的程序。</p>
          <button
            className="secondary-button"
            onClick={() => setActiveCategory("video")}
            type="button"
          >
            查看视频配置示例
          </button>
        </div>
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

function BackupPage() {
  return (
    <main className="simple-page">
      <header className="page-heading">
        <h1>备份与恢复</h1>
        <p>当前没有可恢复的系统关联快照。</p>
      </header>
      <div className="backup-row">
        <div>
          <strong>监控范围配置</strong>
          <p>Agent 会原子化保存已选择的视频格式。</p>
        </div>
        <button className="secondary-button" disabled type="button">
          暂无快照
        </button>
      </div>
    </main>
  );
}

function SettingsPage({ agentStatus }) {
  return (
    <main className="simple-page">
      <header className="page-heading">
        <h1>设置</h1>
        <p>本地 Agent 诊断信息。</p>
      </header>
      <div className="settings-list">
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
      </div>
    </main>
  );
}

export function App() {
  const [activeSection, setActiveSection] = useState("defaults");
  const {
    status: agentStatus,
    configuration,
    error: agentError,
    isRefreshing,
    refresh,
    saveConfiguration,
    openSettings,
  } = useAgentStatus();

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
    if (activeSection === "backup") return <BackupPage />;
    if (activeSection === "settings") {
      return <SettingsPage agentStatus={agentStatus} />;
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
        <div className="window-actions" aria-label="窗口操作">
          <button aria-label="最小化" title="最小化" type="button">
            <span className="minimize-line" />
          </button>
          <button aria-label="最大化" title="最大化" type="button">
            <span className="maximize-box" />
          </button>
          <button aria-label="关闭" title="关闭" type="button">
            <Dismiss24Regular />
          </button>
        </div>
      </header>
      <div className="app-frame">
        <PrimaryNav
          activeSection={activeSection}
          agentError={agentError}
          agentStatus={agentStatus}
          onChange={setActiveSection}
        />
        <div className="content-frame">{content}</div>
      </div>
    </div>
  );
}
