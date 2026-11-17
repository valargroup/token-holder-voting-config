import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ALERT_LABEL,
  checkList,
  findWalletLists,
  issueMarker,
  main,
  reconcileIssue,
  renderIssueBody,
} from "../wallet-list-alerts.mjs";

const root = mkdtempSync(join(tmpdir(), "wallet-list-alerts-"));
const write = (path, value) => {
  mkdirSync(join(root, path, ".."), { recursive: true });
  writeFileSync(join(root, path), JSON.stringify(value));
};
const signer = (keyId, pubkey) => [{ key_id: keyId, alg: "ed25519", pubkey }];
write("prod/wallets/vizor/signers.json", signer("valargroup", "P".repeat(43) + "="));
write("prod/wallets/vizor/list.json", {});
write("stage/wallets/vizor/signers.json", signer("valar-test-keplr-derived", "S".repeat(43) + "="));
write("stage/wallets/other/signers.json", signer("other", "O".repeat(43) + "="));
write("stage/wallets/other/list.json", {});

/** A recording GitHub client answering from replies, keyed "METHOD path". */
function fakeGitHub(replies = {}) {
  const calls = [];
  const github = async (method, path, body) => {
    calls.push({ method, path, body });
    return replies[`${method} ${path}`] ?? {};
  };
  return { github, calls };
}

const finding = (index, kind) => ({ index, handle: `h${index}`, kind, detail: `detail ${index}` });

