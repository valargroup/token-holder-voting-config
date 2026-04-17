# token-holder-voting-config

Service discovery and round configuration for shielded voting infrastructure. Published via GitHub Pages so wallets can fetch it without running their own chain node.

The schema targets [ZIP 1244 §Vote Configuration Format](https://github.com/zcash/zips/pull/1244). Migration is in progress — see [Status](#status) below for the gap list.

## Structure

```
staging/voting-config.json      # servers used by staging/dev builds
production/voting-config.json   # servers used by production wallet builds
```

## Schema

Target schema (ZIP 1244):

```json
{
  "config_version": 1,
  "vote_round_id": "<64 lowercase hex chars>",
  "title": "Round 1: Protocol Upgrade",
  "description": "Vote on the proposed protocol upgrade.",
  "vote_servers": [
    { "url": "https://...", "label": "val1" }
  ],
  "pir_endpoints": [
    { "url": "https://...", "label": "PIR Server" }
  ],
  "snapshot_height": 2800000,
  "vote_end_time": 1735689600,
  "proposals": [
    {
      "id": 1,
      "title": "Approve protocol upgrade",
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
    "vote_server": "v0"
  }
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `config_version` | int | Schema version. Currently `1`. |
| `vote_round_id` | hex, 64 chars | Must match the chain's active round id. |
| `title`, `description` | string | Shown to the user before signing. |
| `vote_servers[]` | `{url, label}` | Chain + helper REST endpoints. |
| `pir_endpoints[]` | `{url, label}` | Nullifier PIR endpoints. |
| `snapshot_height` | int > 0 | Orchard snapshot height. |
| `vote_end_time` | uint64 | Unix seconds. Wallets refuse to submit after this. |
| `proposals[]` | `{id, title, options[]}` | 1–15 proposals, 2–8 options each (0-indexed). |
| `supported_versions.pir` | `[string]` | Wallet must support ≥1 listed PIR version. |
| `supported_versions.{vote_protocol, tally, vote_server}` | string | Wallet must recognize each version. |

### Non-standard fields

`vote_servers[]` entries may carry an `operator_address` field. It is consumed by the vote-sdk admin API for server registration and is **not** part of ZIP 1244. Wallets following the ZIP should ignore unknown fields.

### Staging hostnames

The staging entries use `*.46-101-255-48.sslip.io`. sslip is **dev infrastructure** — wallets SHOULD NOT pin these hostnames in release builds. Production endpoints will use stable DNS names.

## CDN

Files are served via GitHub Pages at:

- **Staging:** `https://valargroup.github.io/token-holder-voting-config/staging/voting-config.json`
- **Production:** `https://valargroup.github.io/token-holder-voting-config/production/voting-config.json`

Deployments happen automatically on push to `main`.

## Adding a server

1. Fork this repo
2. Add your server entry to the appropriate `voting-config.json`
3. Open a pull request
4. A maintainer reviews and merges — your server is live within ~30 seconds

## Removing a server

Same process: open a PR removing the entry.

## Status

As of 2026-04-17 the published files contain `config_version`, `vote_servers[]`, `pir_endpoints[]`, and `supported_versions`. Round-specific fields required by ZIP 1244 are still pending:

- `vote_round_id`, `title`, `description`, `snapshot_height`, `vote_end_time`, `proposals[]` — added when a round is live.
- Per-round vs single-file layout decision.
- Config authenticity model (detached `.sig`, JWS envelope, Sigstore, or documented TOFU).
- Published JSON Schema for programmatic validation.
- Stable (non-sslip) staging hostnames.
- `production/voting-config.json` endpoints and round data.

See `docs/wallet-integration-todo.md` in the vote-sdk repo for the full list.
