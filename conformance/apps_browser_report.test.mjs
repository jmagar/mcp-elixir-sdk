import test from "node:test";
import assert from "node:assert/strict";
import { buildBrowserReport } from "./apps_browser_report.mjs";

test("browser report records console and network failures", () => {
  const report = buildBrowserReport(
    { evidence: { viewRendered: true } },
    [{ type: "pageerror", text: "boom" }],
    [{ url: "https://example.invalid", error: "blocked" }]
  );
  assert.equal(report.status, "failed");
  assert.deepEqual(report.failures, [
    "browser console errors were captured",
    "browser network errors were captured"
  ]);
  assert.equal(report.evidence.viewRendered, true);
});

test("browser report records a clean pass", () => {
  const report = buildBrowserReport({}, [{ type: "log", text: "ready" }], []);
  assert.equal(report.status, "passed");
  assert.deepEqual(report.failures, []);
});
