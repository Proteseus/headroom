// Small adapter around the maintained OpenCode Quota dashboard parser.
// Headroom owns the process boundary and JSON contract; the installed helper
// package owns authentication lookup and the changing dashboard HTML.
const configUrl = new URL(
  "../tools/node_modules/@slkiser/opencode-quota/dist/lib/opencode-go-config.js",
  import.meta.url,
);
const scraperUrl = new URL(
  "../tools/node_modules/@slkiser/opencode-quota/dist/lib/opencode-go.js",
  import.meta.url,
);

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function configError(config) {
  if (config.state === "incomplete") {
    return `OpenCode Go config is missing ${config.missing}`;
  }
  if (config.state === "invalid") {
    return `Invalid OpenCode Go config: ${config.error}`;
  }
  return "Configure OpenCode Go workspaceId and authCookie";
}

try {
  const { resolveOpenCodeGoConfig } = await import(configUrl);
  const { queryOpenCodeGoQuota } = await import(scraperUrl);
  const config = await resolveOpenCodeGoConfig();
  if (config.state !== "configured") {
    emit({ entries: [], error: configError(config) });
    process.exit(0);
  }

  const result = await queryOpenCodeGoQuota(
    config.config.workspaceId,
    config.config.authCookie,
    { requestTimeoutMs: 20_000 },
  );
  if (!result?.success) {
    const parserFoundNoWindows = result?.error?.includes(
      "Could not parse any known OpenCode Go dashboard usage windows",
    );
    emit({
      entries: [],
      error: parserFoundNoWindows
        ? "OpenCode Go returned no usage windows; this workspace has no active Go subscription or its dashboard format changed"
        : result?.error || "OpenCode Go returned no usage",
    });
    process.exit(0);
  }

  const labels = {
    rolling: "OpenCode Go 5h",
    weekly: "OpenCode Go Weekly",
    monthly: "OpenCode Go Monthly",
  };
  const entries = Object.entries(labels).flatMap(([window, name]) => {
    const usage = result[window];
    if (!usage) return [];
    const resetAtMs = Date.parse(usage.resetTimeIso);
    return [{
      name,
      window,
      resultType: "quota",
      percentRemaining: usage.percentRemaining,
      resetInSec: usage.resetInSec,
      resetAt: Number.isFinite(resetAtMs) ? Math.floor(resetAtMs / 1000) : null,
    }];
  });
  emit({ entries, error: entries.length ? null : "OpenCode Go returned no usage windows" });
} catch (error) {
  emit({
    entries: [],
    error: error instanceof Error ? error.message : String(error),
  });
}
