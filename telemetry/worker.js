import { communityPage } from "./community_page.js";

const ALLOWED_PROVIDERS = new Set([
  "ai-gateway", "axiom", "claude", "codex", "copilot", "cursor", "datadog",
  "gemini", "git", "github", "grok", "jetbrains", "local", "openrouter",
  "plausible", "posthog", "sentry", "supabase", "vercel", "windsurf", "zed",
]);

const ALLOWED_MODEL_FAMILIES = new Set([
  "sonnet", "opus", "haiku", "gpt", "codex", "gemini", "cursor", "other",
]);

const ALLOWED_FEATURES = new Set([
  "phone_paired", "agent_gateway_enabled", "multi_mac_enabled",
]);

const COMMUNITY_MINIMUM_GROUP_SIZE = 5;
const COMMUNITY_WINDOW_DAYS = 30;

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extraHeaders,
    },
  });
}

function boundedString(value, max = 80) {
  return typeof value === "string" && value.length > 0 && value.length <= max
    ? value
    : null;
}

function providerList(value) {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.filter((item) =>
    typeof item === "string" && ALLOWED_PROVIDERS.has(item)))]
    .sort();
}

function safeModels(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const result = {};
  for (const [provider, families] of Object.entries(value)) {
    if (!ALLOWED_PROVIDERS.has(provider) || !families || typeof families !== "object") {
      continue;
    }
    const safe = {};
    for (const [family, share] of Object.entries(families)) {
      if (ALLOWED_MODEL_FAMILIES.has(family)
          && Number.isInteger(share) && share >= 0 && share <= 100) {
        safe[family] = share;
      }
    }
    if (Object.keys(safe).length > 0) result[provider] = safe;
  }
  return result;
}

function sanitize(payload) {
  if (!payload || typeof payload !== "object") return null;
  const schema = payload.schema;
  const batchID = boundedString(payload.batch_id, 80);
  const period = boundedString(payload.period, 12);
  const app = payload.app;
  const providers = payload.providers;
  if (schema !== 1 || !batchID || !period || !/^\d{4}-W(?:0[1-9]|[1-4]\d|5[0-3])$/.test(period)) {
    return null;
  }
  if (!app || typeof app !== "object" || !providers || typeof providers !== "object") {
    return null;
  }
  const version = boundedString(app.version, 32);
  const build = boundedString(app.build, 64);
  const architecture = ["arm64", "x86_64", "unknown"].includes(app.architecture)
    ? app.architecture : "unknown";
  const macosMajor = Number.isInteger(app.macos_major) && app.macos_major >= 10 && app.macos_major <= 99
    ? app.macos_major : null;
  if (!version || !build || macosMajor === null) return null;

  const features = {};
  if (payload.features && typeof payload.features === "object") {
    for (const [key, value] of Object.entries(payload.features)) {
      if (ALLOWED_FEATURES.has(key) && typeof value === "boolean") features[key] = value;
    }
  }
  const safe = {
    schema: 1,
    batch_id: batchID,
    period,
    app: {
      version,
      build,
      host_version: boundedString(app.host_version, 32),
      macos_major: macosMajor,
      architecture,
    },
    providers: {
      enabled: providerList(providers.enabled),
      used: providerList(providers.used),
      healthy: providerList(providers.healthy),
    },
    models: safeModels(payload.models),
    features,
  };
  return JSON.stringify(safe).length <= 16384 ? safe : null;
}

function publicCount(count) {
  return count >= COMMUNITY_MINIMUM_GROUP_SIZE ? count : null;
}

function dimensionRows(rows, dimension, period) {
  return rows
    .filter((row) => row.dimension === dimension && row.period === period)
    .map((row) => ({
      name: row.item,
      count: Number(row.sample_count),
      value: Number(row.value_total),
    }));
}

function sortByCount(rows) {
  return rows
    .filter((row) => row.count >= COMMUNITY_MINIMUM_GROUP_SIZE)
    .sort((lhs, rhs) => {
      if (lhs.count !== rhs.count) return rhs.count - lhs.count;
      return lhs.name.localeCompare(rhs.name);
    });
}

