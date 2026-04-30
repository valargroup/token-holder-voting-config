#!/usr/bin/env node
// Validate voting-config.json (and the example) before deploy.
//
// What this checks:
//   - Top-level shape per ZIP 1244 §"Vote Configuration Format".
//   - round_signatures (when present) has the correct shape AND the cryptographic
//     signature(s) verify against ./manifest-signers/<signer>.pub. The wallet
//     does this same check at runtime — verifying at PR time catches typos and
//     accidentally-stripped signatures before they reach a user.
//   - All checkpoints/<height>.json files (when present) have correct shape and
//     valid signatures.
//
// What this does NOT check:
//   - Liveness — that vote_round_id and ea_pk match what's currently on-chain.
//     That's the round-publisher's responsibility (runbooks/sign-round-manifest.md).
//   - Trust-period freshness of checkpoints — that's the wallet's job.
//
// Run via:  node scripts/validate-config.mjs
// Exits non-zero with a precise error on any failure.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const repoRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const ROUND_MANIFEST_DOMAIN_SEP = Buffer.from("shielded-vote/round-manifest/v1", "utf8");
const CHECKPOINT_DOMAIN_SEP    = Buffer.from("shielded-vote/checkpoint/v1",   "utf8");
const CHAIN_ID_DEFAULT         = "svote-1";

let failed = 0;
const fail = (msg) => { console.error(`FAIL: ${msg}`); failed++; };
const ok   = (msg) => { console.log(`ok:   ${msg}`); };
const failuresSnapshot = () => failed;

// --- Helpers -----------------------------------------------------------------

function readJSON(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function readSignerPubkey(signerId) {
  const p = path.join(repoRoot, "manifest-signers", `${signerId}.pub`);
  if (!fs.existsSync(p)) {
    return null;
  }
  const b64 = fs.readFileSync(p, "utf8").trim();
  const bytes = Buffer.from(b64, "base64");
  if (bytes.length !== 32) {
    fail(`signer ${signerId}: pubkey file ${p} decoded to ${bytes.length} bytes, expected 32`);
    return null;
  }
  return bytes;
}

function uint16BE(n) {
  const b = Buffer.alloc(2);
  b.writeUInt16BE(n, 0);
  return b;
}
function uint64BE(n) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n), 0);
  return b;
}
function lenPrefixed(buf) {
  return Buffer.concat([uint16BE(buf.length), buf]);
}

function encodeRoundManifest({ chainId, roundIdBytes, eaPkBytes, valsetHashBytes }) {
  return Buffer.concat([
    lenPrefixed(ROUND_MANIFEST_DOMAIN_SEP),
    lenPrefixed(Buffer.from(chainId, "utf8")),
    lenPrefixed(roundIdBytes),
    lenPrefixed(eaPkBytes),
    lenPrefixed(valsetHashBytes),
  ]);
}

function encodeCheckpoint({ chainId, height, headerHashBytes, valsetHashBytes, appHashBytes, issuedAt }) {
  return Buffer.concat([
    lenPrefixed(CHECKPOINT_DOMAIN_SEP),
    lenPrefixed(Buffer.from(chainId, "utf8")),
    uint64BE(height),
    lenPrefixed(headerHashBytes),
    lenPrefixed(valsetHashBytes),
    lenPrefixed(appHashBytes),
    uint64BE(issuedAt),
  ]);
}

function decodeHex32(s, label) {
  if (typeof s !== "string" || !/^[0-9a-fA-F]{64}$/.test(s)) {
    fail(`${label}: expected 64 lowercase hex chars, got ${typeof s === "string" ? s.length : typeof s}`);
    return null;
  }
  return Buffer.from(s.toLowerCase(), "hex");
}
function decodeBase64Bytes(s, expectedLen, label) {
  if (typeof s !== "string") {
    fail(`${label}: expected base64 string`);
    return null;
  }
  const buf = Buffer.from(s, "base64");
  if (buf.length !== expectedLen) {
    fail(`${label}: decoded ${buf.length} bytes, expected ${expectedLen}`);
    return null;
  }
  return buf;
}

