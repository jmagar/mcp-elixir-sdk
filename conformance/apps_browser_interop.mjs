import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";

const require = createRequire(new URL("./browser/package.json", import.meta.url));
const { chromium } = require("playwright");

const outputDir = process.env.MCP_APPS_INTEROP_OUTPUT;
const token = process.env.MCP_INSPECTOR_API_TOKEN;
const serverUrl = process.env.MCP_APPS_SERVER_URL;
const hostVersion = process.env.MCP_APPS_HOST_VERSION;
const appInfoPath = process.env.MCP_APPS_APP_INFO;
const eventsPath = process.env.MCP_APPS_INTEROP_EVENTS;

if (!outputDir || !token || !serverUrl || !hostVersion || !appInfoPath || !eventsPath) {
  throw new Error("missing required MCP Apps interoperability environment");
}

fs.mkdirSync(outputDir, { recursive: true });
const consoleEvents = [];
const networkErrors = [];
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();

page.on("console", message => {
  consoleEvents.push({ type: message.type(), text: message.text() });
});
page.on("pageerror", error => {
  consoleEvents.push({ type: "pageerror", text: error.message });
});
page.on("requestfailed", request => {
  networkErrors.push({ url: request.url(), error: request.failure()?.errorText ?? "unknown" });
});
page.on("response", response => {
  if (response.status() >= 400) networkErrors.push({ url: response.url(), status: response.status() });
});

const args = Buffer.from("{}")
  .toString("base64")
  .replace(/\+/g, "-")
  .replace(/\//g, "_")
  .replace(/=+$/, "");
const url =
  `http://127.0.0.1:6274/?serverUrl=${encodeURIComponent(serverUrl)}` +
  `&transport=http&autoConnect=${token}` +
  `&openApp=apps_interop_view&appArgs=${args}&autoOpen=${token}`;

try {
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
  await page.waitForSelector(
    '[data-testid="connection-status"][data-status="connected"]',
    { timeout: 30_000 }
  );
  await page.waitForSelector('[data-testid="apps-form"][data-app-status="ready"]', {
    timeout: 30_000
  });
  await page.locator('[data-testid="apps-form"]').screenshot({
    path: path.join(outputDir, "apps-view.png")
  });
  await page.screenshot({ path: path.join(outputDir, "inspector-page.png"), fullPage: true });

  const deadline = Date.now() + 15_000;
  let events = "";
  while (Date.now() < deadline) {
    events = fs.existsSync(eventsPath) ? fs.readFileSync(eventsPath, "utf8") : "";
    if (events.includes("resources_read") && events.includes("same_server_callback")) break;
    await page.waitForTimeout(100);
  }

  if (!events.includes("resources_read")) throw new Error("host did not perform resources/read");
  if (!events.includes("same_server_callback")) throw new Error("view callback was not proxied");

  const appInfo = JSON.parse(fs.readFileSync(appInfoPath, "utf8"));
  const report = {
    host: { name: "@modelcontextprotocol/inspector", version: hostVersion },
    auth: { enabled: true, mode: "per-launch random token", cleanProfile: true },
    policyConfirmation: {
      hasApp: appInfo.hasApp,
      resourceUri: appInfo.resourceUri,
      csp: appInfo.csp,
      permissions: appInfo.permissions
    },
    evidence: {
      resourcesRead: true,
      viewRendered: true,
      sameServerCallback: true,
      screenshots: ["apps-view.png", "inspector-page.png"]
    },
    console: consoleEvents,
    networkErrors
  };
  fs.writeFileSync(path.join(outputDir, "report.json"), JSON.stringify(report, null, 2));

  if (consoleEvents.some(event => event.type === "error" || event.type === "pageerror")) {
    throw new Error("browser console errors were captured; inspect report.json");
  }
  if (networkErrors.length > 0) throw new Error("browser network errors were captured");
} finally {
  await browser.close();
}