try {
  // Lists are found per environment with their pinned keys; a folder with
  // only signers.json has no list to check.
  const lists = findWalletLists(root);
  assert.deepEqual(
    lists.map((l) => [l.env, l.chainId, l.walletId, l.listPath, l.allowedKeys]),
    [
      ["prod", "zvote-1", "vizor", "prod/wallets/vizor/list.json", [`valargroup=${"P".repeat(43)}=`]],
      ["stage", "svote-1", "other", "stage/wallets/other/list.json", [`other=${"O".repeat(43)}=`]],
    ]
  );

  // checkList passes the pins and chain, and reads the JSON result even when
  // voting-config exits non-zero.
  let ran;
  const result = await checkList(lists[0], "https://prod.example", {
    cwd: root,
    run: async (file, args) => {
      ran = [file, ...args];
      return { code: 1, stdout: JSON.stringify({ ok: false, findings: [finding(17, "key_mismatch")] }), stderr: "" };
    },
  });
  assert.deepEqual(ran, [
    "voting-config", "wallet-list", "verify", "--list", "prod/wallets/vizor/list.json", "--wallet-id", "vizor",
    "--chain-id", "zvote-1", "--allowed-key", `valargroup=${"P".repeat(43)}=`, "--chain-check", "https://prod.example", "--json",
  ]);
  assert.equal(result.error, "");
  assert.deepEqual(result.findings, [finding(17, "key_mismatch")]);
  const broken = await checkList(lists[0], "https://prod.example", {
    run: async () => ({ code: 1, stdout: "", stderr: 'unknown command "wallet-list"' }),
  });
  assert.match(broken.error, /unknown command "wallet-list"/);

  // Every finding kind voting-config reports for a row has its own words.
  const kinds = {
    not_registered: "not registered",
    suspended: "suspended",
    retired: "retired",
    provider_mismatch: "registered with another provider",
    handle_mismatch: "registered with another handle",
    key_mismatch: "registered with another key than the row's dk",
  };
  const everyKind = renderIssueBody("vizor", [{ env: "stage", findings: Object.keys(kinds).map((kind, i) => finding(i + 1, kind)) }]);
  Object.values(kinds).forEach((words, i) => {
    assert.ok(everyKind.includes(`| stage | \`${i + 1}\` | \`h${i + 1}\` | ${words} | detail ${i + 1} |`), words);
  });
  assert.ok(!everyKind.includes("reviewed_keys"));

  // Opening, updating, leaving and closing the wallet's issue.
  const results = [{ env: "prod", walletId: "vizor", findings: [finding(17, "key_mismatch"), finding(23, "retired")] }];
  const body = renderIssueBody("vizor", results);
  assert.ok(body.startsWith(issueMarker("vizor")));
  assert.match(body, /\| prod \| `17` \| `h17` \| registered with another key than the row's dk \| detail 17 \|/);
  assert.match(body, /\| prod \| `23` \| `h23` \| retired \| detail 23 \|/);
  // Nothing in it links an issue or mentions a GitHub user.
  assert.doesNotMatch(body, /#\d|@\w/);

  let gh = fakeGitHub();
  assert.equal(await reconcileIssue(gh.github, "vizor", results, []), "opened");
  assert.deepEqual(gh.calls, [{ method: "POST", path: "/issues", body: { title: "Re-review the vizor wallet list", body, labels: [ALERT_LABEL, "wallet:vizor"] } }]);

  const otherWallet = { number: 3, body: issueMarker("other") };
  const pullRequest = { number: 4, body: issueMarker("vizor"), pull_request: {} };
  gh = fakeGitHub();
  assert.equal(await reconcileIssue(gh.github, "vizor", results, [otherWallet, pullRequest, { number: 5, body }]), "unchanged");
  assert.deepEqual(gh.calls, []);

  gh = fakeGitHub();
  const stale = { number: 5, body: renderIssueBody("vizor", [{ env: "prod", findings: [finding(17, "key_mismatch")] }]) };
  assert.equal(await reconcileIssue(gh.github, "vizor", results, [stale]), "updated");
  assert.deepEqual(gh.calls.map((c) => `${c.method} ${c.path}`), ["PATCH /issues/5", "POST /issues/5/comments"]);
  assert.equal(gh.calls[0].body.body, body);

  gh = fakeGitHub();
  const clean = [{ env: "prod", walletId: "vizor", findings: [] }];
  assert.equal(await reconcileIssue(gh.github, "vizor", clean, [stale]), "closed");
  assert.deepEqual(gh.calls.map((c) => `${c.method} ${c.path}`), ["POST /issues/5/comments", "PATCH /issues/5"]);
  assert.equal(gh.calls[1].body.state, "closed");

  gh = fakeGitHub();
  assert.equal(await reconcileIssue(gh.github, "vizor", clean, [otherWallet]), "clean");
  assert.deepEqual(gh.calls, []);

  // main checks every list, opens vizor's issue, and fails the run without
  // touching the wallet whose check failed.
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push(`${init.method} ${url}`);
    assert.equal(init.headers.Authorization, "Bearer token");
    return new Response(init.method === "GET" ? "[]" : "{}", { status: init.method === "POST" ? 201 : 200 });
  };
  const logs = [];
  const code = await main({
    root,
    env: { PROD_CHAIN_URL: "https://prod.example", STAGE_CHAIN_URL: "https://stage.example", GITHUB_TOKEN: "token", GITHUB_REPOSITORY: "valargroup/token-holder-voting-config" },
    run: async (_, args) =>
      args.includes("vizor")
        ? { code: 1, stdout: JSON.stringify({ ok: false, findings: [finding(17, "suspended")] }), stderr: "" }
        : { code: 1, stdout: JSON.stringify({ ok: false, error: "chain node_info: HTTP 502" }), stderr: "" },
    fetchImpl,
    log: (line) => logs.push(line),
  });
  assert.equal(code, 1);
  assert.deepEqual(requests, [
    `GET https://api.github.com/repos/valargroup/token-holder-voting-config/issues?state=open&labels=${ALERT_LABEL}&per_page=100`,
    "POST https://api.github.com/repos/valargroup/token-holder-voting-config/issues",
  ]);
  assert.ok(logs.includes("vizor: opened"), logs.join("\n"));
  assert.ok(logs.some((line) => line.includes("other stage list not checked::chain node_info: HTTP 502")), logs.join("\n"));

  // A stage outage doesn't hold back the same wallet's production finding:
  // the issue gets the new prod rows, keeps stage's rows from the last
  // check, and the run still fails.
  const both = mkdtempSync(join(tmpdir(), "wallet-list-alerts-both-"));
  try {
    for (const env of ["prod", "stage"]) {
      mkdirSync(join(both, env, "wallets", "vizor"), { recursive: true });
      writeFileSync(join(both, env, "wallets", "vizor", "signers.json"), JSON.stringify(signer(env, "K".repeat(43) + "=")));
      writeFileSync(join(both, env, "wallets", "vizor", "list.json"), "{}");
    }
    const previous = renderIssueBody("vizor", [
      { env: "prod", findings: [] },
      { env: "stage", findings: [finding(9, "retired")] },
    ]);
    const bothEnv = { PROD_CHAIN_URL: "https://prod.example", STAGE_CHAIN_URL: "https://stage.example", GITHUB_TOKEN: "token", GITHUB_REPOSITORY: "o/r" };
    const stageDown = (prodFindings) => async (_, args) =>
      args.includes("zvote-1")
        ? { code: prodFindings.length ? 1 : 0, stdout: JSON.stringify({ ok: !prodFindings.length, findings: prodFindings }), stderr: "" }
        : { code: 1, stdout: JSON.stringify({ ok: false, error: "chain node_info: HTTP 502" }), stderr: "" };
    const issueFetch = (sent) => async (url, init) => {
      sent.push({ method: init.method, url, body: init.body ? JSON.parse(init.body) : undefined });
      const reply = init.method === "GET" ? JSON.stringify([{ number: 7, body: previous }]) : "{}";
      return new Response(reply, { status: 200 });
    };

    let sent = [];
    let bothLogs = [];
    assert.equal(
      await main({ root: both, env: bothEnv, run: stageDown([finding(17, "suspended")]), fetchImpl: issueFetch(sent), log: (l) => bothLogs.push(l) }),
      1
    );
    assert.ok(bothLogs.includes("vizor: updated"), bothLogs.join("\n"));
    assert.ok(bothLogs.some((l) => l.includes("vizor stage list not checked::chain node_info: HTTP 502")), bothLogs.join("\n"));
    const patched = sent.find((s) => s.method === "PATCH").body.body;
    assert.match(patched, /\| prod \| `17` \| `h17` \| suspended \| detail 17 \|/);
    assert.match(patched, /\| stage \| `9` \| `h9` \| retired \| detail 9 \|/);
    assert.match(patched, /latest stage check failed/);

    // A clean prod check with stage still down keeps the issue open.
    sent = [];
    bothLogs = [];
    assert.equal(await main({ root: both, env: bothEnv, run: stageDown([]), fetchImpl: issueFetch(sent), log: (l) => bothLogs.push(l) }), 1);
    assert.ok(!sent.some((s) => s.body && s.body.state === "closed"), JSON.stringify(sent));
    assert.ok(bothLogs.includes("vizor: updated"), bothLogs.join("\n"));
    assert.match(sent.find((s) => s.method === "PATCH").body.body, /\| stage \| `9` \|/);
  } finally {
    rmSync(both, { recursive: true, force: true });
  }

  // Nothing to check without lists.
  const empty = mkdtempSync(join(tmpdir(), "wallet-list-alerts-empty-"));
  assert.equal(await main({ root: empty, env: {}, log: () => {} }), 0);
  rmSync(empty, { recursive: true, force: true });
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log("Wallet list alert tests passed");
