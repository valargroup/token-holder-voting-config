// Daily re-review alert for wallet lists (vote-sdk
// docs/proxy-delegation/contracts-v1.md §12.3, "Re-review alert").
//
// For every <env>/wallets/<wallet_id>/list.json it runs `voting-config
// wallet-list verify --chain-check` against the environment's chain, which
// reports each listed delegate whose entry is missing, suspended or retired,
// or has another provider, handle or key than its row. It then keeps one
// open issue per wallet listing those findings: it opens the issue, updates
// it and comments when the findings change, and closes it once every check of
// that wallet comes back clean. A failed check fails the run, and its
// environment keeps the rows the issue already had while the wallet's other
// environments are still reported.

import { execFile } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const ALERT_LABEL = "wallet-list-alert";

/** The chain each environment's lists name. */
export const ENVIRONMENTS = [
  { env: "prod", chainId: "zvote-1", chainUrlVar: "PROD_CHAIN_URL" },
  { env: "stage", chainId: "svote-1", chainUrlVar: "STAGE_CHAIN_URL" },
];

/** Plain words for each finding kind voting-config reports. */
const KIND_WORDS = {
  not_registered: "not registered",
  suspended: "suspended",
  retired: "retired",
  provider_mismatch: "registered with another provider",
  handle_mismatch: "registered with another handle",
  key_mismatch: "registered with another key than the row's dk",
};

/** The hidden marker that ties an issue to its wallet. */
export function issueMarker(walletId) {
  return `<!-- ${ALERT_LABEL}:${walletId} -->`;
}

/** Find every wallet list under root, with the keys its signers.json pins. */
export function findWalletLists(root) {
  const lists = [];
  for (const { env, chainId } of ENVIRONMENTS) {
    const walletsDir = join(root, env, "wallets");
    if (!existsSync(walletsDir)) continue;
    for (const walletId of readdirSync(walletsDir).sort()) {
      const listPath = join(env, "wallets", walletId, "list.json");
      if (!existsSync(join(root, listPath))) continue;
      const signers = JSON.parse(readFileSync(join(root, env, "wallets", walletId, "signers.json"), "utf8"));
      lists.push({ env, chainId, walletId, listPath, allowedKeys: signers.map((key) => `${key.key_id}=${key.pubkey}`) });
    }
  }
  return lists;
}

/** Run a command and resolve with its exit code, stdout and stderr. */
function runCommand(file, args, cwd) {
  return new Promise((resolve) => {
    execFile(file, args, { cwd, maxBuffer: 16 << 20 }, (error, stdout, stderr) => {
      const code = error ? (typeof error.code === "number" ? error.code : 1) : 0;
      resolve({ code, stdout, stderr: stderr || (error && typeof error.code !== "number" ? String(error) : "") });
    });
  });
}

/**
 * Check one list against its chain. Resolves with its findings, or with an
 * error when the list or the chain could not be checked.
 */
export async function checkList(list, chainUrl, { votingConfig = "voting-config", cwd, run = runCommand } = {}) {
  const args = ["wallet-list", "verify", "--list", list.listPath, "--wallet-id", list.walletId, "--chain-id", list.chainId];
  for (const key of list.allowedKeys) args.push("--allowed-key", key);
  args.push("--chain-check", chainUrl, "--json");
  const { stdout, stderr } = await run(votingConfig, args, cwd);
  let result;
  try {
    result = JSON.parse(stdout);
  } catch {
    return { ...list, error: `voting-config gave no result: ${stderr.trim() || stdout.trim() || "no output"}`, findings: [] };
  }
  return { ...list, error: result.error || "", findings: result.findings || [] };
}

/** The rows a previous issue body holds for env. */
function previousRows(body, env) {
  return (body ?? "").split("\n").filter((line) => line.startsWith(`| ${env} | `));
}

/**
 * The issue body for a wallet's findings. A result with an error keeps its
 * environment's rows from previousBody, since its check said nothing new.
 */
