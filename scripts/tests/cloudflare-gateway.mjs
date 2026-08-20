import assert from "node:assert/strict";

import { handleRequest } from "../cloudflare-gateway.mjs";

const sourceRevision = "0123456789abcdef0123456789abcdef01234567";

function assetBinding(body = '{"origin":"cloudflare"}\n', status = 200) {
  const requests = [];
  return {
    requests,
    binding: {
      async fetch(request) {
        requests.push(request);
        return new Response(request.method === "HEAD" ? null : body, {
          status,
        });
      },
    },
  };
}

async function gateway(
  path,
  fetchImpl,
  assets = assetBinding(),
  init = {},
  options = {}
) {
  const request = new Request(
    `https://voting.valargroup.dev/${path}?ignored=yes`,
    init
  );
  const response = await handleRequest(
    request,
    { ASSETS: assets.binding },
    { sourceRevision, fetchImpl, timeoutMs: 50, ...options }
  );
  return { response, assets };
}

{
  let primaryRequest;
  const { response, assets } = await gateway(
    "stage/dynamic-voting-config.json",
    async (request) => {
      primaryRequest = request;
      return new Response('{"origin":"github"}\n', {
        headers: { "Content-Length": "20", "Set-Cookie": "not-forwarded=yes" },
      });
    },
    assetBinding(),
    { headers: { Authorization: "secret", Cookie: "secret=yes" } }
  );

  assert.equal(await response.text(), '{"origin":"github"}\n');
  assert.equal(response.headers.get("x-voting-config-origin"), "github");
  assert.equal(
    response.headers.get("x-voting-config-revision"),
    sourceRevision
  );
  assert.equal(
    response.headers.get("cache-control"),
    "public, max-age=60, must-revalidate, stale-if-error=86400"
  );
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  assert.equal(response.headers.get("vary"), "X-Voting-Config-Rehearsal");
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(response.headers.get("content-length"), null);
  assert.equal(
    primaryRequest.url,
    `https://raw.githubusercontent.com/valargroup/token-holder-voting-config/${sourceRevision}/stage/dynamic-voting-config.json`
  );
  assert.equal(primaryRequest.headers.get("authorization"), null);
  assert.equal(primaryRequest.headers.get("cookie"), null);
  assert.equal(assets.requests.length, 0);
}

for (const primaryFetch of [
  async () => {
    throw new TypeError("network unavailable");
  },
  async () => new Response("upstream unavailable", { status: 503 }),
]) {
  const { response, assets } = await gateway("prod/pir.json", primaryFetch);
  assert.equal(await response.text(), '{"origin":"cloudflare"}\n');
  assert.equal(response.headers.get("x-voting-config-origin"), "cloudflare");
  assert.equal(assets.requests.length, 1);
  assert.equal(
    assets.requests[0].url,
    "https://voting.valargroup.dev/prod/pir.json"
  );
}

{
  const assets = assetBinding();
  const { response } = await gateway(
    "stage/pir.json",
    (request) =>
      new Promise((resolve, reject) => {
        request.signal.addEventListener(
          "abort",
          () => reject(new DOMException("timed out", "AbortError")),
          { once: true }
        );
      }),
    assets,
    {},
    { timeoutMs: 5 }
  );
  assert.equal(response.headers.get("x-voting-config-origin"), "cloudflare");
  assert.equal(assets.requests.length, 1);
}

{
  const assets = assetBinding();
  const { response } = await gateway(
    "stage/dynamic-voting-config.json",
    async () => {
      const body = new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode('{"partial":'));
          setTimeout(() => controller.error(new Error("upstream reset")), 0);
        },
      });
      return new Response(body);
    },
    assets
  );
  assert.equal(await response.text(), '{"origin":"cloudflare"}\n');
  assert.equal(response.headers.get("x-voting-config-origin"), "cloudflare");
  assert.equal(assets.requests.length, 1);
}

