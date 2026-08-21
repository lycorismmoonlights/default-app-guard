import { createServer } from "node:http";

const port = Number(process.env.MOCK_AGENT_PORT || 51973);
const catalog = [
  ["video", ".mp4"], ["video", ".mkv"], ["video", ".avi"],
  ["audio", ".mp3"], ["audio", ".flac"], ["audio", ".wav"],
  ["document", ".pdf"], ["document", ".txt"], ["document", ".docx"],
  ["image", ".jpg"], ["image", ".png"], ["image", ".webp"],
  ["archive", ".zip"], ["archive", ".7z"], ["archive", ".rar"],
  ["web-data", ".html"], ["web-data", ".json"], ["web-data", ".xml"],
].map(([category, extension]) => ({
  category,
  extension,
  label: extension.slice(1).toUpperCase(),
}));

const apps = {
  video: ["Media.Player.Mock", "Microsoft Media Player", "Microsoft.ZuneMusic_mock"],
  audio: ["Audio.Player.Mock", "Windows Media Player", null],
  document: ["Document.Reader.Mock", "Microsoft 365", null],
  image: ["Image.Viewer.Mock", "Microsoft Photos", "Microsoft.Windows.Photos_mock"],
  archive: ["Archive.Manager.Mock", "File Explorer", null],
  "web-data": ["Browser.Mock", "Microsoft Edge", "Microsoft.MicrosoftEdge_mock"],
};

let configuration = {
  schemaVersion: 3,
  protectionMode: "monitor",
  notificationsEnabled: true,
  protectedAssociations: catalog
    .filter((entry) => entry.category === "video" || [".pdf", ".jpg"].includes(entry.extension))
    .map((entry) => rule(entry)),
};

function rule(entry) {
  const [progId, appName, packageId] = apps[entry.category];
  const video = entry.category === "video";
  return {
    extension: entry.extension,
    category: entry.category,
    targetStrategy: video ? "system-media-player" : "captured-current",
    expectedProgId: video ? null : progId,
    expectedPackageId: video ? null : packageId,
    expectedApplicationName: appName,
    capturedAtUtc: video ? null : "2026-08-21T08:00:00Z",
  };
}

function snapshot(entry) {
  const [progId, appName, packageId] = apps[entry.category];
  return {
    extension: entry.extension,
    effectiveProgId: entry.extension === ".pdf" ? "Quark.Pdf.Mock" : progId,
    userChoiceProgId: entry.extension === ".pdf" ? "Quark.Pdf.Mock" : progId,
    userChoiceHashPresent: true,
    applicationName: entry.extension === ".pdf" ? "夸克" : appName,
    packageId,
    querySource: "IApplicationAssociationRegistration.QueryCurrentDefault",
    registryEvidenceMatches: true,
  };
}

function expected(ruleValue) {
  const entry = catalog.find((item) => item.extension === ruleValue.extension);
  const [progId, appName, packageId] = apps[entry.category];
  return {
    extension: entry.extension,
    category: entry.category,
    targetStrategy: ruleValue.targetStrategy,
    progId: ruleValue.expectedProgId || progId,
    packageId: ruleValue.expectedPackageId || packageId,
    applicationName: ruleValue.expectedApplicationName || appName,
  };
}

function status() {
  const items = configuration.protectedAssociations.map((ruleValue) => {
    const entry = catalog.find((item) => item.extension === ruleValue.extension);
    const current = snapshot(entry);
    const target = expected(ruleValue);
    const healthy = current.effectiveProgId === target.progId;
    return {
      extension: entry.extension,
      expected: target,
      healthy,
      snapshot: current,
      error: healthy ? null : "The effective handler does not match the protected baseline.",
    };
  });
  return {
    serviceState: "running",
    monitorAlgorithm: "RegNotifyChangeKeyValue",
    queryAlgorithm: "IApplicationAssociationRegistration.QueryCurrentDefault",
    registryEventCount: 7,
    lastAuditReason: "mock-visual-test",
    audit: {
      expectedHandlers: items.map((item) => item.expected),
      items,
      auditedAtUtc: "2026-08-21T08:30:00Z",
      healthy: items.every((item) => item.healthy),
      healthyCount: items.filter((item) => item.healthy).length,
      driftCount: items.filter((item) => !item.healthy).length,
    },
    lastError: null,
    updatedAtUtc: "2026-08-21T08:30:00Z",
  };
}

function send(response, code, value) {
  response.writeHead(code, {
    "Access-Control-Allow-Headers": "Content-Type,X-DefaultAppGuard-Client",
    "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS",
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json; charset=utf-8",
  });
  response.end(JSON.stringify(value));
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

const server = createServer(async (request, response) => {
  if (request.method === "OPTIONS") return send(response, 204, {});
  if (request.url === "/api/status" || request.url === "/api/audit") {
    return send(response, 200, status());
  }
  if (request.url === "/api/config" && request.method === "GET") {
    return send(response, 200, configuration);
  }
  if (request.url === "/api/config" && request.method === "PUT") {
    const update = await readJson(request);
    if (Array.isArray(update.protectedExtensions)) {
      configuration = {
        ...configuration,
        notificationsEnabled:
          update.notificationsEnabled ?? configuration.notificationsEnabled,
        protectedAssociations: update.protectedExtensions.map((extension) => {
          const entry = catalog.find((item) => item.extension === extension);
          const nextRule = rule(entry);
          if (entry.category !== "video" &&
              update.captureCurrentExtensions?.includes(extension)) {
            const current = snapshot(entry);
            return {
              ...nextRule,
              expectedProgId: current.effectiveProgId,
              expectedPackageId: current.packageId,
              expectedApplicationName: current.applicationName,
              capturedAtUtc: new Date().toISOString(),
            };
          }
          const existing = configuration.protectedAssociations.find(
            (item) => item.extension === extension,
          );
          return existing || nextRule;
        }),
      };
    } else if (typeof update.notificationsEnabled === "boolean") {
      configuration = {
        ...configuration,
        notificationsEnabled: update.notificationsEnabled,
      };
    }
    return send(response, 200, {
      configuration,
      status: status(),
    });
  }
  if (request.url === "/api/association-catalog") {
    return send(response, 200, catalog);
  }
  if (request.url === "/api/associations/inspect") {
    const body = await readJson(request);
    return send(response, 200, body.extensions.map((extension) => {
      const entry = catalog.find((item) => item.extension === extension);
      return {
        extension,
        snapshot: snapshot(entry),
        error: null,
      };
    }));
  }
  if (request.url === "/api/health") {
    return send(response, 200, {
      service: "DefaultAppGuard.Agent",
      version: "0.2.0.0",
      monitor: "RegNotifyChangeKeyValue",
      query: "IApplicationAssociationRegistration.QueryCurrentDefault",
      processMode: "background-no-console",
      notificationsAvailable: true,
      notificationsEnabled: configuration.notificationsEnabled,
      operationalLogChannel: "Serilog.Sinks.File",
      operationalLogsAvailable: true,
      operationalLogFormat: "CLEF",
      operationalLogFileSizeLimitBytes: 2097152,
      operationalLogRetainedFileCountLimit: 7,
      configurationRecovered: false,
      configurationRecoveryCode: "none",
    });
  }
  if (request.url === "/api/open-settings") {
    return send(response, 200, { opened: true });
  }
  return send(response, 404, { error: "Not found" });
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`Mock Agent listening on http://127.0.0.1:${port}\n`);
});