export function renderIssueBody(walletId, results, previousBody = "") {
  const rows = results.flatMap((r) =>
    r.error
      ? previousRows(previousBody, r.env)
      : r.findings.map((f) => `| ${r.env} | #${f.index} | @${f.handle} | ${KIND_WORDS[f.kind] ?? f.kind} | ${f.detail} |`)
  );
  const unchecked = results.filter((r) => r.error).map((r) => r.env);
  return [
    issueMarker(walletId),
    `The daily wallet list check found delegates on the \`${walletId}\` list whose registry entry changed since the list was reviewed. Re-review each one, update or remove its row, raise \`version\` and re-sign the list (README, **Wallet Lists**). This issue closes after the next clean check.`,
    "",
    "| Environment | Delegate | Handle | Finding | Detail |",
    "| --- | --- | --- | --- | --- |",
    ...rows,
    "",
    ...(unchecked.length > 0 ? [`The latest ${unchecked.join(" and ")} check failed, so those rows are from an earlier check.`, ""] : []),
  ].join("\n");
}

/** A minimal GitHub REST client over fetchImpl. */
export function githubClient({ token, repository, fetchImpl = fetch, apiUrl = "https://api.github.com" }) {
  return async (method, path, body) => {
    const response = await fetchImpl(`${apiUrl}/repos/${repository}${path}`, {
      method,
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "X-GitHub-Api-Version": "2022-11-28",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!response.ok) throw new Error(`GitHub ${method} ${path}: HTTP ${response.status} ${await response.text()}`);
    return response.status === 204 ? null : response.json();
  };
}

/**
 * Bring one wallet's issue in line with its results: open, update or close
 * it. A failed check keeps its rows (see `renderIssueBody`) and keeps the
 * issue open. Returns what it did.
 */
export async function reconcileIssue(github, walletId, results, openIssues) {
  const marker = issueMarker(walletId);
  const issue = openIssues.find((i) => !i.pull_request && (i.body ?? "").includes(marker));
  const failed = results.some((r) => r.error);
  const findings = results.flatMap((r) => (r.error ? [] : r.findings));
  if (findings.length === 0 && !issue) return failed ? "unchecked" : "clean";
  if (findings.length === 0 && !failed) {
    await github("POST", `/issues/${issue.number}/comments`, {
      body: "The latest check found no listed delegate that needs a re-review, so this closes.",
    });
    await github("PATCH", `/issues/${issue.number}`, { state: "closed", state_reason: "completed" });
    return "closed";
  }
  const body = renderIssueBody(walletId, results, issue?.body);
  if (!issue) {
    await github("POST", "/issues", { title: `Re-review the ${walletId} wallet list`, body, labels: [ALERT_LABEL] });
    return "opened";
  }
  if (issue.body === body) return "unchanged";
  await github("PATCH", `/issues/${issue.number}`, { body });
  await github("POST", `/issues/${issue.number}/comments`, {
    body: "The findings changed; the table above is current.",
  });
  return "updated";
}

/** Check every list under root and reconcile each wallet's issue. */
export async function main({ root = process.cwd(), env = process.env, run, fetchImpl, log = console.log } = {}) {
  const lists = findWalletLists(root);
  if (lists.length === 0) {
    log("No wallet lists to check.");
    return 0;
  }
  const votingConfig = env.VOTING_CONFIG || "voting-config";
  const results = [];
  for (const list of lists) {
    const chainUrl = env[ENVIRONMENTS.find((e) => e.env === list.env).chainUrlVar];
    if (!chainUrl) throw new Error(`no chain URL for ${list.env}`);
    results.push(await checkList(list, chainUrl, { votingConfig, cwd: root, run }));
  }
  const github = githubClient({ token: env.GITHUB_TOKEN, repository: env.GITHUB_REPOSITORY, fetchImpl });
  const openIssues = await github("GET", `/issues?state=open&labels=${ALERT_LABEL}&per_page=100`);
  let failed = false;
  for (const walletId of [...new Set(results.map((r) => r.walletId))]) {
    const own = results.filter((r) => r.walletId === walletId);
    const errors = own.filter((r) => r.error);
    if (errors.length > 0) {
      failed = true;
      for (const r of errors) log(`::error title=${walletId} ${r.env} list not checked::${r.error}`);
    }
    log(`${walletId}: ${await reconcileIssue(github, walletId, own, openIssues)}`);
  }
  return failed ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(err);
      process.exit(1);
    }
  );
}
