# Cloudflare publication and outage runbook

`main` in this repository is the only source of truth for voting config.
Cloudflare Pages stores and serves reviewed snapshots; it is not a cache in
front of GitHub. Requests to `voting.valargroup.dev` do not need GitHub or
`raw.githubusercontent.com` to be available.

There is one publication path. A GitHub Actions job triggered by `main` builds
and uploads the complete snapshot. Operators do not publish config directly to
Cloudflare. During a GitHub outage, Cloudflare continues serving its current
snapshot, but new config publication waits for GitHub to recover.

## Ownership

| Concern | Owner |
| --- | --- |
| Reviewed config and publication authority | This repository's `main` branch |
| Snapshot packaging and upload | `.github/workflows/deploy-cloudflare-pages.yml` |
| Pages project, custom domain, and DNS | Production Terraform in `vote-infrastructure` |
| Stored snapshot and request serving | Cloudflare Pages |
| Legacy `.org` mirror | This repository's GitHub Pages workflows |

Before any infrastructure change, resolve the exact Cloudflare account,
project, zone, and current Terraform state. The intended project is
`token-holder-voting-config` in the account that owns `valargroup.dev`; the
custom domain is `voting.valargroup.dev`. Import an existing live resource into
Terraform rather than creating a duplicate.

The existing `voting.valargroup.org` GitHub Pages site remains a compatibility
mirror, not an automatic fallback. Its previously published static aliases keep
their original bytes and checksums so existing Vizor, zodl, and other pinned
callers are not broken. Its dynamic aliases continue to update. New consumers
must use Cloudflare, because client fallback between two mutable hosts could mix
snapshots with different freshness.

## Snapshot contract

`scripts/build-cloudflare-pages.sh` is the only snapshot builder. It:

1. Requires a clean checkout whose `SOURCE_REVISION` is exactly `HEAD`.
2. Validates all production, staging, and test JSON, including the PIR schema.
3. Requires static configs to use the matching `voting.valargroup.dev` dynamic
   URL.
4. Requires a content-addressed copy of every current static config under
   `pins/` and rejects deletion of any pin found in reachable repository
   history.
5. Runs compatibility verification against every immutable pin and frozen
   legacy alias.
6. Copies only the public allowlist, adds checksum sidecars, and writes a
   manifest containing the exact source revision and config hashes.

CI uses full Git history so the immutable-pin check cannot be weakened by a
caller-selected comparison revision. `SOURCE_REVISION=local-test` exists only
for local fixture builds; the deployment workflow never uses it.

Cloudflare Pages creates a versioned deployment and changes the production
alias as one operation. Individual JSON files are never uploaded separately,
so readers see either the preceding snapshot or the new complete snapshot, not
a partially copied directory. Static and dynamic files are still separate HTTP
requests. Keep old trusted keys in a new dynamic config until every client that
pins them has retired.

The manifest is evidence about the repository commit and file hashes. It does
not grant publication authority and does not need reconciliation with an older
bootstrap deployment. The first enabled workflow run intentionally supersedes
the existing bootstrap with the reviewed `main` snapshot.

## Cache and stale behavior

| Path | Cache-Control | Behavior |
| --- | --- | --- |
| Dynamic configs, PIR configs, manifest | `max-age=60, must-revalidate, stale-if-error=86400` | Changes appear quickly; caches may reuse a response during a serving error. |
| Current static aliases and test aliases | `max-age=300, must-revalidate, stale-if-error=86400` | Mutable aliases refresh within five minutes. |
| `pins/**` | `max-age=31536000, immutable` | The URL contains the file SHA-256 and its bytes cannot change or disappear. |

The durable outage behavior comes from the stored Pages deployment, not from
`stale-if-error`. A GitHub outage pauses updates but does not affect reads from
the active Cloudflare snapshot.

## Enable the publisher

The Pages resource and GitHub publisher have separate ownership. Complete these
checks before setting `CLOUDFLARE_PAGES_ENABLED=true`:

1. Confirm the Pages project, domain association, and DNS record match the
   reviewed `vote-infrastructure` Terraform state.
2. Confirm the protected GitHub environment `cloudflare-pages-production` has:
   - `CLOUDFLARE_ACCOUNT_ID`
   - `CLOUDFLARE_PAGES_PROJECT`
   - `CLOUDFLARE_PAGES_ORIGIN`
   - `CLOUDFLARE_PAGES_CUSTOM_DOMAIN`
   - a scoped `CLOUDFLARE_API_TOKEN` secret
3. Confirm `main` contains the publisher and all required checks pass.
4. Enable the repository gate and dispatch the workflow from `main` once.
5. Verify the Pages origin and `https://voting.valargroup.dev` report the
   dispatched source revision in `deployment-manifest.json`.
6. Run the outage rehearsal before migrating server consumers.

After enablement, every new `main` revision triggers the same workflow. The
concurrency group serializes publishers, and a freshness check skips a queued
revision when a newer `main` already exists.

