# Cloudflare publication and outage runbook

This repository remains the editorial source of truth. Cloudflare Pages is the
durable serving surface. It is a direct-upload destination, not a cache in front
of GitHub. A request for `voting.valargroup.dev` must not need GitHub or
`raw.githubusercontent.com` to be reachable.

The Cloudflare workflow and infrastructure remain deliberately disabled until
the scoped credentials, Pages project, and bootstrap deployment are ready. Do
not enable or apply them from guessed or stale account identifiers.

## Ownership

| Concern | Owner | Contract |
| --- | --- | --- |
| Reviewed config | This repository's `main` branch | Pull requests, attestation, and existing config verification remain unchanged. |
| Publication | `deploy-cloudflare-pages.yml` | A merge to `main` builds and uploads one complete, allowlisted snapshot. |
| Runtime serving | Cloudflare Pages | Serves stored assets without a request-time GitHub origin. The last successful deployment remains active after a failed upload. |
| Project and domain | `vote-infrastructure` production Terraform | Owns the Pages project and, only after a separate readiness gate, `voting.valargroup.dev`. |
| Emergency publication | A scoped operator credential | Used only when GitHub cannot accept the urgent change. The same local commit must be reconciled to `main` after recovery. |

Read-only inspection on 2026-08-17 resolved `valargroup.dev` to the active
Cloudflare zone in account `152e2a8834283136c2f0575782b1b7aa`. No Pages
projects exist in that account, and `voting.valargroup.dev` has no DNS record.
The legacy `valargroup.org` zone is in a different Cloudflare account. Reconfirm
all of these facts immediately before the first infrastructure apply.

The existing `voting.valargroup.org` CNAME and GitHub Pages site remain a legacy
mirror. Clients do not select between two mutable origins. Automatic client
fallback could mix snapshots with different freshness and makes rollback
behavior ambiguous. The controlled `.dev` domain always names Cloudflare Pages.
The legacy mirror continues publishing current dynamic configs, but its
previously documented static aliases keep their exact pre-migration bytes and
checksums. It does not publish the canonical deployment manifest. New wallet
releases must not pin those mutable `.org` paths.

## Consumer migration boundary

The fleet watchdog, PIR deployment defaults, validator join tooling, and the
updated vote-sdk admin defaults use `voting.valargroup.dev`. Deploy those
changes only after the custom domain passes the readiness gate.

Repository defaults do not replace existing GitHub Environment variables or
host configuration. During rollout, update or remove the old overrides:

- vote-sdk staging and production `VOTING_CONFIG_URL` use
  `https://voting.valargroup.dev/stage/` and
  `https://voting.valargroup.dev/prod/` respectively;
- PIR `PIR_CONFIG_URL` uses the matching environment's `pir.json`, and its
  legacy `VOTING_CONFIG_URL` uses the matching static config;
- each watchdog's `WATCHDOG_CONFIG_URL` uses the matching static config.

Redeploy or restart through each repository's normal workflow, then confirm the
effective host file or application config no longer contains a GitHub Raw URL.

Vizor, zodl-ios, and the Zend iOS and Android wallets currently ship a static
config pinned to a GitHub Raw commit. Those signed binaries continue reading the
raw-hosted static file and its raw-hosted dynamic URL. Each wallet needs a
coordinated release that embeds the new immutable
`pins/<environment>/<sha256>/static-voting-config.json` URL and checksum. Do not
replace a wallet pin with the mutable `prod/static-voting-config.json` or
`stage/static-voting-config.json` alias.

Cloudflare documents direct upload from a local machine or CI, custom headers
through `_headers`, complete deployment history, and production rollback:

- <https://developers.cloudflare.com/pages/get-started/direct-upload/>
- <https://developers.cloudflare.com/pages/configuration/headers/>
- <https://developers.cloudflare.com/pages/configuration/rollbacks/>

## Snapshot contract

`scripts/build-cloudflare-pages.sh` is the only supported package builder. It:

1. Parses every production, staging, and test JSON file.
2. Requires every static config to point at the matching controlled-domain
   dynamic URL.
3. Requires a byte-for-byte immutable copy of each current static config under
   `pins/<environment>/<sha256>/`.
4. Copies an allowlist of public files. In particular, it cannot publish test
   seed material or repository metadata.
5. Generates static-config checksum sidecars and a deployment manifest with the
   source revision and the production and staging hashes.

Cloudflare Pages switches the production alias between versioned deployments.
The post-deploy check compares every served file with the package, validates the
source revision and cache headers, and confirms that the test seed returns 404.
A stale HTTP 200 response is polled until the expected bytes and headers appear
or the three-minute verification deadline expires.
A failed build or upload leaves the preceding production deployment active. If
post-deploy verification fails, the workflow calls the Pages rollback API for
the production deployment it recorded before upload. The first deployment has
no rollback target and must be verified on `pages.dev` before custom-domain
attachment.

The static and dynamic files are separate HTTP requests. A client can therefore
read them on opposite sides of a deployment. Keep old trusted keys in the new
dynamic config until all wallet releases that pin them are retired. Hosting
atomicity does not replace that trust-key overlap rule.

## Cache and stale behavior

| Path | Header | Intended behavior |
| --- | --- | --- |
| `prod/dynamic-voting-config.json`, `stage/dynamic-voting-config.json`, `pir.json`, deployment manifest | `max-age=60, must-revalidate, stale-if-error=86400` | Normal changes appear quickly. A cache that supports `stale-if-error` may reuse its last response for one day during a serving error. |
| Current static aliases and test aliases | `max-age=300, must-revalidate, stale-if-error=86400` | Server tooling can follow the current static config without long cache lag. |
| `pins/**` | `max-age=31536000, immutable` | A URL contains the file's SHA-256 and its bytes never change or disappear. |

Pages stores the last successful deployment until another deployment or an
operator rollback. This is the primary stale-config behavior during a GitHub
outage. New round publication pauses, but the previously published production
and staging snapshots continue to serve. `stale-if-error` is extra client-side
defense and is not the mechanism that removes the GitHub dependency.

## Provision and cut over

Use two separate infrastructure applies. Review each plan against the exact
Cloudflare account and `valargroup.dev` zone.

1. Reconfirm that `valargroup.dev` is active in account
   `152e2a8834283136c2f0575782b1b7aa`, that `voting.valargroup.dev` is unused,
   and that no project with the chosen name exists. Use a dedicated Terraform
   token scoped to Pages writes for only that account. Cloudflare Pages creates
   the CNAME automatically because the `.dev` zone is in the same account. If
   the named project already exists, import it into
   `cloudflare_pages_project.voting_config[0]` instead of creating a duplicate.
2. In `vote-infrastructure/envs/production`, set
   `create_voting_config_pages = true`, provide `cf_pages_api_token`, confirm
   `cf_pages_account_id`, and leave `attach_voting_config_pages_domain = false`.
   Apply this first. It creates the direct-upload project without changing DNS.
3. Configure the protected GitHub environment
   `cloudflare-pages-production`:
   - variable `CLOUDFLARE_ACCOUNT_ID`
   - variable `CLOUDFLARE_PAGES_PROJECT`
   - variable `CLOUDFLARE_PAGES_ORIGIN`, using the exact `pages.dev` URL
   - secret `CLOUDFLARE_API_TOKEN`

   Set the repository variable `CLOUDFLARE_PAGES_ENABLED=true` only after those
   protected values exist. This repository-level gate is evaluated before the
   job can read environment values.