function verifyEd25519(pubkey32, message, signature64) {
  // Node 16+: crypto.verify accepts a raw 32-byte ed25519 pubkey via createPublicKey.
  const key = crypto.createPublicKey({
    key: Buffer.concat([
      // SubjectPublicKeyInfo prefix for Ed25519: 12 bytes
      Buffer.from("302a300506032b6570032100", "hex"),
      pubkey32,
    ]),
    format: "der",
    type: "spki",
  });
  return crypto.verify(null, message, key, signature64);
}

// --- voting-config.json + example -------------------------------------------

function validateVotingConfig(filename) {
  const fullPath = path.join(repoRoot, filename);
  if (!fs.existsSync(fullPath)) {
    ok(`${filename}: not present, skipping`);
    return;
  }
  let cfg;
  try {
    cfg = readJSON(fullPath);
  } catch (e) {
    return fail(`${filename}: parse error: ${e.message}`);
  }

  // Required top-level fields per ZIP 1244 (validate the schema before
  // round_signatures so we don't blame a broken voting-config on a missing
  // signature).
  for (const k of ["config_version", "vote_round_id", "vote_servers", "pir_endpoints", "snapshot_height", "vote_end_time", "proposals", "supported_versions"]) {
    if (!(k in cfg)) {
      return fail(`${filename}: missing top-level field "${k}"`);
    }
  }
  if (cfg.config_version !== 1) fail(`${filename}: config_version=${cfg.config_version}, expected 1`);
  if (!/^[0-9a-f]{64}$/.test(cfg.vote_round_id)) fail(`${filename}: vote_round_id is not 64 lowercase hex chars`);

  // round_signatures may be null/missing during transitional rounds (Phase 0
  // wallets ignore it; Phase 2+ wallets hard-fail). When present, validate it.
  const sigs = cfg.round_signatures;
  if (sigs == null) {
    ok(`${filename}: round_signatures absent (Phase 2 wallets will hard-fail)`);
    return;
  }
  const before = failuresSnapshot();
  validateRoundSignatures(sigs, cfg.vote_round_id, `${filename}.round_signatures`);
  if (failuresSnapshot() === before) {
    ok(`${filename}: shape + signatures verified`);
  }
}

function validateRoundSignatures(sigs, expectedRoundId, label) {
  for (const k of ["round_id", "ea_pk", "valset_hash", "signatures"]) {
    if (!(k in sigs)) return fail(`${label}: missing "${k}"`);
  }
  if (sigs.round_id.toLowerCase() !== expectedRoundId.toLowerCase()) {
    return fail(`${label}: round_id (${sigs.round_id}) does not match top-level vote_round_id (${expectedRoundId})`);
  }
  const roundIdBytes   = decodeHex32(sigs.round_id, `${label}.round_id`);
  const valsetBytes    = decodeHex32(sigs.valset_hash, `${label}.valset_hash`);
  const eaPkBytes      = decodeBase64Bytes(sigs.ea_pk, 32, `${label}.ea_pk`);
  if (!roundIdBytes || !valsetBytes || !eaPkBytes) return;

  const payload = encodeRoundManifest({
    chainId: CHAIN_ID_DEFAULT,
    roundIdBytes,
    eaPkBytes,
    valsetHashBytes: valsetBytes,
  });
  const computedDigest = crypto.createHash("sha256").update(payload).digest("hex");
  if (sigs.signed_payload_hash && sigs.signed_payload_hash.toLowerCase() !== computedDigest) {
    fail(`${label}.signed_payload_hash (${sigs.signed_payload_hash}) does not match computed (${computedDigest})`);
  }

  if (!Array.isArray(sigs.signatures) || sigs.signatures.length === 0) {
    return fail(`${label}.signatures: must be a non-empty array`);
  }
  const seen = new Set();
  for (const entry of sigs.signatures) {
    if (!entry.signer || !entry.alg || !entry.signature) {
      fail(`${label}: each signature needs {signer, alg, signature}`); continue;
    }
    if (entry.alg !== "ed25519") {
      fail(`${label}: signer ${entry.signer}: alg=${entry.alg}, only ed25519 supported`); continue;
    }
    if (seen.has(entry.signer)) {
      fail(`${label}: duplicate signer entry "${entry.signer}"`); continue;
    }
    seen.add(entry.signer);

    const pubkey = readSignerPubkey(entry.signer);
    if (!pubkey) {
      fail(`${label}: signer "${entry.signer}" has no pubkey in manifest-signers/${entry.signer}.pub`);
      continue;
    }
    const sigBytes = Buffer.from(entry.signature, "base64");
    if (sigBytes.length !== 64) {
      fail(`${label}: signer ${entry.signer}: signature decoded to ${sigBytes.length} bytes, expected 64`);
      continue;
    }
    if (!verifyEd25519(pubkey, payload, sigBytes)) {
      fail(`${label}: signer ${entry.signer}: signature does NOT verify against manifest-signers/${entry.signer}.pub`);
      continue;
    }
    ok(`  ${label}: signer ${entry.signer} verified`);
  }
}