## Normal publication

The round attestation flow continues opening its normal one-file pull request.
After that pull request merges, the Cloudflare workflow:

1. Repeats signature and compatibility verification.
2. Builds one complete production, staging, test, and immutable-pin snapshot.
3. Confirms the checked-out commit is still the latest `main` revision.
4. Direct-uploads that snapshot to the Pages production branch.
5. Polls the Pages origin and custom domain until all expected bytes, manifest
   metadata, cache headers, CORS, and the absence of test seed material are
   verified.

No second writer or emergency upload path exists. If an urgent config change is
needed while GitHub cannot accept it, continue serving the current snapshot and
wait for GitHub recovery. Then use the normal reviewed pull request flow.

## Failure and rollback

Failure semantics depend on where the job stopped:

- A validation, build, freshness, or pre-upload failure leaves Cloudflare
  unchanged.
- A rejected or interrupted upload normally leaves the previous deployment
  active. Confirm the live manifest instead of assuming this.
- An accepted upload switches to one complete snapshot. If post-deploy
  verification fails, the workflow is red but the new deployment may already
  be active. It is never a partial directory, but its headers or served bytes
  may not match the package.

Post-deploy failure requires operator investigation; the workflow does not
automatically roll back. This keeps rollback out of the publication state
machine and avoids racing a valid deployment. Disable the repository publisher
gate while investigating and inspect the live manifest and Pages deployment
history.

Do not use Pages deployment-history rollback. An older artifact does not contain
pins added by later wallet releases, so restoring it can turn an immutable URL
into a 404. Roll back through a new reviewed `main` revision instead:

1. Start from the latest `main`, not the historical deployment commit.
2. Restore the mutable config or publication code to the last known good
   behavior. Keep every file under `pins/`, including pins introduced by the
   revision being corrected. A plain revert that deletes a pin is invalid.
3. Merge the correction through the normal pull request and verification flow.
4. Re-enable the publisher gate and dispatch the workflow from the corrective
   `main` revision.
5. Verify both domains against the new package and confirm every repository pin
   still returns its expected bytes.

This creates a new complete snapshot with the desired older mutable behavior and
the full current pin set. Do not publish it directly from an operator machine or
switch clients to `.org`. If GitHub is unavailable, wait for recovery rather
than bypassing the single-writer model.

## Monitoring

Before migrating server consumers, require all of the following:

- GitHub Actions alerts for a failed Cloudflare publication.
- An external uptime check for
  `https://voting.valargroup.dev/deployment-manifest.json`.
- A manifest-lag alert when the live source revision does not reach merged
  `main` within 15 minutes.
- Checks that fetch production and staging static, dynamic, and PIR paths,
  validate JSON and manifest hashes, and confirm CORS.
- Existing watchdog `config_refresh` checks pointed at the matching Cloudflare
  environment.

Do not close an alert merely because GitHub or Cloudflare recovered. Compare the
live source revision and hashes with the intended snapshot first.

## Outage rehearsal

Build a package from the same source revision and publication time as the live
manifest, then test the Pages origin and custom domain:

```bash
rehearsal_root=$(mktemp -d)
SOURCE_REVISION=<live_source_revision> PUBLISHED_AT=<live_published_at> \
  scripts/build-cloudflare-pages.sh "$rehearsal_root/site"

scripts/rehearse-github-outage.sh "$CLOUDFLARE_PAGES_ORIGIN" \
  "$rehearsal_root/site"
scripts/rehearse-github-outage.sh https://voting.valargroup.dev \
  "$rehearsal_root/site"
```

The rehearsal isolates its GitHub Raw probe and then verifies the complete
Cloudflare snapshot. It does not change DNS or `/etc/hosts`.

For the stage gate, restart the staging watchdog with
`WATCHDOG_CONFIG_URL=https://voting.valargroup.dev/stage/static-voting-config.json`
while GitHub Raw is blocked for that isolated process. Confirm config refresh
succeeds and no Sentry issue is created through the normal grace period.

## Consumer migration

Server consumers may use the mutable environment aliases after the publication
and monitoring gates pass:

- production `VOTING_CONFIG_URL` uses
  `https://voting.valargroup.dev/prod/`;
- staging `VOTING_CONFIG_URL` uses
  `https://voting.valargroup.dev/stage/`;
- PIR and watchdog URLs use the matching environment's `pir.json` and static
  config.

Wallets must embed the immutable
`pins/<environment>/<sha256>/static-voting-config.json` URL and matching
checksum. Existing Vizor and zodl builds pinned to GitHub Raw keep working and
are not changed by this deployment, but they remain exposed to a GitHub outage
until a new app release adopts the Cloudflare pin.

Cloudflare reference documentation:

- <https://developers.cloudflare.com/pages/get-started/direct-upload/>
- <https://developers.cloudflare.com/pages/configuration/headers/>
- <https://developers.cloudflare.com/pages/configuration/custom-domains/>
