# manifest-signers

Public keys of every operator authorized to sign `round_signatures` and
`checkpoints/latest.json` for this CDN. Each `.pub` file is a base64-encoded
32-byte ed25519 public key.

These pubkeys ALSO live in every wallet bundle (under `manifest_signers[]` in
the build-time trust anchor — see
[vote-sdk/docs/config.md](https://github.com/valargroup/vote-sdk/blob/main/docs/config.md)).
This directory exists for repository-side auditability and for the CI
validator script (`scripts/validate-config.mjs`) to authenticate freshly
committed `voting-config.json` and `checkpoints/*.json` files at PR time.

| File                | Signer id      | Status                                                                    |
| ------------------- | -------------- | ------------------------------------------------------------------------- |
| `valarg-poc.pub`    | `valarg-poc`   | **POC ONLY.** Used for `voting-config.example.json`. Replace before mainnet. |

## Adding a new signer

1. The new signer runs `manifest-signer keygen` per
   [vote-sdk/docs/runbooks/key-rotation.md](https://github.com/valargroup/vote-sdk/blob/main/docs/runbooks/key-rotation.md).
2. They submit their `<id>.pub` file in a PR, with the `pubkey_sha256`
   fingerprint readout posted in the PR description.
3. A maintainer cross-checks the fingerprint against the value the signer
   communicates over a separate channel (voice or video).
4. After merge, wallet maintainers add the same pubkey to the next wallet
   release and bump `k_required` accordingly. Both must ship before the
   signer's signatures count toward the wallet-side k threshold.

Removing a signer follows the same flow in reverse — see the rotation runbook.

## Why these are not auto-trusted by wallets

Adding a `.pub` here does NOT authorize a new signer at any wallet. Wallets'
trust anchor is compiled into the binary at build time, so the wallet release
pipeline is the bottleneck. This directory is a documentation+CI artifact, not
a runtime authority.