// --- checkpoints/*.json ------------------------------------------------------

function validateCheckpointFile(absPath, relPath) {
  const fileStartFailures = failuresSnapshot();
  let doc;
  try {
    doc = readJSON(absPath);
  } catch (e) {
    return fail(`${relPath}: parse error: ${e.message}`);
  }
  for (const k of ["chain_id", "height", "header_hash", "valset_hash", "app_hash", "issued_at", "signatures"]) {
    if (!(k in doc)) return fail(`${relPath}: missing "${k}"`);
  }
  if (doc.chain_id !== CHAIN_ID_DEFAULT) {
    fail(`${relPath}: chain_id=${doc.chain_id}, expected ${CHAIN_ID_DEFAULT}`);
  }
  if (!Number.isInteger(doc.height) || doc.height <= 0) {
    fail(`${relPath}: height must be a positive integer`);
  }
  const hh = decodeHex32(doc.header_hash, `${relPath}.header_hash`);
  const vh = decodeHex32(doc.valset_hash, `${relPath}.valset_hash`);
  const ah = decodeHex32(doc.app_hash, `${relPath}.app_hash`);
  if (!hh || !vh || !ah) return;

  const payload = encodeCheckpoint({
    chainId: doc.chain_id,
    height: doc.height,
    headerHashBytes: hh,
    valsetHashBytes: vh,
    appHashBytes: ah,
    issuedAt: doc.issued_at,
  });

  if (!Array.isArray(doc.signatures) || doc.signatures.length === 0) {
    return fail(`${relPath}.signatures: must be a non-empty array`);
  }
  const seen = new Set();
  for (const entry of doc.signatures) {
    if (entry.alg !== "ed25519") {
      fail(`${relPath}: signer ${entry.signer}: alg=${entry.alg}, only ed25519 supported`); continue;
    }
    if (seen.has(entry.signer)) { fail(`${relPath}: duplicate signer "${entry.signer}"`); continue; }
    seen.add(entry.signer);

    const pubkey = readSignerPubkey(entry.signer);
    if (!pubkey) { fail(`${relPath}: signer "${entry.signer}" has no pubkey`); continue; }
    const sigBytes = Buffer.from(entry.signature, "base64");
    if (sigBytes.length !== 64) { fail(`${relPath}: signer ${entry.signer}: signature is ${sigBytes.length} bytes, expected 64`); continue; }
    if (!verifyEd25519(pubkey, payload, sigBytes)) {
      fail(`${relPath}: signer ${entry.signer}: signature does NOT verify`);
      continue;
    }
    ok(`  ${relPath}: signer ${entry.signer} verified`);
  }
  if (Array.from(seen).every((s) => doc.signatures.find((e) => e.signer === s))) {
    // Reached without short-circuit; schema-and-shape checks above already
    // ran. Print the per-file summary only if no signature failed.
    if (failuresSnapshot() === fileStartFailures) {
      ok(`${relPath}: shape + signatures verified`);
    }
  }
}

function validateAllCheckpoints() {
  const dir = path.join(repoRoot, "checkpoints");
  if (!fs.existsSync(dir)) {
    ok("checkpoints/: not present, skipping");
    return;
  }
  for (const name of fs.readdirSync(dir).sort()) {
    if (!name.endsWith(".json")) continue;
    validateCheckpointFile(path.join(dir, name), `checkpoints/${name}`);
  }
}

// --- Entry point -------------------------------------------------------------

validateVotingConfig("voting-config.json");
validateVotingConfig("voting-config.example.json");
validateAllCheckpoints();

if (failed > 0) {
  console.error(`\n${failed} check(s) failed.`);
  process.exit(1);
}
console.log("\nall checks passed.");