{
  const assets = assetBinding();
  const { response } = await gateway(
    "stage/dynamic-voting-config.json",
    async (request) => {
      const body = new ReadableStream({
        start(controller) {
          request.signal.addEventListener(
            "abort",
            () => controller.error(new DOMException("timed out", "AbortError")),
            { once: true }
          );
        },
      });
      return new Response(body);
    },
    assets,
    {},
    { timeoutMs: 5 }
  );
  assert.equal(await response.text(), '{"origin":"cloudflare"}\n');
  assert.equal(response.headers.get("x-voting-config-origin"), "cloudflare");
  assert.equal(assets.requests.length, 1);
}

{
  let primaryCalls = 0;
  const assets = assetBinding();
  const { response } = await gateway(
    "prod/dynamic-voting-config.json",
    async () => {
      primaryCalls += 1;
      return new Response("unexpected");
    },
    assets,
    { headers: { "X-Voting-Config-Rehearsal": "github-outage" } }
  );
  assert.equal(response.headers.get("x-voting-config-origin"), "cloudflare");
  assert.equal(primaryCalls, 0);
  assert.equal(assets.requests.length, 1);
  assert.equal(
    assets.requests[0].headers.get("x-voting-config-rehearsal"),
    null
  );
}

{
  let primaryCalls = 0;
  const assets = assetBinding('{"source_revision":"test"}\n');
  const { response } = await gateway(
    "deployment-manifest.json",
    async () => {
      primaryCalls += 1;
      return new Response("unexpected");
    },
    assets
  );
  assert.equal(response.headers.get("x-voting-config-origin"), "cloudflare");
  assert.equal(
    response.headers.get("cache-control"),
    "public, max-age=60, must-revalidate, stale-if-error=86400"
  );
  assert.equal(primaryCalls, 0);
}

{
  const pinPath = `pins/prod/${"a".repeat(64)}/static-voting-config.json`;
  const { response } = await gateway(pinPath, async () => new Response("{}\n"));
  assert.equal(response.headers.get("x-voting-config-origin"), "github");
  assert.equal(
    response.headers.get("cache-control"),
    "public, max-age=31536000, immutable"
  );
}

{
  const { response } = await gateway(
    "prod/v2-static-voting-config.json",
    async () => new Response("{}\n")
  );
  assert.equal(response.headers.get("x-voting-config-origin"), "github");
  assert.equal(
    response.headers.get("cache-control"),
    "public, max-age=300, must-revalidate, stale-if-error=86400"
  );
}

{
  const pinPath = `pins/stage/${"b".repeat(64)}/v2-static-voting-config.json`;
  const { response } = await gateway(pinPath, async () => new Response("{}\n"));
  assert.equal(response.headers.get("x-voting-config-origin"), "github");
  assert.equal(
    response.headers.get("cache-control"),
    "public, max-age=31536000, immutable"
  );
}

{
  let primaryCalls = 0;
  const assets = assetBinding();
  const { response } = await gateway(
    "test/valar-test.seed.b64",
    async () => {
      primaryCalls += 1;
      return new Response("unexpected");
    },
    assets
  );
  assert.equal(response.status, 404);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(primaryCalls, 0);
  assert.equal(assets.requests.length, 0);
}

{
  const { response } = await gateway(
    "stage/dynamic-voting-config.json",
    async (request) => {
      assert.equal(request.method, "HEAD");
      return new Response(null);
    },
    assetBinding(),
    { method: "HEAD" }
  );
  assert.equal(await response.text(), "");
  assert.equal(response.headers.get("x-voting-config-origin"), "github");
}

{
  const { response } = await gateway(
    "stage/dynamic-voting-config.json",
    async () => new Response("unexpected"),
    assetBinding(),
    { method: "POST" }
  );
  assert.equal(response.status, 405);
}

{
  const request = new Request("https://voting.valargroup.dev/prod/pir.json");
  const response = await handleRequest(
    request,
    {
      ASSETS: {
        async fetch() {
          throw new Error("assets unavailable");
        },
      },
    },
    {
      sourceRevision,
      fetchImpl: async () => {
        throw new Error("github unavailable");
      },
      timeoutMs: 50,
    }
  );
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
}

console.log("Cloudflare gateway unit tests passed");
