#!/usr/bin/env node
// Publish a fresh signed CometBFT checkpoint to checkpoints/latest.json + an
// archive at checkpoints/<height>.json.
//
// Implements the flow documented in
// vote-sdk/docs/runbooks/publish-checkpoint.md, in pure Node.js so the
// runbook's "manual flow" and the GitHub Action's automated flow run the same
// code path.
//
// Inputs are read from environment variables (the GitHub Action sets these):
//
//   SVOTE_RPC_PRIMARY    — primary CometBFT RPC URL (required)
//   SVOTE_RPC_SECONDARY  — secondary RPC URL for cross-check (required)
//   SVOTE_CHAIN_ID       — chain id (default: svote-1)
//   SVOTE_SIGNER_ID      — manifest_signers[].id (default: valarg-poc)
//   MANIFEST_SIGNER_PRIVKEY — base64 32-byte ed25519 seed (required; secret)
//   SVOTE_HEIGHT_OFFSET  — how many blocks back from tip to anchor (default: 5)
//   SVOTE_OUT_DIR        — where to write checkpoints (default: ./checkpoints)
//
// Exits non-zero (and prints a precise error) on any failure: RPC unreachable,
// primary/secondary divergence, signing error.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const env = (k, fallback) => process.env[k] ?? fallback;

const PRIMARY   = env("SVOTE_RPC_PRIMARY");
const SECONDARY = env("SVOTE_RPC_SECONDARY");
const CHAIN_ID  = env("SVOTE_CHAIN_ID", "svote-1");
const SIGNER_ID = env("SVOTE_SIGNER_ID", "valarg-poc");
const PRIVKEY   = env("MANIFEST_SIGNER_PRIVKEY");
const OFFSET    = Number(env("SVOTE_HEIGHT_OFFSET", "5"));
const OUT_DIR   = env("SVOTE_OUT_DIR", path.join(process.cwd(), "checkpoints"));

if (!PRIMARY || !SECONDARY) {
  console.error("error: SVOTE_RPC_PRIMARY and SVOTE_RPC_SECONDARY are required");
  process.exit(1);
}
if (!PRIVKEY) {
  console.error("error: MANIFEST_SIGNER_PRIVKEY is required");
  process.exit(1);
}

const seed = Buffer.from(PRIVKEY.trim(), "base64");
if (seed.length !== 32) {
  console.error(`error: MANIFEST_SIGNER_PRIVKEY decoded to ${seed.length} bytes, expected 32`);
  process.exit(1);
}

// --- CometBFT RPC helpers ---------------------------------------------------

async function rpcGet(rpcURL, path) {
  const res = await fetch(`${rpcURL}${path}`);
  if (!res.ok) {
    throw new Error(`rpc ${rpcURL}${path}: HTTP ${res.status}`);
  }
  const json = await res.json();
  if (json.error) throw new Error(`rpc ${rpcURL}${path}: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function fetchHeader(rpcURL, height) {
  const block  = await rpcGet(rpcURL, `/block?height=${height}`);
  const header = await rpcGet(rpcURL, `/header?height=${height}`);
  return {
    headerHash: block.block_id.hash.toLowerCase(),
    valsetHash: header.header.validators_hash.toLowerCase(),
    appHash:    header.header.app_hash.toLowerCase(),
  };
}

// --- Canonical encoding (must match Go cmd/manifest-signer + Swift wallet) --

const CHECKPOINT_DOMAIN_SEP = Buffer.from("shielded-vote/checkpoint/v1", "utf8");

function uint16BE(n) {
  const b = Buffer.alloc(2); b.writeUInt16BE(n, 0); return b;
}
function uint64BE(n) {
  const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n), 0); return b;
}
function lp(buf) { return Buffer.concat([uint16BE(buf.length), buf]); }

function encodeCheckpoint({ chainId, height, headerHashHex, valsetHashHex, appHashHex, issuedAt }) {
  return Buffer.concat([
    lp(CHECKPOINT_DOMAIN_SEP),
    lp(Buffer.from(chainId, "utf8")),
    uint64BE(height),
    lp(Buffer.from(headerHashHex, "hex")),
    lp(Buffer.from(valsetHashHex, "hex")),
    lp(Buffer.from(appHashHex,    "hex")),
    uint64BE(issuedAt),
  ]);
}

function ed25519Sign(seed32, message) {
  // Construct a PKCS#8-wrapped Ed25519 private key from the raw seed:
  // the SubjectPrivateKeyInfo prefix is fixed for Ed25519.
  const pkcs8Header = Buffer.from("302e020100300506032b657004220420", "hex");
  const key = crypto.createPrivateKey({
    key: Buffer.concat([pkcs8Header, seed32]),
    format: "der",
    type: "pkcs8",
  });
  return crypto.sign(null, message, key);
}

// --- Main --------------------------------------------------------------------

async function main() {
  // 1. Pick a height a few blocks back from the primary tip.
  const status = await rpcGet(PRIMARY, "/status");
  const tip = Number(status.sync_info.latest_block_height);
  if (!Number.isFinite(tip) || tip <= OFFSET) {
    throw new Error(`primary tip (${tip}) is too low; offset=${OFFSET}`);
  }
  const height = tip - OFFSET;

  // 2. Fetch (header_hash, valset_hash, app_hash) from primary AND secondary
  //    at the same height. Refuse to publish on any disagreement — that's the
  //    safety net against a hijacked-publisher attack on the trust anchor.
  const [primary, secondary] = await Promise.all([
    fetchHeader(PRIMARY, height),
    fetchHeader(SECONDARY, height),
  ]);

  const compare = (k) => {
    if (primary[k] !== secondary[k]) {
      throw new Error(`primary/secondary RPC divergence at height ${height}: ${k} primary=${primary[k]} secondary=${secondary[k]}`);
    }
  };
  compare("headerHash");
  compare("valsetHash");
  compare("appHash");

  // 3. Encode + sign.
  const issuedAt = Math.floor(Date.now() / 1000);
  const payload = encodeCheckpoint({
    chainId:        CHAIN_ID,
    height,
    headerHashHex:  primary.headerHash,
    valsetHashHex:  primary.valsetHash,
    appHashHex:     primary.appHash,
    issuedAt,
  });
  const sig = ed25519Sign(seed, payload);

  const doc = {
    chain_id:    CHAIN_ID,
    height,
    header_hash: primary.headerHash,
    valset_hash: primary.valsetHash,
    app_hash:    primary.appHash,
    issued_at:   issuedAt,
    signatures: [
      {
        signer:    SIGNER_ID,
        alg:       "ed25519",
        signature: sig.toString("base64"),
      },
    ],
  };

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const archivePath = path.join(OUT_DIR, `${height}.json`);
  const latestPath  = path.join(OUT_DIR, "latest.json");
  const json = JSON.stringify(doc, null, 2) + "\n";
  fs.writeFileSync(archivePath, json);
  fs.writeFileSync(latestPath, json);

  const digest = crypto.createHash("sha256").update(payload).digest("hex");
  console.log(`published checkpoint @${height}`);
  console.log(`  signed_payload_hash: ${digest}`);
  console.log(`  archive:             ${archivePath}`);
  console.log(`  latest:              ${latestPath}`);
}

main().catch((err) => {
  console.error(`error: ${err.message}`);
  process.exit(1);
});
