# token-holder-voting-config

Service discovery and round authentication for shielded voting infrastructure. The reviewed files on `main` are the source of truth. Complete snapshots are published to Cloudflare Pages so wallets can find vote servers, PIR endpoints, and authenticated round metadata without depending on GitHub at request time. `voting.valargroup.dev` is the canonical host. The existing `voting.valargroup.org` GitHub Pages site remains a legacy mirror and is not an automatic client fallback.

This repo serves environment-scoped configuration documents:

| URL | Schema | Status |
| --- | --- | --- |
| [`prod/dynamic-voting-config.json`](https://voting.valargroup.dev/prod/dynamic-voting-config.json) | Production dynamic config, per-round signed registry | Active production path. |
| [`prod/static-voting-config.json`](https://voting.valargroup.dev/prod/static-voting-config.json) | Production static config | Current production alias. Wallet releases must use its immutable `pins/prod/<sha256>/` copy. |
| [`stage/dynamic-voting-config.json`](https://voting.valargroup.dev/stage/dynamic-voting-config.json) | Staging dynamic config, per-round signed registry | Active for staging wallets and test workflows. |
| [`stage/static-voting-config.json`](https://voting.valargroup.dev/stage/static-voting-config.json) | Staging static config | Current staging alias. Staging releases should use its immutable `pins/stage/<sha256>/` copy. |
| [`deployment-manifest.json`](https://voting.valargroup.dev/deployment-manifest.json) | Publication metadata | Identifies the complete snapshot's source revision, publication mode, and config hashes. |

The dynamic and static schemas implement [draft ZIP 1244](https://github.com/zcash/zips/pull/1244) "Shielded Voting Wallet API". The v1 file has no chain of trust; the dynamic config signs each round's election authority public key with an Ed25519 admin key whose public counterpart is fetched through the wallet's hash-pinned static config.

The legacy `voting.valargroup.org` site continues publishing current dynamic
configs, but its previously checksum-pinned static aliases are frozen at their
pre-migration bytes. Every dynamic update must remain authenticated by those
frozen keys and by every published immutable `.dev` pin. New releases must use
the immutable `.dev/pins/` URLs.

## Dynamic Config Schema

```json
{
  "config_version": 1,
  "vote_servers": [
    { "url": "https://vote-chain-primary.valargroup.org", "label": "valarg-genesis" }
  ],
  "pir_endpoints": [
    { "url": "https://pir.valargroup.org", "label": "PIR primary" }
  ],
  "pir_layout": {
    "pir_depth": 19,
    "tier0_layers": 12,
    "tier1_layers": 7,
    "poly_len": 4096
  },
  "supported_versions": {
    "pir": ["v0"],
    "vote_protocol": "v0",
    "tally": "v0",
    "vote_server": "v1"
  },
  "rounds": {
    "<lowercase hex round id, 64 chars>": {
      "auth_version": 1,
      "ea_pk": "<base64, 32 bytes>",
      "signatures": [
        { "key_id": "valar-2026-q2", "alg": "ed25519", "sig": "<base64, 64 bytes>" }
      ]
    }
  }
}
```

`vote_servers`, `pir_endpoints`, `pir_layout`, and `supported_versions` are wrapper metadata and are not signed in v1. Wallets require `pir_layout` (including YPIR `poly_len`, `2048` or `4096`) and verify that it matches the layout advertised by the selected PIR server before issuing a private query. The signature scope is each round entry's `ea_pk`; for `auth_version: 1`, the signed bytes are exactly the raw 32-byte `ea_pk`. Newer wallets authenticate `auth_version: 2` entries over the round id, `ea_pk`, and full `pir_layout` (including `poly_len`); changing `pir_layout` therefore requires re-signing every active round. Round identity, title, description, and proposals live on chain.

## Static Config Schema

Wallet releases embed a hash-pinned URL to the published static
configuration object in the signed application binary. The published
file has this shape:

```json
{
  "static_config_version": 1,
  "dynamic_config_url": "https://voting.valargroup.dev/prod/dynamic-voting-config.json",
  "trusted_keys": [
    {
      "key_id": "valar-2026-q2",
      "alg": "ed25519",
      "pubkey": "<base64, 32 bytes>"
    }
  ]
}
```

`trusted_keys` lists the admin Ed25519 public keys that may authenticate
round entries in the matching environment's `dynamic-voting-config.json`.
Production config lives under `prod/`, and staging config lives under `stage/`.
Wallets bind to a specific byte-for-byte copy by embedding a
cosmovisor-style `URL?checksum=sha256:HEX` pin in the signed wallet
binary. Static configs point only to the controlled `voting.valargroup.dev`
domain. This lets the serving platform change without another static-config
change. Replace the current development key before shipping a production wallet
release.

For testing alternative config URLs, we publish duplicate static configs under
`test/`. The production duplicate lives at
`https://voting.valargroup.dev/test/prod-static-voting-config-duplicate.json`,
and the staging duplicate lives at
`https://voting.valargroup.dev/test/static-voting-config-duplicate.json`.
Each file is independently verified against its matching dynamic config. The
separate "Deploy duplicate static configs" workflow publishes a complete
snapshot and writes `.sha256` files beside the test aliases.

## Trust Model

Wallets carry a hash-pinned URL string in their signed application binary
(`URL?checksum=sha256:HEX`). On boot, the wallet fetches the URL, verifies
the response's SHA-256 matches the embedded hash, and only then trusts the
file's `dynamic_config_url` and `trusted_keys`. The dynamic config is
fetched and validated as before; each round is authenticated by checking:

1. The round exists in `rounds`.
2. The round entry uses a supported `auth_version`.
3. At least one Ed25519 signature verifies against a bundled trusted key.
4. The signed `ea_pk` matches the `ea_pk` returned by the chain for that round.

A signature failure or `ea_pk` mismatch is scoped to that round. Other authenticated rounds remain usable, and an on-chain round missing from `rounds` should be surfaced as unauthenticated.

## Hash-pinning and wallet releases

Any byte-level change to an environment's `static-voting-config.json`
invalidates every wallet binary pinned to that file. Each version therefore has
an immutable copy at `pins/<environment>/<sha256>/static-voting-config.json`.
The publisher refuses a static-config change unless that immutable copy is
checked in. Coordinate every production static-config change with a wallet
release: first merge and deploy this repo, then copy the new immutable pin into
the wallet release branch.

Compute a local pin with:

```bash
PROD_HASH=$(sha256sum prod/static-voting-config.json | awk '{print $1}')
echo "https://voting.valargroup.dev/pins/prod/${PROD_HASH}/static-voting-config.json?checksum=sha256:${PROD_HASH}"

STAGE_HASH=$(sha256sum stage/static-voting-config.json | awk '{print $1}')
echo "https://voting.valargroup.dev/pins/stage/${STAGE_HASH}/static-voting-config.json?checksum=sha256:${STAGE_HASH}"
```

The deploy workflow also writes the canonical pin strings to the GitHub Actions
step summary and publishes `static-voting-config.json.sha256` files for human
verification. Wallets must trust the hash embedded in their signed binary, not
the sidecar file.

## Operator Participation

Bringing a vote server or PIR operator into rotation does not require a chain deploy or wallet release:

1. Operator joins the chain, using [`vote-sdk`](https://github.com/valargroup/vote-sdk) tooling.
2. Operator opens a PR adding their entry to the environment's `dynamic-voting-config.json` (`prod/` for production, `stage/` for staging).
3. CI verifies every dynamic-config round signature against the matching environment's `static-voting-config.json` `trusted_keys`.
4. Maintainer reviews and merges.
5. The deploy workflows verify the config again before publishing a complete Cloudflare Pages snapshot and the transition GitHub Pages mirror.

Removing an operator or changing an operator URL follows the same PR flow.

## Adding or Rotating a Round

A new round entry requires the vote manager to sign the round's public `ea_pk`
with an admin Ed25519 key. For production, that Ed25519 key is derived from
the vote manager's Keplr account so there is no separate long-lived admin seed
to copy between machines.

Preferred path:

1. Create the round on chain.
2. Open the `vote-sdk` admin UI and use the "Sign config entry" page.
3. Pick the round. The UI requests canonical payload bytes and a transparency hash from `/api/sign-config-entry`.
4. Connect the vote manager's Keplr wallet, click **Derive signing key**, and
   confirm Keplr's fixed-purpose `signArbitrary` prompt.
5. Sign the round with the derived key and paste the generated JSON into
   the matching environment's `dynamic-voting-config.json#/rounds/<round_id>`.
6. Include the displayed `signed_payload_hash` in the PR description for reviewer cross-check.

Offline path:

```bash
curl -fsSL \
  https://github.com/valargroup/vote-sdk/releases/download/v1.3.0-rc.2/voting-config-linux-amd64 \
  -o voting-config
echo "40c2be2b97e27f2743f9f34107be7c21d9acd9d918bfda7ce61e0070d2f9fb77  voting-config" | sha256sum -c -
chmod +x voting-config

./voting-config sign \
  --round-id <64-char-lowercase-hex-round-id> \
  --ea-pk <base64-32-byte-ea-pk> \
  --signer-id <key_id from static-voting-config.json#/trusted_keys> \
  --privkey-file test/valar-test.seed.b64 \
  --merge dynamic-voting-config.json
```

The CLI preserves existing signatures when merging. Do not stage placeholder `ea_pk` values; wait until the chain has the round id and final `ea_pk`.

Keplr-compatible offline recovery path:

```bash
# Produces the same Ed25519 public key as the admin UI would derive from the
# same Keplr mnemonic, chain id, bech32 prefix, and BIP44 path.
printf '%s\n' '<vote-manager-keplr-mnemonic>' | ./voting-config config-attestation-keygen \
  --chain-id <shielded-vote-chain-id> \
  --mnemonic-stdin \
  --out ./keplr-derived.seed.b64

./voting-config sign \
  --round-id <64-char-lowercase-hex-round-id> \
  --ea-pk <base64-32-byte-ea-pk> \
  --signer-id keplr:<derived_address_from_config-attestation-keygen> \
  --privkey-file ./keplr-derived.seed.b64 \
  --merge dynamic-voting-config.json
```

`config-attestation-keygen` intentionally requires `--chain-id`; using the wrong chain id
derives a different Ed25519 key. The default path is Keplr's Cosmos account
path, `m/44'/118'/0'/0/0`, with `sv` bech32 addresses.

## Signing Key Custody

Each environment's `static-voting-config.json` lists every public key that wallets trust under its `trusted_keys` array. Each entry is the public side of an admin key that may sign round entries in that environment's `dynamic-voting-config.json`.

The current static config includes a development key, `valar-test`. Replace it with a vote-manager-held production key before shipping the pinned static config URL in a wallet release.

Production handover:

1. Open the `vote-sdk` admin UI and connect the vote manager's Keplr wallet.
2. Click **Derive signing key** and copy the displayed trusted key entry.
3. Open a PR replacing `static-voting-config.json`'s `trusted_keys` with the derived public key and re-signing every production entry under the new `key_id`.
4. Coordinate with the wallet team so the wallet release pins the deployed `static-voting-config.json` hash.
5. Use `voting-config config-attestation-keygen --chain-id <chain> --mnemonic-stdin` only as the offline recovery path; it derives the same public key from the same Keplr mnemonic.
6. Remove retired keys only after a wallet release has dropped them from its bundled trust anchor.

`voting-config keygen` remains available for non-Keplr manager wallets or local
development, but it is no longer the recommended production handover path.

Steady-state rotation follows the same shape: derive the new Keplr-backed key, sign new or updated rounds with it, ship a wallet trust-anchor update, then remove the retired key after the wallet release.

## Local Verification

Install the pinned verifier from `vote-sdk`, then verify the checked-in dynamic config against the checked-in static config:

```bash
curl -fsSL \
  https://github.com/valargroup/vote-sdk/releases/download/v1.3.0-rc.2/voting-config-linux-amd64 \
  -o voting-config
echo "40c2be2b97e27f2743f9f34107be7c21d9acd9d918bfda7ce61e0070d2f9fb77  voting-config" | sha256sum -c -
chmod +x voting-config

./voting-config verify --config prod/dynamic-voting-config.json --static-config prod/static-voting-config.json
./voting-config verify --config stage/dynamic-voting-config.json --static-config stage/static-voting-config.json
SOURCE_REVISION=local-test PUBLICATION_MODE=local-test \
  scripts/build-cloudflare-pages.sh "$(mktemp -d)/site"
```

## CI

Four workflows guard the serving path:

- [`verify-config.yml`](.github/workflows/verify-config.yml) runs on pull requests and pushes that touch the dynamic config, static config, or workflow files. It downloads the checksum-pinned `voting-config` binary from the `vote-sdk` v1.3.0-rc.2 GitHub release and runs `voting-config verify`.
- [`deploy-cloudflare-pages.yml`](.github/workflows/deploy-cloudflare-pages.yml) publishes one versioned Cloudflare Pages snapshot and verifies the exact served bytes and headers. It is inert until the explicit repository enable flag and exact Cloudflare target are configured.
- [`deploy-pages.yml`](.github/workflows/deploy-pages.yml) retains the GitHub Pages transition mirror while freezing its previously checksum-pinned static aliases.
- [`deploy-duplicate-static-config.yml`](.github/workflows/deploy-duplicate-static-config.yml) applies the same full-snapshot publisher when a test alias changes.

The ownership model, rollout gates, failure behavior, rollback steps, and outage rehearsal are documented in [`docs/cloudflare-hosting.md`](docs/cloudflare-hosting.md).
