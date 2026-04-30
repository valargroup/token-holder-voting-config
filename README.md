# token-holder-voting-config

Service discovery and round configuration for shielded voting infrastructure.
Published via GitHub Pages so wallets can fetch it without running their own
chain node.

The schema targets [ZIP 1244 §Vote Configuration Format](https://github.com/zcash/zips/pull/1244).

The full trust model — including how wallets authenticate `ea_pk` against this
config and what each layer protects against — lives in
[vote-sdk/docs/config.md](https://github.com/valargroup/vote-sdk/blob/main/docs/config.md).
This README is the operator-facing companion: schema, publish workflow, and
the format of files served from this repo's GitHub Pages site.

## Files served by this repo

| Path                                | Purpose                                                                |
| ----------------------------------- | ---------------------------------------------------------------------- |
| `voting-config.json`                | Per-round discovery config + round-manifest signatures (`round_signatures`) |
| `checkpoints/latest.json`           | Rolling pointer to the most recent signed CometBFT checkpoint (12–24h cadence) |
| `checkpoints/<height>.json`         | Append-only archive — one file per published checkpoint                |

All are static JSON, served with default GitHub Pages caching. Wallets refetch
on every cold start and on every round transition.

## Schema — `voting-config.json`

```json
{
  "config_version": 1,
  "vote_round_id": "<64 lowercase hex chars>",
  "vote_servers": [
    { "url": "https://...", "label": "primary" }
  ],
  "pir_endpoints": [
    { "url": "https://...", "label": "PIR primary" }
  ],
  "snapshot_height": 2800000,
  "vote_end_time": 1735689600,
  "proposals": [
    {
      "id": 1,
      "title": "Approve protocol upgrade",
      "description": "Approve or oppose the proposed protocol upgrade.",
      "options": [
        { "index": 0, "label": "Support" },
        { "index": 1, "label": "Oppose" }
      ]
    }
  ],
  "supported_versions": {
    "pir": ["v0"],
    "vote_protocol": "v0",
    "tally": "v0",
    "vote_server": "v1"
  },
  "round_signatures": {
    "round_id": "<must equal vote_round_id>",
    "ea_pk": "<base64 32-byte Pallas pubkey from on-chain VoteRound.ea_pk>",
    "valset_hash": "<64-char hex CometBFT valset_hash at round.creation_height>",
    "signed_payload_hash": "<64-char hex sha256 of the canonical payload>",
    "signatures": [
      {
        "signer": "valarg-vote-authority",
        "alg": "ed25519",
        "signature": "<base64 64-byte ed25519 signature>"
      }
    ]
  }
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `config_version` | int | Schema version. Currently `1`. |
| `vote_round_id` | hex, 64 chars | Must match the chain's active round id. |
| `vote_servers[]` | `{url, label}` | Chain REST + helper endpoints. Wallets use the first for API traffic; all are used for share submission. |
| `pir_endpoints[]` | `{url, label}` | Nullifier PIR endpoints. Wallets use the first. |
| `snapshot_height` | int > 0 | Orchard snapshot height. Multiple of 10. PIR servers must serve this exact height; the admin UI auto-populates round drafts from it. |
| `vote_end_time` | uint64 | Unix seconds. Wallets refuse to submit after this. |
| `proposals[]` | `{id, title, description, options[]}` | 1–15 proposals, 2–8 options each (0-indexed). Must match the chain byte-for-byte (see below). |
| `supported_versions.pir` | `[string]` | Wallet must support ≥1 listed PIR version. |
| `supported_versions.{vote_protocol, tally, vote_server}` | string | Wallet must recognize each version. |
| `round_signatures` | object | Phase 1+. See [`round_signatures` schema](#round_signatures-schema) below. Phase 2+ wallets hard-fail when missing. |

Round-level title and description are **not** part of this config — they live
on the chain and wallets read them from the round object directly.

### `round_signatures` schema

`round_signatures` is the off-chain attestation that `ea_pk` for `vote_round_id`
came from the chain's TSS ceremony. Wallets verify it against signer pubkeys
baked into their bundle (see
[vote-sdk/docs/config.md](https://github.com/valargroup/vote-sdk/blob/main/docs/config.md)).

| Field | Type | Notes |
| --- | --- | --- |
| `round_id` | hex, 64 chars | MUST equal `vote_round_id`. |
| `ea_pk` | base64, 32 bytes | The on-chain `VoteRound.ea_pk` (Pallas point, compressed). |
| `valset_hash` | hex, 64 chars | CometBFT validator-set hash at the round's `created_at_height`. Binds the signature to a specific chain history. |
| `signed_payload_hash` | hex, 64 chars | SHA-256 of the canonical payload, included as a transparency aid. Wallets do not have to compute it but operators publish it for auditability. |
| `signatures[]` | `[{signer, alg, signature}]` | One entry per attesting signer. `signer` matches `manifest_signers[].id` in the wallet bundle. `alg` is `ed25519`. `signature` is base64. |

**Canonical signing payload** (the bytes ed25519 signs over):

```
"shielded-vote/round-manifest/v1" ||
u16_be(7) || "svote-1" ||                  // chain_id
u16_be(32) || round_id_bytes ||
u16_be(32) || ea_pk_bytes ||
u16_be(32) || valset_hash_bytes
```

The reference implementation lives at
[`vote-sdk/cmd/manifest-signer`](https://github.com/valargroup/vote-sdk/tree/main/cmd/manifest-signer).
Use `manifest-signer sign-round` to produce, `manifest-signer verify` to check.

## Schema — `checkpoints/latest.json`

Signed CometBFT checkpoint, published on a 12–24h cadence. Phase 3 wallets use
this to refresh their light-client trust anchor without a new wallet release.

```json
{
  "chain_id": "svote-1",
  "height": 123456,
  "header_hash": "<64-char hex>",
  "valset_hash": "<64-char hex>",
  "app_hash":    "<64-char hex>",
  "issued_at":   1730000000,
  "signatures": [
    { "signer": "valarg-vote-authority", "alg": "ed25519", "signature": "<base64>" }
  ]
}
```

`signatures[]` uses the same shape as `round_signatures.signatures[]`. The
canonical payload differs and uses domain separator
`shielded-vote/checkpoint/v1` — see
[vote-sdk/docs/config.md](https://github.com/valargroup/vote-sdk/blob/main/docs/config.md#signed-checkpoint-schema).

The publisher (a scheduled GitHub Action in this repo, see `.github/workflows/`)
queries a primary RPC for the latest finalized header, cross-checks against a
secondary RPC at the same height, and refuses to publish on header divergence.

## Proposals must match the chain byte-for-byte

The chain commits to the proposals array via
`VoteRound.proposals_hash = SHA-256(canonical_json(proposals))`. Wallets
recompute this on fetch and hard-fail if it doesn't match the on-chain round.

Canonical form (ZIP 1244 §"Proposals Hash"):

- Proposals sorted by `id` ascending
- Options sorted by `index` ascending
- Keys emitted in order: `id`, `title`, `description`, `options` (and per
  option: `index`, `label`)
- No whitespace, UTF-8, no forward-slash escaping (matches Rust
  `serde_json::to_string`)

Any difference — a trailing space, a smart quote, a missing option — and every
wallet will reject the config. When updating `proposals`, make sure the content
matches what the round creator submitted on-chain.

## CDN

Served via GitHub Pages at:

- `https://valargroup.github.io/token-holder-voting-config/voting-config.json`
- `https://valargroup.github.io/token-holder-voting-config/checkpoints/latest.json`
- `https://valargroup.github.io/token-holder-voting-config/checkpoints/<height>.json`

Deployments happen automatically on push to `main`.

## Adding a server

Operators join the chain using `join.sh` from
[vote-sdk](https://github.com/valargroup/vote-sdk) (`join-loop` waits for
funding and runs `create-val-tx`). That flow does **not** add your REST URL
here automatically.

1. After you are bonded, fork this repo (or push a branch if you have access)
2. Add your server entry to `vote_servers` in `voting-config.json` (URL + label)
3. Open a pull request
4. A maintainer reviews and merges — your server is live within ~30 seconds

## Removing a server

Same process: open a PR removing the entry.

## Round-rollover workflow

After a new on-chain round is created:

1. Update `vote_round_id`, `snapshot_height`, `vote_end_time`, `proposals[]` in
   `voting-config.json` to match the new round.
2. After the round's TSS ceremony completes and `ea_pk` is final on-chain,
   produce `round_signatures` using `manifest-signer sign-round` (see
   [`vote-sdk/docs/runbooks/sign-round-manifest.md`](https://github.com/valargroup/vote-sdk/blob/main/docs/runbooks/sign-round-manifest.md)).
3. Open a PR with both updates. CI validates the JSON schema (including
   `round_signatures` shape and signature byte-validity, but does NOT verify
   the signature against the trust anchor — that's the wallet's job).
4. Merge → GitHub Pages picks up within ~30 seconds → wallets see the new
   manifest on next config fetch.
