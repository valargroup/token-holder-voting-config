# token-holder-voting-config

Service discovery and round authentication for shielded voting infrastructure. This repo is published through GitHub Pages so wallets can find vote servers, PIR endpoints, and authenticated round metadata without running their own chain node.

This repo serves two published configuration documents and one sample of
the wallet-bundled static configuration:

| URL | Schema | Status |
| --- | --- | --- |
| [`voting-config.json`](https://valargroup.github.io/token-holder-voting-config/voting-config.json) | v1, unsigned | Frozen for backwards compatibility with installed wallets that predate the v2 schema. |
| [`dynamic-voting-config.json`](https://valargroup.github.io/token-holder-voting-config/dynamic-voting-config.json) | Dynamic config, per-round signed registry | Active. New wallet releases consume this through their bundled static config. |
| [`static-voting-config-sample.json`](static-voting-config-sample.json) | Static config sample | Sample of the bundled wallet trust anchor. This file is not itself the wallet trust anchor unless bundled into a signed wallet release. |

The dynamic and static schemas implement [draft ZIP 1244](https://github.com/zcash/zips/pull/1244) "Shielded Voting Wallet API". The v1 file has no chain of trust; the dynamic config signs each round's election authority public key with an Ed25519 admin key whose public counterpart is bundled in the wallet binary through the static config.

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

## Static Config Schema

Wallet releases bundle a static configuration object into the signed
application binary. The sample in this repo mirrors the shape that
wallets should embed:

```json
{
  "static_config_version": 1,
  "dynamic_config_url": "https://valargroup.github.io/token-holder-voting-config/dynamic-voting-config.json",
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
round entries in `dynamic-voting-config.json`. The static config itself
is the wallet's trust anchor and is bundled into the signed application
binary, so changing it requires a wallet release.

## Trust Model

Wallets carry the trust anchor in their signed application binary: the dynamic config URL plus the trusted public keys from the bundled static config. On boot, a wallet fetches the dynamic config, validates the wrapper, and authenticates each round it interacts with by checking:

1. The round exists in `rounds`.
2. The round entry uses a supported `auth_version`.
3. At least one Ed25519 signature verifies against a bundled trusted key.
4. The signed `ea_pk` matches the `ea_pk` returned by the chain for that round.

A signature failure or `ea_pk` mismatch is scoped to that round. Other authenticated rounds remain usable, and an on-chain round missing from `rounds` should be surfaced as unauthenticated.

## Operator Participation

Bringing a vote server or PIR operator into rotation does not require a chain deploy or wallet release:

1. Operator joins the chain, using [`vote-sdk`](https://github.com/valargroup/vote-sdk) tooling.
2. Operator opens a PR adding their entry to `vote_servers` or `pir_endpoints` in `dynamic-voting-config.json`. They may also update `voting-config.json` if they need visibility to v1 wallets.
3. CI verifies every dynamic-config round signature against `static-voting-config-sample.json`'s `trusted_keys`.
4. Maintainer reviews and merges.
5. The deploy workflow verifies the config again before publishing GitHub Pages.

Removing an operator or changing an operator URL follows the same PR flow.

## Adding or Rotating a Round

A new round entry requires the vote manager to sign the round's public `ea_pk` with an admin Ed25519 key.

Preferred path:

1. Create the round on chain.
2. Open the `vote-sdk` admin UI and use the "Sign config entry" page.
3. Pick the round. The UI requests canonical payload bytes and a transparency hash from `/api/sign-config-entry`.
4. Sign in the browser with the admin Ed25519 key stored in that browser.
5. Paste the generated JSON into `dynamic-voting-config.json#/rounds/<round_id>`.
6. Include the displayed `signed_payload_hash` in the PR description for reviewer cross-check.

Offline path:

```bash
curl -fsSL \
  https://github.com/valargroup/vote-sdk/releases/download/v0.5.52/voting-config-linux-amd64 \
  -o voting-config
echo "730173e20fdd84258516f7741ecbe9456db9ea9962483b9c3aa402a31b313ab8  voting-config" | sha256sum -c -
chmod +x voting-config

./voting-config sign \
  --round-id <64-char-lowercase-hex-round-id> \
  --ea-pk <base64-32-byte-ea-pk> \
  --signer-id <key_id from static-voting-config-sample.json#/trusted_keys> \
  --privkey-file test/valar-test.seed.b64 \
  --merge dynamic-voting-config.json
```

The CLI preserves existing signatures when merging. Do not stage placeholder `ea_pk` values; wait until the chain has the round id and final `ea_pk`.

## Signing Key Custody

`static-voting-config-sample.json` lists every public key that wallets trust under its `trusted_keys` array. Each entry is the public side of an admin key that may sign round entries in `dynamic-voting-config.json`.

The current sample includes a development key, `valar-test`. Replace it with a vote-manager-held production key before shipping the dynamic config URL in a wallet release.

Production handover:

1. Generate an Ed25519 keypair with `voting-config keygen` on a trusted machine.
2. Store the base64 seed outside git under the vote manager's custody.
3. Open a PR replacing `static-voting-config-sample.json`'s `trusted_keys` with the new public key and re-signing every entry under the new `key_id`.
4. Coordinate with the wallet team so the bundled trust anchor mirrors `static-voting-config-sample.json`.
5. Remove retired keys only after a wallet release has dropped them from its bundled trust anchor.

Steady-state rotation follows the same shape: add the new key, sign new or updated rounds with it, ship a wallet trust-anchor update, then remove the retired key after the wallet release.

## Local Verification

Install the pinned verifier from `vote-sdk`, then verify the checked-in dynamic config against the checked-in static config sample:

```bash
curl -fsSL \
  https://github.com/valargroup/vote-sdk/releases/download/v0.5.52/voting-config-linux-amd64 \
  -o voting-config
echo "730173e20fdd84258516f7741ecbe9456db9ea9962483b9c3aa402a31b313ab8  voting-config" | sha256sum -c -
chmod +x voting-config

./voting-config verify --config dynamic-voting-config.json --static-config static-voting-config-sample.json
```

## CI

Two workflows guard the dynamic-config path:

- [`verify-config.yml`](.github/workflows/verify-config.yml) runs on pull requests and pushes that touch the dynamic config, static config sample, or workflow files. It downloads the pinned `voting-config` binary from the `vote-sdk` GitHub release and runs `voting-config verify`.
- [`deploy-pages.yml`](.github/workflows/deploy-pages.yml) runs the same checks before publishing to GitHub Pages. A bad signature blocks deployment.
