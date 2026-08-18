const BUILD_SOURCE_REVISION = "__SOURCE_REVISION__";
const PRIMARY_TIMEOUT_MS = 2500;
const REHEARSAL_HEADER = "x-voting-config-rehearsal";
const REHEARSAL_VALUE = "github-outage";

const SOURCE_PATHS = new Set([
  "prod/dynamic-voting-config.json",
  "prod/pir.json",
  "prod/static-voting-config.json",
  "stage/dynamic-voting-config.json",
  "stage/pir.json",
  "stage/static-voting-config.json",
  "test/prod-static-voting-config-duplicate.json",
  "test/static-voting-config-duplicate.json",
]);

const ASSET_ONLY_PATHS = new Set([
  "deployment-manifest.json",
  "prod/static-voting-config.json.sha256",
  "stage/static-voting-config.json.sha256",
  "test/prod-static-voting-config-duplicate.json.sha256",
  "test/static-voting-config-duplicate.json.sha256",
]);

const PIN_PATH_PATTERN =
  /^pins\/(?:test\/)?(?:prod|stage)\/[0-9a-f]{64}\/static-voting-config\.json$/;
const PIN_SIDECAR_PATTERN =
  /^pins\/(?:test\/)?(?:prod|stage)\/[0-9a-f]{64}\/static-voting-config\.json\.sha256$/;

function isSourcePath(path) {
  return SOURCE_PATHS.has(path) || PIN_PATH_PATTERN.test(path);
}

function isAssetOnlyPath(path) {
  return ASSET_ONLY_PATHS.has(path) || PIN_SIDECAR_PATTERN.test(path);
}

function cacheControl(path) {
  if (PIN_PATH_PATTERN.test(path) || PIN_SIDECAR_PATTERN.test(path)) {
    return "public, max-age=31536000, immutable";
  }
  if (path.startsWith("test/") || path.includes("static-voting-config.json")) {
    return "public, max-age=300, must-revalidate, stale-if-error=86400";
  }
  return "public, max-age=60, must-revalidate, stale-if-error=86400";
}

function contentType(path) {
  return path.endsWith(".sha256")
    ? "text/plain; charset=utf-8"
    : "application/json; charset=utf-8";
}

function responseHeaders(upstream, path, origin, sourceRevision) {
  const headers = new Headers();
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Cache-Control", upstream.ok ? cacheControl(path) : "no-store");
  headers.set("Content-Type", contentType(path));
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("Vary", "X-Voting-Config-Rehearsal");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Voting-Config-Origin", origin);
  headers.set("X-Voting-Config-Revision", sourceRevision);
  return headers;
}

function forwardResponse(request, upstream, path, origin, sourceRevision) {
  return new Response(request.method === "HEAD" ? null : upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders(upstream, path, origin, sourceRevision),
  });
}

function gatewayResponse(status, message) {
  return new Response(message, {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-store",
      "Content-Type": "text/plain; charset=utf-8",
      "Referrer-Policy": "no-referrer",
      Vary: "X-Voting-Config-Rehearsal",
      "X-Content-Type-Options": "nosniff",
      "X-Voting-Config-Origin": "gateway",
    },
  });
}

async function fetchPrimary(
  request,
  path,
  sourceRevision,
  fetchImpl,
  timeoutMs
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const primaryUrl = `https://raw.githubusercontent.com/valargroup/token-holder-voting-config/${sourceRevision}/${path}`;
  const primaryRequest = new Request(primaryUrl, {
    method: request.method,
    headers: { Accept: contentType(path) },
    redirect: "follow",
    signal: controller.signal,
  });

  try {
    const primary = await fetchImpl(primaryRequest);
    if (!primary.ok || request.method === "HEAD") {
      return primary;
    }

    const body = await primary.arrayBuffer();
    return new Response(body, {
      status: primary.status,
      statusText: primary.statusText,
    });
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchFallback(request, env) {
  const assetUrl = new URL(request.url);
  assetUrl.search = "";
  return env.ASSETS.fetch(new Request(assetUrl, { method: request.method }));
}

export async function handleRequest(request, env, options = {}) {
  const sourceRevision = options.sourceRevision ?? BUILD_SOURCE_REVISION;
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const timeoutMs = options.timeoutMs ?? PRIMARY_TIMEOUT_MS;

  if (
    !/^[0-9a-f]{40}$/.test(sourceRevision) &&
    sourceRevision !== "local-test"
  ) {
    return gatewayResponse(500, "Gateway revision is invalid\n");
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    return gatewayResponse(405, "Method not allowed\n");
  }

  const path = new URL(request.url).pathname.replace(/^\/+/, "");
  const sourcePath = isSourcePath(path);
  if (!sourcePath && !isAssetOnlyPath(path)) {
    return gatewayResponse(404, "Not found\n");
  }
  if (!env?.ASSETS || typeof env.ASSETS.fetch !== "function") {
    return gatewayResponse(503, "Voting configuration unavailable\n");
  }

  const forceFallback =
    request.headers.get(REHEARSAL_HEADER) === REHEARSAL_VALUE;
  if (sourcePath && !forceFallback) {
    try {
      const primary = await fetchPrimary(
        request,
        path,
        sourceRevision,
        fetchImpl,
        timeoutMs
      );
      if (primary.ok) {
        return forwardResponse(
          request,
          primary,
          path,
          "github",
          sourceRevision
        );
      }
      await primary.body?.cancel();
    } catch {
      // Network failures and timeouts use the byte-identical Pages snapshot.
    }
  }

  try {
    const fallback = await fetchFallback(request, env);
    return forwardResponse(
      request,
      fallback,
      path,
      "cloudflare",
      sourceRevision
    );
  } catch {
    return gatewayResponse(503, "Voting configuration unavailable\n");
  }
}

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  },
};
