# token-holder-voting-config

Service discovery and round configuration for shielded voting infrastructure. Published via GitHub Pages so wallets can fetch it without running their own chain node.

The schema targets [ZIP 1244 §Vote Configuration Format](https://github.com/zcash/zips/pull/1244).

## Schema

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

Round-level title and description are **not** part of this config — they live on the chain and wallets read them from the round object directly.

## Proposals must match the chain byte-for-byte

The chain commits to the proposals array via `VoteRound.proposals_hash = SHA-256(canonical_json(proposals))`. Wallets recompute this on fetch and hard-fail if it doesn't match the on-chain round.

Canonical form (ZIP 1244 §"Proposals Hash"):
- Proposals sorted by `id` ascending
- Options sorted by `index` ascending
- Keys emitted in order: `id`, `title`, `description`, `options` (and per option: `index`, `label`)
- No whitespace, UTF-8, no forward-slash escaping (matches Rust `serde_json::to_string`)

Any difference — a trailing space, a smart quote, a missing option — and every wallet will reject the config. When updating `proposals`, make sure the content matches what the round creator submitted on-chain.

## CDN

Served via GitHub Pages at:

`https://valargroup.github.io/token-holder-voting-config/voting-config.json`

Deployments happen automatically on push to `main`.

## Adding a server

Operators join the chain using `join.sh` from [vote-sdk](https://github.com/valargroup/vote-sdk)
(`join-loop` waits for funding and runs `create-val-tx`). That flow does **not** add
your REST URL here automatically.

1. After you are bonded, fork this repo (or push a branch if you have access)
2. Add your server entry to `vote_servers` in `voting-config.json` (URL + label)
3. Open a pull request
4. A maintainer reviews and merges — your server is live within ~30 seconds

## Removing a server

Same process: open a PR removing the entry.