async function communityStats(env) {
  const periodsResult = await env.DB.prepare(
    `SELECT period, batch_count
     FROM telemetry_periods
     WHERE last_received_at >= datetime('now', ?)
     ORDER BY period DESC`
  ).bind(`-${COMMUNITY_WINDOW_DAYS} days`).all();
  const periods = (periodsResult.results ?? []).map((row) => ({
    period: row.period,
    count: Number(row.batch_count),
  }));
  const latest = periods[0];
  if (!latest) {
    return {
      schema: 1,
      generated_on: new Date().toISOString().slice(0, 10),
      privacy: { minimum_group_size: COMMUNITY_MINIMUM_GROUP_SIZE },
      weekly_active_macs: [],
      latest: null,
    };
  }

  const dimensionsResult = await env.DB.prepare(
    `SELECT period, dimension, item, sample_count, value_total
     FROM telemetry_dimensions
     WHERE period IN (${periods.map(() => "?").join(",")})`
  ).bind(...periods.map((row) => row.period)).all();
  const rows = dimensionsResult.results ?? [];
  const versions = sortByCount(dimensionRows(rows, "version", latest.period));
  const enabled = sortByCount(
    dimensionRows(rows, "provider_enabled", latest.period));
  const used = sortByCount(
    dimensionRows(rows, "provider_used", latest.period));
  const healthy = sortByCount(
    dimensionRows(rows, "provider_healthy", latest.period));
  const modelShares = dimensionRows(rows, "model_share", latest.period)
    .filter((row) => row.count >= COMMUNITY_MINIMUM_GROUP_SIZE)
    .map((row) => ({
      name: row.name,
      share: Math.round(row.value / row.count),
      count: row.count,
    }))
    .sort((lhs, rhs) => {
      if (lhs.share !== rhs.share) return rhs.share - lhs.share;
      return lhs.name.localeCompare(rhs.name);
    });
  const features = dimensionRows(rows, "feature", latest.period)
    .filter((row) => row.count >= COMMUNITY_MINIMUM_GROUP_SIZE)
    .map((row) => ({
      name: row.name,
      adoption: Math.round(row.value / row.count * 100),
      count: row.count,
    }))
    .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name));

  return {
    schema: 1,
    generated_on: new Date().toISOString().slice(0, 10),
    privacy: { minimum_group_size: COMMUNITY_MINIMUM_GROUP_SIZE },
    weekly_active_macs: periods.reverse().map((row) => ({
      period: row.period,
      count: publicCount(row.count),
    })),
    latest: {
      period: latest.period,
      reporting_macs: publicCount(latest.count),
      versions: versions.map((row) => ({ name: row.name, count: row.count })),
      services: {
        enabled: enabled.map((row) => ({ name: row.name, count: row.count })),
        used: used.map((row) => ({ name: row.name, count: row.count })),
        healthy: healthy.map((row) => ({ name: row.name, count: row.count })),
      },
      model_shares: modelShares.map((row) => ({
        name: row.name,
        share: row.share,
      })),
      features: features.map((row) => ({
        name: row.name,
        adoption: row.adoption,
      })),
    },
  };
}

function upsertDimension(env, period, dimension, item, valueTotal = 0) {
  return env.DB.prepare(
    `INSERT INTO telemetry_dimensions
       (period, dimension, item, sample_count, value_total)
     VALUES (?, ?, ?, 1, ?)
     ON CONFLICT(period, dimension, item) DO UPDATE SET
       sample_count = sample_count + 1,
       value_total = value_total + excluded.value_total`
  ).bind(period, dimension, item, valueTotal);
}

async function recordRollups(env, safe, receivedAt) {
  const statements = [
    env.DB.prepare(
      `INSERT INTO telemetry_periods (period, batch_count, last_received_at)
       VALUES (?, 1, ?)
       ON CONFLICT(period) DO UPDATE SET
         batch_count = batch_count + 1,
         last_received_at = excluded.last_received_at`
    ).bind(safe.period, receivedAt),
    upsertDimension(env, safe.period, "version", safe.app.version),
    upsertDimension(env, safe.period, "architecture", safe.app.architecture),
  ];
  for (const provider of safe.providers.enabled) {
    statements.push(upsertDimension(
      env, safe.period, "provider_enabled", provider));
  }
  for (const provider of safe.providers.used) {
    statements.push(upsertDimension(
      env, safe.period, "provider_used", provider));
  }
  for (const provider of safe.providers.healthy) {
    statements.push(upsertDimension(
      env, safe.period, "provider_healthy", provider));
  }
  for (const [provider, families] of Object.entries(safe.models)) {
    for (const [family, share] of Object.entries(families)) {
      statements.push(upsertDimension(
        env, safe.period, "model_share", `${provider}:${family}`, share));
    }
  }
  for (const [feature, enabled] of Object.entries(safe.features)) {
    statements.push(upsertDimension(
      env, safe.period, "feature", feature, enabled ? 1 : 0));
  }
  await env.DB.batch(statements);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/v1/community") {
      return json(await communityStats(env), 200, {
        "access-control-allow-origin": "*",
        "cache-control": "public, max-age=300",
      });
    }
    if (request.method === "GET" &&
        (url.pathname === "/" || url.pathname === "/community")) {
      return new Response(communityPage(), {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=300",
        },
      });
    }
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
      return json({ error: "content_type_required" }, 415);
    }
    let payload;
    try {
      payload = await request.json();
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    const safe = sanitize(payload);
    if (!safe) return json({ error: "invalid_payload" }, 400);
    const receivedAt = new Date().toISOString();
    const result = await env.DB.prepare(
      `INSERT OR IGNORE INTO telemetry_batches
       (batch_id, received_at, period, app_version, host_version, macos_major, architecture, payload)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      safe.batch_id,
      receivedAt,
      safe.period,
      safe.app.version,
      safe.app.host_version,
      safe.app.macos_major,
      safe.app.architecture,
      JSON.stringify(safe),
    ).run();
    const inserted = (result.meta?.changes ?? result.changes ?? 0) > 0;
    if (inserted) await recordRollups(env, safe, receivedAt);
    return json({ ok: true });
  },

  async scheduled(_event, env) {
    const expired = await env.DB.prepare(
      `SELECT period FROM telemetry_periods
       WHERE last_received_at < datetime('now', ?)`
    ).bind(`-${COMMUNITY_WINDOW_DAYS} days`).all();
    const periods = (expired.results ?? []).map((row) => row.period);
    if (periods.length > 0) {
      await env.DB.batch([
        env.DB.prepare(
          `DELETE FROM telemetry_dimensions
           WHERE period IN (${periods.map(() => "?").join(",")})`
        ).bind(...periods),
        env.DB.prepare(
          `DELETE FROM telemetry_periods
           WHERE period IN (${periods.map(() => "?").join(",")})`
        ).bind(...periods),
      ]);
    }
    await env.DB.prepare(
      "DELETE FROM telemetry_batches WHERE received_at < datetime('now', ?)"
    ).bind(`-${COMMUNITY_WINDOW_DAYS} days`).run();
  },
};
