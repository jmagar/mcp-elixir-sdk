export function browserFailures(consoleEvents, networkErrors) {
  const failures = [];
  if (consoleEvents.some(event => event.type === "error" || event.type === "pageerror")) {
    failures.push("browser console errors were captured");
  }
  if (networkErrors.length > 0) failures.push("browser network errors were captured");
  return failures;
}

export function buildBrowserReport(base, consoleEvents, networkErrors) {
  const failures = browserFailures(consoleEvents, networkErrors);
  return {
    ...base,
    status: failures.length === 0 ? "passed" : "failed",
    failures,
    console: consoleEvents,
    networkErrors
  };
}