4. From the reviewed config commit, make the one-time bootstrap deployment
   before merging the config change. Require a clean working tree, build with
   `PUBLICATION_MODE=manual-bootstrap`, deploy it to the Pages production
   branch, and verify the `pages.dev` origin with
   `scripts/verify-publication.sh`. Record the commit and deployment IDs.

   ```bash
   bootstrap_root=$(mktemp -d)
   PIN_BASE_REVISION=origin/main SOURCE_REVISION=$(git rev-parse HEAD) \
     PUBLICATION_MODE=manual-bootstrap \
     scripts/build-cloudflare-pages.sh "$bootstrap_root/site"
   npx --yes wrangler@4.123.0 pages deploy "$bootstrap_root/site" \
     --project-name "$CLOUDFLARE_PAGES_PROJECT" \
     --branch main \
     --commit-hash "$(git rev-parse HEAD)" \
     --commit-dirty=false
   scripts/verify-publication.sh "$CLOUDFLARE_PAGES_ORIGIN" \
     "$bootstrap_root/site" "$(git rev-parse HEAD)"
   ```

5. Rehearse the staging outage and rollback against the Pages origin.
6. Set `attach_voting_config_pages_domain = true` in a separately reviewed
   Terraform plan. This associates `voting.valargroup.dev` with the Pages
   project without changing the legacy `voting.valargroup.org` CNAME. A manual
   CNAME without a Pages custom-domain association is not sufficient and can
   return HTTP 522.
7. Set `CLOUDFLARE_PAGES_CUSTOM_DOMAIN=https://voting.valargroup.dev` and verify
   both the Pages origin and custom domain against the bootstrap package.
8. Merge the exact reviewed config commit through the normal pull request path.
   Confirm the automatic publisher advances the manifest to the merged revision
   without changing the config hashes.
9. Enable the external manifest uptime check and require the Cloudflare deploy
   job before relying on the domain for production.
10. Replace existing server-side URL overrides, deploy the server consumers,
   and verify their effective configuration. Then ship wallet releases with the
   new immutable Cloudflare pin. Existing wallet
   binaries whose pinned static file still points to `raw.githubusercontent.com`
   are not fixed by the new host.

Cloudflare's custom-domain setup is documented at
<https://developers.cloudflare.com/pages/configuration/custom-domains/>. The
Pages Terraform resources are documented at
<https://developers.cloudflare.com/api/terraform/resources/pages/subresources/projects/>.

## Normal publication

The round attestation workflow continues opening its one-file GitHub pull
request. After it merges, the Cloudflare workflow:

1. Repeats the cryptographic config verification.
2. Builds the complete production and staging snapshot.
3. Direct-uploads the snapshot to the production branch of the Pages project.
4. Compares every important served object with the local package.

Immediately before upload, after preloading Wrangler, the workflow queries the
Cloudflare API for the then-current production deployment and reads the
manifest from that deployment's immutable Pages URL. Its source revision must
be an ancestor of the `main` revision being published. The earlier deployment
record is used only as a rollback target. This prevents a queued run from
relying on state captured before a manual emergency deployment landed.

Do not publish individual JSON objects. An upload failure leaves the preceding
snapshot active and should be treated as a delayed publication, not as permission
to bypass verification.

## Emergency publication while GitHub is unavailable

Use this only when an urgent config change cannot wait for GitHub recovery. A
GitHub outage by itself does not require a republish because Pages continues
serving the last good snapshot.

1. Start from the source revision named by the live
   `deployment-manifest.json` and save that exact SHA as
   `published_revision`.
2. Make the smallest config change locally and run the same `voting-config
   verify` commands as CI. Obtain the normal maintainer review outside GitHub.
3. Create a local commit so the emergency deployment has an immutable source
   revision. Ensure `git status --short` is empty.
4. Load a narrowly scoped operator token from macOS Keychain or a dedicated
   operator Infisical project. Do not place it in a production service's shared
   secret root, and do not print it.
5. Build and deploy the complete snapshot:

```bash
emergency_root=$(mktemp -d)
PIN_BASE_REVISION="$published_revision" SOURCE_REVISION=$(git rev-parse HEAD) \
  PUBLICATION_MODE=manual-emergency \
  scripts/build-cloudflare-pages.sh "$emergency_root/site"

npx --yes wrangler@4.123.0 pages deploy "$emergency_root/site" \
  --project-name "$CLOUDFLARE_PAGES_PROJECT" \
  --branch main \
  --commit-hash "$(git rev-parse HEAD)" \
  --commit-dirty=false

scripts/verify-publication.sh "$CLOUDFLARE_PAGES_ORIGIN" \
  "$emergency_root/site" "$(git rev-parse HEAD)"
scripts/verify-publication.sh https://voting.valargroup.dev \
  "$emergency_root/site" "$(git rev-parse HEAD)"
```

Record the Cloudflare deployment ID and local commit SHA. When GitHub recovers,
push the exact commit through the normal pull request path. Do not recreate the
change by hand. If the eventual reviewed result differs, deploy that complete
snapshot and record which emergency deployment it superseded.
Automatic publication remains blocked until the live emergency commit is an
ancestor of `main`.

## Monitoring

Before custom-domain cutover, all of these must be active:

- The fleet watchdog's existing `config_refresh` check reads the environment's
  static config and follows its controlled-domain dynamic URL. The Sentry event
  must retain `service=watchdog`, `alert=infra_health`, and
  `check=config_refresh` routing.
- A watchdog JSON target and a Sentry Uptime monitor fetch
  `https://voting.valargroup.dev/deployment-manifest.json` independently of the
  GitHub Actions runner.
- Publication alerts fire when the Cloudflare workflow fails or when the live
  manifest does not reach the merged source revision within 15 minutes.
- The monitor fetches both production and staging static and dynamic paths. It
  checks HTTP 200, JSON decoding, manifest hashes, and CORS.

Do not resolve a publication alert merely because GitHub recovered. Compare the
live manifest revision and hashes with the intended snapshot first.

## Rollback

Cloudflare Pages keeps successful deployments. Select the preceding verified
deployment in the Pages dashboard or call the documented deployment rollback
API, then run `scripts/verify-publication.sh` against the package for that
deployment. Rollback changes the whole production and staging snapshot.

If the automatic rollback call itself fails, keep the publication alert open,
roll back from a separately authenticated operator path, and verify the complete
preceding package. Do not silently switch clients to the legacy `.org` mirror.

After GitHub recovers, reconcile `main` with a normal revert or fix-forward pull
request. Until that happens, a source-revision monitor should intentionally show
that the serving revision differs from the tip of `main`.

Cloudflare's rollback API is documented at
<https://developers.cloudflare.com/api/resources/pages/subresources/projects/subresources/deployments/>.

## Outage rehearsal

Run the rehearsal against the `pages.dev` origin first, then the custom domain:

```bash
rehearsal_root=$(mktemp -d)
SOURCE_REVISION=local-test PUBLICATION_MODE=local-test \
  scripts/build-cloudflare-pages.sh "$rehearsal_root/site"

scripts/rehearse-github-outage.sh "$CLOUDFLARE_PAGES_ORIGIN" \
  "$rehearsal_root/site"
scripts/rehearse-github-outage.sh https://voting.valargroup.dev \
  "$rehearsal_root/site"
```

The script forces only its GitHub Raw probe to loopback, proves that request
fails, and then verifies the complete Cloudflare snapshot. It does not change
DNS or `/etc/hosts`.

For the stage gate, also restart the staging watchdog with its normal
`WATCHDOG_CONFIG_URL=https://voting.valargroup.dev/stage/static-voting-config.json`
and confirm its immediate `config_refresh` succeeds while outbound GitHub Raw is
blocked for that isolated test process or container. Wait through the alert
grace period and confirm no config-refresh Sentry issue is created. Then deploy
a harmless stage-only snapshot, roll it back in Pages, and confirm the manifest
and stage bytes return to the preceding deployment. Repeat the read-only
availability checks in production before declaring the cutover complete.
