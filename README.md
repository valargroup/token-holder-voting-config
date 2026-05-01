# token-holder-voting-config

Service discovery and round authentication for shielded voting infrastructure. This repo is published through GitHub Pages so wallets can find vote servers, PIR endpoints, and authenticated round metadata without running their own chain node.

This repo serves two configuration documents:

| URL | Schema | Status |
| --- | --- | --- |
| [`voting-config.json`](https://valargroup.github.io/token-holder-voting-config/voting-config.json) | v1, unsigned | Frozen for backwards compatibility with installed wallets that predate the v2 schema. |
| [`voting-config-v2.json`](https://valargroup.github.io/token-holder-voting-config/voting-config-v2.json) | v2, per-round signed registry | Active. New wallet releases consume this. |

The v2 schema implements [draft ZIP 1244](https://github.com/zcash/zips/pull/1244) "Shielded Voting Wallet API". The v1 file has no chain of trust; v2 signs each round's election authority public key with an Ed25519 admin key whose public counterpart is bundled in the wallet binary.

## v2 Schema

```json
{
  "config_version": 1,
  "vote_servers": [
    { "url": "https://vote-chain-primary.valargroup.org", "label": "valarg-genesis" }
  ],
  "pir_endpoints": [
    { "url": "https://pir.valargroup.org", "label": "PIR primary" }
  ],
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

`vote_servers`, `pir_endpoints`, and `supported_versions` are wrapper metadata and are not signed in v1. The signature scope is each round entry's `ea_pk`; for `auth_version: 1`, the signed bytes are exactly the raw 32-byte `ea_pk`. Round identity, title, description, and proposals live on chain.

## Trust Model

Wallets carry the v2 trust anchor in their signed application binary: the URL of `voting-config-v2.json` plus the trusted public keys from `trusted_keys.json`. On boot, a wallet fetches the config, validates the wrapper, and authenticates each round it interacts with by checking:

1. The round exists in `rounds`.
2. The round entry uses a supported `auth_version`.
3. At least one Ed25519 signature verifies against a bundled trusted key.
4. The signed `ea_pk` matches the `ea_pk` returned by the chain for that round.

A signature failure or `ea_pk` mismatch is scoped to that round. Other authenticated rounds remain usable, and an on-chain round missing from `rounds` should be surfaced as unauthenticated.

## Operator Participation

Bringing a vote server or PIR operator into rotation does not require a wallet release or chain deploy:

1. Operator joins the chain, using [`vote-sdk`](https://github.com/valargroup/vote-sdk) tooling.
2. Operator opens a PR adding their entry to `vote_servers` or `pir_endpoints` in `voting-config-v2.json`. They may also update `voting-config.json` if they need visibility to v1 wallets.
3. CI verifies every v2 round signature against `trusted_keys.json`.
4. Maintainer reviews and merges. GitHub Pages republishes after the deploy workflow completes.

Removing an operator or changing an operator URL follows the same PR flow.

## Adding or Rotating a Round

A new round entry requires the vote manager to sign the round's public `ea_pk` with an admin Ed25519 key.

Preferred path:

1. Create the round on chain.
2. Open the `vote-sdk` admin UI and use the "Sign config entry" page.
3. Pick the round. The UI requests canonical payload bytes and a transparency hash from `/api/sign-config-entry`.
4. Sign in the browser with the admin Ed25519 key stored in that browser.
5. Paste the generated JSON into `voting-config-v2.json#/rounds/<round_id>`.
6. Include the displayed `signed_payload_hash` in the PR description for reviewer cross-check.

Offline path:

```bash
curl -fsSL \
  https://github.com/valargroup/vote-sdk/releases/download/v0.5.51/voting-config-linux-amd64 \
  -o voting-config
chmod +x voting-config

./voting-config sign \
  --round-id <64-char-lowercase-hex-round-id> \
  --ea-pk <base64-32-byte-ea-pk> \
  --signer-id <key_id from trusted_keys.json> \
  --privkey-file test/valar-test.seed.b64 \
  --merge voting-config-v2.json
```

The CLI preserves existing signatures when merging. Do not stage placeholder `ea_pk` values; wait until the chain has the round id and final `ea_pk`.

## Signing Key Custody

`trusted_keys.json` lists every public key that wallets trust. The file is a JSON array, and each entry is the public side of an admin key that may sign round entries in `voting-config-v2.json`.

The current `trusted_keys.json` includes a development key, `valar-test`. Replace it with a vote-manager-held production key before shipping the v2 URL in a wallet release.

Production handover:

1. Generate an Ed25519 keypair with `voting-config keygen` on a trusted machine.
2. Store the base64 seed outside git under the vote manager's custody.
3. Open a PR replacing `trusted_keys.json` with the new public key and re-signing every entry under the new `key_id`.
4. Coordinate with the wallet team so the bundled trust anchor mirrors `trusted_keys.json`.
5. Remove retired keys only after a wallet release has dropped them from its bundled trust anchor.

Steady-state rotation follows the same shape: add the new key, sign new or updated rounds with it, ship a wallet trust-anchor update, then remove the retired key after the wallet release.

## Local Verification

Install the pinned verifier from `vote-sdk`, then verify the checked-in config against the checked-in trusted keys:

```bash
curl -fsSL \
  https://github.com/valargroup/vote-sdk/releases/download/v0.5.51/voting-config-linux-amd64 \
  -o voting-config
chmod +x voting-config

./voting-config verify --config voting-config-v2.json --keys trusted_keys.json
```

## CI

Two workflows guard the v2 path:

- [`verify-config.yml`](.github/workflows/verify-config.yml) runs on pull requests and pushes that touch the v2 config, trusted keys, or workflow files. It downloads the pinned `voting-config` binary from the `vote-sdk` GitHub release and runs `voting-config verify`.
- [`deploy-pages.yml`](.github/workflows/deploy-pages.yml) runs the same verifier before publishing to GitHub Pages. A bad signature blocks deployment.
